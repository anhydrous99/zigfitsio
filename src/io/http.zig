//! Read-only `Device` backend over `std.http.Client` HTTP(S) Range GETs (FR-RMT-3, §8.1).
//!
//! Serves a remote FITS file as a seekable, read-only `Device`: each `pread` is an
//! HTTP `Range: bytes=a-b` request whose `206 Partial Content` body is copied into the
//! caller's buffer. Writes are unsupported (`error.NotWritable`). Like `io/file.zig` this is
//! an OS/network-backed leaf: it owns a single-threaded `std.Io.Threaded` and a
//! `std.http.Client`, and it is deliberately excluded from the `wasm32-freestanding` build
//! graph (see `src/wasm_check.zig`). All `std.http`/`std.Uri` failures are mapped to the
//! `IoError` set — neither `anyerror` nor `std.http` error types ever escape.
//!
//! Fallback for servers that ignore `Range`: if a ranged GET answers `200 OK` (whole body),
//! the body is downloaded once into an internal `MemoryDevice` and all further `pread`s are
//! served from that in-memory copy. The selected representation is requested with identity
//! encoding, and its size is learned once and cached for the lifetime of the device.
const std = @import("std");
const IoError = @import("../errors.zig").IoError;
const Device = @import("device.zig").Device;
const MemoryDevice = @import("memory.zig").MemoryDevice;

/// Errors that can occur opening an `HttpDevice`.
pub const OpenError = IoError || std.mem.Allocator.Error;

/// A heap-allocated, pinned read-only `Device` backed by a remote HTTP(S) URL. Created by
/// `open`; released by `Device.close` (which frees this struct), so the owner just holds the
/// `Device`.
pub const HttpDevice = struct {
    alloc: std.mem.Allocator,
    threaded: std.Io.Threaded,
    client: std.http.Client,
    /// Owned copy of the target URL (re-parsed per request; `std.Uri` borrows this string).
    url: []u8,
    /// Whole-file cache, populated when the server ignores `Range` (200 fallback) or when
    /// the size can only be learned by downloading the body.
    cache: ?MemoryDevice = null,
    /// Object size learned from a successful HEAD, Content-Range, or whole-body response.
    /// Stable for this device's lifetime; close and reopen to refresh remote metadata.
    known_size: ?u64 = null,
    /// Upper bound on a whole-body download into `cache`, so a server that ignores `Range` and
    /// streams a huge/endless `200 OK` body cannot grow memory without limit (NFR-SAFE-1).
    /// Defaults to the `Limits.max_open_alloc` default (4 GiB); tune on the struct if needed.
    max_cache_bytes: u64 = 1 << 32,
    /// Scratch for `receiveHead` redirect following.
    redirect_buf: [16 * 1024]u8 = undefined,
    /// Scratch for the body reader.
    transfer_buf: [64 * 1024]u8 = undefined,

    /// Open `url` (http or https) as a read-only device. No request is issued here; the first
    /// connection is made lazily on the first `pread`/`getSize`. A malformed URL is
    /// `error.ReadFailed`.
    pub fn open(allocator: std.mem.Allocator, url: []const u8) OpenError!Device {
        _ = std.Uri.parse(url) catch return error.ReadFailed;
        const self = try allocator.create(HttpDevice);
        errdefer allocator.destroy(self);
        const url_copy = try allocator.dupe(u8, url);
        errdefer allocator.free(url_copy);
        self.* = .{
            .alloc = allocator,
            .threaded = .init_single_threaded,
            .client = undefined,
            .url = url_copy,
        };
        self.client = .{ .allocator = allocator, .io = self.threaded.io() };
        return .{ .ptr = self, .vtable = &ro_vtable };
    }

    fn uri(self: *HttpDevice) IoError!std.Uri {
        return std.Uri.parse(self.url) catch error.ReadFailed;
    }

    // ── Device vtable ──────────────────────────────────────────────────────────────────

    fn pread(ctx: *anyopaque, buf: []u8, offset: u64) IoError!usize {
        const self: *HttpDevice = @ptrCast(@alignCast(ctx));
        if (buf.len == 0) return 0;
        if (self.cache) |*c| return cachePread(c, buf, offset);
        var read_len = buf.len;
        if (self.known_size) |size| {
            if (offset >= size) return 0;
            read_len = @intCast(@min(@as(u64, buf.len), size - offset));
        }
        // An offset whose byte range would overflow u64 is past any possible EOF; report 0
        // (end-of-stream) like the other backends rather than overflowing in formatRange.
        if (offset > std.math.maxInt(u64) - read_len) return 0;

        var range_buf: [64]u8 = undefined;
        const range = formatRange(&range_buf, offset, read_len);
        const u = try self.uri();
        var req = self.client.request(.GET, u, .{
            .keep_alive = true,
            .headers = identityHeaders(),
            .extra_headers = &.{.{ .name = "range", .value = range }},
        }) catch return error.ReadFailed;
        defer req.deinit();
        req.sendBodiless() catch return error.ReadFailed;
        var resp = req.receiveHead(&self.redirect_buf) catch return error.ReadFailed;
        if (resp.head.content_encoding != .identity) return error.ReadFailed;
        switch (resp.head.status) {
            // The expected case: the body is exactly the requested byte range.
            .partial_content => {
                const parsed = contentRange(&resp) orelse return error.ReadFailed;
                const validated = validateSatisfiedRange(parsed, offset, read_len) orelse
                    return error.ReadFailed;
                if (resp.head.content_length) |len| {
                    if (len != validated.span) return error.ReadFailed;
                }
                if (validated.total) |total| try self.ensureSizeCompatible(total);
                const r = resp.reader(&self.transfer_buf);
                const response_len: usize = @intCast(validated.span);
                r.readSliceAll(buf[0..response_len]) catch return error.ReadFailed;
                if (validated.total) |total| _ = try self.recordSize(total);
                return response_len;
            },
            // The server ignored `Range` and sent the whole file: cache it and serve locally.
            .ok => {
                try self.fillCacheFrom(&resp);
                return cachePread(&self.cache.?, buf, offset);
            },
            // Requested range starts past end-of-file: learn the current size when supplied.
            .range_not_satisfiable => {
                const parsed = contentRange(&resp) orelse return error.ReadFailed;
                const total = switch (parsed) {
                    .unsatisfied => |n| n,
                    .satisfied => return error.ReadFailed,
                };
                if (offset < total) return error.ReadFailed;
                _ = try self.recordSize(total);
                return 0;
            },
            else => return error.ReadFailed,
        }
    }

    fn getSize(ctx: *anyopaque) IoError!u64 {
        const self: *HttpDevice = @ptrCast(@alignCast(ctx));
        if (self.cache) |*c| return c.bytes().len;
        if (self.known_size) |size| return size;
        const u = try self.uri();

        // Primary: a HEAD request and its Content-Length.
        {
            var req = self.client.request(.HEAD, u, .{
                .keep_alive = true,
                .headers = identityHeaders(),
            }) catch return error.ReadFailed;
            defer req.deinit();
            req.sendBodiless() catch return error.ReadFailed;
            const resp = req.receiveHead(&self.redirect_buf) catch return error.ReadFailed;
            if (resp.head.content_encoding != .identity) return error.ReadFailed;
            if (resp.head.status == .ok) {
                if (resp.head.content_length) |len| {
                    return self.recordSize(len);
                }
            }
        }

        // Secondary: a one-byte ranged GET and the total in its Content-Range header.
        {
            var range_buf: [64]u8 = undefined;
            const range = formatRange(&range_buf, 0, 1);
            var req = self.client.request(.GET, u, .{
                .keep_alive = true,
                .headers = identityHeaders(),
                .extra_headers = &.{.{ .name = "range", .value = range }},
            }) catch return error.ReadFailed;
            defer req.deinit();
            req.sendBodiless() catch return error.ReadFailed;
            var resp = req.receiveHead(&self.redirect_buf) catch return error.ReadFailed;
            if (resp.head.content_encoding != .identity) return error.ReadFailed;
            switch (resp.head.status) {
                .partial_content => {
                    const parsed = contentRange(&resp) orelse return error.ReadFailed;
                    const validated = validateSatisfiedRange(parsed, 0, 1) orelse
                        return error.ReadFailed;
                    if (resp.head.content_length) |len| {
                        if (len != validated.span) return error.ReadFailed;
                    }
                    if (validated.total) |total| return self.recordSize(total);
                },
                .range_not_satisfiable => {
                    const parsed = contentRange(&resp) orelse return error.ReadFailed;
                    const total = switch (parsed) {
                        .unsatisfied => |n| n,
                        .satisfied => return error.ReadFailed,
                    };
                    if (total != 0) return error.ReadFailed;
                    return self.recordSize(0);
                },
                // Reuse the body already returned by a server that ignored Range rather than
                // discarding it and issuing a second full GET.
                .ok => {
                    try self.fillCacheFrom(&resp);
                    return self.cache.?.bytes().len;
                },
                else => {},
            }
        }

        // Fallback: download the whole body once and report its length.
        try self.fetchFull();
        return self.cache.?.bytes().len;
    }

    fn syncFn(_: *anyopaque) IoError!void {}

    fn closeFn(ctx: *anyopaque) void {
        const self: *HttpDevice = @ptrCast(@alignCast(ctx));
        if (self.cache) |*c| c.deinit();
        self.client.deinit();
        self.threaded.deinit();
        self.alloc.free(self.url);
        self.alloc.destroy(self);
    }

    // ── Helpers ────────────────────────────────────────────────────────────────────────

    /// Issue a plain (un-ranged) GET and buffer the whole body into `self.cache`.
    fn fetchFull(self: *HttpDevice) IoError!void {
        const u = try self.uri();
        var req = self.client.request(.GET, u, .{
            .keep_alive = true,
            .headers = identityHeaders(),
        }) catch return error.ReadFailed;
        defer req.deinit();
        req.sendBodiless() catch return error.ReadFailed;
        var resp = req.receiveHead(&self.redirect_buf) catch return error.ReadFailed;
        if (resp.head.status != .ok or resp.head.content_encoding != .identity)
            return error.ReadFailed;
        try self.fillCacheFrom(&resp);
    }

    /// Drain the remaining body of `resp` into a fresh `MemoryDevice` stored in `self.cache`.
    fn fillCacheFrom(self: *HttpDevice, resp: *std.http.Client.Response) IoError!void {
        if (resp.head.content_encoding != .identity) return error.ReadFailed;
        if (resp.head.content_length) |len| {
            if (len > self.max_cache_bytes) return error.DeviceFull;
        }
        var mem = MemoryDevice.init(self.alloc);
        errdefer mem.deinit();
        const dev = mem.device();
        const r = resp.reader(&self.transfer_buf);
        var tmp: [16 * 1024]u8 = undefined;
        var pos: u64 = 0;
        while (true) {
            const n = r.readSliceShort(&tmp) catch return error.ReadFailed;
            if (n == 0) break;
            // Bound the download: a server that ignores Range and streams a huge/endless body
            // must not grow the cache without limit (NFR-SAFE-1).
            if (n > self.max_cache_bytes - pos) return error.DeviceFull;
            try dev.writeAll(tmp[0..n], pos);
            pos += n;
        }
        _ = try self.recordSize(pos);
        self.cache = mem; // ownership moves into self; errdefer above no longer fires
    }

    /// Record one authoritative size observation without allowing a later response to silently
    /// switch this seekable handle to a different representation.
    fn recordSize(self: *HttpDevice, observed: u64) IoError!u64 {
        try self.ensureSizeCompatible(observed);
        if (self.known_size) |known| return known;
        self.known_size = observed;
        return observed;
    }

    fn ensureSizeCompatible(self: *const HttpDevice, observed: u64) IoError!void {
        if (self.known_size) |known| {
            if (known != observed) return error.ReadFailed;
        }
    }

    /// Serve a `pread` from the in-memory cache.
    fn cachePread(mem: *MemoryDevice, buf: []u8, offset: u64) IoError!usize {
        return mem.device().pread(buf, offset);
    }

    const ro_vtable: Device.VTable = .{
        .pread = pread,
        .pwrite = null,
        .getSize = getSize,
        .setSize = null,
        .sync = syncFn,
        .close = closeFn,
    };
};

// ── Deterministic, network-free logic (unit-tested directly) ───────────────────────────

fn identityHeaders() std.http.Client.Request.Headers {
    return .{ .accept_encoding = .{ .override = "identity" } };
}

/// Format an HTTP byte-range header value `"bytes=<offset>-<offset+len-1>"` into `buf`.
/// Asserts `len > 0`; `buf` must hold at least 47 bytes (it always does at the call sites).
fn formatRange(buf: []u8, offset: u64, len: usize) []const u8 {
    std.debug.assert(len > 0);
    // Saturating: a near-u64-max offset+len must not integer-overflow panic. The resulting
    // range lies past any real EOF, so the server answers range_not_satisfiable → pread 0.
    const end = (offset +| @as(u64, len)) -| 1;
    return std.fmt.bufPrint(buf, "bytes={d}-{d}", .{ offset, end }) catch unreachable;
}

const ContentRange = union(enum) {
    satisfied: struct { first: u64, last: u64, total: ?u64 },
    unsatisfied: u64,
};

/// Parse RFC Content-Range byte forms: `bytes first-last/total`, `bytes first-last/*`, and
/// the unsatisfied-range form `bytes */total`.
fn parseContentRange(value: []const u8) ?ContentRange {
    const trimmed = std.mem.trim(u8, value, " \t");
    var unit_end: usize = 0;
    while (unit_end < trimmed.len and trimmed[unit_end] != ' ' and trimmed[unit_end] != '\t')
        unit_end += 1;
    if (unit_end == trimmed.len or !std.ascii.eqlIgnoreCase(trimmed[0..unit_end], "bytes"))
        return null;
    const spec = std.mem.trimStart(u8, trimmed[unit_end..], " \t");
    const slash = std.mem.indexOfScalar(u8, spec, '/') orelse return null;
    if (std.mem.indexOfScalar(u8, spec[slash + 1 ..], '/') != null) return null;

    const range_part = std.mem.trim(u8, spec[0..slash], " \t");
    const total_part = std.mem.trim(u8, spec[slash + 1 ..], " \t");
    if (range_part.len == 0 or total_part.len == 0) return null;

    if (std.mem.eql(u8, range_part, "*")) {
        if (std.mem.eql(u8, total_part, "*")) return null;
        return .{ .unsatisfied = std.fmt.parseInt(u64, total_part, 10) catch return null };
    }

    const dash = std.mem.indexOfScalar(u8, range_part, '-') orelse return null;
    if (std.mem.indexOfScalar(u8, range_part[dash + 1 ..], '-') != null) return null;
    const first = std.fmt.parseInt(u64, std.mem.trim(u8, range_part[0..dash], " \t"), 10) catch
        return null;
    const last = std.fmt.parseInt(u64, std.mem.trim(u8, range_part[dash + 1 ..], " \t"), 10) catch
        return null;
    if (last < first) return null;

    const total: ?u64 = if (std.mem.eql(u8, total_part, "*")) null else (std.fmt.parseInt(u64, total_part, 10) catch return null);
    if (total) |n| {
        if (last >= n) return null;
    }
    return .{ .satisfied = .{ .first = first, .last = last, .total = total } };
}

/// Scan a response's headers for a parsed `Content-Range` value.
/// Must be called before `resp.reader(...)` (which invalidates the header bytes).
fn contentRange(resp: *std.http.Client.Response) ?ContentRange {
    var it = std.http.HeaderIterator.init(resp.head.bytes);
    while (it.next()) |h| {
        if (std.ascii.eqlIgnoreCase(h.name, "content-range"))
            return parseContentRange(h.value);
    }
    return null;
}

const ValidatedRange = struct { span: u64, total: ?u64 };

/// Validate that a satisfied Content-Range begins at the requested offset and does not extend
/// beyond the requested end. Servers may intentionally cap a response to a smaller subrange.
fn validateSatisfiedRange(parsed: ContentRange, offset: u64, len: usize) ?ValidatedRange {
    const range = switch (parsed) {
        .satisfied => |r| r,
        .unsatisfied => return null,
    };
    if (range.first != offset or len == 0) return null;
    const requested_last = offset + @as(u64, len) - 1;
    if (range.last > requested_last) return null;
    return .{ .span = range.last - range.first + 1, .total = range.total };
}

const testing = std.testing;

test "formatRange builds a correct bytes= header" {
    var buf: [64]u8 = undefined;
    try testing.expectEqualStrings("bytes=0-99", formatRange(&buf, 0, 100));
    try testing.expectEqualStrings("bytes=2880-5759", formatRange(&buf, 2880, 2880));
    // Single-byte range (used by the size probe).
    try testing.expectEqualStrings("bytes=0-0", formatRange(&buf, 0, 1));
    // 64-bit offset is not truncated.
    const huge: u64 = (3 << 30) + 5;
    try testing.expectEqualStrings("bytes=3221225477-3221225484", formatRange(&buf, huge, 8));
    // Regression: a near-u64-max offset+len must saturate, not integer-overflow panic.
    const max = std.math.maxInt(u64);
    _ = formatRange(&buf, max, 1);
    _ = formatRange(&buf, max - 2, 8);
}

test "parseContentRange validates satisfied and unsatisfied byte ranges" {
    try testing.expectEqualDeep(
        ContentRange{ .satisfied = .{ .first = 0, .last = 99, .total = 12345 } },
        parseContentRange("bytes 0-99/12345").?,
    );
    try testing.expectEqualDeep(
        ContentRange{ .satisfied = .{ .first = 0, .last = 0, .total = null } },
        parseContentRange("BYTES 0-0/*").?,
    );
    try testing.expectEqualDeep(ContentRange{ .unsatisfied = 0 }, parseContentRange(" bytes */0 ").?);

    try testing.expectEqual(@as(?ContentRange, null), parseContentRange("items 0-99/12345"));
    try testing.expectEqual(@as(?ContentRange, null), parseContentRange("bytes 99-0/12345"));
    try testing.expectEqual(@as(?ContentRange, null), parseContentRange("bytes 0-99/99"));
    try testing.expectEqual(@as(?ContentRange, null), parseContentRange("bytes */*"));
    try testing.expectEqual(@as(?ContentRange, null), parseContentRange("bytes 0-99/1/2"));
    try testing.expectEqual(@as(?ContentRange, null), parseContentRange("bytes 0-99/abc"));
    try testing.expectEqual(@as(?ContentRange, null), parseContentRange("bytes 0-99/18446744073709551616"));
}

test "validateSatisfiedRange accepts exact and EOF-shortened responses" {
    const exact = parseContentRange("bytes 10-19/100").?;
    try testing.expectEqualDeep(
        ValidatedRange{ .span = 10, .total = 100 },
        validateSatisfiedRange(exact, 10, 10).?,
    );
    const shortened = parseContentRange("bytes 90-99/100").?;
    try testing.expectEqualDeep(
        ValidatedRange{ .span = 10, .total = 100 },
        validateSatisfiedRange(shortened, 90, 20).?,
    );
    try testing.expectEqual(@as(?ValidatedRange, null), validateSatisfiedRange(exact, 11, 10));
    try testing.expectEqualDeep(
        ValidatedRange{ .span = 10, .total = 100 },
        validateSatisfiedRange(exact, 10, 20).?,
    );
    try testing.expectEqual(@as(?ValidatedRange, null), validateSatisfiedRange(exact, 10, 5));
}

test "recordSize memoizes zero and rejects conflicting observations" {
    const dev = try HttpDevice.open(testing.allocator, "http://example.invalid/data.fits");
    defer dev.close();
    const http: *HttpDevice = @ptrCast(@alignCast(dev.ptr));

    try testing.expectEqual(@as(u64, 0), try http.recordSize(0));
    try testing.expectEqual(@as(u64, 0), try http.recordSize(0));
    try testing.expectError(error.ReadFailed, http.recordSize(1));
    try testing.expectEqual(@as(?u64, 0), http.known_size);
    // A memoized getSize must stay network-free even though the URL cannot resolve.
    try testing.expectEqual(@as(u64, 0), try dev.getSize());
}

test "open/close round-trip is leak-free and read-only (no network)" {
    // `open` only parses the URL; no request is issued until the first read, so this
    // exercises the allocate/free + vtable wiring without touching the network.
    const dev = try HttpDevice.open(testing.allocator, "http://example.invalid/data.fits");
    defer dev.close();
    try testing.expect(!dev.isWritable());
    try testing.expectError(error.NotWritable, dev.writeAll("x", 0));
    try testing.expectError(error.NotWritable, dev.setSize(0));
}

test "open rejects a malformed URL" {
    try testing.expectError(error.ReadFailed, HttpDevice.open(testing.allocator, "http://[::bad"));
}

const LoopbackScript = enum {
    head_size,
    large_head_size,
    range_size,
    zero_range_size,
    read_seeds_size,
    no_range_fallback,
    truncated_chunked,
    truncated_fixed,
    range_limited,
};

const LoopbackContext = struct {
    io: std.Io,
    listener: *std.Io.net.Server,
    script: LoopbackScript,
    head_count: usize = 0,
    get_count: usize = 0,
    err_name: ?[]const u8 = null,
};

fn requestHeader(req: *const std.http.Server.Request, name: []const u8) ?[]const u8 {
    var it = req.iterateHeaders();
    while (it.next()) |header| {
        if (std.ascii.eqlIgnoreCase(header.name, name)) return header.value;
    }
    return null;
}

fn checkLoopbackRequest(
    req: *const std.http.Server.Request,
    method: std.http.Method,
    range: ?[]const u8,
) !void {
    if (req.head.method != method) return error.UnexpectedMethod;
    const encoding = requestHeader(req, "accept-encoding") orelse return error.MissingIdentityEncoding;
    if (!std.ascii.eqlIgnoreCase(encoding, "identity")) return error.MissingIdentityEncoding;
    if (range) |expected| {
        const actual = requestHeader(req, "range") orelse return error.MissingRange;
        if (!std.mem.eql(u8, actual, expected)) return error.UnexpectedRange;
    }
}

fn serveLoopback(ctx: *LoopbackContext) void {
    serveLoopbackFallible(ctx) catch |err| {
        ctx.err_name = @errorName(err);
    };
}

fn serveLoopbackFallible(ctx: *LoopbackContext) !void {
    var stream = try ctx.listener.accept(ctx.io);
    defer stream.close(ctx.io);
    var read_buf: [4096]u8 = undefined;
    var write_buf: [4096]u8 = undefined;
    var connection_reader = stream.reader(ctx.io, &read_buf);
    var connection_writer = stream.writer(ctx.io, &write_buf);
    var server = std.http.Server.init(&connection_reader.interface, &connection_writer.interface);

    switch (ctx.script) {
        .head_size, .large_head_size => {
            var req = try server.receiveHead();
            try checkLoopbackRequest(&req, .HEAD, null);
            ctx.head_count += 1;
            if (ctx.script == .head_size) {
                try req.respond("abcde", .{ .keep_alive = false });
            } else {
                try req.respond("", .{
                    .keep_alive = false,
                    .transfer_encoding = .none,
                    .extra_headers = &.{.{ .name = "content-length", .value = "4294967297" }},
                });
            }
        },
        .range_size, .zero_range_size, .no_range_fallback => {
            var head = try server.receiveHead();
            try checkLoopbackRequest(&head, .HEAD, null);
            ctx.head_count += 1;
            try head.respond("", .{ .status = .method_not_allowed, .keep_alive = true });

            var get = try server.receiveHead();
            try checkLoopbackRequest(&get, .GET, "bytes=0-0");
            ctx.get_count += 1;
            if (ctx.script == .range_size) {
                try get.respond("a", .{
                    .status = .partial_content,
                    .keep_alive = false,
                    .extra_headers = &.{.{ .name = "content-range", .value = "bytes 0-0/5" }},
                });
            } else if (ctx.script == .zero_range_size) {
                try get.respond("", .{
                    .status = .range_not_satisfiable,
                    .keep_alive = false,
                    .extra_headers = &.{.{ .name = "content-range", .value = "bytes */0" }},
                });
            } else {
                try get.respond("abcde", .{ .keep_alive = false });
            }
        },
        .read_seeds_size => {
            var req = try server.receiveHead();
            try checkLoopbackRequest(&req, .GET, "bytes=1-2");
            ctx.get_count += 1;
            try req.respond("bc", .{
                .status = .partial_content,
                .keep_alive = false,
                .extra_headers = &.{.{ .name = "content-range", .value = "bytes 1-2/5" }},
            });
        },
        .truncated_chunked, .truncated_fixed => {
            var req = try server.receiveHead();
            try checkLoopbackRequest(&req, .GET, "bytes=0-3");
            ctx.get_count += 1;
            if (ctx.script == .truncated_chunked) {
                try req.respond("ab", .{
                    .status = .partial_content,
                    .keep_alive = false,
                    .transfer_encoding = .chunked,
                    .extra_headers = &.{.{ .name = "content-range", .value = "bytes 0-3/100" }},
                });
            } else {
                try req.server.out.writeAll(
                    "HTTP/1.1 206 Partial Content\r\n" ++
                        "content-length: 4\r\n" ++
                        "content-range: bytes 0-3/100\r\n" ++
                        "connection: close\r\n\r\n" ++
                        "ab",
                );
                try req.server.out.flush();
            }
        },
        .range_limited => {
            var first = try server.receiveHead();
            try checkLoopbackRequest(&first, .GET, "bytes=0-3");
            ctx.get_count += 1;
            try first.respond("ab", .{
                .status = .partial_content,
                .keep_alive = true,
                .extra_headers = &.{.{ .name = "content-range", .value = "bytes 0-1/5" }},
            });

            var second = try server.receiveHead();
            try checkLoopbackRequest(&second, .GET, "bytes=2-3");
            ctx.get_count += 1;
            try second.respond("cd", .{
                .status = .partial_content,
                .keep_alive = false,
                .extra_headers = &.{.{ .name = "content-range", .value = "bytes 2-3/5" }},
            });
        },
    }
}

fn runLoopbackScenario(script: LoopbackScript) !void {
    var threaded: std.Io.Threaded = .init_single_threaded;
    defer threaded.deinit();
    const io = threaded.io();
    const address = try std.Io.net.IpAddress.parseIp4("127.0.0.1", 0);
    var listener = try address.listen(io, .{ .reuse_address = true });
    var ctx: LoopbackContext = .{ .io = io, .listener = &listener, .script = script };
    var thread = try std.Thread.spawn(.{}, serveLoopback, .{&ctx});
    var joined = false;
    defer if (!joined) {
        listener.deinit(io);
        thread.join();
    } else {
        listener.deinit(io);
    };

    var url_buf: [128]u8 = undefined;
    const url = try std.fmt.bufPrint(&url_buf, "http://127.0.0.1:{d}/data.fits", .{
        listener.socket.address.getPort(),
    });
    const dev = try HttpDevice.open(testing.allocator, url);
    defer dev.close();

    switch (script) {
        .head_size, .range_size => {
            try testing.expectEqual(@as(u64, 5), try dev.getSize());
            try testing.expectEqual(@as(u64, 5), try dev.getSize());
        },
        .large_head_size => {
            const large = (@as(u64, 1) << 32) + 1;
            try testing.expectEqual(large, try dev.getSize());
            try testing.expectEqual(large, try dev.getSize());
        },
        .zero_range_size => {
            try testing.expectEqual(@as(u64, 0), try dev.getSize());
            try testing.expectEqual(@as(u64, 0), try dev.getSize());
        },
        .read_seeds_size => {
            var buf: [2]u8 = undefined;
            try testing.expectEqual(@as(usize, 2), try dev.pread(&buf, 1));
            try testing.expectEqualStrings("bc", &buf);
            try testing.expectEqual(@as(u64, 5), try dev.getSize());
        },
        .no_range_fallback => {
            try testing.expectEqual(@as(u64, 5), try dev.getSize());
            var buf: [2]u8 = undefined;
            try testing.expectEqual(@as(usize, 2), try dev.pread(&buf, 2));
            try testing.expectEqualStrings("cd", &buf);
            try testing.expectEqual(@as(u64, 5), try dev.getSize());
        },
        .truncated_chunked, .truncated_fixed => {
            var buf: [4]u8 = undefined;
            try testing.expectError(error.ReadFailed, dev.pread(&buf, 0));
            const http: *HttpDevice = @ptrCast(@alignCast(dev.ptr));
            try testing.expectEqual(@as(?u64, null), http.known_size);
        },
        .range_limited => {
            var buf: [4]u8 = undefined;
            try dev.readAll(&buf, 0);
            try testing.expectEqualStrings("abcd", &buf);
            try testing.expectEqual(@as(u64, 5), try dev.getSize());
        },
    }

    thread.join();
    joined = true;
    if (ctx.err_name) |name| {
        std.debug.print("loopback HTTP server failed: {s}\n", .{name});
        return error.LoopbackServerFailed;
    }
    switch (script) {
        .head_size, .large_head_size => {
            try testing.expectEqual(@as(usize, 1), ctx.head_count);
            try testing.expectEqual(@as(usize, 0), ctx.get_count);
        },
        .range_size, .zero_range_size, .no_range_fallback => {
            try testing.expectEqual(@as(usize, 1), ctx.head_count);
            try testing.expectEqual(@as(usize, 1), ctx.get_count);
        },
        .read_seeds_size => {
            try testing.expectEqual(@as(usize, 0), ctx.head_count);
            try testing.expectEqual(@as(usize, 1), ctx.get_count);
        },
        .truncated_chunked, .truncated_fixed => {
            try testing.expectEqual(@as(usize, 0), ctx.head_count);
            try testing.expectEqual(@as(usize, 1), ctx.get_count);
        },
        .range_limited => {
            try testing.expectEqual(@as(usize, 0), ctx.head_count);
            try testing.expectEqual(@as(usize, 2), ctx.get_count);
        },
    }
}

test "HTTP size is discovered once per device lifetime" {
    try runLoopbackScenario(.head_size);
    try runLoopbackScenario(.large_head_size);
    try runLoopbackScenario(.range_size);
    try runLoopbackScenario(.zero_range_size);
}

test "range reads seed size and no-range fallback reuses its response" {
    try runLoopbackScenario(.read_seeds_size);
    try runLoopbackScenario(.no_range_fallback);
}

test "truncated partial responses fail without caching their advertised size" {
    try runLoopbackScenario(.truncated_chunked);
    try runLoopbackScenario(.truncated_fixed);
}

test "server-limited partial responses remain valid short reads" {
    try runLoopbackScenario(.range_limited);
}

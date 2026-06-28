//! The `Fits` file handle: open/create, lazy HDU scan, navigation, and the programmatic
//! HDU builder (FR-HDU-1/3/4, FR-IO-5, FR-TPL-2, NFR-MEM-1, NFR-CONC-1; §10.3, §25).
//!
//! All library state lives in this handle (no globals), so distinct handles are usable
//! concurrently from different threads; a **single handle is not thread-safe** (it mutates
//! its block cache, CHDU index, and lazily-grown HDU list). HDUs are scanned lazily and each
//! `*Hdu` is individually allocated, so a view holding one stays valid as the list grows.
const std = @import("std");
const errors = @import("errors.zig");
const Diagnostics = @import("diag.zig").Diagnostics;
const Limits = @import("limits.zig").Limits;
const limits = @import("limits.zig");
const Device = @import("io/device.zig").Device;
const FileDevice = @import("io/file.zig").FileDevice;
const file = @import("io/file.zig");
const block = @import("io/block.zig");
const Header = @import("header/header.zig").Header;
const hdu_mod = @import("hdu.zig");
const Hdu = hdu_mod.Hdu;

const Allocator = std.mem.Allocator;

/// The error set produced by file-handle operations (a wide but specific union — not the
/// umbrella `Error`, and never `anyerror`).
pub const FitsError = errors.IoError || errors.HeaderError || errors.StructError ||
    errors.ValueError || errors.ConvError || errors.LimitError || Allocator.Error;

/// How a file is opened.
pub const Mode = enum { read_only, read_write, create };

/// Options for `open`/`create`.
pub const OpenOpts = struct {
    /// Optional diagnostics sink for the most-recent failure (FR-ERR-3).
    diag: ?*Diagnostics = null,
    /// Resource limits (NFR-SAFE-1).
    limits: Limits = .{},
    /// Update `CHECKSUM`/`DATASUM` automatically on `flush`/`deinit` (FR-SUM-3).
    checksum_on_close: bool = false,
};

/// Specification for a programmatically-built image HDU (FR-TPL-2).
pub const ImageSpec = struct {
    /// `BITPIX`: 8, 16, 32, 64, -32, or -64.
    bitpix: i64,
    /// Per-axis lengths (most-rapidly-varying first); `len` is `NAXIS` (0–999).
    axes: []const u64,
};

/// A FITS file handle.
pub const Fits = struct {
    alloc: Allocator,
    dev: Device,
    mode: Mode,
    limits: Limits,
    diag: ?*Diagnostics,
    checksum_on_close: bool,
    /// Lazily-scanned HDUs; each is individually allocated for pointer stability (§10.3).
    hdus: std.ArrayList(*Hdu) = .empty,
    /// Current-HDU index (0-based; renamed from `current` to avoid a field/method collision).
    chdu: usize = 0,
    reader: block.BlockReader,
    /// Byte offset where the next unscanned HDU begins.
    scan_off: u64 = 0,
    fully_scanned: bool = false,
    /// Whether `deinit` closes the device (true when the handle created it, e.g. `openFile`).
    owns_device: bool = false,
    /// Hook registered by the checksum module; invoked by `flush` when `checksum_on_close`.
    checksum_hook: ?*const fn (*Fits) FitsError!void = null,

    /// Open an existing FITS file over `dev`. Parses HDU 1 eagerly; further HDUs are scanned
    /// on demand (§10.3). A read-only device makes write operations `error.NotWritable`.
    pub fn open(alloc: Allocator, dev: Device, mode: Mode, opts: OpenOpts) FitsError!Fits {
        std.debug.assert(mode != .create); // use `create` for new files
        var self = try initHandle(alloc, dev, mode, opts);
        errdefer self.deinitInternal(false);
        _ = try self.scanOne(); // eagerly parse HDU 1
        return self;
    }

    /// Create a new (empty) FITS file over `dev`. Build HDUs with `appendImageHdu` etc.
    pub fn create(alloc: Allocator, dev: Device, opts: OpenOpts) FitsError!Fits {
        var self = try initHandle(alloc, dev, .create, opts);
        self.fully_scanned = true; // nothing to scan yet
        return self;
    }

    /// Open an on-disk file by path (the handle owns and closes the device).
    pub fn openFile(alloc: Allocator, path: []const u8, mode: Mode, opts: OpenOpts) FitsError!Fits {
        const access: file.Access = switch (mode) {
            .read_only => .read_only,
            .read_write => .read_write,
            .create => .create,
        };
        const dev = try FileDevice.openPath(alloc, path, access);
        errdefer dev.close();
        var self = if (mode == .create)
            try create(alloc, dev, opts)
        else
            try open(alloc, dev, mode, opts);
        self.owns_device = true;
        return self;
    }

    /// Create a new on-disk file by path (the handle owns and closes the device).
    pub fn createFile(alloc: Allocator, path: []const u8, opts: OpenOpts) FitsError!Fits {
        return openFile(alloc, path, .create, opts);
    }

    fn initHandle(alloc: Allocator, dev: Device, mode: Mode, opts: OpenOpts) FitsError!Fits {
        const reader = try block.BlockReader.init(alloc, dev, 0);
        return .{
            .alloc = alloc,
            .dev = dev,
            .mode = mode,
            .limits = opts.limits,
            .diag = opts.diag,
            .checksum_on_close = opts.checksum_on_close,
            .reader = reader,
        };
    }

    /// Release all resources. Closes the device if the handle created it.
    pub fn deinit(self: *Fits) void {
        self.deinitInternal(self.owns_device);
    }

    fn deinitInternal(self: *Fits, close_device: bool) void {
        for (self.hdus.items) |h| {
            h.deinit(self.alloc);
            self.alloc.destroy(h);
        }
        self.hdus.deinit(self.alloc);
        self.reader.deinit();
        if (close_device) self.dev.close();
    }

    // ── scanning ─────────────────────────────────────────────────────────────────────────

    // Parse the next unscanned HDU, append it, and advance `scan_off`. Returns null at EOF or
    // when trailing bytes are special records (§3.5) rather than another HDU.
    fn scanOne(self: *Fits) FitsError!?*Hdu {
        if (self.fully_scanned) return null;
        const size = try self.dev.getSize();
        if (self.scan_off >= size or size - self.scan_off < block.BLOCK) {
            self.fully_scanned = true;
            return null;
        }
        const first_card = self.scan_off / block.CARD;
        const max_cards = @as(u64, self.limits.max_header_blocks) * block.CARDS_PER_BLOCK;
        const res = Header.parse(self.alloc, &self.reader, first_card, @intCast(max_cards)) catch |err| {
            // After at least one HDU, a non-header tail is treated as special records, not an error.
            if (self.hdus.items.len > 0) {
                self.fully_scanned = true;
                return null;
            }
            return err;
        };

        const is_primary = self.hdus.items.len == 0;
        const hdu_ptr = self.alloc.create(Hdu) catch |e| {
            var h = res.header;
            h.deinit(self.alloc);
            return e;
        };
        errdefer self.alloc.destroy(hdu_ptr);
        // Hdu.init takes ownership of the header (frees it on its own error).
        hdu_ptr.* = try Hdu.init(self.alloc, res.header, is_primary, self.scan_off, res.cards_consumed, self.limits);
        errdefer hdu_ptr.deinit(self.alloc);
        try self.hdus.append(self.alloc, hdu_ptr);

        self.scan_off = hdu_ptr.nextOff();
        if (self.scan_off >= size) self.fully_scanned = true;
        return hdu_ptr;
    }

    fn ensureScanned(self: *Fits, upto_count: usize) FitsError!void {
        while (self.hdus.items.len < upto_count and !self.fully_scanned) {
            _ = try self.scanOne();
        }
    }

    fn ensureScannedAll(self: *Fits) FitsError!void {
        while (!self.fully_scanned) _ = try self.scanOne();
    }

    // ── navigation ───────────────────────────────────────────────────────────────────────

    /// Total number of HDUs (forces a full scan) (FR-HDU-1).
    pub fn hduCount(self: *Fits) FitsError!usize {
        try self.ensureScannedAll();
        return self.hdus.items.len;
    }

    /// Select HDU `n` (1-based) as the current HDU and return it (FR-HDU-3).
    pub fn select(self: *Fits, n: usize) FitsError!*Hdu {
        if (n == 0) return error.WrongHduType;
        try self.ensureScanned(n);
        if (n > self.hdus.items.len) return error.WrongHduType;
        self.chdu = n - 1;
        return self.hdus.items[self.chdu];
    }

    /// Move the current HDU by `delta` (relative navigation) and return it.
    pub fn move(self: *Fits, delta: isize) FitsError!*Hdu {
        const target = @as(isize, @intCast(self.chdu)) + delta;
        if (target < 0) return error.WrongHduType;
        return self.select(@as(usize, @intCast(target)) + 1);
    }

    /// Select the first extension whose `EXTNAME` matches `extname` (case-insensitive) and,
    /// if `extver` is given, whose `EXTVER` matches (FR-HDU-3).
    pub fn selectByName(self: *Fits, extname: []const u8, extver: ?i64) FitsError!*Hdu {
        try self.ensureScannedAll();
        for (self.hdus.items, 0..) |h, i| {
            var buf: [80]u8 = undefined;
            var fba = std.heap.FixedBufferAllocator.init(&buf);
            const name = h.header.getString(fba.allocator(), "EXTNAME") catch continue;
            if (!std.ascii.eqlIgnoreCase(std.mem.trim(u8, name, " "), extname)) continue;
            if (extver) |want| {
                const ver = h.header.getValue(i64, "EXTVER") catch 1;
                if (ver != want) continue;
            }
            self.chdu = i;
            return h;
        }
        return error.WrongHduType;
    }

    /// The current HDU (CHDU). Valid after `open` (HDU 1) or any navigation/append.
    pub fn current(self: *Fits) *Hdu {
        return self.hdus.items[self.chdu];
    }

    // ── mutation / builders (FR-HDU-4, FR-TPL-2) ───────────────────────────────────────────

    /// Append a caller-built HDU: write `header_in` (ownership transferred) after all existing
    /// HDUs, validate it, reserve and zero-fill its data unit, make it current, and return the
    /// `*Hdu`. The header must carry the mandatory keywords for its kind (e.g. `XTENSION`,
    /// `NAXISn`, `PCOUNT`, `GCOUNT`, `TFIELDS` for a table); `END` is appended if absent. This
    /// is the general programmatic-builder primitive (FR-HDU-4, FR-TPL-2) that the typed
    /// `appendImageHdu` and the table builders use.
    pub fn appendHdu(self: *Fits, header_in: Header) FitsError!*Hdu {
        if (self.mode == .read_only or !self.dev.isWritable()) return error.NotWritable;
        var header = header_in;
        var header_owned = true;
        errdefer if (header_owned) header.deinit(self.alloc);
        try self.ensureScannedAll(); // append after all existing HDUs
        try header.ensureEnd(self.alloc);

        const is_primary = self.hdus.items.len == 0;
        const offset = self.scan_off;
        var bw = try block.BlockWriter.init(self.alloc, self.dev, offset, 0);
        defer bw.deinit();
        try header.writeTo(&bw);
        const cards = header.count();

        const hdu_ptr = try self.alloc.create(Hdu);
        errdefer self.alloc.destroy(hdu_ptr);
        header_owned = false; // Hdu.init takes ownership of `header` from here
        hdu_ptr.* = try Hdu.init(self.alloc, header, is_primary, offset, cards, self.limits);
        errdefer hdu_ptr.deinit(self.alloc);

        // Reserve & zero-fill the data unit so the file is structurally valid before data lands.
        const data_end = try limits.add(hdu_ptr.data_off, block.roundUpBlocks(hdu_ptr.data_bytes));
        if (data_end > try self.dev.getSize()) try self.dev.setSize(data_end);

        try self.hdus.append(self.alloc, hdu_ptr);
        self.scan_off = data_end;
        self.fully_scanned = true;
        self.chdu = self.hdus.items.len - 1;
        return hdu_ptr;
    }

    /// Append a programmatically-built image HDU (primary if the file is empty, else an
    /// `IMAGE` extension). Pixels are written via the image view (`image.zig`). The primary,
    /// complete image-construction path — no template required (FR-TPL-2).
    pub fn appendImageHdu(self: *Fits, spec: ImageSpec) FitsError!*Hdu {
        if (self.mode == .read_only or !self.dev.isWritable()) return error.NotWritable;
        if (!validBitpix(spec.bitpix)) return error.BadBitpix;
        if (spec.axes.len > 999) return error.BadNaxis;
        try self.ensureScannedAll();
        const is_primary = self.hdus.items.len == 0;
        const header = try self.buildImageHeader(spec, is_primary);
        return self.appendHdu(header);
    }

    fn buildImageHeader(self: *Fits, spec: ImageSpec, is_primary: bool) FitsError!Header {
        var header = Header.initEmpty();
        errdefer header.deinit(self.alloc);
        if (is_primary) {
            try header.appendValue(self.alloc, "SIMPLE", .{ .logical = true }, "conforms to FITS standard");
        } else {
            try header.appendValue(self.alloc, "XTENSION", .{ .string = "IMAGE" }, "image extension");
        }
        try header.appendValue(self.alloc, "BITPIX", .{ .int = spec.bitpix }, null);
        try header.appendValue(self.alloc, "NAXIS", .{ .int = @intCast(spec.axes.len) }, null);
        var name_buf: [8]u8 = undefined;
        for (spec.axes, 0..) |ax, i| {
            const kw = std.fmt.bufPrint(&name_buf, "NAXIS{d}", .{i + 1}) catch unreachable;
            try header.appendValue(self.alloc, kw, .{ .int = @intCast(ax) }, null);
        }
        if (is_primary) {
            try header.appendValue(self.alloc, "EXTEND", .{ .logical = true }, "may contain extensions");
        } else {
            try header.appendValue(self.alloc, "PCOUNT", .{ .int = 0 }, null);
            try header.appendValue(self.alloc, "GCOUNT", .{ .int = 1 }, null);
        }
        try header.ensureEnd(self.alloc);
        return header;
    }

    // ── structural editing: data/header resize + following-HDU shift (Phase-1 contract) ────
    //
    // Editing a FITS file in place means moving every byte that follows the edited region, then
    // re-aligning to 2880-byte blocks (§3.1). All of these ops first force a full scan (you can
    // only shift a fully-known file), require a writable device/mode, move bytes in bounded
    // chunks (never per byte, never per-byte allocation), patch the in-memory offsets of the
    // HDUs that moved, and re-init the block reader (its window cache goes stale after a byte
    // move). The lone primitive underneath them is `shiftTail`.

    // Bounded staging buffer for byte moves and zero-fills (NFR-PERF-3): 64 KiB, on the stack.
    const CHUNK: usize = 64 * 1024;

    // Move the byte range [from_off, EOF) by `delta` (a signed multiple of BLOCK) and re-align
    // the device size. GROW (delta>0): grow the device first, copy back-to-front so the shifted
    // copy never overwrites a not-yet-read source byte, then zero-fill the vacated gap
    // [from_off, from_off+delta). SHRINK (delta<0): copy front-to-back, then shrink the device.
    fn shiftTail(self: *Fits, from_off: u64, delta: i64) FitsError!void {
        if (delta == 0) return;
        if (!self.dev.isWritable()) return error.NotWritable;
        const size = try self.dev.getSize();
        const tail_len = if (from_off < size) size - from_off else 0;
        var buf: [CHUNK]u8 = undefined;
        if (delta > 0) {
            const d: u64 = @intCast(delta);
            try self.dev.setSize(try limits.add(size, d)); // grow before copying into the new space
            var remaining = tail_len; // back-to-front to avoid overlap
            while (remaining > 0) {
                const n: usize = @intCast(@min(@as(u64, buf.len), remaining));
                const src = from_off + remaining - n;
                try self.dev.readAll(buf[0..n], src);
                try self.dev.writeAll(buf[0..n], src + d);
                remaining -= n;
            }
            @memset(buf[0..], 0); // zero-fill the vacated gap [from_off, from_off+d)
            var z = d;
            var zo = from_off;
            while (z > 0) {
                const n: usize = @intCast(@min(@as(u64, buf.len), z));
                try self.dev.writeAll(buf[0..n], zo);
                zo += n;
                z -= n;
            }
        } else {
            const d: u64 = @intCast(-delta);
            var done: u64 = 0; // front-to-back to avoid overlap
            while (done < tail_len) {
                const n: usize = @intCast(@min(@as(u64, buf.len), tail_len - done));
                const src = from_off + done;
                try self.dev.readAll(buf[0..n], src);
                try self.dev.writeAll(buf[0..n], src - d);
                done += n;
            }
            try self.dev.setSize(size - d); // drop the now-unused tail
        }
    }

    // Zero exactly `len` bytes at `off`, in bounded chunks.
    fn zeroRange(self: *Fits, off: u64, len: u64) FitsError!void {
        if (len == 0) return;
        var buf: [CHUNK]u8 = [_]u8{0} ** CHUNK;
        var remaining = len;
        var o = off;
        while (remaining > 0) {
            const n: usize = @intCast(@min(@as(u64, buf.len), remaining));
            try self.dev.writeAll(buf[0..n], o);
            o += n;
            remaining -= n;
        }
    }

    // Add `delta` to the header/data offsets of every HDU AFTER `pivot`, and to `scan_off`.
    fn shiftFollowing(self: *Fits, pivot: *const Hdu, delta: i64) void {
        var seen = false;
        for (self.hdus.items) |h| {
            if (seen) {
                h.header_off = applyDelta(h.header_off, delta);
                h.data_off = applyDelta(h.data_off, delta);
            }
            if (h == pivot) seen = true;
        }
        self.scan_off = applyDelta(self.scan_off, delta);
    }

    // Re-create the block reader: after a byte move its cached window is stale (NFR-CORR). Builds
    // the replacement before freeing the old one so a failed allocation leaves the handle intact.
    fn reinitReader(self: *Fits) FitsError!void {
        const fresh = try block.BlockReader.init(self.alloc, self.dev, 0);
        self.reader.deinit();
        self.reader = fresh;
    }

    /// Resize the data unit of `hdu` to `new_data_bytes`, shifting all following HDUs and
    /// re-aligning to 2880-byte blocks; zero-fills any growth (the FITS data fill, §3.3.2). The
    /// header keywords are NOT touched (the caller updates `NAXISn` etc. and may pair this with
    /// `rewriteHeaderInPlace`). Updates the in-memory offsets of moved HDUs and `scan_off`, and
    /// re-inits the block reader (FR-HDU-4).
    pub fn resizeHduData(self: *Fits, hdu: *Hdu, new_data_bytes: u64) FitsError!void {
        if (self.mode == .read_only or !self.dev.isWritable()) return error.NotWritable;
        try self.ensureScannedAll();

        const old_data_bytes = hdu.data_bytes;
        const data_off = hdu.data_off;
        const next_off = hdu.nextOff(); // first byte after the OLD (padded) data unit
        const old_blocks = block.roundUpBlocks(old_data_bytes);
        const new_blocks = block.roundUpBlocks(new_data_bytes);

        const delta: i64 = @as(i64, @intCast(new_blocks)) - @as(i64, @intCast(old_blocks));
        if (delta != 0) {
            try self.shiftTail(next_off, delta);
            self.shiftFollowing(hdu, delta);
        }
        hdu.data_bytes = new_data_bytes;

        // Zero everything from the last preserved byte to the new block-padded end: the grown
        // data region plus any block padding (and, on shrink, the vacated padding bytes).
        const keep = @min(old_data_bytes, new_data_bytes);
        try self.zeroRange(data_off + keep, new_blocks - keep);

        try self.reinitReader();
    }

    /// Recompute `hdu`.{bitpix,naxis,axes,pcount,gcount,data_bytes} from its CURRENT header
    /// (after structural keywords were mutated) WITHOUT moving bytes. Returns the new data byte
    /// count (§4.4.1.1). Pair with `resizeHduData`/`rewriteHeaderInPlace` to commit the change.
    pub fn refreshGeometry(self: *Fits, hdu: *Hdu) FitsError!u64 {
        try self.ensureScannedAll();
        try hdu.recomputeGeometry(self.alloc, self.limits);
        return hdu.data_bytes;
    }

    /// Re-serialize `hdu`'s (possibly card-count-changed) header in place: re-align the header
    /// block count, shift following HDUs, recompute `data_off`, then — if the geometry implied by
    /// the new header changed the data size — re-align the data too. Call after editing
    /// structural keywords (`NAXISn`/`TFORM`/`TFIELDS`/`BITPIX`). Re-inits the block reader.
    pub fn rewriteHeaderInPlace(self: *Fits, hdu: *Hdu) FitsError!void {
        if (self.mode == .read_only or !self.dev.isWritable()) return error.NotWritable;
        try self.ensureScannedAll();
        try hdu.header.ensureEnd(self.alloc);

        const old_header_blocks = hdu.data_off - hdu.header_off; // already block-aligned
        const new_header_blocks = block.roundUpBlocks(@as(u64, hdu.header.count()) * block.CARD);
        const header_delta: i64 =
            @as(i64, @intCast(new_header_blocks)) - @as(i64, @intCast(old_header_blocks));
        if (header_delta != 0) {
            try self.shiftTail(hdu.data_off, header_delta);
            self.shiftFollowing(hdu, header_delta);
            hdu.data_off = hdu.header_off + new_header_blocks;
        }

        // Re-write the header cards at their (possibly unchanged) offset, padding with spaces.
        var bw = try block.BlockWriter.init(self.alloc, self.dev, hdu.header_off, 0);
        defer bw.deinit();
        try hdu.header.writeTo(&bw);

        // Refresh the structural fields and re-align the data if the new geometry changed its size.
        const old_data_bytes = hdu.data_bytes;
        try hdu.recomputeGeometry(self.alloc, self.limits);
        const new_data_bytes = hdu.data_bytes;
        if (new_data_bytes != old_data_bytes) {
            hdu.data_bytes = old_data_bytes; // restore so resizeHduData sees the on-disk size
            try self.resizeHduData(hdu, new_data_bytes); // re-inits the reader
        } else {
            try self.reinitReader();
        }
    }

    /// Delete HDU `n` (1-based): shift the tail down over its bytes, drop and free it, and fix the
    /// offsets/CHDU of everything that followed. Refuses to delete the primary (FITS requires one)
    /// with `error.WrongHduType` (FR-HDU-4).
    pub fn deleteHdu(self: *Fits, n: usize) FitsError!void {
        if (self.mode == .read_only or !self.dev.isWritable()) return error.NotWritable;
        try self.ensureScannedAll();
        if (n == 0 or n > self.hdus.items.len) return error.WrongHduType;
        if (n == 1) return error.WrongHduType; // a FITS file must keep its primary HDU

        const h = self.hdus.items[n - 1];
        const total = h.nextOff() - h.header_off; // padded header + padded data, block-aligned
        try self.shiftTail(h.nextOff(), -@as(i64, @intCast(total))); // also truncates the gap
        for (self.hdus.items[n..]) |fh| {
            fh.header_off -= total;
            fh.data_off -= total;
        }
        self.scan_off -= total;

        h.deinit(self.alloc);
        self.alloc.destroy(h);
        _ = self.hdus.orderedRemove(n - 1);

        if (self.chdu > n - 1) self.chdu -= 1;
        if (self.chdu >= self.hdus.items.len) self.chdu = self.hdus.items.len - 1;
        try self.reinitReader();
    }

    /// Copy HDU `src_n` (1-based) and append the duplicate after the last HDU; returns the new
    /// `*Hdu`. The on-disk bytes are an exact copy (FR-HDU-4). Note the duplicate is appended as
    /// an extension, so copying the primary (which carries `SIMPLE`, not `XTENSION`) is rejected
    /// when the copy is parsed.
    pub fn copyHdu(self: *Fits, src_n: usize) FitsError!*Hdu {
        if (self.mode == .read_only or !self.dev.isWritable()) return error.NotWritable;
        try self.ensureScannedAll();
        if (src_n == 0 or src_n > self.hdus.items.len) return error.WrongHduType;

        const src = self.hdus.items[src_n - 1];
        const start = src.header_off;
        const len = src.nextOff() - start; // whole HDU, block-aligned
        const dest = self.scan_off; // immediately after the last HDU

        const new_size = try limits.add(dest, len);
        if (new_size > try self.dev.getSize()) try self.dev.setSize(new_size);
        // Source and destination never overlap (dest ≥ end of the last HDU ≥ src end), so a plain
        // forward copy is safe.
        var buf: [CHUNK]u8 = undefined;
        var done: u64 = 0;
        while (done < len) {
            const n: usize = @intCast(@min(@as(u64, buf.len), len - done));
            try self.dev.readAll(buf[0..n], start + done);
            try self.dev.writeAll(buf[0..n], dest + done);
            done += n;
        }

        try self.reinitReader(); // read the freshly-written copy through a clean window
        const first_card = dest / block.CARD;
        const max_cards = @as(u64, self.limits.max_header_blocks) * block.CARDS_PER_BLOCK;
        const res = try Header.parse(self.alloc, &self.reader, first_card, @intCast(max_cards));

        const hdu_ptr = self.alloc.create(Hdu) catch |e| {
            var hdr = res.header;
            hdr.deinit(self.alloc);
            return e;
        };
        errdefer self.alloc.destroy(hdu_ptr);
        // Always an extension (a primary already exists); Hdu.init takes ownership of res.header.
        hdu_ptr.* = try Hdu.init(self.alloc, res.header, false, dest, res.cards_consumed, self.limits);
        errdefer hdu_ptr.deinit(self.alloc);
        try self.hdus.append(self.alloc, hdu_ptr);

        self.scan_off = hdu_ptr.nextOff();
        self.fully_scanned = true;
        self.chdu = self.hdus.items.len - 1;
        return hdu_ptr;
    }

    /// Flush buffered writes to the device, optionally updating checksums first (FR-SUM-3).
    pub fn flush(self: *Fits) FitsError!void {
        if (self.checksum_on_close) {
            if (self.checksum_hook) |hook| try hook(self);
        }
        try self.dev.sync();
    }

    /// The device underlying this handle (for low-level access, e.g. checksum computation).
    pub fn device(self: *Fits) Device {
        return self.dev;
    }
};

fn validBitpix(b: i64) bool {
    return switch (b) {
        8, 16, 32, 64, -32, -64 => true,
        else => false,
    };
}

// Apply a signed byte delta to an unsigned offset. Callers only ever shift offsets that lie at
// or beyond the moved region, so a negative delta never underflows a real offset.
fn applyDelta(off: u64, delta: i64) u64 {
    return if (delta >= 0) off + @as(u64, @intCast(delta)) else off - @as(u64, @intCast(-delta));
}

// ── tests ──────────────────────────────────────────────────────────────────────────────
const testing = std.testing;
const MemoryDevice = @import("io/memory.zig").MemoryDevice;

// Write a two-HDU file (primary NAXIS=0 + an IMAGE extension) into a memory device.
fn twoHduFile(alloc: Allocator) !*MemoryDevice {
    const mem = try alloc.create(MemoryDevice);
    mem.* = MemoryDevice.init(alloc);
    var f = try Fits.create(alloc, mem.device(), .{});
    defer f.deinit();
    _ = try f.appendImageHdu(.{ .bitpix = 8, .axes = &.{} }); // primary, no data
    _ = try f.appendImageHdu(.{ .bitpix = 16, .axes = &.{ 4, 3 } }); // image extension
    try f.flush();
    return mem;
}

test "create → append two HDUs → reopen → scan and navigate" {
    const mem = try twoHduFile(testing.allocator);
    defer {
        mem.deinit();
        testing.allocator.destroy(mem);
    }

    var f = try Fits.open(testing.allocator, mem.device(), .read_only, .{});
    defer f.deinit();
    try testing.expectEqual(@as(usize, 2), try f.hduCount());

    const h1 = try f.select(1);
    try testing.expectEqual(hdu_mod.HduKind.primary, h1.kind);
    try testing.expectEqual(@as(u16, 0), h1.naxis);

    const h2 = try f.select(2);
    try testing.expectEqual(hdu_mod.HduKind.image, h2.kind);
    try testing.expectEqual(@as(i64, 16), h2.bitpix);
    try testing.expectEqualSlices(u64, &.{ 4, 3 }, h2.axes);
    try testing.expectEqual(@as(u64, 2 * 4 * 3), h2.data_bytes);

    // relative navigation
    const back = try f.move(-1);
    try testing.expectEqual(hdu_mod.HduKind.primary, back.kind);

    // out-of-range selection is typed, not a crash
    try testing.expectError(error.WrongHduType, f.select(3));
}

test "lazy scan only parses HDU 1 on open" {
    const mem = try twoHduFile(testing.allocator);
    defer {
        mem.deinit();
        testing.allocator.destroy(mem);
    }
    var f = try Fits.open(testing.allocator, mem.device(), .read_only, .{});
    defer f.deinit();
    try testing.expectEqual(@as(usize, 1), f.hdus.items.len); // only HDU 1 scanned
    _ = try f.hduCount();
    try testing.expectEqual(@as(usize, 2), f.hdus.items.len);
}

test "*Hdu stays valid across reallocating appends (stable pointers)" {
    const mem = try testing.allocator.create(MemoryDevice);
    mem.* = MemoryDevice.init(testing.allocator);
    defer {
        mem.deinit();
        testing.allocator.destroy(mem);
    }
    var f = try Fits.create(testing.allocator, mem.device(), .{});
    defer f.deinit();

    const first = try f.appendImageHdu(.{ .bitpix = 8, .axes = &.{} });
    // Append many more HDUs, forcing the hdus list to grow/reallocate.
    var i: usize = 0;
    while (i < 200) : (i += 1) {
        _ = try f.appendImageHdu(.{ .bitpix = 8, .axes = &.{2} });
    }
    // The original pointer is still valid (individually allocated).
    try testing.expectEqual(hdu_mod.HduKind.primary, first.kind);
}

test "read-only device rejects appends" {
    const mem = try twoHduFile(testing.allocator);
    defer {
        mem.deinit();
        testing.allocator.destroy(mem);
    }
    var f = try Fits.open(testing.allocator, mem.device(), .read_only, .{});
    defer f.deinit();
    // The memory device is writable, but read_only mode forbids mutation.
    try testing.expectError(error.NotWritable, f.appendImageHdu(.{ .bitpix = 8, .axes = &.{} }));
}


// ── X-CONC: distinct handles are usable concurrently (NFR-CONC-1, NFR-TEST-5a) ────────────
// NOTE: a single `Fits` handle is NOT thread-safe (it mutates its block cache, CHDU index,
// and lazily-grown HDU list); this is documented on `Fits` above. Distinct handles share no
// state and are safe to use from different threads, which this test exercises.

fn concWorker(alloc: Allocator, ok: *bool, idx: u32) void {
    concBuild(alloc, idx) catch {
        ok.* = false;
        return;
    };
    ok.* = true;
}

fn concBuild(alloc: Allocator, idx: u32) !void {
    var mem = MemoryDevice.init(alloc);
    defer mem.deinit();
    {
        var f = try Fits.create(alloc, mem.device(), .{});
        defer f.deinit();
        const hdu = try f.appendImageHdu(.{ .bitpix = 32, .axes = &.{ 4, 4 } });
        // Write 16 big-endian i32 pixels = idx, directly through the device.
        var bytes: [64]u8 = undefined;
        var k: usize = 0;
        while (k < 16) : (k += 1) {
            @import("endian.zig").write(i32, @intCast(idx), bytes[k * 4 ..][0..4]);
        }
        try f.dev.writeAll(&bytes, hdu.data_off);
        try f.flush();
    }
    // Reopen the same (distinct) device and verify the geometry and a pixel round-trip.
    var f2 = try Fits.open(alloc, mem.device(), .read_only, .{});
    defer f2.deinit();
    const h = try f2.select(1);
    if (h.naxis != 2 or h.axes[0] != 4 or h.axes[1] != 4) return error.BadDimensions;
    var rb: [4]u8 = undefined;
    try f2.dev.readAll(&rb, h.data_off);
    if (@import("endian.zig").read(i32, &rb) != @as(i32, @intCast(idx))) return error.BadDimensions;
}

// ── structural-editing tests (resizeHduData / refreshGeometry / rewriteHeaderInPlace /
//    deleteHdu / copyHdu) ───────────────────────────────────────────────────────────────────

const endian = @import("endian.zig");

// A writable in-memory handle that owns its MemoryDevice (freed on deinit via owns_device... but
// MemoryDevice.close is a no-op, so the test frees the device explicitly). Returns both so the
// test can poke the device directly.
const Built = struct {
    f: Fits,
    mem: *MemoryDevice,
    fn deinit(self: *Built, alloc: Allocator) void {
        self.f.deinit();
        self.mem.deinit();
        alloc.destroy(self.mem);
    }
};

fn newHandle(alloc: Allocator) !Built {
    const mem = try alloc.create(MemoryDevice);
    mem.* = MemoryDevice.init(alloc);
    const f = try Fits.create(alloc, mem.device(), .{});
    return .{ .f = f, .mem = mem };
}

// Fill `len` bytes at `off` with a recognizable, position-dependent pattern.
fn writePattern(dev: Device, off: u64, len: usize, seed: u8) !void {
    var buf: [4096]u8 = undefined;
    var done: usize = 0;
    while (done < len) {
        const n = @min(buf.len, len - done);
        for (buf[0..n], 0..) |*b, i| b.* = @truncate(seed +% @as(u8, @truncate(done + i)));
        try dev.writeAll(buf[0..n], off + done);
        done += n;
    }
}

fn expectPattern(dev: Device, off: u64, len: usize, seed: u8) !void {
    var buf: [4096]u8 = undefined;
    var done: usize = 0;
    while (done < len) {
        const n = @min(buf.len, len - done);
        try dev.readAll(buf[0..n], off + done);
        for (buf[0..n], 0..) |b, i| {
            try testing.expectEqual(@as(u8, @truncate(seed +% @as(u8, @truncate(done + i)))), b);
        }
        done += n;
    }
}

test "resizeHduData grow then shrink keeps a trailing HDU byte-intact" {
    var b = try newHandle(testing.allocator);
    defer b.deinit(testing.allocator);
    const f = &b.f;

    _ = try f.appendImageHdu(.{ .bitpix = 8, .axes = &.{} }); // primary, no data
    const h2 = try f.appendImageHdu(.{ .bitpix = 8, .axes = &.{10} }); // 10 data bytes
    const h3 = try f.appendImageHdu(.{ .bitpix = 16, .axes = &.{ 4, 3 } }); // 24 data bytes
    try writePattern(f.dev, h3.data_off, 24, 0x40);

    // Grow h2's data so it spans two blocks, pushing h3 forward. h3 now begins right after h2.
    try f.resizeHduData(h2, 5000);
    try testing.expectEqual(@as(u64, 5000), h2.data_bytes);
    try testing.expectEqual(h2.nextOff(), h3.header_off);
    try testing.expectEqual(h2.data_off + block.roundUpBlocks(5000), h3.header_off);
    try expectPattern(f.dev, h3.data_off, 24, 0x40); // trailing HDU survived the move

    // Shrink h2 back down; h3 returns to its original neighbourhood and stays intact.
    try f.resizeHduData(h2, 10);
    try testing.expectEqual(@as(u64, 10), h2.data_bytes);
    try testing.expectEqual(h2.nextOff(), h3.header_off);
    try testing.expectEqual(h2.data_off + block.BLOCK, h3.header_off);
    try expectPattern(f.dev, h3.data_off, 24, 0x40);

    // Re-scanning the file from scratch must see the same structure.
    var f2 = try Fits.open(testing.allocator, b.mem.device(), .read_only, .{});
    defer f2.deinit();
    try testing.expectEqual(@as(usize, 3), try f2.hduCount());
}

test "resizeHduData grow within one block zero-fills the new bytes" {
    var b = try newHandle(testing.allocator);
    defer b.deinit(testing.allocator);
    const f = &b.f;
    _ = try f.appendImageHdu(.{ .bitpix = 8, .axes = &.{} });
    const h2 = try f.appendImageHdu(.{ .bitpix = 8, .axes = &.{8} });
    try writePattern(f.dev, h2.data_off, 8, 0x11);
    try f.resizeHduData(h2, 20); // still one block
    try expectPattern(f.dev, h2.data_off, 8, 0x11); // original bytes preserved
    var z: [12]u8 = undefined;
    try f.dev.readAll(&z, h2.data_off + 8); // grown bytes are zero
    try testing.expectEqualSlices(u8, &[_]u8{0} ** 12, &z);
}

test "refreshGeometry recomputes data_bytes after a NAXISn edit" {
    var b = try newHandle(testing.allocator);
    defer b.deinit(testing.allocator);
    const f = &b.f;
    _ = try f.appendImageHdu(.{ .bitpix = 8, .axes = &.{} });
    const h2 = try f.appendImageHdu(.{ .bitpix = 16, .axes = &.{ 4, 3 } }); // 24 bytes
    try h2.header.update(f.alloc, "NAXIS2", .{ .int = 5 }, null);
    const nb = try f.refreshGeometry(h2);
    try testing.expectEqual(@as(u64, 2 * 4 * 5), nb);
    try testing.expectEqual(@as(u64, 40), h2.data_bytes);
    try testing.expectEqualSlices(u64, &.{ 4, 5 }, h2.axes);
}

test "rewriteHeaderInPlace: adding NAXIS3 grows the data and shifts the trailing HDU" {
    var b = try newHandle(testing.allocator);
    defer b.deinit(testing.allocator);
    const f = &b.f;
    _ = try f.appendImageHdu(.{ .bitpix = 8, .axes = &.{} });
    const h2 = try f.appendImageHdu(.{ .bitpix = 8, .axes = &.{ 2000, 1 } }); // 2000 bytes → 1 block
    const h3 = try f.appendImageHdu(.{ .bitpix = 8, .axes = &.{7} }); // 7 bytes
    try writePattern(f.dev, h3.data_off, 7, 0x77);
    const old_h3_data_off = h3.data_off;

    // Promote to a 3-D cube: 2000×1×2 = 4000 bytes → 2 blocks.
    try h2.header.update(f.alloc, "NAXIS", .{ .int = 3 }, null);
    try h2.header.update(f.alloc, "NAXIS3", .{ .int = 2 }, null);
    try f.rewriteHeaderInPlace(h2);

    try testing.expectEqual(@as(u16, 3), h2.naxis);
    try testing.expectEqual(@as(u64, 4000), h2.data_bytes);
    try testing.expectEqual(old_h3_data_off + block.BLOCK, h3.data_off); // shifted one block
    try expectPattern(f.dev, h3.data_off, 7, 0x77);

    // The rewritten header parses back identically on a fresh open.
    var f2 = try Fits.open(testing.allocator, b.mem.device(), .read_only, .{});
    defer f2.deinit();
    const r2 = try f2.select(2);
    try testing.expectEqual(@as(u16, 3), r2.naxis);
    try testing.expectEqualSlices(u64, &.{ 2000, 1, 2 }, r2.axes);
}

test "rewriteHeaderInPlace: header card growth shifts following HDUs without touching data size" {
    var b = try newHandle(testing.allocator);
    defer b.deinit(testing.allocator);
    const f = &b.f;
    _ = try f.appendImageHdu(.{ .bitpix = 8, .axes = &.{} });
    const h2 = try f.appendImageHdu(.{ .bitpix = 8, .axes = &.{ 2000, 1 } });
    const h3 = try f.appendImageHdu(.{ .bitpix = 8, .axes = &.{7} });
    try writePattern(f.dev, h3.data_off, 7, 0x55);
    const old_h2_data_off = h2.data_off;
    const old_h3_header_off = h3.header_off;

    // Add enough keywords to push the header from one block (36 cards) into two.
    var name_buf: [8]u8 = undefined;
    var i: usize = 0;
    while (i < 41) : (i += 1) {
        const kw = std.fmt.bufPrint(&name_buf, "KEY{d:0>3}", .{i}) catch unreachable;
        try h2.header.update(f.alloc, kw, .{ .int = @intCast(i) }, null);
    }
    try f.rewriteHeaderInPlace(h2);

    try testing.expectEqual(@as(u64, 2000), h2.data_bytes); // data size unchanged
    try testing.expectEqual(old_h2_data_off + block.BLOCK, h2.data_off); // header grew one block
    try testing.expectEqual(old_h3_header_off + block.BLOCK, h3.header_off);
    try expectPattern(f.dev, h3.data_off, 7, 0x55);

    var f2 = try Fits.open(testing.allocator, b.mem.device(), .read_only, .{});
    defer f2.deinit();
    const r2 = try f2.select(2);
    try testing.expectEqual(@as(i64, 40), try r2.header.getValue(i64, "KEY040"));
}

test "deleteHdu removes the named HDU and the rest stay valid" {
    var b = try newHandle(testing.allocator);
    defer b.deinit(testing.allocator);
    const f = &b.f;
    _ = try f.appendImageHdu(.{ .bitpix = 8, .axes = &.{} });
    _ = try f.appendImageHdu(.{ .bitpix = 8, .axes = &.{10} }); // h2 (to be deleted)
    const h3 = try f.appendImageHdu(.{ .bitpix = 16, .axes = &.{ 4, 3 } }); // h3, known data
    try writePattern(f.dev, h3.data_off, 24, 0x90);

    try testing.expectEqual(@as(usize, 3), try f.hduCount());
    try f.deleteHdu(2);
    try testing.expectEqual(@as(usize, 2), f.hdus.items.len);

    // The old h3 is now HDU 2; its bytes moved down but stayed intact.
    const moved = try f.select(2);
    try testing.expectEqual(hdu_mod.HduKind.image, moved.kind);
    try testing.expectEqualSlices(u64, &.{ 4, 3 }, moved.axes);
    try expectPattern(f.dev, moved.data_off, 24, 0x90);

    // A fresh open agrees.
    var f2 = try Fits.open(testing.allocator, b.mem.device(), .read_only, .{});
    defer f2.deinit();
    try testing.expectEqual(@as(usize, 2), try f2.hduCount());
    const r2 = try f2.select(2);
    try testing.expectEqualSlices(u64, &.{ 4, 3 }, r2.axes);
}

test "deleteHdu refuses to delete the primary" {
    var b = try newHandle(testing.allocator);
    defer b.deinit(testing.allocator);
    const f = &b.f;
    _ = try f.appendImageHdu(.{ .bitpix = 8, .axes = &.{} });
    _ = try f.appendImageHdu(.{ .bitpix = 8, .axes = &.{4} });
    try testing.expectError(error.WrongHduType, f.deleteHdu(1));
    try testing.expectError(error.WrongHduType, f.deleteHdu(9)); // out of range
}

test "copyHdu produces a byte-identical duplicate" {
    var b = try newHandle(testing.allocator);
    defer b.deinit(testing.allocator);
    const f = &b.f;
    _ = try f.appendImageHdu(.{ .bitpix = 8, .axes = &.{} });
    const h2 = try f.appendImageHdu(.{ .bitpix = 16, .axes = &.{ 4, 3 } });
    try writePattern(f.dev, h2.data_off, 24, 0xA0);
    const src_start = h2.header_off;
    const src_len = h2.nextOff() - src_start;

    const dup = try f.copyHdu(2);
    try testing.expectEqual(@as(usize, 3), f.hdus.items.len);
    try testing.expectEqual(hdu_mod.HduKind.image, dup.kind);
    try testing.expectEqualSlices(u64, &.{ 4, 3 }, dup.axes);

    // The two on-disk byte ranges are identical.
    const a = try testing.allocator.alloc(u8, @intCast(src_len));
    defer testing.allocator.free(a);
    const c = try testing.allocator.alloc(u8, @intCast(src_len));
    defer testing.allocator.free(c);
    try f.dev.readAll(a, src_start);
    try f.dev.readAll(c, dup.header_off);
    try testing.expectEqualSlices(u8, a, c);

    var f2 = try Fits.open(testing.allocator, b.mem.device(), .read_only, .{});
    defer f2.deinit();
    try testing.expectEqual(@as(usize, 3), try f2.hduCount());
}

test "structural edits are rejected on a read-only handle" {
    const mem = try twoHduFile(testing.allocator);
    defer {
        mem.deinit();
        testing.allocator.destroy(mem);
    }
    var f = try Fits.open(testing.allocator, mem.device(), .read_only, .{});
    defer f.deinit();
    const h2 = try f.select(2);
    try testing.expectError(error.NotWritable, f.resizeHduData(h2, 100));
    try testing.expectError(error.NotWritable, f.rewriteHeaderInPlace(h2));
    try testing.expectError(error.NotWritable, f.deleteHdu(2));
    try testing.expectError(error.NotWritable, f.copyHdu(2));
}

test "distinct Fits handles run concurrently from multiple threads" {
    // A thread-safe allocator (the testing allocator's leak tracking is not thread-safe; leak
    // checking is covered by the single-threaded tests).
    const alloc = std.heap.smp_allocator;
    const N = 8;
    var oks = [_]bool{false} ** N;
    var threads: [N]std.Thread = undefined;
    for (&threads, 0..) |*t, i| {
        t.* = try std.Thread.spawn(.{}, concWorker, .{ alloc, &oks[i], @as(u32, @intCast(i + 1)) });
    }
    for (&threads) |t| t.join();
    for (oks) |ok| try testing.expect(ok);
}

//! GZIP_1 / GZIP_2 tile codecs (FR-CMP-2, §17.2; FITS 4.0 §10.4.2).
//!
//! Both use the gzip container (RFC 1952 header / CRC32 / ISIZE) over DEFLATE via
//! `std.compress.flate` — the container is supplied by `std`, never hand-rolled. `GZIP_2`
//! additionally applies the MSB-first type-aware byte shuffle (`compress/shuffle.zig`) before
//! compression (and its inverse after decompression) for multi-byte numeric elements only —
//! never logical/bit/character data.
const std = @import("std");
const flate = std.compress.flate;
const CompressError = @import("../errors.zig").CompressError;
const shuffle = @import("shuffle.zig");

const Allocator = std.mem.Allocator;
const Alloc = Allocator.Error;

/// GZIP_1: compress raw `in` bytes into a gzip stream. Caller owns the returned slice.
pub fn gzipEncode(alloc: Allocator, in: []const u8) (CompressError || Alloc)![]u8 {
    // gzip never expands data by more than the container overhead plus a small per-block
    // amount; this bound comfortably covers the worst case (stored blocks).
    const cap = in.len + (in.len >> 3) + 128;
    const out = try alloc.alloc(u8, cap);
    errdefer alloc.free(out);
    var ow = std.Io.Writer.fixed(out);
    var window: [flate.max_window_len]u8 = undefined;
    var comp = flate.Compress.init(&ow, &window, .gzip, .default) catch return error.CorruptTile;
    comp.writer.writeAll(in) catch return error.CorruptTile;
    comp.finish() catch return error.CorruptTile;
    const n = ow.buffered().len;
    // Shrink to fit. On the (essentially unreachable) realloc-down failure, propagate the error:
    // the `errdefer` above frees the intact `out` at its real capacity. Returning `out[0..n]`
    // instead would hand back a length-`n` slice of a capacity-length allocation, so a later
    // `alloc.free` sees a mismatched length (DebugAllocator asserts, page/arena leak or corrupt).
    return try alloc.realloc(out, n);
}

/// GZIP_1: decompress a gzip stream into raw bytes, bounded by `max_out` (NFR-SAFE-1).
/// Caller owns the returned slice.
pub fn gzipDecode(alloc: Allocator, in: []const u8, max_out: u64) (CompressError || Alloc)![]u8 {
    var rdr = std.Io.Reader.fixed(in);
    var window: [flate.max_window_len]u8 = undefined;
    return decodeMembers(alloc, &rdr, &window, max_out) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.CorruptTile,
    };
}

/// Append through EOF with an inclusive payload ceiling. Capacity growth never exceeds it.
pub fn appendBounded(alloc: Allocator, reader: *std.Io.Reader, out: *std.ArrayList(u8), max_out: u64) (Alloc || error{ LimitExceeded, ReadFailed })!void {
    const cap = std.math.cast(usize, max_out) orelse std.math.maxInt(usize);
    var buf: [8192]u8 = undefined;
    while (true) {
        if (out.items.len >= cap) {
            _ = reader.takeByte() catch |err| switch (err) {
                error.EndOfStream => return,
                error.ReadFailed => return error.ReadFailed,
            };
            return error.LimitExceeded;
        }
        const n = try reader.readSliceShort(buf[0..@min(buf.len, cap - out.items.len)]);
        if (n == 0) return;
        const needed = out.items.len + n;
        if (needed > out.capacity) {
            const grown = out.capacity +| @max(out.capacity, buf.len);
            try out.ensureTotalCapacityPrecise(alloc, @min(cap, @max(needed, grown)));
        }
        out.appendSliceAssumeCapacity(buf[0..n]);
    }
}

/// Decode every RFC-1952 member and verify each footer against that member's payload.
/// The aggregate payload ceiling is inclusive; the caller supplies reusable deflate scratch.
pub fn decodeMembers(alloc: Allocator, reader: *std.Io.Reader, window: []u8, max_out: u64) (Alloc || error{ LimitExceeded, Corrupt })![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    while (true) {
        const start = out.items.len;
        var dec = flate.Decompress.init(reader, .gzip, window);
        appendBounded(alloc, &dec.reader, &out, max_out) catch |err| switch (err) {
            error.ReadFailed => return error.Corrupt,
            else => |e| return e,
        };
        const payload = out.items[start..];
        const footer = dec.container_metadata.gzip;
        if (footer.crc != std.hash.Crc32.hash(payload) or footer.count != @as(u32, @truncate(payload.len))) return error.Corrupt;
        _ = reader.peekByte() catch |err| switch (err) {
            error.EndOfStream => return out.toOwnedSlice(alloc),
            error.ReadFailed => return error.Corrupt,
        };
    }
}

/// GZIP_2: decompress, then un-shuffle for the given element byte width. `elem_width` of 1
/// (B/A/L) means no shuffle was applied, so this is identical to `gzipDecode`. Caller owns
/// the returned slice.
pub fn gzip2Decode(alloc: Allocator, in: []const u8, elem_width: usize, max_out: u64) (CompressError || Alloc)![]u8 {
    const planes = try gzipDecode(alloc, in, max_out);
    if (elem_width <= 1) return planes;
    if (!isShuffleWidth(elem_width) or planes.len % elem_width != 0) {
        alloc.free(planes);
        return error.CorruptTile;
    }
    defer alloc.free(planes);
    const out = try alloc.alloc(u8, planes.len);
    errdefer alloc.free(out);
    shuffle.unshuffleWidth(elem_width, planes, out);
    return out;
}

/// GZIP_2: shuffle for the given element byte width, then compress. `elem_width` of 1 means
/// no shuffle. Caller owns the returned slice.
pub fn gzip2Encode(alloc: Allocator, in: []const u8, elem_width: usize) (CompressError || Alloc)![]u8 {
    if (elem_width <= 1) return gzipEncode(alloc, in);
    if (!isShuffleWidth(elem_width) or in.len % elem_width != 0) return error.DataConstraintViolated;
    const planes = try alloc.alloc(u8, in.len);
    defer alloc.free(planes);
    shuffle.shuffleWidth(elem_width, in, planes);
    return gzipEncode(alloc, planes);
}

fn isShuffleWidth(w: usize) bool {
    return w == 2 or w == 4 or w == 8 or w == 16;
}

const testing = std.testing;

test "GZIP_1 encode→decode round-trips" {
    const original = std.mem.asBytes(&@as([30]["SIMPLE  =                    T / FITS tile payload ".len]u8, @splat("SIMPLE  =                    T / FITS tile payload ".*)));
    const enc = try gzipEncode(testing.allocator, original);
    defer testing.allocator.free(enc);
    try testing.expect(enc.len < original.len);
    const dec = try gzipDecode(testing.allocator, enc, 1 << 20);
    defer testing.allocator.free(dec);
    try testing.expectEqualStrings(original, dec);
}

test "GZIP_2 shuffles numeric widths and round-trips" {
    inline for (.{ 2, 4, 8 }) |W| {
        var data: [W * 64]u8 = undefined;
        for (&data, 0..) |*b, i| b.* = @truncate(i * 7 + 3);
        const enc = try gzip2Encode(testing.allocator, &data, W);
        defer testing.allocator.free(enc);
        const dec = try gzip2Decode(testing.allocator, enc, W, 1 << 20);
        defer testing.allocator.free(dec);
        try testing.expectEqualSlices(u8, &data, dec);
    }
}

test "GZIP_2 with width 1 is plain gzip (no shuffle)" {
    const data = std.mem.asBytes(&@as([4]["byte column data, no shuffle for A/B/L".len]u8, @splat("byte column data, no shuffle for A/B/L".*)));
    const enc = try gzip2Encode(testing.allocator, data, 1);
    defer testing.allocator.free(enc);
    const dec = try gzip2Decode(testing.allocator, enc, 1, 1 << 20);
    defer testing.allocator.free(dec);
    try testing.expectEqualStrings(data, dec);
}

test "decode enforces the output ceiling" {
    const original = &@as([5000]u8, @splat('x'));
    const enc = try gzipEncode(testing.allocator, original);
    defer testing.allocator.free(enc);
    try testing.expectError(error.CorruptTile, gzipDecode(testing.allocator, enc, 100));
}

test "gzip validates every concatenated member and the inclusive aggregate ceiling" {
    const first = try gzipEncode(testing.allocator, "abc");
    defer testing.allocator.free(first);
    const second = try gzipEncode(testing.allocator, "de");
    defer testing.allocator.free(second);
    const joined = try std.mem.concat(testing.allocator, u8, &.{ first, second });
    defer testing.allocator.free(joined);
    const decoded = try gzipDecode(testing.allocator, joined, 5);
    defer testing.allocator.free(decoded);
    try testing.expectEqualStrings("abcde", decoded);
    try testing.expectError(error.CorruptTile, gzipDecode(testing.allocator, joined, 4));
    for ([_]usize{ 8, 4 }) |distance| {
        joined[joined.len - distance] ^= 1;
        try testing.expectError(error.CorruptTile, gzipDecode(testing.allocator, joined, 5));
        joined[joined.len - distance] ^= 1;
    }
    try testing.expectError(error.CorruptTile, gzipDecode(testing.allocator, joined[0 .. joined.len - 1], 5));
    const empty = try gzipEncode(testing.allocator, "");
    defer testing.allocator.free(empty);
    const empty_out = try gzipDecode(testing.allocator, empty, 0);
    defer testing.allocator.free(empty_out);
    try testing.expectEqual(@as(usize, 0), empty_out.len);
}

test "corrupt gzip stream fails typed" {
    try testing.expectError(error.CorruptTile, gzipDecode(testing.allocator, "not a gzip stream", 1 << 20));
}

test "malformed gzip back-reference fails typed" {
    const malformed = "\x1f\x8b\x08\x00\x00\x00\x00\x00\x00\xff" ++
        "\x03\x02\x00" ++
        "\x00\x00\x00\x00\x00\x00\x00\x00";
    try testing.expectError(error.CorruptTile, gzipDecode(testing.allocator, malformed, 1 << 20));
    try testing.expectError(error.CorruptTile, gzip2Decode(testing.allocator, malformed, 2, 1 << 20));
}

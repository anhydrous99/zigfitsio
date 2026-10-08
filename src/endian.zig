//! Big-endian wire access (GC-5, NFR-PORT-2, NFR-PERF-2).
//!
//! All FITS wire values are big-endian. This module is the **only** place that knows it:
//! every multi-byte read/write off disk goes through `read`/`write`, and bulk buffers are
//! converted in place by `swapToNative`. Floats are swapped through their same-width integer
//! representation (IEEE-754 byte order follows the integer byte order), never by arithmetic.
const std = @import("std");
const builtin = @import("builtin");

const native_endian = builtin.cpu.arch.endian();

/// The unsigned integer type with the same width as `T` (the bit-pattern carrier used for
/// byte-swapping floats and integers uniformly).
fn IntOf(comptime T: type) type {
    return switch (@typeInfo(T)) {
        .int => T,
        .float => @Int(.unsigned, @bitSizeOf(T)),
        else => @compileError("endian: unsupported type " ++ @typeName(T)),
    };
}

/// Read a big-endian value of type `T` (int or float) from exactly `@sizeOf(T)` bytes.
pub inline fn read(comptime T: type, bytes: *const [@sizeOf(T)]u8) T {
    const I = IntOf(T);
    return @bitCast(std.mem.readInt(I, bytes, .big));
}

/// Write `v` of type `T` (int or float) as big-endian into exactly `@sizeOf(T)` bytes.
pub inline fn write(comptime T: type, v: T, out: *[@sizeOf(T)]u8) void {
    const I = IntOf(T);
    const bits: I = @bitCast(v);
    std.mem.writeInt(I, out, bits, .big);
}

/// Unconditionally byte-swap each element of `items` in place. This is the work
/// `swapToNative` performs on a little-endian host; exposed directly so the swap logic is
/// testable on any host (the genuine native big-endian path is covered by the X-CI cell).
/// Vectorized over the elements' integer representation with a scalar tail; no allocation.
pub fn swapSlice(comptime T: type, items: []T) void {
    if (@sizeOf(T) == 1) return;
    const I = IntOf(T);
    const ints: []I = @ptrCast(@alignCast(items));
    const lanes = 16;
    var i: usize = 0;
    const n = ints.len;
    while (i + lanes <= n) : (i += lanes) {
        const v: @Vector(lanes, I) = ints[i..][0..lanes].*;
        ints[i..][0..lanes].* = @byteSwap(v);
    }
    while (i < n) : (i += 1) ints[i] = @byteSwap(ints[i]);
}

/// Convert a big-endian buffer to native byte order in place (no-op on big-endian hosts or
/// 1-byte elements). Used by bulk image/column paths after a block read (NFR-PERF-2).
pub fn swapToNative(comptime T: type, items: []T) void {
    if (native_endian == .big or @sizeOf(T) == 1) return;
    swapSlice(T, items);
}

/// Convert a native-order buffer to big-endian in place before a bulk write. Identical to
/// `swapToNative` (byte-swap is its own inverse), named for intent at the call site.
pub fn swapToBig(comptime T: type, items: []T) void {
    swapToNative(T, items);
}

const testing = std.testing;

test "read/write round-trips per width" {
    inline for (.{ u16, i16, u32, i32, u64, i64, f32, f64 }) |T| {
        var buf: [@sizeOf(T)]u8 = undefined;
        const v: T = switch (@typeInfo(T)) {
            .float => @as(T, 3.14159),
            else => @as(T, 0x1234 % std.math.maxInt(T)),
        };
        write(T, v, &buf);
        try testing.expectEqual(v, read(T, &buf));
    }
}

test "read decodes known big-endian bytes" {
    const bytes = [_]u8{ 0x12, 0x34, 0x56, 0x78 };
    try testing.expectEqual(@as(u32, 0x12345678), read(u32, &bytes));
    try testing.expectEqual(@as(i16, 0x1234), read(i16, bytes[0..2]));
}

test "swapSlice is its own inverse and vectorizes past 16 lanes" {
    var data: [40]u32 = undefined;
    for (&data, 0..) |*d, idx| d.* = @intCast(idx * 0x01020304 +% 1);
    const original = data;
    swapSlice(u32, &data);
    try testing.expect(!std.mem.eql(u32, &original, &data)); // actually changed
    swapSlice(u32, &data);
    try testing.expectEqualSlices(u32, &original, &data); // restored
}

test "forced swap matches manual byte reversal for floats" {
    var fs = [_]f64{ 1.0, -2.5, 1.0e300 };
    const expected = if (native_endian == .little)
        [_]u8{ 0x3f, 0xf0, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xc0, 0x04, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x7e, 0x37, 0xe4, 0x3c, 0x88, 0x00, 0x75, 0x9c }
    else
        [_]u8{ 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xf0, 0x3f, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x04, 0xc0, 0x9c, 0x75, 0x00, 0x88, 0x3c, 0xe4, 0x37, 0x7e };
    swapSlice(f64, &fs);
    try testing.expectEqualSlices(u8, &expected, std.mem.sliceAsBytes(&fs));
}

test "1-byte and single-byte-int elements are untouched" {
    var bytes = [_]u8{ 1, 2, 3 };
    swapSlice(u8, &bytes);
    try testing.expectEqualSlices(u8, &[_]u8{ 1, 2, 3 }, &bytes);
}

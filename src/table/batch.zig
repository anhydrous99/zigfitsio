//! Bounded row-window batching shared by binary and ASCII tables.
//!
//! Column values are strided by `NAXIS1` on disk.  Reading or writing one field at a time
//! therefore turns a column transfer into one device call per row.  `Plan` groups adjacent
//! rows into bounded windows when the amount of unrelated row data is reasonable; callers
//! perform one physical read (and, for writes, one read-modify-write) per window and use the
//! borrowed in-memory device below for the existing cell codecs.
const std = @import("std");
const errors = @import("../errors.zig");
const Device = @import("../io/device.zig").Device;

/// Target physical transfer size.  Large enough to amortize syscall/HTTP overhead while
/// remaining cheap to allocate once per column operation.
pub const target_bytes: usize = 64 * 1024;

/// Do not read whole rows when doing so would transfer more than this multiple of the selected
/// field.  Very wide sparse rows retain the scalar path until vectored I/O is available.
pub const max_amplification: u64 = 8;

pub const Plan = struct {
    rows_per_window: usize,
    window_bytes: usize,

    /// Returns `null` when scalar field I/O is preferable or when the window cannot be safely
    /// represented/allocated on this target.
    pub fn init(row_bytes: u64, field_bytes: u64, row_count: u64, alloc_limit: u64) ?Plan {
        if (row_count < 2 or row_bytes == 0 or field_bytes == 0) return null;
        const allowed = std.math.mul(u64, field_bytes, max_amplification) catch std.math.maxInt(u64);
        if (row_bytes > allowed or row_bytes > alloc_limit or row_bytes > target_bytes) return null;

        const byte_budget = @min(@as(u64, target_bytes), alloc_limit);
        const rows64 = @min(row_count, @max(@as(u64, 1), byte_budget / row_bytes));
        const bytes64 = std.math.mul(u64, rows64, row_bytes) catch return null;
        if (bytes64 > alloc_limit) return null;
        return .{
            .rows_per_window = std.math.cast(usize, rows64) orelse return null,
            .window_bytes = std.math.cast(usize, bytes64) orelse return null,
        };
    }
};

/// Validate a caller-owned row-strided destination and return its row count as `usize`.
/// Only the addressed cell bytes must be present; padding after the final row is optional.
pub fn validateStrided(row_count: u64, cell_bytes: usize, row_stride: usize, out_len: usize) errors.TableError!usize {
    const rows = std.math.cast(usize, row_count) orelse return error.CellOutOfRange;
    if (rows == 0) return 0;
    if (row_stride < cell_bytes) return error.CellOutOfRange;
    const last = std.math.mul(usize, rows - 1, row_stride) catch return error.CellOutOfRange;
    const span = std.math.add(usize, last, cell_bytes) catch return error.CellOutOfRange;
    if (span > out_len) return error.CellOutOfRange;
    return rows;
}

/// Non-owning, fixed-size writable memory device used to run the existing cell codecs over a
/// physical row window.  It never grows and does not own or close the caller's buffer.
pub const BorrowedDevice = struct {
    bytes: []u8,

    fn pread(ctx: *anyopaque, dst: []u8, offset: u64) errors.IoError!usize {
        const self: *BorrowedDevice = @ptrCast(@alignCast(ctx));
        const off = std.math.cast(usize, offset) orelse return 0;
        if (off >= self.bytes.len) return 0;
        const n = @min(dst.len, self.bytes.len - off);
        @memcpy(dst[0..n], self.bytes[off..][0..n]);
        return n;
    }

    fn pwrite(ctx: *anyopaque, src: []const u8, offset: u64) errors.IoError!usize {
        const self: *BorrowedDevice = @ptrCast(@alignCast(ctx));
        const off = std.math.cast(usize, offset) orelse return error.DeviceFull;
        const end = std.math.add(usize, off, src.len) catch return error.DeviceFull;
        if (end > self.bytes.len) return error.DeviceFull;
        @memcpy(self.bytes[off..end], src);
        return src.len;
    }

    fn getSize(ctx: *anyopaque) errors.IoError!u64 {
        const self: *BorrowedDevice = @ptrCast(@alignCast(ctx));
        return self.bytes.len;
    }
    fn setSize(_: *anyopaque, _: u64) errors.IoError!void {
        return error.NotWritable;
    }
    fn sync(_: *anyopaque) errors.IoError!void {}
    fn close(_: *anyopaque) void {}

    const vtable: Device.VTable = .{
        .pread = pread,
        .pwrite = pwrite,
        .getSize = getSize,
        .setSize = setSize,
        .sync = sync,
        .close = close,
    };

    pub fn device(self: *BorrowedDevice) Device {
        return .{ .ptr = self, .vtable = &vtable };
    }
};

test "planner batches dense rows and rejects sparse rows" {
    const testing = std.testing;
    const dense = Plan.init(32, 4, 100_000, 1 << 32).?;
    try testing.expect(dense.rows_per_window > 1);
    try testing.expect(dense.window_bytes <= target_bytes);
    try testing.expect(Plan.init(4096, 4, 100_000, 1 << 32) == null);
    try testing.expect(Plan.init(32, 4, 1, 1 << 32) == null);

    const limited = Plan.init(16, 4, 10_000, 4096).?;
    try testing.expectEqual(@as(usize, 256), limited.rows_per_window);
    try testing.expectEqual(@as(usize, 4096), limited.window_bytes);
}

test "row-strided destination validation checks span and overflow" {
    const testing = std.testing;
    try testing.expectEqual(@as(usize, 3), try validateStrided(3, 4, 9, 22));
    try testing.expectEqual(@as(usize, 0), try validateStrided(0, 8, 0, 0));
    try testing.expectError(error.CellOutOfRange, validateStrided(2, 4, 3, 8));
    try testing.expectError(error.CellOutOfRange, validateStrided(3, 4, 9, 21));
    try testing.expectError(error.CellOutOfRange, validateStrided(2, 1, std.math.maxInt(usize), std.math.maxInt(usize)));
}

test "borrowed device reads and writes without resizing" {
    const testing = std.testing;
    var storage = [_]u8{ 0, 1, 2, 3 };
    var borrowed: BorrowedDevice = .{ .bytes = &storage };
    const dev = borrowed.device();
    var out: [2]u8 = undefined;
    try dev.readAll(&out, 1);
    try testing.expectEqualSlices(u8, &.{ 1, 2 }, &out);
    try dev.writeAll(&.{ 9, 8 }, 2);
    try testing.expectEqualSlices(u8, &.{ 0, 1, 9, 8 }, &storage);
    try testing.expectError(error.DeviceFull, dev.writeAll(&.{ 7, 6 }, 3));
}

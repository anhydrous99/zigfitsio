//! On-disk `Device` backend over `std.Io.File` (FR-IO-3/5/6, §8.1).
//!
//! Wraps a `std.Io.File` with positioned 64-bit reads/writes. Zig 0.16 threads a `std.Io`
//! instance through file operations; that instance is owned here (a single-threaded
//! `std.Io.Threaded`) so the rest of the library only ever sees the `Device` vtable and
//! never the OS. This is an OS-backed leaf module: it is excluded from the
//! `wasm32-freestanding` build graph (the in-memory backend is the freestanding path).
const std = @import("std");
const builtin = @import("builtin");
const IoError = @import("../errors.zig").IoError;
const Device = @import("device.zig").Device;

/// How to open a path.
pub const Access = enum {
    /// Open an existing file read-only (write operations return `error.NotWritable`).
    read_only,
    /// Open an existing file read/write.
    read_write,
    /// Create (or truncate) a file read/write.
    create,
};

/// Errors that can occur opening a `FileDevice`.
pub const OpenError = IoError || std.mem.Allocator.Error;

/// A heap-allocated, pinned `Device` backed by an on-disk file. Created by `open`/`openPath`
/// or `fromHandle`;
/// released by `Device.close` (which frees this struct), so the owner just holds the
/// `Device`.
pub const FileDevice = struct {
    alloc: std.mem.Allocator,
    threaded: std.Io.Threaded,
    file: std.Io.File,
    owns_file: bool = true,

    fn io(self: *FileDevice) std.Io {
        return self.threaded.io();
    }

    /// Open `path` relative to `dir` with the given access mode.
    pub fn open(allocator: std.mem.Allocator, dir: std.Io.Dir, path: []const u8, access: Access) OpenError!Device {
        const self = try allocator.create(FileDevice);
        errdefer allocator.destroy(self);
        self.* = .{ .alloc = allocator, .threaded = .init_single_threaded, .file = undefined };
        self.file = switch (access) {
            .read_only => dir.openFile(self.io(), path, .{ .mode = .read_only }),
            .read_write => dir.openFile(self.io(), path, .{ .mode = .read_write }),
            .create => dir.createFile(self.io(), path, .{ .read = true, .truncate = true }),
        } catch return error.ReadFailed;
        return .{ .ptr = self, .vtable = if (access == .read_only) &ro_vtable else &rw_vtable };
    }

    /// Open `path` relative to the current working directory.
    pub fn openPath(allocator: std.mem.Allocator, path: []const u8, access: Access) OpenError!Device {
        return open(allocator, std.Io.Dir.cwd(), path, access);
    }

    /// Borrow an empty blocking buffered read/write regular file. The caller retains its OS handle
    /// and must keep it open, without concurrent I/O, until this device is closed.
    pub fn fromHandle(allocator: std.mem.Allocator, native_handle: usize) OpenError!Device {
        const self = try allocator.create(FileDevice);
        errdefer allocator.destroy(self);
        const handle: std.Io.File.Handle = if (builtin.os.tag == .windows) blk: {
            if (native_handle == 0 or native_handle == std.math.maxInt(usize)) return error.NotWritable;
            break :blk @ptrFromInt(native_handle);
        } else std.math.cast(std.Io.File.Handle, native_handle) orelse return error.NotWritable;
        self.* = .{
            .alloc = allocator,
            .threaded = .init_single_threaded,
            .file = .{ .handle = handle, .flags = .{ .nonblocking = false } },
            .owns_file = false,
        };
        if (builtin.os.tag == .windows) {
            const windows = std.os.windows;
            var iosb: windows.IO_STATUS_BLOCK = undefined;
            var info: windows.FILE.ALL_INFORMATION = undefined;
            switch (windows.ntdll.NtQueryInformationFile(handle, &iosb, &info, @sizeOf(@TypeOf(info)), .All)) {
                .SUCCESS, .BUFFER_OVERFLOW => {},
                else => return error.NotWritable,
            }
            const access = info.AccessInformation.AccessFlags.SPECIFIC.FILE;
            const mode = info.ModeInformation.Mode;
            if (info.StandardInformation.Directory.toBool() or info.StandardInformation.EndOfFile != 0 or
                !access.READ_DATA or !access.WRITE_DATA or mode.NO_INTERMEDIATE_BUFFERING or
                (mode.IO != .SYNCHRONOUS_ALERT and mode.IO != .SYNCHRONOUS_NONALERT)) return error.NotWritable;
        } else {
            // Check foreign descriptors before std.Io operations: std assumes EBADF is a
            // programming error and may panic. Positioned writes also require no O_APPEND.
            const result = std.posix.system.fcntl(handle, std.posix.F.GETFL, @as(usize, 0));
            if (std.posix.errno(result) != .SUCCESS) return error.NotWritable;
            const flags: std.posix.O = @bitCast(@as(u32, @intCast(result)));
            if (flags.ACCMODE != .RDWR or flags.NONBLOCK or flags.APPEND) return error.NotWritable;
            if (@hasField(std.posix.O, "DIRECT")) {
                if (flags.DIRECT) return error.NotWritable; // FITS card I/O is not sector-aligned
            }
            const info = self.file.stat(self.io()) catch return error.NotWritable;
            if (info.kind != .file or info.size != 0) return error.NotWritable;
        }
        return .{ .ptr = self, .vtable = &rw_vtable };
    }

    fn pread(ctx: *anyopaque, buf: []u8, offset: u64) IoError!usize {
        const self: *FileDevice = @ptrCast(@alignCast(ctx));
        return self.file.readPositionalAll(self.io(), buf, offset) catch error.ReadFailed;
    }

    fn pwrite(ctx: *anyopaque, buf: []const u8, offset: u64) IoError!usize {
        const self: *FileDevice = @ptrCast(@alignCast(ctx));
        self.file.writePositionalAll(self.io(), buf, offset) catch return error.WriteFailed;
        return buf.len;
    }

    fn getSize(ctx: *anyopaque) IoError!u64 {
        const self: *FileDevice = @ptrCast(@alignCast(ctx));
        return self.file.length(self.io()) catch error.ReadFailed;
    }

    fn setSize(ctx: *anyopaque, size: u64) IoError!void {
        const self: *FileDevice = @ptrCast(@alignCast(ctx));
        self.file.setLength(self.io(), size) catch return error.WriteFailed;
    }

    fn syncFn(ctx: *anyopaque) IoError!void {
        const self: *FileDevice = @ptrCast(@alignCast(ctx));
        self.file.sync(self.io()) catch return error.WriteFailed;
    }

    // A read-only device has no buffered writes to flush, so sync is a no-op. Crucially it must
    // NOT reach the OS: FlushFileBuffers on a read-only Windows handle fails with
    // ERROR_ACCESS_DENIED (POSIX fsync on a read-only fd is a harmless success, which is why this
    // only surfaced on Windows). `Fits.flush` runs on any handle — including a read-only open
    // copied via writeto()/to_bytes() — so this path is reached in normal use.
    fn noSyncFn(_: *anyopaque) IoError!void {}

    fn closeFn(ctx: *anyopaque) void {
        const self: *FileDevice = @ptrCast(@alignCast(ctx));
        if (self.owns_file) self.file.close(self.io());
        self.alloc.destroy(self);
    }

    const ro_vtable: Device.VTable = .{
        .pread = pread,
        .pwrite = null,
        .getSize = getSize,
        .setSize = null,
        .sync = noSyncFn,
        .close = closeFn,
    };
    const rw_vtable: Device.VTable = .{
        .pread = pread,
        .pwrite = pwrite,
        .getSize = getSize,
        .setSize = setSize,
        .sync = syncFn,
        .close = closeFn,
    };
};

const testing = std.testing;

test "file device create→write→reopen→read round-trip; read-only rejects writes" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    {
        const dev = try FileDevice.open(testing.allocator, tmp.dir, "rt.fits", .create);
        defer dev.close();
        try testing.expect(dev.isWritable());
        try dev.writeAll("FITS-DATA", 0);
        try dev.sync();
        try testing.expectEqual(@as(u64, 9), try dev.getSize());
    }
    {
        const dev = try FileDevice.open(testing.allocator, tmp.dir, "rt.fits", .read_only);
        defer dev.close();
        try testing.expect(!dev.isWritable());
        try testing.expectError(error.NotWritable, dev.writeAll("x", 0));
        // A read-only sync is a no-op that must succeed and never reach the OS — FlushFileBuffers
        // on a read-only handle fails on Windows. `Fits.flush` hits this when a read-only open is
        // copied via writeto()/to_bytes().
        try dev.sync();
        var buf: [9]u8 = undefined;
        try dev.readAll(&buf, 0);
        try testing.expectEqualStrings("FITS-DATA", &buf);
    }
    {
        const dev = try FileDevice.open(testing.allocator, tmp.dir, "rt.fits", .read_write);
        defer dev.close();
        try dev.setSize(2880); // grow to a block boundary
        try testing.expectEqual(@as(u64, 2880), try dev.getSize());
    }
}

test "opening a missing path is error.ReadFailed (and leaks nothing)" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // A read-only open of a path that does not exist must surface the typed I/O error rather than
    // a panic, and the half-built `FileDevice` must be freed (errdefer covers the allocation).
    try testing.expectError(
        error.ReadFailed,
        FileDevice.open(testing.allocator, tmp.dir, "does-not-exist.fits", .read_only),
    );
}

fn nativeHandle(file: std.Io.File) usize {
    return if (builtin.os.tag == .windows) @intFromPtr(file.handle) else @intCast(file.handle);
}

test "borrowed file device rejects unsuitable handles and retains caller ownership" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const io_ = testing.io;
    const caller = try tmp.dir.createFile(io_, "borrowed.fits", .{ .read = true });
    defer caller.close(io_);
    const handle = nativeHandle(caller);
    try testing.expectError(error.NotWritable, FileDevice.fromHandle(testing.allocator, std.math.maxInt(usize)));
    try testing.expectError(error.NotWritable, FileDevice.fromHandle(testing.allocator, 1234567));
    if (builtin.os.tag == .windows) try testing.expectError(error.NotWritable, FileDevice.fromHandle(testing.allocator, 0));
    const closed = try tmp.dir.createFile(io_, "closed.fits", .{ .read = true });
    const closed_handle = nativeHandle(closed);
    closed.close(io_);
    try testing.expectError(error.NotWritable, FileDevice.fromHandle(testing.allocator, closed_handle));
    const ro = try tmp.dir.openFile(io_, "borrowed.fits", .{});
    defer ro.close(io_);
    try testing.expectError(error.NotWritable, FileDevice.fromHandle(testing.allocator, nativeHandle(ro)));
    _ = try ro.stat(io_); // rejection must not close its descriptor
    if (builtin.os.tag != .windows) {
        const directory = try tmp.dir.openDir(io_, ".", .{});
        defer directory.close(io_);
        try testing.expectError(error.NotWritable, FileDevice.fromHandle(testing.allocator, @intCast(directory.handle)));
        const original = std.posix.system.fcntl(caller.handle, std.posix.F.GETFL, @as(usize, 0));
        for ([_]u32{ @bitCast(std.posix.O{ .APPEND = true }), @bitCast(std.posix.O{ .NONBLOCK = true }) }) |flag| {
            try testing.expect(std.posix.errno(std.posix.system.fcntl(caller.handle, std.posix.F.SETFL, @as(usize, @intCast(original)) | flag)) == .SUCCESS);
            try testing.expectError(error.NotWritable, FileDevice.fromHandle(testing.allocator, handle));
            try testing.expect(std.posix.errno(std.posix.system.fcntl(caller.handle, std.posix.F.SETFL, @as(usize, @intCast(original)))) == .SUCCESS);
        }
    }
    const borrowed = try FileDevice.fromHandle(testing.allocator, handle);
    try borrowed.writeAll("owned by caller", 0);
    try borrowed.sync();
    borrowed.close();
    var saved: [15]u8 = undefined;
    try testing.expectEqual(saved.len, try caller.readPositionalAll(io_, &saved, 0));
    try testing.expectEqualStrings("owned by caller", &saved);
    try testing.expectError(error.NotWritable, FileDevice.fromHandle(testing.allocator, handle));
    try testing.expectEqual(@as(u64, saved.len), try caller.length(io_));
}

test "borrowed file device rejects Linux direct I/O before std.Io" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const caller = try tmp.dir.createFile(testing.io, "direct.fits", .{ .read = true });
    defer caller.close(testing.io);
    const original = std.posix.system.fcntl(caller.handle, std.posix.F.GETFL, @as(usize, 0));
    try testing.expect(std.posix.errno(original) == .SUCCESS);
    const direct: u32 = @bitCast(std.posix.O{ .DIRECT = true });
    switch (std.posix.errno(std.posix.system.fcntl(caller.handle, std.posix.F.SETFL, @as(usize, @intCast(original)) | direct))) {
        .SUCCESS => {},
        .INVAL, .OPNOTSUPP => return error.SkipZigTest, // backing filesystem has no O_DIRECT support
        else => return error.TestUnexpectedResult,
    }
    try testing.expectError(error.NotWritable, FileDevice.fromHandle(testing.allocator, nativeHandle(caller)));
    try testing.expectEqual(@as(u64, 0), try caller.length(testing.io));
}

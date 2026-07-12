//! Throughput benchmarks for `zigfitsio` (X-BENCH, NFR-PERF-1/2/3).
//!
//! Measures bulk image read/write and checksum update/verify throughput over an in-memory `Device`
//! (no syscalls, so the numbers reflect the library's transfer, endian-conversion, and checksum
//! paths rather than disk). The hot paths use bounded bulk buffers — no per-element allocation
//! (NFR-PERF-1/3). This is a reporting tool, not a release gate: it prints MB/s and checks every
//! result so a regression that corrupts data also fails the run.
const std = @import("std");
const fits = @import("zigfitsio");

fn mbPerSec(bytes: u64, ns: u64) f64 {
    if (ns == 0) return 0;
    const secs = @as(f64, @floatFromInt(ns)) / 1e9;
    return (@as(f64, @floatFromInt(bytes)) / (1024.0 * 1024.0)) / secs;
}

// Monotonic elapsed nanoseconds via the std.Io `.awake` clock (Zig 0.16 retired std.time.Timer).
fn elapsedNs(io: std.Io, start: std.Io.Timestamp) u64 {
    const end = std.Io.Timestamp.now(io, .awake);
    return @intCast(end.nanoseconds - start.nanoseconds);
}

fn benchImage(comptime T: type, io: std.Io, a: std.mem.Allocator, bitpix: i64, w: u64, h: u64, reps: usize) !void {
    const n = w * h;
    const src = try a.alloc(T, n);
    defer a.free(src);
    const dst = try a.alloc(T, n);
    defer a.free(dst);
    for (src, 0..) |*p, i| {
        const v = i % 1000;
        p.* = if (@typeInfo(T) == .float) @floatFromInt(v) else @intCast(v);
    }

    var mem = fits.MemoryDevice.init(a);
    defer mem.deinit();
    var f = try fits.create(a, mem.device(), .{});
    defer f.deinit();
    var img = try fits.ImageView.append(&f, .{ .bitpix = bitpix, .axes = &.{ w, h } });

    const bytes_per_rep = n * @sizeOf(T);

    var t0 = std.Io.Timestamp.now(io, .awake);
    var r: usize = 0;
    while (r < reps) : (r += 1) try img.writeAll(T, src, .{});
    const write_ns = elapsedNs(io, t0);

    t0 = std.Io.Timestamp.now(io, .awake);
    r = 0;
    while (r < reps) : (r += 1) try img.readAll(T, dst, .{});
    const read_ns = elapsedNs(io, t0);

    if (!std.mem.eql(T, src, dst)) return error.RoundTripMismatch;

    const abspix: u64 = @intCast(if (bitpix < 0) -bitpix else bitpix); // unsigned: `{d}` would prefix a signed value with '+'
    std.debug.print(
        "  {s:<4} {d:>4}-bit {d}x{d}   write {d:>8.1} MB/s    read {d:>8.1} MB/s\n",
        .{
            @typeName(T),                             abspix,
            w,                                        h,
            mbPerSec(bytes_per_rep * reps, write_ns), mbPerSec(bytes_per_rep * reps, read_ns),
        },
    );
}

fn benchChecksum(io: std.Io, a: std.mem.Allocator, bytes: u64, reps: usize) !void {
    var mem = fits.MemoryDevice.init(a);
    defer mem.deinit();
    var f = try fits.create(a, mem.device(), .{ .checksum_on_close = true });
    defer f.deinit();
    const hdu = try f.appendImageHdu(.{ .bitpix = 8, .axes = &.{bytes} });

    // Warm the allocation/device pages and leave valid cards for the verification loop.
    try fits.checksum.update(&f, hdu);

    var t0 = std.Io.Timestamp.now(io, .awake);
    var r: usize = 0;
    while (r < reps) : (r += 1) try fits.checksum.update(&f, hdu);
    const update_ns = elapsedNs(io, t0);

    t0 = std.Io.Timestamp.now(io, .awake);
    r = 0;
    while (r < reps) : (r += 1) {
        const report = try fits.checksum.verify(&f, hdu);
        if (report.data != .match or report.sum != .match) return error.ChecksumMismatch;
    }
    const verify_ns = elapsedNs(io, t0);

    std.debug.print(
        "  checksum {d:>4} MiB          update {d:>8.1} MB/s  verify {d:>8.1} MB/s\n",
        .{
            bytes / (1024 * 1024),
            mbPerSec(bytes * reps, update_ns),
            mbPerSec(bytes * reps, verify_ns),
        },
    );
}

fn benchTiledI16(io: std.Io, a: std.mem.Allocator, w: u64, h: u64, reps: usize) !void {
    const n = w * h;
    const src = try a.alloc(i16, n);
    defer a.free(src);
    const dst = try a.alloc(i16, n);
    defer a.free(dst);
    for (src, 0..) |*p, i| p.* = @intCast(i % 1000);

    var mem = fits.MemoryDevice.init(a);
    defer mem.deinit();
    var f = try fits.create(a, mem.device(), .{});
    defer f.deinit();
    _ = try f.appendImageHdu(.{ .bitpix = 8, .axes = &.{} });
    const hdu = try fits.writeCompressed(i16, &f, .{
        .bitpix = 16,
        .axes = &.{ w, h },
        .tile = &.{ 32, 32 },
        .codec = .gzip_1,
    }, src);
    var image = try fits.TiledImage.of(&f, hdu);
    defer image.deinit(a);

    // Warm the codec/build caches before timing. Deterministic request-count assertions live in
    // the tiled unit tests; this benchmark measures the complete tiled read path.
    try image.readAll(i16, dst);
    const t0 = std.Io.Timestamp.now(io, .awake);
    var r: usize = 0;
    while (r < reps) : (r += 1) try image.readAll(i16, dst);
    const read_ns = elapsedNs(io, t0);
    if (!std.mem.eql(i16, src, dst)) return error.RoundTripMismatch;

    std.debug.print(
        "  tiled i16 16-bit {d}x{d} 32x32 tiles   read {d:>8.1} MB/s\n",
        .{ w, h, mbPerSec(n * @sizeOf(i16) * reps, read_ns) },
    );
}

pub fn main() !void {
    const a = std.heap.page_allocator;
    var threaded: std.Io.Threaded = .init_single_threaded;
    const io = threaded.io();
    std.debug.print("zigfitsio {s} — bulk/checksum throughput (in-memory device, no syscalls)\n", .{fits.version});
    // f32/f64 hit the float path (no endian-swap allocation); i16/i32 exercise the big-endian
    // swap on the hot path. 1024x1024 keeps each tile a few MiB so timing is stable.
    try benchImage(f32, io, a, -32, 1024, 1024, 40);
    try benchImage(f64, io, a, -64, 1024, 1024, 20);
    try benchImage(i16, io, a, 16, 1024, 1024, 40);
    try benchImage(i32, io, a, 32, 1024, 1024, 40);
    try benchTiledI16(io, a, 512, 512, 20);
    try benchChecksum(io, a, 64 * 1024 * 1024, 5);
    std.debug.print("ok — all round-trips verified\n", .{});
}

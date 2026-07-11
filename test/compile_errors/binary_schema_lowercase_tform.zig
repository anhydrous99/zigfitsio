const fits = @import("zigfitsio");

comptime {
    _ = fits.BinarySchema(&.{
        .{ .name = "COUNT", .tform = "1j" },
    });
}

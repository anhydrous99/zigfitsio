const fits = @import("zigfitsio");

comptime {
    _ = fits.BinarySchema(&.{
        .{ .name = "FLUX", .tform = "1E" },
        .{ .name = "flux", .tform = "1D" },
    });
}

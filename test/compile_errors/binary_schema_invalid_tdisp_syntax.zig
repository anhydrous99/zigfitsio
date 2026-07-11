const fits = @import("zigfitsio");

comptime {
    _ = fits.BinarySchema(&.{
        .{ .name = "LABEL", .tform = "8A", .tdisp = "A8.2" },
    });
}

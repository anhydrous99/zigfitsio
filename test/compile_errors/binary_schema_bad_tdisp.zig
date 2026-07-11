const fits = @import("zigfitsio");

comptime {
    _ = fits.BinarySchema(&.{
        .{ .name = "COUNT", .tform = "1J", .tdisp = "Q8" },
    });
}

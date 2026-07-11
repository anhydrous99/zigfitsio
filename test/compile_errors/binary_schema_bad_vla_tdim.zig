const fits = @import("zigfitsio");

comptime {
    _ = fits.BinarySchema(&.{
        .{ .name = "VALUES", .tform = "1PJ(4)", .tdim = &.{10} },
    });
}

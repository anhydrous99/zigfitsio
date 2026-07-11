const fits = @import("zigfitsio");

comptime {
    _ = fits.BinarySchema(&.{
        .{ .name = "COORD", .tform = "4E", .tdim = &.{ 3, 2 } },
    });
}

const fits = @import("zigfitsio");

comptime {
    _ = fits.Iterator(struct {
        x: [:0]u8,
    }, error{});
}

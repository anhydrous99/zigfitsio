const fits = @import("zigfitsio");

comptime {
    _ = fits.Iterator(struct {
        x: i32,
    }, error{});
}

/* External benchmark only: match tools/bench.zig's memory image workloads. */
#include <fitsio.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

static double now(void) {
    struct timespec t;
    if (clock_gettime(CLOCK_MONOTONIC, &t)) exit(1);
    return (double)t.tv_sec + (double)t.tv_nsec / 1e9;
}

static void check(int status) {
    if (status) {
        fits_report_error(stderr, status);
        exit(1);
    }
}

static void bench_image(const char *name, int bitpix, int datatype, size_t width,
                        long side, int reps, int tiled) {
    size_t n = (size_t)side * side;
    void *src = malloc(n * width), *dst = malloc(n * width), *memory = NULL;
    size_t memory_size = 0;
    fitsfile *f = NULL;
    int status = 0, anynull = 0;
    if (!src || !dst) exit(1);
    for (size_t i = 0; i < n; ++i) {
        switch (datatype) {
        case TFLOAT: ((float *)src)[i] = (float)(i % 1000); break;
        case TDOUBLE: ((double *)src)[i] = (double)(i % 1000); break;
        case TSHORT: ((int16_t *)src)[i] = (int16_t)(i % 1000); break;
        case TINT: ((int32_t *)src)[i] = (int32_t)(i % 1000); break;
        default: exit(1);
        }
    }
    fits_create_memfile(&f, &memory, &memory_size, 2880, realloc, &status);
    long axes[2] = {side, side};
    if (tiled) {
        long tile[2] = {32, 32};
        fits_set_compression_type(f, GZIP_1, &status);
        fits_set_tile_dim(f, 2, tile, &status);
    }
    fits_create_img(f, bitpix, 2, axes, &status);
    check(status);
    double start = now();
    for (int r = 0; r < (tiled ? 1 : reps); ++r)
        fits_write_img(f, datatype, 1, (LONGLONG)n, src, &status);
    check(status);
    double write_seconds = now() - start;
    if (tiled) {
        fits_read_img(f, datatype, 1, (LONGLONG)n, NULL, dst, &anynull, &status);
        check(status); /* same warm complete tiled read as the Zig workload */
    }
    start = now();
    for (int r = 0; r < reps; ++r)
        fits_read_img(f, datatype, 1, (LONGLONG)n, NULL, dst, &anynull, &status);
    check(status);
    double read_seconds = now() - start;
    if (memcmp(src, dst, n * width)) {
        fprintf(stderr, "CFITSIO round-trip mismatch: %s\n", name);
        exit(1);
    }
    double mib = (double)(n * width) * reps / (1024.0 * 1024.0);
    if (tiled)
        printf("  tiled i16 16-bit %ldx%ld 32x32 tiles   read %8.1f MB/s\n", side, side, mib / read_seconds);
    else
        printf("  %-4s %4d-bit %ldx%ld   write %8.1f MB/s    read %8.1f MB/s\n",
               name, abs(bitpix), side, side, mib / write_seconds, mib / read_seconds);
    fits_close_file(f, &status);
    check(status);
    free(memory);
    free(src);
    free(dst);
}

int main(void) {
    float version;
    fits_get_version(&version);
    printf("CFITSIO %.3f — bulk image throughput (memory file, no disk I/O)\n", version);
    bench_image("f32", FLOAT_IMG, TFLOAT, sizeof(float), 1024, 40, 0);
    bench_image("f64", DOUBLE_IMG, TDOUBLE, sizeof(double), 1024, 20, 0);
    bench_image("i16", SHORT_IMG, TSHORT, sizeof(int16_t), 1024, 40, 0);
    bench_image("i32", LONG_IMG, TINT, sizeof(int32_t), 1024, 40, 0);
    bench_image("i16", SHORT_IMG, TSHORT, sizeof(int16_t), 512, 20, 1);
    puts("ok — all round-trips verified");
    return 0;
}

# zigfitsio (TypeScript/JavaScript bindings)

TypeScript bindings for [zigfitsio](https://github.com/anhydrous99/zigfitsio), a pure-Zig
FITS 4.0 I/O library. Same two-layer design as the Python bindings: a low-level 1:1 FFI
mapping of the `zf_*` C ABI (`zigfitsio/lowlevel`), and a high-level astropy-style API on
top (`open`, `HDUList`, HDU classes, `Header`, `Column`, `verify`).

**Runtimes:** Bun ≥1.1 (via `bun:ffi`) and Node ≥18 (via [koffi](https://koffi.dev/)).
The right backend is picked automatically; Bun never loads koffi. The prebuilt shared
library ships in `@zigfitsio/<platform>` packages installed automatically as
optionalDependencies (linux x64/arm64 glibc+musl, macOS x64/arm64, Windows x64).

```sh
npm install zigfitsio     # or: bun add zigfitsio
```

## Quickstart

```ts
import * as zf from "zigfitsio";

// Write an image (shape is C-order, [NAXIS2, NAXIS1] — same layout as numpy/astropy).
const data = new zf.FitsArray(Float32Array.from({ length: 24 }, (_, i) => i * 0.25), [4, 6]);
zf.writeTo("image.fits", data, { overwrite: true });

// Read it back. `using` closes the handle at scope exit (or call hdul.close()).
{
  using hdul = zf.open("image.fits");
  const img = hdul.get(0).data as zf.FitsArray; // lazy read
  console.log(img.shape, img.dtype, img.get(2, 3));
  console.log(hdul.get(0).header.get("BITPIX"));
}

// A binary table with typed, string, and variable-length columns.
const table = zf.BinTableHDU.fromColumns(
  [
    new zf.Column("INDEX", "J", { array: Int32Array.from([10, 20, 30]) }),
    new zf.Column("FLUX", "E", { array: Float32Array.from([1.5, 2.5, 3.5]), unit: "Jy" }),
    new zf.Column("NAME", "8A", { array: ["alpha", "beta", "gamma"] }),
    new zf.Column("TRACE", "1PJ", { array: [Int32Array.from([1, 2]), Int32Array.from([3]), new Int32Array(0)] }),
  ],
  { name: "EVENTS" },
);
new zf.HDUList([new zf.PrimaryHDU(), table]).writeTo("table.fits", { overwrite: true });

{
  using hdul = zf.open("table.fits");
  const rec = hdul.get("EVENTS").data as zf.TableData;
  console.log(rec.names, rec.nrows, rec.get("FLUX"));
}

// Tile compression (RICE/GZIP/PLIO/HCOMPRESS incl. lossy + quantized floats).
const ramp = new zf.FitsArray(Int32Array.from({ length: 256 }, (_, i) => i), [16, 16]);
new zf.HDUList([new zf.PrimaryHDU(), new zf.CompImageHDU({ data: ramp, compression: "RICE_1" })])
  .writeTo("compressed.fits", { overwrite: true });

// Structural validation + checksums.
zf.writeTo("check.fits", data, { overwrite: true, checksum: true });
console.log(zf.verify("check.fits")); // [] when clean

// WCS (1-based FITS pixel convention).
// const [lon, lat] = (hdul.get(0) as zf.ImageHDU).pix2world(40.0, 30.0);
```

## Conventions

- **Arrays are native-endian TypedArrays.** The C ABI exchanges converted native-endian
  values; there is no byte-order handling anywhere in this layer. Image data is a flat
  TypedArray + C-order shape (`FitsArray`); tables are columnar (`TableData`).
- **64-bit integers use BigInt64Array/BigUint64Array** (values are `bigint`). Header
  integers parse to `number` when exactly representable as a double, else `bigint`.
- **Complex values are interleaved float pairs** (`re, im, re, im, …` in a
  Float32Array/Float64Array); `ColumnData.kind === "complex"`, dtype `c8`/`c16`.
- **Scaling is automatic.** `BSCALE`/`BZERO` and `TSCAL`/`TZEROn` are applied by the Zig
  layer on read (scaled data reads as floats); the unsigned convention maps to/from
  `u2`/`u4`/`u8` exactly, including `uint64`.
- **Close your handles.** `hdul.close()` (flushes first in update/append modes), or
  `using hdul = zf.open(...)` — TypeScript transpiles `using` everywhere; in plain
  JavaScript the syntax needs Bun or Node ≥24 (`Symbol.dispose` itself exists from
  Node 20.4). There is no GC-based freeing.
- **Errors are typed**: `FitsError` subclasses carrying the CFITSIO-compatible `status`
  (e.g. `KeywordNotFound` status 202, `FitsOverflowError` 412). Unlike Python,
  `KeywordNotFound` is not also a `KeyError` — catch the class.

## Low-level escape hatch

`zigfitsio/lowlevel` exposes every `zf_*` symbol (see `bindings/c/zigfitsio.h`) with
typed marshalling, `check(status)`, the `ZfOpenOpts`/`ZfScaling`/`ZfColInfo` codecs, and
the LLP64-safe `long` helpers:

```ts
import { lowlevel as ll } from "zigfitsio";
const out = ll.outU64();
ll.check(ll.lib.zf_create_memory(null, out));
// ... raw zf_* calls ...
ll.lib.zf_close(out[0]);
```

## Bundlers / Electron

Mark `zigfitsio`, `koffi`, and `@zigfitsio/*` as external — the platform packages and
koffi's addon must stay on disk, and `bun:ffi` is required lazily (never bundle it into
a Node build).

## Development

```sh
zig build capi          # build the shared library into zig-out/ (Debug)
cd bindings/typescript
npm ci
bun test tests          # Bun lane (bun:ffi)
npx vitest run          # Node lane (koffi)
npm run build           # tsc -> dist/
node scripts/build-native.mjs --target=darwin-arm64   # generate a platform package
```

The loader searches `ZIGFITSIO_LIBRARY` → the installed `@zigfitsio/<platform>` package
→ a `zig-out/{lib,bin}` dev build found by walking parent directories.

Note: bun:ffi ≤1.3.14 mislays stack-passed arguments on macOS arm64 (Apple's ABI packs
them naturally; bun uses 8-byte slots). The bun backend transparently works around this
(`src/ffi/bun.ts`); do not remove the fix when bun updates — it is layout-identical
either way.

## Known gaps (mirrors the Python bindings; see CAVEATS.md §3)

- Not a CFITSIO drop-in (`zf_*`, not `fits_*`).
- Integer null masks: float nulls surface as NaN; integer `BLANK`/`TNULLn` are readable
  via `lowlevel`, not masked automatically.
- Writing complex VLA columns is not supported (fail-loud).
- In-place update of compressed images, VLA columns, scaled columns, or a changed row
  count is not supported (fail-loud `NotSupportedError`) — use `writeTo()` to a new file.
- `writeTo()` of a *scanned* quantized-float compressed image re-quantizes at the
  default level (the FITS header does not record the level).
- Signed-byte (`i1`) images are not mapped to the BZERO=-128 convention yet (typed error).
- On **Alpine/musl**, prefer Bun: the `@zigfitsio/*-musl` library packages are published,
  but koffi ships no musl prebuilds, so the Node path falls back to a source build that
  needs a C++ toolchain.

# zigfitsio

[![Python wheels](https://github.com/anhydrous99/zigfitsio/actions/workflows/python-wheels.yml/badge.svg)](https://github.com/anhydrous99/zigfitsio/actions/workflows/python-wheels.yml)
[![PyPI](https://img.shields.io/pypi/v/zigfitsio)](https://pypi.org/project/zigfitsio/)
[![Python versions](https://img.shields.io/pypi/pyversions/zigfitsio)](https://pypi.org/project/zigfitsio/)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue)](https://github.com/anhydrous99/zigfitsio/blob/main/LICENSE)

**Read and write FITS files with a NumPy-first, astropy.io.fits-style API — no C compiler, no CFITSIO required.**

Python bindings for [zigfitsio](https://github.com/anhydrous99/zigfitsio), a pure-Zig FITS 4.0
I/O library. The native code is a Zig-built shared library loaded via `ctypes`, in two layers:

- **High-level** (`zigfitsio`) — modeled on `astropy.io.fits`: `open`, `HDUList`, the HDU classes, `Column`, `Header`, and `getdata`/`getheader`/`writeto`/`verify`.
- **Low-level** (`zigfitsio.lowlevel`) — a 1:1 `ctypes` binding over the C ABI, for power users.

## Install

```sh
pip install zigfitsio
```

Prebuilt wheels need no compiler. To build from source, install Zig 0.17.0 and put `zig` on
`PATH` before running pip. The build hook does not install the toolchain automatically.

## Quickstart

```python
import numpy as np
import zigfitsio as zf

# Write an image
zf.writeto("image.fits", np.arange(12, dtype="f4").reshape(3, 4), overwrite=True)

# Read it back (NumPy array, shape (NAXIS2, NAXIS1), C-order — like astropy)
with zf.open("image.fits") as hdul:
    data = hdul[0].data
    print(data.shape, hdul[0].header["NAXIS1"])
```

### Tables

```python
cols = [
    zf.Column("INDEX", "J", np.array([10, 20, 30], dtype="i4")),
    zf.Column("FLUX",  "E", np.array([1.5, 2.5, 3.5], dtype="f4"), unit="Jy"),
    zf.Column("NAME",  "8A", np.array(["alpha", "beta", "gamma"])),
]
zf.HDUList([zf.PrimaryHDU(), zf.BinTableHDU.from_columns(cols, name="EVENTS")]).writeto(
    "table.fits", overwrite=True
)
```

### Compressed images

```python
ramp = np.arange(256, dtype="i4").reshape(16, 16)
zf.HDUList([zf.PrimaryHDU(), zf.CompImageHDU(ramp, compression="RICE_1")]).writeto(
    "comp.fits", overwrite=True
)
```

### Headers (dict-like)

```python
with zf.open("image.fits", mode="update") as hdul:
    h = hdul[0].header
    h["OBSERVER"] = ("Hubble", "the observer")  # value + comment
    print(h["OBSERVER"], "/", h.comment_of("OBSERVER"))
    print("BITPIX" in h, list(h.keys()))
```

Setters remain eager by default. Use `Header.edit()` to validate related changes together and
commit them with one Zig call/header write:

```python
with zf.open("image.fits", mode="update") as hdul:
    with hdul[0].header.edit() as h:
        h["OBSERVER"] = ("Hubble", "who")
        h["ESO DET CHIP ID"] = 42  # HIERARCH is serialized by the Zig core
        h.add_history("calibrated")
```

Callback, validation, and revision-conflict failures leave the file unchanged. Device failures
use best-effort rollback and are not a crash-safe/on-disk journaling transaction.

### WCS (celestial)

Pixel pairs are one-based and ordered (longitude-axis pixel, latitude-axis pixel); the
celestial axes need not be FITS Axes 1 and 2.

```python
with zf.open("wcs.fits") as hdul:
    lon, lat = hdul[0].pix2world(40.0, 30.0)   # 1-based pixel (FITS CRPIX convention)
    px, py = hdul[0].world2pix(lon, lat)
```

### Validation

```python
for finding in zf.verify("image.fits"):   # fitsverify-style structural checks
    print(finding)
```

### Low-level (ctypes)

```python
import ctypes as c
import zigfitsio.lowlevel as ll

h = c.c_void_p()
ll.check(ll.lib.zf_create_memory(None, c.byref(h)))
ll.check(ll.lib.zf_create_img(h, -32, 2, (c.c_long * 2)(4, 3)))
ll.lib.zf_close(h)
```

## Conventions

- Image and table data is exchanged as **native-endian** NumPy arrays; non-native (byte-swapped)
  input is coerced automatically before writing. Image shape is the reversed FITS axis order
  (`(NAXIS2, NAXIS1)`), C-contiguous — identical memory layout to `astropy.io.fits`.
- `BSCALE`/`BZERO` and `TSCAL`/`TZERO` scaling and the unsigned-integer convention are applied
  automatically on read (images and table columns) and honored on write; the output dtype is
  widened to float when real scaling is present, or to `u2/u4/u8` for the unsigned convention.
- Errors are raised as typed `FitsError` subclasses (`KeywordNotFound` is also a `KeyError`).
- `writeto()` reconstructs directly into an exclusively created sibling file, without retaining
  a second complete output in RAM. New files use normal umask permissions; replacing a file
  preserves its existing mode. The bundled native library must provide `zf_create_file_handle_v1`
  for reconstruction; `to_bytes()` remains the explicit in-memory serialization API.

## Known limitations

- Not a CFITSIO drop-in — the ABI is purpose-built `zf_*` symbols, not `fits_*`.
- Integer images declaring `BLANK` are promoted to float with NaN at blank pixels (the unsigned
  `BZERO` convention keeps raw unsigned values). Table `TNULLn` values are not returned as
  `numpy.ma` masks; float nulls surface as NaN.
- In-place update of compressed images, VLA or scaled columns, or a changed row count raises —
  use `writeto()` to a new file instead.
- Tables with duplicate effective column names can be inspected as metadata or copied verbatim,
  but high-level data access/reconstruction raises `FitsTableError` (status 219); use low-level
  indexed column reads when duplicates must be addressed.
- `writeto()` of a *scanned* quantized-float compressed image re-quantizes at the default level
  (the FITS header does not record the level).
- Reconstructed tables and compressed images preserve science/provenance headers. Table layout,
  units, scaling, and indexed metadata follow the emitted columns; unsupported scaled or complex
  VLA reconstructions raise instead of replaying incompatible cards. Table WCS descriptions are
  removed together if a required coordinate column or referenced coordinate target is deleted
  or retyped. Attached formats come from the native source header; materialized VLA writes retain
  their P/Q descriptor and element type but omit optional maximum lengths. Inherited measured
  `TDMINn`/`TDMAXn` bounds are omitted during reconstruction because their validity cannot be
  established after edits; pristine raw copies retain them.
- Detached `from_columns()` tables honor later `.data` replacement and clearing. ASCII
  replacement requires the same schema and reuses explicit/source formats; use new `Column`
  specifications for schema changes.

The full list lives in
[CAVEATS.md](https://github.com/anhydrous99/zigfitsio/blob/main/CAVEATS.md).

## Development

```sh
zig build capi                    # build the shared library into zig-out/lib
pip install -e .[test]            # editable install (builds the lib via the hook)
pytest bindings/python/tests -q   # run the suite (incl. astropy cross-checks)
```

Missing native libraries fail the suite rather than skipping it. For wheel verification, run
`pytest --installed-package /path/to/source/bindings/python/tests -q` from outside the checkout
after installing the wheel. That mode bypasses source/loader overrides and requires both the
package in the interpreter's site-packages and its native library inside the installed package.
CI also rebuilds a wheel from the sdist outside the checkout and runs this installed check.

## License

MIT — see [LICENSE](https://github.com/anhydrous99/zigfitsio/blob/main/LICENSE).

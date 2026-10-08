# Caveats & Known Limitations

Current limits of the FITS core and its bindings. Verification uses `zig build test` (core,
C ABI, corpus, e2e, and goldens), `zig build wasm-check`, and `zig build fuzz` (headers,
tables, direct tile decoders, and compressed-HDU mutation). The core remains pure Zig std,
with no C imports or third-party build dependencies. Measured validation results are dated
at the end of this document.

The cross-tool interoperability previously listed here as *unconfirmed* is now **verified
against CFITSIO 4.6.4 + Astropy** (§1); the genuinely-remaining limits are stated plainly below.

## 1. Tile-codec & checksum interoperability — now verified against CFITSIO 4.6.4

This was previously the headline caveat: `PLIO_1`/`HCOMPRESS_1` and the `CHECKSUM`/`DATASUM`
parity were round-trip-correct *within* zigfitsio but **not proven byte-identical to the
reference implementations**, because no CFITSIO/Astropy toolchain was available.

That gap is now closed. A committed **golden corpus authored by CFITSIO 4.6.4 + `fpack`** lives
under `test/golden/` (generators under `interop/`), consumed hermetically by `test/golden.zig`
on every CI cell, plus a dedicated **`interop` CI job** that opens every zigfitsio-written file
with CFITSIO `funpack`, Astropy, and `fitsverify`. Authoring this corpus surfaced — and this
branch fixes — **two real interop bugs** that the prior self-round-trip tests could not catch:

- **`PLIO_1` was not CFITSIO-interoperable in either direction.** The codec omitted the
  CFITSIO/IRAF **7-word line-list header** and stored `COMPRESSED_DATA` as `1PB` (byte VLA)
  rather than `1PI` (16-bit-integer VLA, which CFITSIO byte-swaps on read). Both are fixed in
  `src/compress/{plio,tiled}.zig`: zigfitsio now decodes genuine CFITSIO PLIO tiles **and**
  emits tiles `funpack`/Astropy read back to the exact pixels. (The opcode set was already
  correct — `SH = 1`, per `pl_p2li` — which is why only the header/TFORM were wrong.)
- **`checksum_on_close` was a silent no-op.** The flush hook (`Fits.checksum_hook`) was declared
  but never registered, so `checksum_on_close = true` wrote no `DATASUM`/`CHECKSUM`. It is now
  wired (`src/fits.zig` reserves the cards at HDU-build time; `src/checksum.zig` registers
  `updateAll` and `flush` invokes it), and a reopened file verifies `match`.

**What is now verified (committed goldens + the `interop` CI job):**

- `RICE_1`, `GZIP_1`/`GZIP_2`, `PLIO_1`, and `HCOMPRESS_1` — **lossless AND lossy, including
  decode-side smoothing** — decode committed CFITSIO tiles to the exact pixels (inbound) **and**
  `funpack`/CFITSIO read zigfitsio's compressed output back to the exact pixels (outbound).
- **`HCOMPRESS_1` lossy is complete and CFITSIO-parity, both directions.** Decode implements
  `hsmooth` (the `ZNAME2='SMOOTH'`/`ZVAL2` request) and reproduces `funpack` bit-for-bit on the
  committed lossy goldens (`tile_hcompress_lossy16/lossy32/smooth` + funpack-authored
  `*_expected` pixel files, with a non-vacuousness gate proving the smooth path changes pixels);
  Astropy independently decodes the same bytes to the same pixels. Encode supports absolute
  (`hcomp_scale < 0`) and noise-adaptive (`hcomp_scale > 0`, via the ported
  `FnNoise5_int`/`quick_select` MAD estimators, bit-exact vs `fits_img_stats_int`) scaling plus
  the SMOOTH request, records `ZVAL1` (float request)/`ZVAL2` exactly like CFITSIO, and uses
  CFITSIO's default row-block tiling; `funpack` decodes zigfitsio's lossy output to exactly the
  pixels zigfitsio itself decodes (`check_funpack.py`). A lossy reconstruction that overshoots
  the `ZBITPIX` range **clamps to the type range exactly as CFITSIO clips it** (the
  `tile_hcompress_clip16` golden pins this) — PLIO, whose decode is lossless, still strictly
  rejects out-of-range values as corrupt.
- `DATASUM` recomputes to a CFITSIO-authored golden vector (`X-SUM`).
- WCS TAN `pixel→world` agrees with Astropy reference points within tolerance.
- **Quantized-float writes through the integer codecs are CFITSIO-parity** (closing the former
  "HCOMPRESS write is integer-only" limit): float images (BITPIX −32/−64) compress with
  `HCOMPRESS_1`/`RICE_1` under `NO_DITHER`/`SUBTRACTIVE_DITHER_1`/`_2` via an exact port of
  CFITSIO 4.6.4 `fits_quantize_float`/`_double` (`src/compress/quantize.zig`: `FnNoise5`
  MAD-based `sigma/q` steps, absolute steps, the `iqfactor` ZZERO fudge, `NINT` rounding, the
  §10.2 dither draws, and the raw-float `GZIP_COMPRESSED_DATA` fallback for unquantizable
  tiles), pinned **bit-exact against the real CFITSIO dylib** on committed reference vectors
  (`bscale`/`bzero` f64 bits + every stored integer, six cases). `funpack`, Astropy, and
  fitsverify all read zigfitsio's quantized-float output; funpack/Astropy reproduce zigfitsio's
  own dequantized decode to the exact f32 bit pattern (`check_funpack.py`). The
  `CompressSpec.quantize_level` knob follows `fpack -q` semantics (`zf_write_compressed3` /
  Python `CompImageHDU(quantize_level=…)`). Deliberate fail-loud divergences, conforming files
  unaffected: HCOMPRESS + `SUBTRACTIVE_DITHER_2` errors (CFITSIO silently coerces to
  `DITHER_1`); float + integer codec *without* quantization errors (CFITSIO silently truncates
  floats to ints); PLIO + floats errors up front (its 0..2²⁴ range cannot hold the quantizer's
  output; CFITSIO fails per tile at runtime); a ±Inf tile is stored losslessly (CFITSIO's
  quantizer has no Inf guard and stores garbage). The pre-existing dithered-GZIP path keeps
  its legacy `(max−min)/100000` scheme when `quantize_level` is unset, so existing callers'
  bytes are unchanged — set `quantize_level` for CFITSIO-parity quantization there.

**Genuinely-remaining limits:**

- The **byte-exact regeneration drift-guard** in the `interop` CI job assumes CFITSIO exactly
  **4.6.4** (the version the committed bytes were authored with); it runs *informationally* so a
  distro CFITSIO version skew cannot red the build — the *semantic* interop checks (funpack
  decodes to the exact pixels; Astropy opens every file) are the authoritative gate.
- **Coverage-guided fuzzing remains limited on Linux.** Zig 0.17.0 fixes the former
  `StackTrace` compile error, and all 12 seeded harness tests pass with instrumentation.
  The Linux engine probe then aborts with `start index 1 is larger than end index 0` after
  those tests complete. CI retains a timeboxed engine probe and a std-only diagnostic;
  the required seeded `zig build fuzz` gate is unaffected. A successful seeded run is not
  evidence of sustained coverage-guided exploration.
- **Explicit HCOMPRESS tile shapes are more permissive than CFITSIO's author.** CFITSIO's
  `imcomp_init_table` rejects HCOMPRESS tiles/images with any dimension under 4 pixels;
  zigfitsio deliberately accepts them (the repo's own fixtures use 4×3 tiles, and every tested
  decoder — zigfitsio, CFITSIO/funpack — reads them exactly). The *default* tiling follows
  CFITSIO's row-block rule, so this only applies to explicit `tile=` choices; note Astropy
  refuses HCOMPRESS tiles that squeeze to one dimension (e.g. `{N, 1}`).

**Deliberate code-level divergences (conforming files unaffected; documented at the code):**

- **`SMOOTH` is looked up by `ZNAMEn` name, not positionally** (`tiled.zig` decode): differs
  from CFITSIO only on a hand-crafted header whose `ZNAME2` is mislabeled.
- **Single `i64` HCOMPRESS decode path** vs CFITSIO's int32/int64 split (`hcompress.zig` module
  doc): identical results on all valid data; on an adversarial overflow-inducing stream where
  CFITSIO's int32 variant would silently wrap, zigfitsio errors `CorruptTile` instead.
- **Quantized-float write gates fail loud where CFITSIO degrades silently** (see the verified
  section above): HCOMPRESS + `SUBTRACTIVE_DITHER_2`, float + integer codec without
  quantization, PLIO + floats, and ±Inf tiles (stored losslessly, not quantized to garbage).
- **The legacy dithered-GZIP scheme (kept when `quantize_level` is unset) quantizes f64 pixels
  through an f32 cast** and uses its fixed `(max−min)/100000` step — both pre-existing behavior,
  preserved so existing callers' bytes are unchanged. The CFITSIO-parity path (any explicit
  `quantize_level`, `NO_DITHER`, or an integer codec) quantizes f64 natively via
  `fits_quantize_double` semantics. Set `quantize_level` to opt in on GZIP.
- **Lossless-float compressed writes omit `ZQUANTIZ`** where CFITSIO writes `ZQUANTIZ='NONE'`;
  both readers treat the absent keyword as "no quantization", so this is cosmetic (kept to
  avoid churning existing output bytes; the reader also accepts `'NONE'`).
- **`iqfactor` saturates where CFITSIO's cast is UB** (`quantize.zig`): the ZZERO fudge's
  `(LONGLONG)` cast of an out-of-i64-range double is undefined behavior in C; zigfitsio uses a
  saturating cast, diverging only on pathological data where CFITSIO has no defined answer.
- **Near-zero dequantized pixels are FP-contraction knife edges in CFITSIO's own builds**
  (discovered authoring the quantized-float goldens; `interop/c/gen_sources.c`): `ZZERO` is an
  exact multiple of `ZSCALE`, so `s·ZSCALE + ZZERO` cancels catastrophically for values near 0
  and the last bit depends on the compiler's FMA contraction — an arm64 Homebrew funpack
  yields a `2⁻⁵³` residual where baseline-x86-64 CFITSIO, Astropy, and zigfitsio all yield
  exactly `0.0`. Not a zigfitsio divergence per se (CFITSIO disagrees with *itself* across
  builds); the committed goldens use all-positive fields so every reference build agrees.

## 2. Delivery status — unmerged branch (point-in-time)

As of this commit, the conformance-hardening work lives on branch
`finish-fits-conformance` and has **not been merged to `main` or pushed to `origin`**. It
is organized as four self-contained, individually-green commits, so it can be reviewed,
merged, or reset at batch granularity:

| Commit | Scope |
|--------|-------|
| `1c0c244` | FITS-conformance correctness bugs (ASCII space-fill, CONTINUE/HIERARCH/complex header API, §4.2.4 float exponent, CAR/LATPOLE WCS, MJDREF precedence, copyHdu rollback, write-path keyword-order validation, image-section streaming, TDIM string arrays, heap hardening, group-table fixes) |
| `2f0aadb` | Standard-format `PLIO_1`/`HCOMPRESS_1` rewrites + tiled `ZBLANK`/transparent/write-codec wiring |
| `3271d65` | HTTP range-GET backend, `.fits.gz` open path, iterator null substitution, committed sample corpus, failure-path tests |
| `a7f4fb3` | Doc/status reconciliation (README, CHANGELOG, design.md, tasks.md, code comments, CI) |

This section is a snapshot of the delivery state and becomes moot once the branch is
merged.

## 3. Language bindings (Python / TypeScript / C ABI) — scope & known gaps

The bindings under `bindings/` are **additive**: a `zf_*` C-ABI shim (`bindings/capi/`, built by
`zig build capi`) over the public Zig module, a low-level `ctypes` binding, a high-level
NumPy/Astropy-style API, and a TypeScript package (`bindings/typescript/`) mirroring the same two
layers (a single WebAssembly build of the same C ABI under an astropy-style TypedArray API,
running on Node/Bun/browsers). `src/` contains **no C** (the `.h` contract lives under
`bindings/c/`, outside the `GC-1` guard's
`src tools test` scope). Interoperability is verified both directions against Astropy and the
committed golden corpus, plus a TS↔Python cross-check in CI. Honest limits as delivered (they
apply to both language bindings unless noted; TypeScript-specific ones are listed at the end):

- **Not a CFITSIO drop-in.** The exported symbols are `zf_*`, not `fits_*`/`ff*`; the ABI is
  purpose-built for bindings (opaque handles + runtime datatype codes), not a CFITSIO replacement.
- **Compressed image transfers require the whole image.** C-ABI `zf_read_img` accepts a
  compressed image only with `firstelem = 1` and its complete element count. Partial compressed
  reads/writes and sections remain unsupported; plain-image ranges are checked before access.
- **Allocation limits apply before memory ownership and inflation.** `max_open_alloc` bounds
  native and wasm memory opens, owned-buffer builders, and decoded gzip output. The additive
  `zf_wopen_memory_begin_v2` accepts options before allocation; v1 retains its signature and
  default limit, and commit rechecks the supplied options. These are per-allocation limits,
  not a cap on total process or WebAssembly linear memory.
- **Integer null masks.** Float nulls surface as NaN. Integer **images** declaring `BLANK`
  (or `ZBLANK`/plain `BLANK` in a tile-compressed header) are promoted to float with NaN at the
  blanked pixels, matching astropy/funpack; the unsigned-`BZERO`-convention path intentionally
  keeps raw unsigned ints and ignores `BLANK`, exactly as astropy does. In-place **update-mode**
  write-back of a BLANK-promoted image is not supported: the promoted array is float while the
  on-disk data unit is integer, so a mutated-data flush fails loud (`NanToInt`, status 412)
  rather than corrupting — use `writeto()` to a new file (the reconstruction path drops the
  then-illegal `BLANK` card from the float output). Table `TNULLn` values remain readable (and
  exposed via `zf_table_col_info`), but the high-level API does not yet return `numpy.ma` masked
  arrays for integer columns — that masking is a follow-up.
- **Duplicate table column names require positional access.** The high-level table data models are
  keyed by effective name (trimmed `TTYPE`, or `colN` when unnamed), so materializing a table with
  duplicate effective names raises `FitsTableError` (status 219) rather than hiding or mis-writing
  a physical column. Metadata inspection and pristine byte-for-byte copies remain available; use
  the low-level indexed column API when duplicate names must be addressed.
- **VLA writing.** The high-level `from_columns`/`writeto` path writes variable-length-array
  columns, reserving the heap (`PCOUNT`) up front via `zf_create_tbl_heap`; reading VLAs is
  complete. The lower-level `zf_write_col_vla` still assumes the heap is reserved (create the table
  with `zf_create_tbl_heap`). Writing *complex* VLAs is not supported.
- **Unsigned-integer writing.** The high-level write path maps `u1/i2/i4/i8/f4/f8` directly and
  writes `u2/u4/u8` images and columns via the `BZERO`/`TZEROn` convention (integer-space, exact for
  all widths incl. `uint64`); reading the same convention (`BZERO`/`TZEROn` → `u2/u4/u8`) is handled.
- **Iterator and the raw `Device` vtable** are intentionally not exposed 1:1; the Python layer
  provides NumPy-native equivalents (column/section reads) and the file/memory/gzip open paths.
- **Toolchain for wheels.** The `ziglang` PyPI package can lag the 0.17 toolchain this project
  targets, so wheel builds use a real Zig 0.17 (CI `setup-zig` / the in-container installer); the
  hatch build hook falls back to a system `zig` when `ziglang` is absent, incompatible, or fails its version probe; stable 0.17.x is required.
- **`writeto()` of a *scanned* quantized-float compressed image re-quantizes with default
  knobs.** The FITS header records the method (`ZQUANTIZ`) but not the quantization *level*
  (CFITSIO stores `q` only in a free-text `HISTORY` card), and the Python re-emit path writes
  `ZDITHER0 = 1` rather than reusing the source seed — so re-emitting decodes the pixels and
  quantizes them *again* (a second, bounded lossy pass at the default level; the codec, tiling
  and method are preserved, and the result is a fully valid file). Integer-codec and lossless
  copies are unaffected; copying compressed HDUs verbatim (no re-quantization) is a follow-up.
- **TypeScript-specific.** 64-bit integer data uses `BigInt64Array`/`BigUint64Array` (`bigint`
  values); complex values are interleaved float pairs (no complex array type in JS); header
  integers parse to `number` when exactly double-representable, else `bigint`;
  `KeywordNotFound` is not also a `KeyError` (no such JS class); handles need an explicit
  `close()` (or `using` on runtimes with `Symbol.dispose`) — there is no GC-based freeing.
  (Historical: the pre-wasm FFI backends carried a bun:ffi ≤1.3.14 darwin-arm64 stack-argument
  workaround; the package is wasm-only now and the workaround is gone with the backends.)
- **Signed-byte (`i1`) images (TypeScript).** The high-level image writer does not map
  `Int8Array` data to the FITS `BZERO = -128` signed-byte convention yet — it fails with a typed
  error rather than writing a mislabeled unsigned image. (The table-side `Int8Array` rejection in
  `tableFromArrays` is the sibling limit, listed below.)
- **WebAssembly execution (TypeScript).** The compute-heavy codecs (RICE/HCOMPRESS/quantize) run
  inside wasm at roughly 1.5–3× the runtime of a native build, and large image/table transfers
  copy through wasm linear memory. The module is single-threaded, and its heap only grows —
  pages are never returned to the OS for the life of the instance.
- **No filesystem inside the wasm module (TypeScript).** Path-based file I/O is a JS-side
  convenience (`node:fs`) available on Node/Bun only; browsers use `fromBytes`/`toBytes`.
  Writing a `.fits.gz` via the C ABI (`zf_save_gzip`) and the raw `zf_open_file`/`zf_create_file`
  return `NotWritable` in the wasm build — the high-level `open`/`writeTo` route around them.

### TypeScript high-level ergonomics (the TS-native surface)

The TypeScript package layers a TS-idiomatic surface (discriminated `kind`, typed `image()`/
`table()` accessors, a columnar-plus-row `TableData`, `Header` Map semantics, the
`tableFromArrays`/`imageFromArray` factories, and `ImageHDU.section()`) over the astropy-shaped
classes. It is **additive sugar** — the Python-parity classes and the `lowlevel` escape hatch are
unchanged and always sufficient. Honest boundaries of that sugar:

- **HDU `kind` narrowing is exact for `"image"`/`"bintable"`/`"asciitable"`, partial for
  `"primary"`/`"compimage"`.** Because `PrimaryHDU`/`CompImageHDU` extend `ImageHDU`, narrowing
  `AnyHDU` on `kind === "primary"` yields `PrimaryHDU | ImageHDU` (and `"compimage"` →
  `CompImageHDU | ImageHDU`). Harmless — every image kind shares the same `FitsArray | null`
  `.data` — and the typed `image()`/`table()` accessors sidestep it entirely.
- **`TableData<T>` / `HDUList.table<T>()` column shapes are a compile-time contract only.** `T`
  is never checked at runtime: a wrong `T` mis-types reads without throwing, and a column name
  outside `T` falls through to the untyped `ColumnValues` overload. The **runtime**-checked reads
  are `numeric()/strings()/vla()/complex()`, which throw `FitsTypeError` on a kind mismatch.
- **A `Row<T>` numeric cell is typed `ElementOf<V> | V`** (scalar *or* TypedArray slice), because
  repeat-1-vs-vector is a runtime distinction TypeScript cannot see. Row slices are **zero-copy
  views** over the column buffer — mutating a returned slice mutates the column (and, in update
  mode, is written back on `flush()`). For a statically-known element type, prefer the column
  accessors.
- **`ImageHDU.section()` (strided cutout) is image-data only.** It reads the plain image data
  unit via `zf_read_subset`, so it fails loud (`NotSupportedError`) on a tile-compressed image —
  read the whole array through `.data`. In update mode it flushes pending in-place `.data` edits
  first, so a section never lags `.data`; in read-only mode it reads the file **as opened**, so
  unflushed in-memory edits are not visible. Windows are 0-based, half-open `[start, stop)` in
  C-order; negative, out-of-bounds, or empty windows throw `RangeError`.
- **In-place table write-back matches unique columns by name and cannot add columns.** Setting a
  reordered `TableData` in update mode writes each changed column to its true on-disk slot; a
  `TableData` carrying a column name absent from the file fails loud (`NotSupportedError`) rather
  than silently mis-writing (an index-based match would corrupt a reordered table). Row-count,
  VLA, and scaled/unsigned-column in-place edits remain unsupported (fail-loud) — use `writeTo()`.
- **`Header` iteration is Map-style over `[keyword, value]` entries.** A parsed header may repeat
  a keyword across cards: iteration yields **every** card, `get()` returns the **first**, and
  `size` counts them **all**, so `new Map([...header]).size` can be smaller. Commentary
  (`COMMENT`/`HISTORY`/blank) cards are excluded from iteration — see `.comments`/`.history`.
- **`tableFromArrays` TFORM inference is a convenience, not exhaustive.** `Int8Array` (no FITS
  binary signed-byte code) is rejected fail-loud, complex columns are not inferable, and a
  uniformly-empty cell array infers a variable-length column (`1P<t>`) rather than a 0-repeat
  fixed one. Pass an explicit `Column[]` via `BinTableHDU.fromColumns` for complex (`C`/`M`),
  signed-byte, or hand-tuned formats. Arbitrary `BSCALE`/`BZERO` scaling is **not** expressible
  through the high-level image writer (it derives scaling from the array dtype and emits only the
  unsigned `u2/u4/u8` `BZERO` convention) — use `lowlevel` for a custom `BSCALE`/`BZERO`.

None of these require ABI changes to address — they are extension points, not design constraints.

## 4. Update and reconstruction boundaries

The fixes are recorded in `CHANGELOG.md`. The remaining boundaries below raise clear errors
when the requested reconstruction or update is unsupported.

- **Python: in-place update of a *compressed* image is not supported.** Mutating a materialized
  `CompImageHDU`'s pixels and then `flush()`/`close()` (update mode) raises `NotImplementedError`
  rather than attempting in-place recompression (the tile heap would have to be resized in place).
  Use `writeto()`, which reconstructs the file and recompresses correctly, preserving the source
  codec/tiling/quantization.
- **Python: in-place table update is limited to fixed-geometry cell edits.** `flush()`/`close()`
  write back changed cell values of ordinary (fixed-width, unscaled) columns. Changing the row
  count, or editing a variable-length-array (`P`/`Q`) or `TSCAL`/`TZERO`-scaled column in place,
  raises `NotImplementedError` — use `writeto()` to a new file (which reconstructs) for those.
- **Python & TypeScript: HDUList structural edits (insert/delete/reorder) persist on `flush()`/`close()`**
  (2026-07-07, BUGHUNT-2026-07-06 items 4+8 — previously they were silently dropped). The reconcile
  appends first and deletes the displaced originals after, so a mid-append failure rolls the file
  back byte-identically and a (raw-I/O) delete-phase failure can only leave duplicate — never
  missing — HDUs. Shifted HDUs of the same file travel as **exact byte copies** (`zf_copy_hdu`):
  user keywords, VLA heaps, compression bytes, and checksums survive verbatim. Documented
  boundaries, each fail-loud: the **primary HDU must remain first** (`insert(0, …)`, `del h[0]`,
  `reverse()` raise `NotImplementedError` — use `writeto()`); the **same HDU object may not occupy
  two positions** (`ValueError` — insert a copy instead). An HDU adopted from *another* HDUList is
  re-serialized through the reconstruct path: science and provenance cards are preserved while
  layout, scaling, and indexed column metadata are regenerated or remapped to the emitted schema.
  Column ranges and table WCS use compatible source-column identities, including alternate
  descriptions and matrix terms. Removing or retyping a required coordinate column drops its
  affected WCS description as a set; references to a removed coordinate target are also dropped,
  using the case-sensitive labels specified by [FITS WCS cross-references](https://ned.ipac.caltech.edu/level5/Sept02/Greisen/Greisen3_5.html).
  Inherited measured `TDMINn`/`TDMAXn` bounds are omitted on
  reconstruction; fresh detached schemas may explicitly supply bounds, and pristine byte copies
  preserve them.
  One undetected aliasing
  edge (same as astropy): a single `Header` object shared between two different HDUs — the
  last-flushed HDU wins the header's live-persist hook; give each HDU its own `Header`.
- **Python: `append` and structural table edits go through the file, not a scratch copy.** Appending
  an HDU to an update-mode list serializes it to the open file on `flush()`/`close()`. The HDU-level
  reconcile above rolls back its append phase on failure; there is still no transactional rollback of
  a partial in-place structural *table* edit if the device write fails midway (the same is true at
  the Zig layer — see the append/copy rollback that *is* implemented, versus the header-rewrite path
  which validates-before-mutating but does not un-shift relocated bytes on a mid-write I/O error).
- **Header `update()`/`modify()` do not support HIERARCH long-keyword cards.** Reading a HIERARCH
  card by its hierarchical name is correct (`get`/`has`/`comment`/`getValue`/`getHierarch`), but the
  *write* helpers build a fixed-format 8-char card (`Card.buildValue`) and cannot construct a
  HIERARCH card, so updating a HIERARCH keyword's value in place is unsupported. Rebuild the card via
  the HIERARCH builder (`src/header/hierarch.zig`) instead.
- **Dithered/quantized-float compression interop is golden-committed** (closing the earlier
  follow-up note here): CFITSIO-authored quantized-float `.fz` goldens now live under
  `test/golden/compress/` — HCOMPRESS `SUBTRACTIVE_DITHER_1` (pinned `ZDITHER0=1`; fpack's
  clock-derived seed is non-deterministic, so the C generator authors it), HCOMPRESS `NO_DITHER`
  (`fpack -q0 4`), and RICE `SUBTRACTIVE_DITHER_1` — each paired with funpack's own decode, which
  zigfitsio, Astropy (`interop/xval.py`), and the Python bindings must reproduce to the exact f32
  bit pattern. One honest boundary discovered while authoring them: CFITSIO itself is **not
  bit-stable across its own builds** for pixels that reconstruct near zero (`ZZERO` is fudged to
  an exact multiple of `ZSCALE`, so `s·ZSCALE + ZZERO` cancels catastrophically and the result
  depends on the compiler's FMA contraction — an arm64 Homebrew funpack yields a `2⁻⁵³` residual
  where baseline-x86-64 CFITSIO, Astropy, and zigfitsio all yield exactly `0.0`). The committed
  goldens use an all-positive field so every reference build agrees on every bit; the hermetic
  round-trip unit tests (`NO_DITHER`, `SUBTRACTIVE_DITHER_2`, lossless-fallback/±Inf tiles,
  ZBLANK) still cover zero-crossing data semantically.
- **Table reconstruction uses stored formats.** Attached `TFORMn` values come from a fresh native
  header snapshot, so local edits to structural cards do not redefine stored cells. Materialized
  VLA writes retain their P/Q descriptor and element type but omit optional maximum lengths;
  pristine raw copies retain their original bytes and maxima.
- **ASCII table reconstruction requires known column formats.** Source `TFORMn` cards and
  detached `from_columns`/`fromColumns` specifications preserve exact `Iw`, `Aw`, and `Fw.d`/
  `Ew.d`/`Dw.d` formats. Same-schema replacement reuses those formats after validation. Schema
  changes that require ASCII format inference raise a clear unsupported error; construct explicit
  columns instead. Replacing or clearing detached builder data never reuses the original arrays.
- **Atomic file replacement is not a crash-recovery journal.** TypeScript update close writes
  the exact flushed bytes through an exclusive sibling temporary file, then renames it into place;
  partial-write and rename failures preserve the original. `writeTo()` and Python `writeto()` use
  the same staging policy, preserving an existing file's permissions. New Python files honor
  umask; reconstruction emits directly through `zf_create_file_handle_v1` into the already-open
  exclusive temporary file. The native FITS handle borrows that descriptor and never closes it;
  Python retains it until native flush/close completes. This avoids a whole-output memory buffer
  and requires a native library with that additive symbol. Native Python update close
  still flushes its open native file in place. These APIs do not promise `fsync` durability or
  recovery from a process or system crash during an in-place native update.

### Delivery status (point-in-time)

Local validation on 2026-09-30 passed 720 hermetic Zig tests plus 12 seeded fuzz tests,
with one additional Linux-only direct-I/O test skipped on macOS, `zig build wasm-check`,
311 Python tests, and 369 Vitest tests on Node 24. Bun passed 368 tests with one deliberate skip
for a Node-only file-growth injection. The installed sdist-built wheel passed all 311 Python tests
with package and native-library provenance checked in site-packages.
The packed npm artifact passed Node 18.0.0 and Node 20 consumer checks and a Vite production
build in real Chrome using default `ready()` wasm loading. The external checks verified 30
inbound goldens and 13 outbound FITS files with Astropy, funpack, and checksum-bearing fitsverify.
Additional Astropy-authored table probes checked remapped primary/alternate coordinates and
grown variable-length cells through both bindings; the written files passed `fitsverify`.
The direct-file writer matched native file output's peak memory (about 95 MiB for a 64 MiB image),
compared with about 195 MiB for the whole-output memory path in the same separate-process probe.
Linux and Windows native builds cross-compiled; those platform runtimes were not exercised here.

CI now requires external interop on every PR/main run and schedule, and explicitly on each
release SHA. Its big-endian job requires `qemu-s390x` and runs the full build suite without a
fallback that could hide a failed cell; that Linux/QEMU job was not executed on this macOS host.
`make -C interop benchmark` reports five-run optimized memory-workload medians against CFITSIO;
the measured ratios are informational and make no universal speed or release-threshold claim.

# zigfitsio — Implementation Task List (v2)

A dependency-ordered, requirement-traced backlog for building `zigfitsio`, derived from
[`requirements.md`](./requirements.md), [`design.md`](./design.md), and the
[FITS Standard v4.0](https://fits.gsfc.nasa.gov/standard40/fits_standard40aa-le.pdf).

> **v2 (post-review).** This backlog was hardened against an adversarial review (spec-conformance,
> requirements traceability, design consistency, dependency graph, a real Zig 0.16 compiler, and
> backlog completeness). Coarse nodes were split (`HDR-3`→`a/b/c`, `FITS-1`→`a/b`, `BTB-3`→`a/b`,
> `CMP-3`→`a/b`), fixture-provenance (`X-FIXTURES`) and invariant-guard (`X-GUARD`) tasks were added,
> a big-endian CI cell was added, and the scheduling waves are now **machine-generated** by
> [`tools/check_tasks.py`](./tools/check_tasks.py).

It is structured to drive a **dynamic workflow**: each task is a node, `Depends on` lists the edges,
and a task becomes *runnable* only when every dependency is `done`. A runner should topologically sort
on `Depends on`, **serialize tasks that share a `Module-lock`** (they edit the same file), parallelize
the rest within a wave (§ Scheduling Waves), and flip each task's `Status` `todo → in_progress → done`.
The [Global Definition of Done](#global-definition-of-done) applies to **every** task, so per-task
**Acceptance** lists only what is *additional* to it.

---

## How to use this file with a workflow runner

- **Node** = one `### ` task. **ID** = the heading text (area-prefixed, stable under insertion).
- **Edge** = each ID in `Depends on`. A task is ready when all its deps are `done`.
- **Module-lock** = an optional field naming the `src/` file a task edits. Tasks sharing a `Module-lock`
  **must be serialized** (never run concurrently) even if the wave table lists them together — they
  touch the same file and would conflict.
- **State** = the `Status:` field (`todo` / `in_progress` / `blocked` / `done`); the runner owns it.
- **Scope of one task** = a unit a single focused agent/iteration can finish and verify. `XL` tasks are
  split candidates if your runner prefers smaller nodes.
- **Traceability** = `Req` / `Design` / `Spec`. The [Traceability Check](#traceability-check) asserts
  every `FR/NFR/GC` ID is covered. `tools/check_tasks.py` re-verifies coverage, dependency resolution,
  acyclicity, and wave consistency on every edit.

### Field schema

| Field | Meaning |
|-------|---------|
| **Milestone** | `M0` Foundation (P0) · `M1` Core (P1) · `M2` Full-standard (P2) · `M3` Extended (P3) · `X` Cross-cutting/continuous |
| **Module** | Target file(s) under `src/` (or `test/`, `tools/`) per `design.md` §3 |
| **Module-lock** | The shared `src/` file; co-locked tasks must be serialized |
| **Size** | `S` ≤½ day · `M` 1–2 d · `L` 3–5 d · `XL` >5 d (split candidate) |
| **Depends on** | Task IDs that must be `done` first |
| **Req / Design / Spec** | Traceability anchors |
| **Goal / Deliverables / Acceptance** | Intent · artifacts · testable exit criteria (*beyond* the Global DoD) |

---

## Global Definition of Done

Every task must satisfy all of these before it is `done`:

1. **Builds.** `zig build` and `zig build test` succeed on Zig **0.16.0** (`GC-3`, `NFR-BUILD-1/2`).
2. **No C.** No `@cImport`, no C sources, no non-`std` dependency anywhere (`GC-1`, `GC-2`). Enforced by
   `X-GUARD`'s grep guard, not just review.
3. **Idiomatic API.** Typed error unions over the `errors.zig` sets; no `anyerror`; no integer/inherited
   status; bulk data via slices; comptime datatype selection (`GC-4`, `FR-ERR-1/2`).
4. **No leaks.** New paths exercised under `std.testing.allocator`, zero leaks; every owning type has
   `deinit`; `errdefer` covers partial construction (`GC-8`, `NFR-MEM-1/2`).
5. **No UB on hostile input.** Declared sizes validated against `Limits` **and** stream length with
   checked arithmetic *before* allocation; typed errors, never panic/OOB (`GC-6`, `NFR-SAFE-1`).
6. **Endian-neutral.** Every multi-byte wire access goes through `endian.zig` (`GC-5`, `NFR-PORT-2`).
7. **Docs.** Every new public declaration carries a doc comment (`NFR-DOC-1`).
8. **Tests.** Unit tests cover the task's success and failure paths and pass in CI.
9. **Public surface.** Only intended types re-exported from `root.zig`; internal handle fields private
   (`NFR-API-2`).

---

## Milestone M0 — Foundation (P0)

### SETUP-1 — Build scaffolding & module skeleton
- **Milestone:** M0 · **Module:** `build.zig`, `build.zig.zon`, `src/root.zig` · **Size:** M · **Status:** todo
- **Depends on:** _(none)_
- **Req:** GC-1, GC-2, GC-3, NFR-BUILD-1, NFR-BUILD-2, NFR-API-2 · **Design:** §3, §24 · **Spec:** §3.1
- **Goal:** A buildable, dependency-free Zig package with the §3 source tree stubbed.
- **Deliverables:** `build.zig` (`addModule`/`addLibrary{.linkage=.static}`/`addTest`, stubbed
  `bench`/`fuzz`/`wasm-check` steps); `build.zig.zon` (`name`, `version`, `minimum_zig_version="0.16.0"`,
  empty `.dependencies`, `paths`, **`fingerprint` left for `zig build` to emit on first run**);
  the §3 tree as compiling placeholders; `root.zig` re-exports only the public surface.
- **Acceptance:** `zig build` and `zig build test` succeed on a clean checkout with **zero** fetched
  deps. **Do not hand-pick `.fingerprint`** — its low 32 bits checksum `.name`, so a literal is rejected;
  run `zig build` once and paste the value it reports.

### ERR-1 — Error sets & umbrella `Error`
- **Milestone:** M0 · **Module:** `src/errors.zig` · **Size:** S · **Status:** todo · **Module-lock:** errors.zig
- **Depends on:** SETUP-1
- **Req:** FR-ERR-1, FR-ERR-2, GC-4 · **Design:** §4.1
- **Goal:** Every area-scoped error set + the composed `Error` umbrella (§4.1), folding in
  `std.mem.Allocator.Error` where allocation occurs.
- **Acceptance:** a compile test asserts the sets compose with `||` and no signature needs `anyerror`.

### ERR-2 — Diagnostics context
- **Milestone:** M0 · **Module:** `src/diag.zig` · **Size:** S · **Status:** todo
- **Depends on:** ERR-1
- **Req:** FR-ERR-3 · **Design:** §4.3
- **Goal:** Opt-in `Diagnostics` recording the most-recent failure (offset/keyword/HDU/inline card text),
  using a plain `[N]u8`+len (not the removed `std.BoundedArray`).
- **Acceptance:** zero cost when no `Diagnostics` supplied (`errdefer if (diag) |d| …`); a test renders a
  populated record via `render(*std.Io.Writer)`.

### ERR-3 — Version & error-message text
- **Milestone:** M0 · **Module:** `src/version.zig` · **Size:** S · **Status:** todo
- **Depends on:** ERR-1
- **Req:** FR-UTL-3 · **Design:** §4.3, §19.1
- **Goal:** `version()` and a stable `errorText(err)` for every `Error`.
- **Acceptance:** exhaustive switch test asserts a non-empty message per error value.

### LIM-1 — Limits & validate-before-allocate helper
- **Milestone:** M0 · **Module:** `src/limits.zig` · **Size:** M · **Status:** todo
- **Depends on:** ERR-1
- **Req:** NFR-SAFE-1, GC-6 · **Design:** §7.2 · **Spec:** §3.1, §4.4.1, §7.3.5
- **Goal:** The `Limits` struct (defaults + per-handle override) and the single size-validation helper
  used everywhere before allocation. Note `Limits.max_matches` is the **runtime ceiling** bounded by the
  comptime `name.MAX_MATCHES` (§ NAME-1).
- **Acceptance:** overflowing `NAXISn` products / `PCOUNT` yield a typed error *before* any allocation.

### END-1 — Endianness module
- **Milestone:** M0 · **Module:** `src/endian.zig` · **Size:** M · **Status:** todo
- **Depends on:** SETUP-1
- **Req:** GC-5, NFR-PORT-2, NFR-PERF-2 · **Design:** §7.1 · **Spec:** §3.3.2, §5
- **Goal:** Typed big-endian `read`/`write` + vectorized in-place `swapToNative` (floats via int repr;
  `@Vector` batches + scalar tail; no-op fast path on big-endian/1-byte).
- **Acceptance:** round-trip per width; a **forced-swap** test on both host endiannesses gives identical
  results (the genuine native big-endian path is exercised by the X-CI big-endian cell).

### CONV-1 — Numeric-conversion policy
- **Milestone:** M0 · **Module:** `src/convert.zig` · **Size:** M · **Status:** todo
- **Depends on:** ERR-1
- **Req:** FR-CONV-1, FR-CONV-2, GC-6, NFR-PERF-2 · **Design:** §6 · **Spec:** §4.2.3–4.2.4, §5.2
- **Goal:** The single `cast(comptime Dst, src, mode)` — `Mode{scalar,bulk}`; range-check before
  truncation; `@round` half-away-from-zero; `NaN→int = NanToInt`; precision-losing widening errors in
  `scalar`, silent in `bulk`.
- **Acceptance:** edge tests for overflow at each int boundary, half-rounding, exact-vs-inexact
  `i64→f64`, `NaN→int`; documents the CFITSIO `(x±0.5)` divergence.

### IO-1 — `Device` vtable (seekable)
- **Milestone:** M0 · **Module:** `src/io/device.zig` · **Size:** M · **Status:** todo
- **Depends on:** ERR-1
- **Req:** FR-IO-3, FR-IO-5, FR-IO-6, GC-7 · **Design:** §8.1 · **Spec:** §3.1, §3.6
- **Goal:** Position-explicit `pread`/`pwrite` device behind a vtable; null `pwrite` ⇒ read-only;
  64-bit offsets.
- **Acceptance:** read-only device ⇒ `NotWritable`; >2 GiB offsets exercised in a mock.

### IO-2 — `Stream` vtable (sequential)
- **Milestone:** M0 · **Module:** `src/io/stream.zig` · **Size:** S · **Status:** todo · **Module-lock:** io/stream.zig
- **Depends on:** ERR-1
- **Req:** FR-IO-3, FR-RMT-1, GC-7 · **Design:** §8.1 · **Spec:** §3.6
- **Goal:** Sequential-only stream over `std.Io.Reader`/`Writer` (stdin/stdout) + the
  "materialize into a memory `Device` to seek" path.
- **Acceptance:** stdin→memory-`Device` materialization round-trips a buffer.

### IO-3 — In-memory backend
- **Milestone:** M0 · **Module:** `src/io/memory.zig` · **Size:** S · **Status:** todo
- **Depends on:** IO-1
- **Req:** FR-IO-3, FR-RMT-1, NFR-PORT-3 · **Design:** §8.1 · **Spec:** §3.1
- **Goal:** Growable `[]u8`/`ArrayList`-backed `Device` — the freestanding/WASM path and the `FR-RMT-1`
  in-memory buffer.
- **Acceptance:** `@memcpy` pread/pwrite; grows on `setSize`; usable with no OS file access.

### IO-4 — File backend
- **Milestone:** M0 · **Module:** `src/io/file.zig` · **Size:** S · **Status:** todo
- **Depends on:** IO-1
- **Req:** FR-IO-3, FR-IO-5, FR-IO-6 · **Design:** §8.1 · **Spec:** §3.1
- **Goal:** `std.fs.File`-backed `Device` (`pread`/`pwrite`/`stat`/`setEndPos`), 64-bit offsets.
- **Acceptance:** create→write→reopen→read round-trip; read-only open rejects writes.

### IO-5 — Block model & buffering
- **Milestone:** M0 · **Module:** `src/io/block.zig` · **Size:** L · **Status:** todo
- **Depends on:** IO-1, LIM-1
- **Req:** FR-IO-1, FR-IO-2, FR-IO-4, NFR-PERF-1, NFR-PERF-3 · **Design:** §8.2 · **Spec:** §3.1, §3.3.1, §7.1.3
- **Goal:** `BlockReader`/`BlockWriter` caching in multiples of 2880 B; `cardAt`/`bytes`; `pad(fill)` with
  `.space` (headers + ASCII-table data) vs `.zero` (other data); in-place edits write only touched blocks.
- **Acceptance:** correct pad kind per unit; a multi-block header scan issues one windowed read; bounded
  memory on a large mock device.

### NAME-1 — Keyword normalization, wildcards, `Matches`
- **Milestone:** M0 · **Module:** `src/header/name.zig` · **Size:** M · **Status:** todo
- **Depends on:** ERR-1, LIM-1
- **Req:** FR-HDR-2, FR-UTL-4 · **Design:** §9.1, §19.1 · **Spec:** §4.1.2.1, Appendix A
- **Goal:** 8-char keyword normalization and case-insensitive wildcard matching with the explicit
  multi-match contract.
- **Deliverables:** `Name`; `*`/`?`/`#` matcher; **`pub const MAX_MATCHES: usize = 4096`** (the comptime
  inline-buffer bound) and `Matches{buf:[MAX_MATCHES]u32, len, overflow}` with `slice()`/`at()`. The
  comptime bound is a top-level const — a struct's runtime field (`Limits.max_matches`) **cannot** be a
  type-name-qualified array bound on Zig 0.16; `Limits.max_matches ≤ MAX_MATCHES` is the runtime ceiling.
- **Acceptance:** zero / one / ordered-all tested; `overflow` set past `MAX_MATCHES`; no status-iteration
  idiom; the `Matches` declaration compiles on 0.16.

### HDR-1 — Keyword value parsing
- **Milestone:** M0 · **Module:** `src/header/value.zig` · **Size:** L · **Status:** todo · **Module-lock:** header/value.zig
- **Depends on:** ERR-1, CONV-1
- **Req:** FR-HDR-3, FR-HDR-4 · **Design:** §9.2 · **Spec:** §4.2.1–4.2.7
- **Goal:** The `KeywordValue` union and a fixed-**and**-free-format value FSM preserving the
  null/empty/undefined three-way distinction; fixed-format writer for mandatory keywords.
- **Acceptance:** absent ⇒ `KeywordNotFound`; `= ''` ⇒ empty; `= ` + blanks ⇒ `.undefined`; free-format
  reads accepted; mandatory writes fixed-format.

### HDR-2 — Card parse / serialize & classification
- **Milestone:** M0 · **Module:** `src/header/card.zig` · **Size:** M · **Status:** todo
- **Depends on:** HDR-1, NAME-1
- **Req:** FR-HDR-1, FR-HDR-2, FR-HDR-6 · **Design:** §9.1 · **Spec:** §4.1, §4.4.2.4, Appendix A
- **Goal:** The 80-byte `Card` with raw-byte preservation and the exact value-vs-commentary rule
  (`classify()` = value **iff** bytes 9–10 are `= ` and name is not commentary).
- **Acceptance:** a `COMMENT`/`HISTORY`/blank card with `= ` stays commentary; raw bytes survive an
  unmodified read→write; control char ⇒ `NonAsciiInHeader`.

### HDR-3a — Header container, index & read API
- **Milestone:** M0 · **Module:** `src/header/header.zig` · **Size:** M · **Status:** todo · **Module-lock:** header/header.zig
- **Depends on:** HDR-2, NAME-1, CONV-1
- **Req:** FR-HDR-5, FR-HDR-7, FR-HDR-13 · **Design:** §9.4 · **Spec:** §4.1, §4.4.1
- **Goal:** Ordered card list + case-insensitive name index; read API and mandatory `END` handling.
- **Deliverables:** `get`/`getValue(comptime T)` (via `convert.cast(.scalar)`)/`card(n)`/`find`/
  `findAlloc`; **a structured `/`-comment accessor** (parse + expose the comment field, FR-HDR-5, not
  just raw preservation); scan-to-`END` with `MissingEnd` when the block budget is exhausted.
- **Acceptance:** `END` absence ⇒ `MissingEnd`; comment accessor returns the parsed comment; ordered
  serialization preserved.

### HDU-1 — HDU model, kind detection & required-keyword validation
- **Milestone:** M0 · **Module:** `src/hdu.zig` · **Size:** M · **Status:** todo
- **Depends on:** HDR-3a
- **Req:** FR-HDU-1, FR-HDU-2, FR-HDU-5, FR-HDU-6 · **Design:** §10.1, §10.2 · **Spec:** §3.3, §4.4.1, §7
- **Goal:** `HduKind`, the `Hdu` struct, and finalize-time mandatory-keyword presence/order/type checks;
  **`EXTEND` advisory** (never flag missing/non-adjacent).
- **Acceptance:** valid headers pass; reordered/absent mandatory keywords ⇒ typed `StructError`; an
  extensionful file with no `EXTEND` is not flagged.

### FITS-1a — File handle: open/create/scan/navigate
- **Milestone:** M0 · **Module:** `src/fits.zig` · **Size:** L · **Status:** todo · **Module-lock:** fits.zig
- **Depends on:** HDU-1, IO-3, IO-4, IO-5, LIM-1, ERR-2
- **Req:** FR-HDU-1, FR-HDU-3, FR-IO-5, NFR-MEM-1, NFR-CONC-1 · **Design:** §10.3, §25 · **Spec:** §3.1, §3.4.3, §3.5
- **Goal:** The `Fits` handle's read side: `Mode{read_only,read_write,create}`, lazy HDU scan, navigation
  (`hduCount`/`select`/`move`/`selectByName`/`current`), **individually-allocated stable `*Hdu`**, and
  **disregarding trailing special records** (§3.5) during the scan.
- **Acceptance:** a `*Hdu` held across many reallocating appends stays valid (no UAF); lazy scan parses
  only HDU 1 on open; **no package-level `var` / global allocator — all state lives in `Fits`**
  (NFR-MEM-1/NFR-CONC-1); read-only device ⇒ writes `NotWritable`.

### FITS-1b — File handle: HDU mutation & programmatic builders
- **Milestone:** M0 · **Module:** `src/fits.zig` · **Size:** L · **Status:** done · **Module-lock:** fits.zig
- **Depends on:** FITS-1a
- **Req:** FR-HDU-4, FR-TPL-2, FR-SUM-3 (flush hook) · **Design:** §10.3, §21.2 · **Spec:** §3.1
- **Goal:** The mutation side + the **primary programmatic builder** (FR-TPL-2): `appendHdu`/`copyHdu`/
  `deleteHdu`/`flush` with block realignment, plus the typed convenience builders `appendImage`/
  `appendTable` and `fileDevice` used by the §21 examples. `flush` exposes a nullable
  `checksum_on_close` hook that `SUM-1` registers `updateChecksum` into.
- **Acceptance:** structural edits keep block alignment and the primary/extension invariant; **the
  programmatic builder is the complete, sufficient HDU-construction path independent of any template**
  (FR-TPL-2); `appendImage`/`appendTable`/`fileDevice` exist for the README examples.

### IMG-1 — Image core: type model & contiguous pixel I/O
- **Milestone:** M0 · **Module:** `src/image.zig` · **Size:** L · **Status:** todo · **Module-lock:** image.zig
- **Depends on:** FITS-1a, FITS-1b, CONV-1, END-1, IO-5
- **Req:** FR-IMG-1, FR-IMG-2, FR-IMG-3, FR-IMG-9 · **Design:** §11.1, §11.2 · **Spec:** §3.3.2, §4.4.1, §5, §7.1
- **Goal:** `ImageView` over all six `BITPIX` and `NAXIS` 0–999; chunked block-aligned
  `readAll`/`readPixels`/`writeAll`/`writePixels` in the caller's comptime element type (whole-array
  calls wrap the chunked core). Depends on `FITS-1b` because the write round-trip test creates an HDU.
- **Acceptance:** every `BITPIX` round-trips; an N-D `first`+count run reads the right bytes; multi-chunk
  read stays in bounded memory.

---

## Milestone M1 — Core library (P1)

### HDR-3b — Header edit operations
- **Milestone:** M1 · **Module:** `src/header/header.zig` · **Size:** M · **Status:** todo · **Module-lock:** header/header.zig
- **Depends on:** HDR-3a
- **Req:** FR-HDR-11 · **Design:** §9.4 · **Spec:** §4.1
- **Goal:** `append`/`update`(create-if-absent)/`insert`/`delete`/`rename` **plus an explicit
  modify-in-place** path (FR-HDR-11 lists it distinctly from `update`).
- **Acceptance:** each op preserves ordering and the index; in-place modify changes a value without
  reordering; `update` creates when absent.

### HDR-4 — CONTINUE long-string convention
- **Milestone:** M1 · **Module:** `src/header/continue.zig` · **Size:** M · **Status:** todo
- **Depends on:** HDR-3b
- **Req:** FR-HDR-8 · **Design:** §9.3 · **Spec:** §4.2.1.2
- **Goal:** Assemble `&`-continued strings on read; split >68-char values into primary + `CONTINUE` on
  write (bounded by `max_string_value`).
- **Acceptance:** the §4.2.1.2 example reassembles exactly; raw cards remain for byte-exact round-trip;
  **a value ending in `&` with no valid following `CONTINUE` keeps `&` as a literal character**, while an
  **orphaned `CONTINUE` card** is treated as commentary (the two cases are distinct, §4.2.1.2).

### IMG-2 — Linear scaling (BSCALE/BZERO)
- **Milestone:** M1 · **Module:** `src/image.zig` · **Size:** M · **Status:** todo · **Module-lock:** image.zig
- **Depends on:** IMG-1
- **Req:** FR-IMG-5 · **Design:** §11.3 · **Spec:** §4.4.2.5, Eq. 3
- **Goal:** Transparent `physical = BZERO + BSCALE×stored` on read, inverted on write, `.raw` switch.
- **Acceptance:** scaled read matches Eq. 3; `.raw` exposes stored values; write inverts exactly for
  representable values.

### IMG-3 — Unsigned-integer convention
- **Milestone:** M1 · **Module:** `src/image.zig` · **Size:** M · **Status:** todo · **Module-lock:** image.zig
- **Depends on:** IMG-2
- **Req:** FR-IMG-6 · **Design:** §11.3 · **Spec:** §4.4.2.5, Table 11
- **Goal:** Read/write `u16`/`u32`/`u64` via `BSCALE=1`, `BZERO=2^15/2^31/2^63`, offset in integer space.
- **Acceptance:** values near `2^63` round-trip with no `f64` precision loss.

### IMG-4 — Null handling (BLANK / NaN)
- **Milestone:** M1 · **Module:** `src/image.zig` · **Size:** M · **Status:** todo · **Module-lock:** image.zig
- **Depends on:** IMG-2, X-FIXTURES
- **Req:** FR-IMG-8 · **Design:** §11.4 · **Spec:** §4.4.2.5, §5.3, Appendix E
- **Goal:** Honor integer `BLANK` and IEEE-NaN nulls with caller sentinels, comparing the **raw stored**
  value before scaling; `ReadOpts(T){null_sentinel,scaling}`; exported `fits_nan_f32`/`fits_nan_f64`.
- **Acceptance:** raw `BLANK`↔sentinel on read/write; **any** NaN reads as null; **the emitted
  `fits_nan` bit pattern equals CFITSIO's**, asserted against a committed CFITSIO-written NaN float image
  (X-FIXTURES) — not merely "any NaN reads as null".

### IMG-5 — Rectangular sections with stride
- **Milestone:** M1 · **Module:** `src/image.zig` · **Size:** M · **Status:** todo · **Module-lock:** image.zig
- **Depends on:** IMG-1
- **Req:** FR-IMG-4 · **Design:** §11.2 · **Spec:** §3.3.2
- **Goal:** `readSection`/`writeSection` over `lower..upper` per axis with optional stride, one innermost
  row at a time.
- **Acceptance:** a strided 2-D sub-rectangle matches a manual gather; bounds validated.

### UTL-1 — Date/time helpers
- **Milestone:** M1 · **Module:** `src/wcs/time.zig` (date/JD core) · **Size:** M · **Status:** todo · **Module-lock:** wcs/time.zig
- **Depends on:** ERR-1
- **Req:** FR-UTL-1 · **Design:** §19.1 · **Spec:** §4.2.7, §9.1.1
- **Goal:** Format/parse `DATE`/`DATE-OBS`; accept deprecated `DD/MM/YY` (⇒19YY); convert to/from JD/MJD.
- **Acceptance:** ISO-8601 round-trips incl. fractional seconds; `DD/MM/YY`⇒19YY; JD/MJD match known epochs.

### TBL-1 — Column model & TFORM/TDISP parsing
- **Milestone:** M1 · **Module:** `src/table/common.zig` · **Size:** M · **Status:** todo · **Module-lock:** table/common.zig
- **Depends on:** ERR-1, CONV-1
- **Req:** FR-UTL-2 · **Design:** §12.2, §13.1 · **Spec:** §7.2.4, §7.3.3, Tables 15–20
- **Goal:** Shared `TFORM`/`TDISP` parsing (type code, repeat, width, decimals) + ASCII column-position
  computation.
- **Acceptance:** every Table 15/18/16/20 code parses; `TBCOLn` math validated.

### ATB-1 — ASCII TABLE extension
- **Milestone:** M1 · **Module:** `src/table/ascii.zig` · **Size:** L · **Status:** todo
- **Depends on:** TBL-1, FITS-1a, HDR-3a, IO-5, CONV-1
- **Req:** FR-ATB-1, FR-ATB-2, FR-ATB-3, FR-ATB-4 · **Design:** §12 · **Spec:** §7.2
- **Goal:** `XTENSION='TABLE'` read/write with fixed-width FORTRAN-style formatting/parsing, null fields,
  `TSCALn`/`TZEROn`. Single-cell reads use `convert.cast(.scalar)`, whole-column reads `.bulk`
  (FR-CONV-1(c)).
- **Acceptance:** read/write round-trips each format; `TNULLn`/all-blank ⇒ null; `NAXIS1` may exceed the
  field extent; width overflow is a typed error, not truncation.

### BTB-1 — BINARY TABLE structure & TFORM codes
- **Milestone:** M1 · **Module:** `src/table/binary.zig` · **Size:** L · **Status:** todo · **Module-lock:** table/binary.zig
- **Depends on:** TBL-1, FITS-1a, HDR-3a, END-1, IO-5
- **Req:** FR-BTB-1, FR-BTB-2, FR-BTB-3 · **Design:** §13.1 · **Spec:** §7.3
- **Goal:** `XTENSION='BINTABLE'` with all standard `TFORMn` codes (`L X B I J K A E D C M` + `P`/`Q`),
  repeat counts incl. `0`, MSB-first `X` bit packing, and `TDIMn` reshaping.
- **Acceptance:** each code reads/writes; `X` MSB-first; `r=0` accepted; **`TDIMn` element product must be
  `≤` the repeat count (`≤` the descriptor length for `P`/`Q`), with trailing elements interpreted as
  undefined fill** (FITS §7.3.2) — not required to equal it.

### BTB-2 — Binary scaling, nulls & unsigned/signed types
- **Milestone:** M1 · **Module:** `src/table/binary.zig` · **Size:** M · **Status:** todo · **Module-lock:** table/binary.zig
- **Depends on:** BTB-1, CONV-1
- **Req:** FR-BTB-4 · **Design:** §13.2 · **Spec:** §7.3.2, Table 19
- **Goal:** Per-column `TSCALn`/`TZEROn`, integer `TNULLn`, IEEE-NaN float nulls, and the unsigned/signed
  types surfaced as `u16`/`u32`/`u64`/`i8`. **`U`/`V`/`W`/`S` are internal API type tags stored on disk
  with the standard `I`/`J`/`K`/`B` codes + Table 19 `TZEROn` — never written to `TFORMn`.**
- **Acceptance:** the Table 19 offsets surface the unsigned/`i8` types; NaN pattern matches IMG-4.

### BTB-3a — Binary column access & A-format
- **Milestone:** M1 · **Module:** `src/table/binary.zig` · **Size:** L · **Status:** todo · **Module-lock:** table/binary.zig
- **Depends on:** BTB-1, NAME-1, CONV-1
- **Req:** FR-BTB-5, FR-BTB-7 · **Design:** §13.3, §13.4 · **Spec:** §7.3.3, §7.3.4
- **Goal:** Column locate-by-name(wildcard)/number; read/write whole columns, cell ranges, single
  elements; precise `A`-format. **Single-element reads use `convert.cast(.scalar)`; cell-range/whole-column
  reads use `.bulk`** (FR-CONV-1(c)).
- **Deliverables:** `ColumnRef`; `columnByName(pat,*Matches)` honoring the `FR-UTL-4` contract;
  block-aligned whole-row buffering with columnar striding; `A`: NUL-terminate within repeat, space-pad
  on write, leading NUL ⇒ null string; `rAw` shorthand **out of scope**.
- **Acceptance:** wildcard zero/one/many contract holds; `A`-format decode/encode matches §7.3.3; a
  single-cell precision-losing read errors while the column read does not.

### BTB-3b — Binary row & column structural operations
- **Milestone:** M1 · **Module:** `src/table/binary.zig` · **Size:** L · **Status:** done · **Module-lock:** table/binary.zig
- **Depends on:** BTB-3a
- **Req:** FR-BTB-6 · **Design:** §13.3 · **Spec:** §7.3
- **Goal:** Row ops `appendRows`/`insertRows`/`deleteRows`/`copyRows` and column ops
  `insertColumn`/`appendColumn`/`deleteColumn`/`copyColumn`, maintaining geometry.
- **Acceptance:** row/column edits preserve `NAXIS1`/`NAXIS2`/`TFIELDS` invariants and re-index correctly.

### VLA-1 — Variable-length arrays & heap
- **Milestone:** M1 · **Module:** `src/table/heap.zig` · **Size:** L · **Status:** todo
- **Depends on:** BTB-1, LIM-1
- **Req:** FR-VLA-1, FR-VLA-2, FR-VLA-3, FR-VLA-4 · **Design:** §14 · **Spec:** §7.3.5, §7.3.6
- **Goal:** `rPt`/`rQt` descriptor columns following into the heap with strict geometry validation and a
  compacting heap manager.
- **Deliverables:** signed `Descriptor{len,off}` (negatives rejected); `r`∈{absent,0,1}; heap size =
  `PCOUNT − (THEAP − NAXIS1×NAXIS2)`; `off+len*elem` bounds-checked vs heap **and** data-unit extent;
  `THEAP` default = min = `NAXIS1×NAXIS2`; `HeapManager{alloc,free,compact}`.
- **Acceptance:** read/write follows descriptors with scaling/conversion; out-of-bounds/negative ⇒
  `BadDescriptor`; rewrites don't grow the heap unboundedly.

### SUM-1 — DATASUM & CHECKSUM
- **Milestone:** M1 · **Module:** `src/checksum.zig` · **Size:** L · **Status:** todo
- **Depends on:** IO-5, HDR-3a, FITS-1a, END-1
- **Req:** FR-SUM-1, FR-SUM-2, FR-SUM-3 · **Design:** §16 · **Spec:** §4.4.2.7, Appendix J
- **Goal:** `DATASUM` over the **padded** data unit (fill summed, big-endian groups via `endian.read`) as
  an unsigned decimal string; `CHECKSUM` as the 16-char Seaman–Pence ASCII encoding; `DATASUM` written
  before `CHECKSUM`.
- **Deliverables:** incremental `datasum`; `encodeChecksum`/`decodeChecksum`; `verify` →
  `{match,mismatch,not_present}`; **an explicit `updateChecksum()` operation** (FR-SUM-3) registered into
  the `FITS-1b.flush` `checksum_on_close` hook.
- **Acceptance:** Appendix J example ⇒ `DATASUM='2503531142'` / `CHECKSUM='hcHjjc9ghcEghc9g'`; the
  CFITSIO ASCII-table vector recomputes to `628729719` space-padded and `1302441855` zero-padded;
  `updateChecksum()` is callable as a standalone op. (Committed-fixture parity lives in X-SUM.)

---

## Milestone M2 — Full standard (P2)

### HDR-3c — Header-space pre-allocation
- **Milestone:** M2 · **Module:** `src/header/header.zig` · **Size:** S · **Status:** todo · **Module-lock:** header/header.zig
- **Depends on:** HDR-3b
- **Req:** FR-HDR-12 · **Design:** §9.4 · **Spec:** §4.4.2.4
- **Goal:** `reserveSpace(n)` appends blank cards before `END` so later `update` calls fill in place
  (design §26 places header-space in M2).
- **Acceptance:** `reserveSpace` then `update` fills in place without rewriting following HDUs.

### HDR-5 — HIERARCH convention
- **Milestone:** M2 · **Module:** `src/header/hierarch.zig` · **Size:** M · **Status:** todo
- **Depends on:** HDR-2, HDR-3b
- **Req:** FR-HDR-9 · **Design:** §9.3 · **Spec:** Registry (HIERARCH)
- **Goal:** Parse/write `HIERARCH a b c = val`; lookups accept either spelling.
- **Acceptance:** long-name round-trip; lookup by both spellings.

### HDR-6 — Keyword units (`[unit]` comment convention)
- **Milestone:** M2 · **Module:** `src/header/value.zig` · **Size:** S · **Status:** todo · **Module-lock:** header/value.zig
- **Depends on:** HDR-1, HDR-2
- **Req:** FR-HDR-10 · **Design:** §9.3 · **Spec:** §4.3.2
- **Goal:** Parse the leading `[unit]` comment convention into an optional `units` accessor without
  disturbing comment text.
- **Acceptance:** `EXPTIME = 1200. / [s] exposure` ⇒ `units = "s"`; non-unit bracket text not misread.

### HDR-7 — INHERIT convention
- **Milestone:** M2 · **Module:** `src/header/header.zig` · **Size:** M · **Status:** todo · **Module-lock:** header/header.zig
- **Depends on:** HDR-3a
- **Req:** FR-HDR-14 · **Design:** §9.4 · **Spec:** §4.4.2.6, Appendix K
- **Goal:** Opt-in, read-only-in-effect fall-through from an extension header to the primary; never
  changes bytes. Resolves the structural-keyword exclusion **locally** (no dependency on `hdu.zig` — that
  would create a `header.zig ↔ hdu.zig` import cycle, design §2).
- **Acceptance:** when enabled, a miss falls through **except** the non-inheritable set —
  `XTENSION/BITPIX/NAXIS/NAXISn/PCOUNT/GCOUNT/TFIELDS/EXTEND/END`, **plus `SIMPLE`, `COMMENT`, `HISTORY`,
  blank cards, the §7.2/7.3 table-specific keywords, and the §8 table-WCS keywords** (Appendix K);
  disabled by default; serialization unchanged.

### IMG-6 — Signed-byte convention
- **Milestone:** M2 · **Module:** `src/image.zig` · **Size:** S · **Status:** todo · **Module-lock:** image.zig
- **Depends on:** IMG-2
- **Req:** FR-IMG-7 · **Design:** §11.3 · **Spec:** §4.4.2.5, Table 11
- **Goal:** `BITPIX=8` + `BZERO=−128` read/written as `i8`.
- **Acceptance:** full `i8` range round-trips.

### IMG-7 — Resize / redefine image
- **Milestone:** M2 · **Module:** `src/image.zig` · **Size:** M · **Status:** done · **Module-lock:** image.zig
- **Depends on:** IMG-1, FITS-1b
- **Req:** FR-IMG-10 · **Design:** §11.5 · **Spec:** §4.4.1
- **Goal:** `reshape(bitpix, axes)` rewriting structural keywords and shifting following HDUs with block
  re-alignment (uses the `FITS-1b` mutation path).
- **Acceptance:** following HDUs stay valid and aligned after a data-size-changing reshape.

### RG-1 — Random groups
- **Milestone:** M2 · **Module:** `src/groups.zig` · **Size:** L · **Status:** todo
- **Depends on:** IMG-2, HDR-3b
- **Req:** FR-RG-1, FR-RG-2 · **Design:** §15 · **Spec:** §6
- **Goal:** Read the §6 random-groups structure (order, `NAXIS1=0`, `GROUPS=T`, `PTYPEn`/`PSCALn`/
  `PZEROn`); access parameters + per-group array with scaling (read via the IMG-2 scaling path); optional
  write (MAY).
- **Acceptance:** parameters/arrays read with `PSCALn`/`PZEROn`(+BSCALE/BZERO); no keyword intervenes
  between `SIMPLE` and the last `NAXISn`; **a write→read round-trip preserves group data** (or write is
  explicitly marked descoped if not implemented — FR-RG-2 is MAY).

### WCS-1 — WCS keyword set
- **Milestone:** M2 · **Module:** `src/wcs/keys.zig` · **Size:** L · **Status:** todo
- **Depends on:** HDR-3a, HDR-3b
- **Req:** FR-WCS-1 · **Design:** §18.1 · **Spec:** §8.1, §8.2, Tables 21–22
- **Goal:** Parse (`fromHeader`, HDR-3a) and serialize (`writeTo`, HDR-3b) the WCS keyword set incl.
  alternate (`…a`) descriptions and the mutually-exclusive `CDi_j`/`PCi_j` matrices; `CROTAn` read-only.
- **Acceptance:** `CDi_j` + `PCi_j` together ⇒ `BadWcs`; alternates parsed; `CROTAn` not written with
  `PC/PV/PS`.

### WCS-2 — Celestial transforms
- **Milestone:** M2 · **Module:** `src/wcs/celestial.zig` · **Size:** XL · **Status:** todo
- **Depends on:** WCS-1, X-FIXTURES
- **Req:** FR-WCS-2 · **Design:** §18.2 · **Spec:** §8.3, Table 23
- **Goal:** pixel↔world for the common projections (TAN, SIN, ARC, STG, ZEA, AIT, CAR, MER, …) via
  PC/CD+CDELT, projection math, LONPOLE/LATPOLE rotation; extensible registry; unsupported ⇒
  `UnsupportedProjection`. (Realistically XL — split per projection family if the runner prefers.)
- **Acceptance:** for each implemented projection, pixel→world→pixel **and** agreement with committed
  **astropy/WCSLIB reference points** (X-FIXTURES) within a stated tolerance (e.g. `< 1e-9 deg`).

### WCS-3 — Spectral coordinates
- **Milestone:** M2 · **Module:** `src/wcs/spectral.zig` · **Size:** M · **Status:** todo
- **Depends on:** WCS-1, X-FIXTURES
- **Req:** FR-WCS-3 · **Design:** §18.2 · **Spec:** §8.4, Tables 25–27
- **Goal:** Spectral `CTYPEn` types, `RESTFRQ`/`RESTWAV`, `SPECSYS`.
- **Acceptance:** spectral keyword sets parse/serialize; reference-frame recognition checked against a
  committed Table-25/27 fixture (X-FIXTURES).

### WCS-4 — Time coordinates
- **Milestone:** M2 · **Module:** `src/wcs/time.zig` · **Size:** M · **Status:** todo · **Module-lock:** wcs/time.zig
- **Depends on:** WCS-1, UTL-1
- **Req:** FR-WCS-4 · **Design:** §18.2 · **Spec:** §9, Tables 30–35
- **Goal:** `MJDREF[I|F]`/`JDREF`/`DATEREF`, `TIMESYS`, `TIMEUNIT`, `TREFPOS`, `DATE-OBS`,
  `TSTART`/`TSTOP`, sharing UTL-1's JD helpers.
- **Acceptance:** global time keywords parse/serialize; `TIMESYS`/`TREFPOS` validated vs Tables 30/31.

### CMP-1 — GZIP_2 byte shuffle
- **Milestone:** M2 · **Module:** `src/compress/shuffle.zig` · **Size:** M · **Status:** todo
- **Depends on:** END-1
- **Req:** FR-CMP-2 · **Design:** §17.2 · **Spec:** §10.4.2
- **Goal:** The MSB-first type-aware byte shuffle (split N W-byte values into W planes) + exact inverse —
  integer/float only, never logical/bit/char.
- **Acceptance:** `unshuffle(shuffle(x)) == x` per width; the §10.4.2 byte ordering reproduced.

### CMP-2 — GZIP_1 / GZIP_2 codecs
- **Milestone:** M2 · **Module:** `src/compress/gzip.zig` · **Size:** S · **Status:** todo
- **Depends on:** CMP-1
- **Req:** FR-CMP-2 · **Design:** §17.2 · **Spec:** §10.4.2
- **Goal:** Use `std.compress.flate` with `Container.gzip` (which already supplies the RFC-1952 header /
  CRC32 / ISIZE — **do not hand-roll the container**); `GZIP_2` = shuffle then GZIP_1. The only
  FITS-specific in-house code is the CMP-1 shuffle, which `std` does not provide.
- **Acceptance:** decode of a CFITSIO/Astropy GZIP tile (X-FIXTURES) matches raw pixels; encode→decode
  round-trips; `GZIP_2` shuffles numeric types only.

### CMP-3a — Tiled-image structure & codec registry
- **Milestone:** M2 · **Module:** `src/compress/tiled.zig` · **Size:** L · **Status:** todo · **Module-lock:** compress/tiled.zig
- **Depends on:** BTB-1, VLA-1
- **Req:** FR-CMP-1 · **Design:** §17.1 · **Spec:** §10.1
- **Goal:** Parse the compressed-image structure and define the codec interface. Parse the mandatory
  `ZIMAGE`/`ZCMPTYPE`/`ZBITPIX`/**`ZNAXIS`**/`ZNAXISn` and `ZTILEn`/`ZQUANTIZ`/`ZDITHER0`/`ZNAMEn`/
  `ZVALn`; the columns `COMPRESSED_DATA`(1P/1Q), `GZIP_COMPRESSED_DATA`/`UNCOMPRESSED_DATA`, per-tile
  `ZSCALE`/`ZZERO`, `ZBLANK`(kw or column); the tiling/geometry model; the `TileCodec` registry; and
  `UnsupportedCodec` gating.
- **Acceptance:** all mandatory `Z*` keywords (incl. `ZNAXIS`) parsed/validated; an unimplemented
  `ZCMPTYPE` ⇒ `UnsupportedCodec` (never a silent mis-read); tile geometry computed for non-multiple
  dimensions.

### CMP-3b — Tiled-image decode & ImageView
- **Milestone:** M2 · **Module:** `src/compress/tiled.zig` · **Size:** L · **Status:** todo · **Module-lock:** compress/tiled.zig
- **Depends on:** CMP-3a, CMP-2, IMG-2, IMG-4
- **Req:** FR-CMP-1 · **Design:** §17.1 · **Spec:** §10.1
- **Goal:** Decode the covering tile(s) via the registry and present a normal `ImageView` with per-tile
  `ZSCALE`/`ZZERO`/`ZBLANK` scaling.
- **Acceptance:** a GZIP-tiled image reads identically to its uncompressed twin, **including a fixture
  whose dimensions are not a tile multiple (edge/partial tiles) and a read spanning ≥2 tiles**.

### ITR-1 — Work-function iterator
- **Milestone:** M2 · **Module:** `src/iterator.zig` · **Size:** L · **Status:** todo
- **Depends on:** IMG-1, BTB-3a, CONV-1
- **Req:** FR-ITR-1, FR-ITR-2 · **Design:** §19.2
- **Goal:** Drive a caller work-function over image pixels / **binary-table** columns in block-aligned
  chunks with buffering, conversion, null substitution; `Iterator(comptime Cols, comptime E)` with
  `Role{in,out,inout}` and per-call grouping; caller's typed `E` threaded through `run` (no `anyerror`).
  (ASCII-table iteration is a documented follow-up, design §19.2.)
- **Acceptance:** a heterogeneous `Cols` is driven in one pass; a caller error propagates with its
  concrete type; **chunked operation is bounded-memory with no per-element allocation** (NFR-PERF-1/3,
  also measured by X-BENCH).

### UTL-2 — TDISP rendering
- **Milestone:** M2 · **Module:** `src/table/common.zig` · **Size:** M · **Status:** todo · **Module-lock:** table/common.zig
- **Depends on:** TBL-1, X-FIXTURES
- **Req:** FR-UTL-5 · **Design:** §19.1 · **Spec:** §7.2.2/§7.3.4, Tables 16/20
- **Goal:** Apply `TDISPn`/`TDISP` to render values as text and compute display width
  (≡ `fits_get_col_display_width`).
- **Acceptance:** each Table 16/20 code renders at the correct width; display widths match a **committed
  CFITSIO `fits_get_col_display_width` golden table** (X-FIXTURES).

### VLD-1 — Structural validation (`fitsverify`-style)
- **Milestone:** M2 · **Module:** `src/validate.zig` · **Size:** L · **Status:** todo
- **Depends on:** HDU-1, ATB-1, BTB-1, VLA-1, RG-1, SUM-1
- **Req:** FR-VAL-1, FR-VAL-2 · **Design:** §19.3 · **Spec:** §3, §4.4.1, §7
- **Goal:** A pass reporting **all** findings classified error vs warning. Checks: block sizing;
  mandatory keyword presence/order/type; **no duplicate mandatory keyword** (§4.2.1.1); value ranges
  incl. **`BLANK` only with positive `BITPIX`** (§4.4.2.5/§5.3); table geometry (binary: `NAXIS1`=Σ field
  widths; ASCII: `TBCOLn`+width ≤ `NAXIS1`, which may exceed the extent); **random-groups geometry**
  (via RG-1); declared-vs-actual data sizes; `END`/padding; **`DATASUM`/`CHECKSUM` verification** (via
  SUM-1); a missing/non-adjacent `EXTEND` is **not** a finding.
- **Acceptance:** valid fixtures yield no errors; malformed fixtures (authored by X-FIXTURES) yield the
  expected error/warning set, not just the first.

---

## Milestone M3 — Extended (P3)

### CMP-4 — RICE_1 codec
- **Milestone:** M3 · **Module:** `src/compress/rice.zig` · **Size:** L · **Status:** done (round-trip; byte-exact X-FIXTURES pending)
- **Depends on:** CMP-3a, X-FIXTURES
- **Req:** FR-CMP-3 · **Design:** §17.3 · **Spec:** §10.4.1, Table 37
- **Goal:** Integer-only Rice (de)compression honoring `BLOCKSIZE`/`BYTEPIX`, plugged into the CMP-3a
  registry.
- **Acceptance:** decode of a committed CFITSIO RICE_1 tile matches; round-trip lossless; non-integer ⇒
  `DataConstraintViolated`.

### CMP-5 — PLIO_1 codec
- **Milestone:** M3 · **Module:** `src/compress/plio.zig` · **Size:** L · **Status:** done (round-trip; byte-exact X-FIXTURES pending)
- **Depends on:** CMP-3a, X-FIXTURES
- **Req:** FR-CMP-3 · **Design:** §17.3 · **Spec:** §10.4.3, Table 38
- **Goal:** IRAF PLIO run-length mask codec (16-bit instructions), values `0…2^24`.
- **Acceptance:** the Table 38 instruction set reconstructs a mask line from a committed CFITSIO PLIO
  tile; out-of-range ⇒ `DataConstraintViolated`.

### CMP-6 — HCOMPRESS_1 codec
- **Milestone:** M3 · **Module:** `src/compress/hcompress.zig` · **Size:** XL · **Status:** done (lossless round-trip; byte-exact X-FIXTURES pending)
- **Depends on:** CMP-3a, X-FIXTURES
- **Req:** FR-CMP-3 · **Design:** §17.3 · **Spec:** §10.4.4, Table 39
- **Goal:** H-transform + quantization + quadtree coding, 2-D tiles only, `SCALE` from `ZVAL1`.
- **Acceptance:** lossless (`SCALE=0`) round-trip is exact **and decode of a committed CFITSIO-written
  HCOMPRESS_1 tile matches** (X-FIXTURES — same inbound bar as CMP-4/CMP-5); non-2-D ⇒
  `DataConstraintViolated`.

### CMP-7 — Subtractive dithering & random generator
- **Milestone:** M3 · **Module:** `src/compress/dither.zig` · **Size:** M · **Status:** done
- **Depends on:** CMP-3a
- **Req:** FR-CMP-4 · **Design:** §17.3 · **Spec:** §10.2, §10.2.1, Appendix I
- **Goal:** `NO_DITHER`/`SUBTRACTIVE_DITHER_1`/`_2` quantization seeded by `ZDITHER0`, using Park–Miller.
- **Acceptance:** the Appendix I generator's 10000ᵗʰ seed equals `1043618065`; dither→undither matches
  the documented behavior; zero-valued and NaN pixels handled per §10.2.1.

### CMP-8 — Tiled-image compressed write
- **Milestone:** M3 · **Module:** `src/compress/tiled.zig` · **Size:** L · **Status:** done (GZIP incl. float dither; CFITSIO read-back is an X-FIXTURES item) · **Module-lock:** compress/tiled.zig
- **Depends on:** CMP-3b, CMP-7
- **Req:** FR-CMP-4 · **Design:** §17.3 · **Spec:** §10.1, §10.2
- **Goal:** Write a tiled-compressed image for at least GZIP incl. float dithering options.
- **Acceptance:** a `zigfitsio`-written compressed image is read back by CFITSIO/Astropy and matches the
  source (within the quantization tolerance for lossy modes).

### CMP-9 — Tiled-table compression (read)
- **Milestone:** M3 · **Module:** `src/compress/tiled.zig` · **Size:** L · **Status:** done (GZIP columns; byte-exact X-FIXTURES pending) · **Module-lock:** compress/tiled.zig
- **Depends on:** CMP-3a, BTB-1, X-FIXTURES
- **Req:** FR-CMP-5 · **Design:** §17.3 · **Spec:** §10.3
- **Goal:** Read a `ZTABLE=T` tile-compressed BINTABLE (§10.3 supersedes the registered convention).
- **Acceptance:** a committed CFITSIO-written tiled table decompresses to the expected rows.

### EFN-1 — Extended filename syntax + programmatic spec
- **Milestone:** M3 · **Module:** `src/filename.zig` · **Size:** L · **Status:** done (parse + programmatic; column/row filters out of scope)
- **Depends on:** FITS-1a, IMG-5, BTB-3a
- **Req:** FR-EFN-1, FR-EFN-2, FR-EFN-3, FR-EFN-4, FR-EFN-5 · **Design:** §20.1
- **Goal:** Parse CFITSIO-style extended names into a `FileSpec` with a programmatic equivalent (the DSL
  is never the only path). 0-based bracket index (`[n]` ↔ HDU `n+1`); section `[a:b:c,…]` → `readSection`;
  column/row filtering are MAY (full expression engine **not committed**).
- **Acceptance:** `img.fits[1:512:2,1:512]` maps to the right bounds/stride; `[0]`=primary; every
  supported DSL feature has a struct-level equivalent; grammar documented.

### RMT-1 — Whole-file gzip backend
- **Milestone:** M3 · **Module:** `src/io/stream.zig` · **Size:** M · **Status:** done · **Module-lock:** io/stream.zig
- **Depends on:** IO-2, IO-3
- **Req:** FR-RMT-2 · **Design:** §20.2
- **Goal:** Transparent `.fits.gz` read/write via `std.compress.flate` — decompress into a memory
  `Device` for random access, compress on flush.
- **Acceptance:** a gzip-compressed FITS file opens, reads, and re-compresses identically in content.

### RMT-2 — HTTP(S) range-GET backend
- **Milestone:** M3 · **Module:** `src/io/http.zig` · **Size:** L · **Status:** todo
- **Depends on:** IO-1, IO-3
- **Req:** FR-RMT-3 · **Design:** §20.2
- **Goal:** Read-only `Device` over `std.http.Client` Range requests (TLS 1.3 only), falling back to a
  full in-memory download. Leaf module the core never imports.
- **Deliverables:** **register `io/http.zig` in the `wasm32-freestanding` exclusion list** (X-WASM) when
  adding it — it is an OS-backed leaf.
- **Acceptance:** range reads fetch the right bytes; no-range servers fall back; excluded from the
  freestanding build graph.

### TPL-1 — ASCII header template loader
- **Milestone:** M3 · **Module:** `src/template.zig` · **Size:** M · **Status:** done
- **Depends on:** HDR-3b, FITS-1b
- **Req:** FR-TPL-1 · **Design:** §20.3
- **Goal:** Create a FITS file from a CFITSIO-style ASCII template — a thin convenience over the
  `FITS-1b` programmatic builder, which remains the primary, sufficient path (FR-TPL-2, owned by FITS-1b).
- **Acceptance:** a template produces the same HDUs as the equivalent programmatic build; auto-indexing
  and directives handled.

### GRP-1 — Hierarchical grouping tables
- **Milestone:** M3 · **Module:** `src/group_table.zig` · **Size:** L · **Status:** done
- **Depends on:** BTB-3b, FITS-1a
- **Req:** FR-GRP-1, FR-GRP-2 · **Design:** §20.4 · **Spec:** Registry (Grouping)
- **Goal:** Read grouping BINTABLEs (`GRPNAME`, `MEMBER_*`, member-side `GRPIDn`/`GRPLCn`) and resolve
  membership to HDUs (FR-GRP-1); create/edit grouping tables via the BTB-3b structural ops (FR-GRP-2).
- **Acceptance:** membership resolves to referenced HDUs on a sample grouped file; **adding/removing a
  member updates the `MEMBER_*` rows and `GRPIDn`/`GRPLCn` and re-resolves correctly** (FR-GRP-2).

### ERR-4 — CFITSIO status-code map
- **Milestone:** M3 · **Module:** `src/errors.zig` · **Size:** S · **Status:** todo · **Module-lock:** errors.zig
- **Depends on:** ERR-1
- **Req:** FR-ERR-4 · **Design:** §4.2
- **Goal:** Pure `cfitsioStatus(err) c_int` mapping each `Error` to the nearest CFITSIO status (e.g.
  `MissingEnd → 210`).
- **Acceptance:** exhaustive switch maps every error value; spot-checked vs CFITSIO's documented codes.

---

## Cross-cutting tracks (continuous, from M0)

### X-CI — Portability CI matrix (incl. big-endian)
- **Milestone:** X · **Module:** CI config · **Size:** M · **Status:** todo
- **Depends on:** SETUP-1
- **Req:** NFR-PORT-1, NFR-PORT-2 · **Design:** §24.3
- **Goal:** `{Linux, macOS, Windows} × {x86_64, aarch64}` running `zig build test`, **plus a big-endian
  cell** (`s390x-linux` or `powerpc64-linux` under QEMU) running `zig build test`.
- **Acceptance:** all cells green; the big-endian cell exercises a genuine native big-endian read path —
  the LE-only `{x86_64, aarch64}` matrix cannot, by itself, prove endian-neutrality.

### X-FIXTURES — Corpus & golden-file provenance
- **Milestone:** X · **Module:** `test/corpus/`, `test/golden/`, CI config · **Size:** L · **Status:** todo
- **Depends on:** SETUP-1
- **Req:** NFR-TEST-2, NFR-TEST-3, NFR-INTEROP-1 · **Design:** §23
- **Goal:** Author/commit the externally-produced fixtures every other test consumes, and declare the
  environment that regenerates them.
- **Deliverables:** committed CFITSIO/Astropy-authored corpus + golden outputs (GZIP/RICE/PLIO/HCOMPRESS
  tiles, tiled tables, NaN float image, `fits_get_col_display_width` table, WCS reference points,
  malformed conformance fixtures); a documented regeneration toolchain; **the CI environment prereq —
  CFITSIO 4.6.4 + Astropy + Python — provisioned for the jobs that need it** (X-XVAL/X-INTEROP).
- **Acceptance:** all consumer tasks (X-CORPUS, X-XVAL, X-INTEROP, X-SUM, X-CONF, the `CMP-*` decode
  acceptances, IMG-4, UTL-2, WCS-2/3) can resolve their fixtures from this task's output; the regen
  toolchain reproduces them.

### X-GUARD — Invariant guards (no-C, convert-Mode, public surface)
- **Milestone:** X · **Module:** `test/guard/` · **Size:** S · **Status:** todo
- **Depends on:** SETUP-1, CONV-1, HDR-3a, IMG-1, ATB-1, BTB-3a
- **Req:** GC-1, FR-CONV-1, NFR-API-2 · **Design:** §1, §6, §3
- **Goal:** Automated guards for invariants otherwise enforced only by review.
- **Deliverables:** source-grep guards (no `@cImport`/C files → GC-1; no lowercase `std.io`; `root.zig`
  exposes only the intended surface → NFR-API-2); per-site fixtures asserting each public read/write
  picks the correct `convert` Mode (single-cell/keyword `.scalar` errors on precision loss; bulk silent
  → FR-CONV-1(c)).
- **Acceptance:** a planted `@cImport`/C file fails the guard; a planted lowercase `std.io` fails; a
  single-cell precision-losing read errors while the bulk path is silent.

### X-WASM — wasm32-freestanding core build
- **Milestone:** X · **Module:** `build.zig` + CI · **Size:** M · **Status:** done (full upper-layer stack; only the OS leaves io/file.zig, io/stream.zig, and the future io/http.zig are excluded)
- **Depends on:** IMG-1, IO-3, RMT-2
- **Req:** NFR-PORT-3, GC-7 · **Design:** §2, §8.1, §24.3
- **Goal:** Compile the core for `wasm32-freestanding`, excluding `io/file.zig`, `io/stream.zig`,
  `io/http.zig` (memory backend = the freestanding I/O path). Depends on RMT-2 so the `io/http.zig` leaf
  exists and is confirmed excluded.
- **Acceptance:** the freestanding build compiles in CI and excludes every OS-backed leaf.

### X-DOC — License, SemVer, changelog & usage guide
- **Milestone:** X · **Module:** `LICENSE`, `README.md`, `CHANGELOG.md` · **Size:** M · **Status:** todo
- **Depends on:** SETUP-1
- **Req:** NFR-DOC-1, NFR-DOC-2, NFR-API-1 · **Design:** §24.3, §27
- **Goal:** Choose & apply a CFITSIO-independent license (open question — MIT/Apache-2.0/BSD-3); SemVer +
  changelog; ship the §21 usage examples in `README.md`.
- **Acceptance:** `LICENSE` present and referenced by `build.zig.zon`; README has the read-image /
  create-image / read-column / verify-checksum examples; changelog scaffolded. (Resolve the §27 license
  open question before 1.0.)

### X-FUZZ — Header & table fuzz harnesses
- **Milestone:** X · **Module:** `test/fuzz/` · **Size:** M · **Status:** todo
- **Depends on:** HDR-3a, BTB-1, VLA-1
- **Req:** NFR-SAFE-2, NFR-SAFE-1, GC-6 · **Design:** §23
- **Goal:** `zig build fuzz` harnesses for the header and table/VLA parsers, seeded from the corpus,
  targeting validate-before-allocate. **As IMG-1 and CMP-3a land, add image-`NAXISn`-product and
  compression-tile-size seeds** so the §NFR-SAFE-1 paths beyond header/table are also fuzzed.
- **Acceptance:** hostile `NAXISn` product / `PCOUNT` / **VLA descriptor length+offset** produce typed
  errors, never panics/leaks; crashes/leaks are release blockers.

### X-CORPUS — Sample-file corpus & round-trip
- **Milestone:** X · **Module:** `test/` · **Size:** L · **Status:** todo
- **Depends on:** IMG-1, ATB-1, BTB-1, VLA-1, CMP-3b, CMP-8, X-FIXTURES
- **Req:** NFR-TEST-2, NFR-INTEROP-2 · **Design:** §23
- **Goal:** Exercise the X-FIXTURES corpus (images, ASCII/binary tables, VLA, **compressed**) for read +
  round-trip.
- **Acceptance:** read→write→read preserves data and mandatory/reserved keyword semantics; byte-for-byte
  where the format permits; compressed members read (CMP-3b) and round-trip (CMP-8).

### X-XVAL — Cross-validation vs CFITSIO/Astropy
- **Milestone:** X · **Module:** CI job · **Size:** M · **Status:** todo
- **Depends on:** X-CORPUS, SUM-1, X-FIXTURES
- **Req:** NFR-TEST-3 · **Design:** §23
- **Goal:** Compare `zigfitsio` output against CFITSIO/Astropy for the same inputs (goldens from
  X-FIXTURES; needs the provisioned CFITSIO/Astropy environment).
- **Acceptance:** outputs agree on the committed golden set.

### X-CONF — Conformance fixtures runner (valid + malformed)
- **Milestone:** X · **Module:** `test/` · **Size:** M · **Status:** todo
- **Depends on:** VLD-1, X-FIXTURES
- **Req:** NFR-TEST-4 · **Design:** §23 · **Spec:** §3, §4, §7
- **Goal:** Run `validate.zig` over the valid/malformed fixtures **authored in X-FIXTURES** (the fixtures
  are not produced by VLD-1 — that would be circular) and assert the FITS 4.0 rules.
- **Acceptance:** each malformed fixture produces its expected finding(s).

### X-CONC — Concurrency test & single-handle caveat
- **Milestone:** X · **Module:** `test/` · **Size:** S · **Status:** todo
- **Depends on:** FITS-1a
- **Req:** NFR-TEST-5 (a), NFR-CONC-1 · **Design:** §25
- **Goal:** A multi-threaded test driving **distinct** `Fits` handles concurrently + a doc-presence check
  for the single-handle-not-thread-safe caveat.
- **Acceptance:** distinct handles run concurrently with no shared-state races; the caveat is documented
  on `Fits`.

### X-INTEROP — Inbound & outbound interoperability
- **Milestone:** X · **Module:** CI job · **Size:** M · **Status:** todo
- **Depends on:** X-CORPUS, X-FIXTURES
- **Req:** NFR-TEST-5 (b), NFR-INTEROP-1 · **Design:** §23
- **Goal:** Read CFITSIO/Astropy-written files (inbound) **and** open every `zigfitsio`-written corpus
  file with CFITSIO + Astropy asserting success (outbound), using the provisioned environment.
- **Acceptance:** both legs green; an HDU using an unimplemented codec/convention fails typed, not
  silently mis-read.

### X-SUM — Checksum golden parity fixture
- **Milestone:** X · **Module:** `test/` · **Size:** S · **Status:** todo
- **Depends on:** SUM-1, X-FIXTURES
- **Req:** NFR-TEST-1, NFR-INTEROP-1 · **Design:** §16, §23 · **Spec:** Appendix J
- **Goal:** Run the committed CFITSIO ASCII-table vector and the Appendix J example as locked fixtures
  (SUM-1 owns the algorithmic golden in its own unit test; X-SUM owns the committed-file recompute).
- **Acceptance:** suite recomputes `DATASUM=628729719` space-padded and `1302441855` zero-padded;
  Appendix J example reproduces `CHECKSUM='hcHjjc9ghcEghc9g'`.

### X-API — Zig 0.16 API-regression fixtures
- **Milestone:** X · **Module:** `test/` · **Size:** S · **Status:** todo
- **Depends on:** ITR-1, FITS-1b, NAME-1
- **Req:** GC-3, GC-4 · **Design:** §23
- **Goal:** Compile-fixtures asserting the corrected snippets build and the original defects do **not**
  (field/method `current` collision; method-on-error-union; removed `std.BoundedArray`); compile the §21
  README examples (which use `fileDevice`/`appendImage`/`appendTable` and `Matches`).
- **Acceptance:** positive fixtures + the README §21 examples compile; the negative fixtures fail with the
  expected diagnostics; a `*Hdu` held across 1000 reallocating appends is safe; the `Matches` declaration
  (top-level `MAX_MATCHES` bound) compiles.

### X-BENCH — Throughput benchmarks
- **Milestone:** X · **Module:** `tools/bench.zig` · **Size:** M · **Status:** done (bulk image read/write MB/s; iterator/column bench is a follow-up)
- **Depends on:** IMG-1, BTB-3a, ITR-1
- **Req:** NFR-PERF-1, NFR-PERF-2, NFR-PERF-3 · **Design:** §23, §24
- **Goal:** Bulk image/column **and iterator** throughput benchmarks vs the ~2× CFITSIO non-binding goal;
  assert block-aligned, no per-element allocation (incl. the ITR-1 iterator path).
- **Acceptance:** `zig build bench` runs and reports throughput; no per-element alloc on hot paths
  (measured, not a release gate).

### X-TOOL — `fitsverify` CLI demo
- **Milestone:** X · **Module:** `tools/fitsverify.zig` · **Size:** S · **Status:** todo
- **Depends on:** VLD-1
- **Req:** FR-VAL-2 (demo), NFR-DOC-1 · **Design:** §3
- **Goal:** A CLI over `validate.zig` producing a `fitsverify`-style report.
- **Acceptance:** runs on a sample file and prints classified findings.

### X-DOCAPI — Doc-comment & public-surface audit
- **Milestone:** X · **Module:** all `src/` · **Size:** M · **Status:** todo
- **Depends on:** ERR-1, ERR-2, ERR-3, ERR-4, LIM-1, CONV-1, NAME-1, IO-1, IO-2, IO-3, IO-4, IO-5, HDR-1, HDR-2, HDR-3a, HDR-3b, HDR-3c, HDR-4, HDR-5, HDR-6, HDR-7, HDU-1, FITS-1a, FITS-1b, IMG-1, IMG-2, IMG-3, IMG-4, IMG-5, IMG-6, IMG-7, TBL-1, ATB-1, BTB-1, BTB-2, BTB-3a, BTB-3b, VLA-1, SUM-1, UTL-1, UTL-2, RG-1, WCS-1, WCS-2, WCS-3, WCS-4, CMP-1, CMP-2, CMP-3a, CMP-3b, CMP-4, CMP-5, CMP-6, CMP-7, CMP-8, CMP-9, ITR-1, VLD-1, EFN-1, RMT-1, RMT-2, TPL-1, GRP-1
- **Req:** NFR-DOC-1, NFR-API-2 · **Design:** §3, §24
- **Goal:** Final pass ensuring every public declaration is documented and `root.zig` re-exports only the
  intended surface. (Deps enumerate every task that contributes a `src/` public declaration, so a runner
  can resolve the ready-condition.)
- **Acceptance:** a doc-coverage check passes; no internal handle fields are reachable from `root.zig`.

---

## Scheduling waves

<!-- GENERATED by tools/check_tasks.py — do not hand-edit. Run `python3 tools/check_tasks.py --waves`
     and paste its output below. The per-task `Depends on` is the source of truth; waves are a
     parallelization hint. Within a wave, tasks sharing a `Module-lock` must still be serialized. -->

| Wave | Tasks |
|-----:|-------|
| 0 | SETUP-1 |
| 1 | END-1 · ERR-1 · X-CI · X-DOC · X-FIXTURES |
| 2 | CMP-1 · CONV-1 · ERR-2 · ERR-3 · ERR-4 · IO-1 · IO-2 · LIM-1 · UTL-1 |
| 3 | CMP-2 · HDR-1 · IO-3 · IO-4 · IO-5 · NAME-1 · TBL-1 |
| 4 | HDR-2 · RMT-1 · RMT-2 · UTL-2 |
| 5 | HDR-3a · HDR-6 |
| 6 | HDR-3b · HDR-7 · HDU-1 |
| 7 | FITS-1a · HDR-3c · HDR-4 · HDR-5 · WCS-1 |
| 8 | ATB-1 · BTB-1 · FITS-1b · SUM-1 · WCS-2 · WCS-3 · WCS-4 · X-CONC |
| 9 | BTB-2 · BTB-3a · IMG-1 · TPL-1 · VLA-1 · X-SUM |
| 10 | BTB-3b · CMP-3a · IMG-2 · IMG-5 · IMG-7 · ITR-1 · X-FUZZ · X-GUARD · X-WASM |
| 11 | CMP-4 · CMP-5 · CMP-6 · CMP-7 · CMP-9 · EFN-1 · GRP-1 · IMG-3 · IMG-4 · IMG-6 · RG-1 · X-API · X-BENCH |
| 12 | CMP-3b · VLD-1 |
| 13 | CMP-8 · X-CONF · X-TOOL |
| 14 | X-CORPUS · X-DOCAPI |
| 15 | X-INTEROP · X-XVAL |

> Within a wave, tasks sharing a **Module-lock** (e.g. `image.zig`: `IMG-2/3/4/5/6/7`;
> `binary.zig`: `BTB-2/3a/3b`; `header.zig`: `HDR-3a/3b/3c/7`; `fits.zig`: `FITS-1a/1b`;
> `tiled.zig`: `CMP-3a/3b/9`) **must be serialized**, not run concurrently.

---

## Traceability check

Every requirement ID maps to at least one task. `tools/check_tasks.py` re-verifies this on every edit.

### Global constraints
| ID | Task(s) |
|----|---------|
| GC-1 No C | SETUP-1, X-GUARD, *Global DoD* |
| GC-2 std-only | SETUP-1 |
| GC-3 Zig 0.16.0 | SETUP-1, X-API |
| GC-4 Idiomatic API | ERR-1, CONV-1, X-API, *Global DoD* |
| GC-5 Big-endian | END-1 |
| GC-6 No UB | LIM-1, CONV-1, X-FUZZ, *Global DoD* |
| GC-7 No-libc core | IO-1, X-WASM |
| GC-8 No leaks | *Global DoD*, X-CORPUS |

### Functional
| ID | Task | ID | Task | ID | Task |
|----|------|----|------|----|------|
| FR-IO-1 | IO-5 | FR-HDR-1 | HDR-2 | FR-IMG-1 | IMG-1 |
| FR-IO-2 | IO-5 | FR-HDR-2 | HDR-2, NAME-1 | FR-IMG-2 | IMG-1 |
| FR-IO-3 | IO-1, IO-2, IO-3, IO-4 | FR-HDR-3 | HDR-1 | FR-IMG-3 | IMG-1 |
| FR-IO-4 | IO-5 | FR-HDR-4 | HDR-1 | FR-IMG-4 | IMG-5 |
| FR-IO-5 | IO-1, IO-4, FITS-1a | FR-HDR-5 | HDR-2, HDR-3a | FR-IMG-5 | IMG-2 |
| FR-IO-6 | IO-1, IO-4 | FR-HDR-6 | HDR-2 | FR-IMG-6 | IMG-3 |
| FR-HDU-1 | HDU-1, FITS-1a | FR-HDR-7 | HDR-3a | FR-IMG-7 | IMG-6 |
| FR-HDU-2 | HDU-1 | FR-HDR-8 | HDR-4 | FR-IMG-8 | IMG-4 |
| FR-HDU-3 | FITS-1a | FR-HDR-9 | HDR-5 | FR-IMG-9 | IMG-1 |
| FR-HDU-4 | FITS-1b | FR-HDR-10 | HDR-6 | FR-IMG-10 | IMG-7 |
| FR-HDU-5 | HDU-1 | FR-HDR-11 | HDR-3b | FR-ATB-1 | ATB-1 |
| FR-HDU-6 | HDU-1, VLD-1 | FR-HDR-12 | HDR-3c | FR-ATB-2 | ATB-1 |
| FR-BTB-1 | BTB-1 | FR-HDR-13 | HDR-3a | FR-ATB-3 | ATB-1 |
| FR-BTB-2 | BTB-1 | FR-HDR-14 | HDR-7 | FR-ATB-4 | ATB-1 |
| FR-BTB-3 | BTB-1 | FR-VLA-1 | VLA-1 | FR-RG-1 | RG-1 |
| FR-BTB-4 | BTB-2 | FR-VLA-2 | VLA-1 | FR-RG-2 | RG-1 |
| FR-BTB-5 | BTB-3a | FR-VLA-3 | VLA-1 | FR-SUM-1 | SUM-1 |
| FR-BTB-6 | BTB-3b | FR-VLA-4 | VLA-1 | FR-SUM-2 | SUM-1 |
| FR-BTB-7 | BTB-3a | FR-CMP-1 | CMP-3a, CMP-3b | FR-SUM-3 | SUM-1, FITS-1b |
| FR-WCS-1 | WCS-1 | FR-CMP-2 | CMP-1, CMP-2 | FR-CONV-1 | CONV-1, X-GUARD |
| FR-WCS-2 | WCS-2 | FR-CMP-3 | CMP-4, CMP-5, CMP-6 | FR-CONV-2 | CONV-1 |
| FR-WCS-3 | WCS-3 | FR-CMP-4 | CMP-7, CMP-8 | FR-ITR-1 | ITR-1 |
| FR-WCS-4 | WCS-4 | FR-CMP-5 | CMP-9 | FR-ITR-2 | ITR-1 |
| FR-UTL-1 | UTL-1 | FR-EFN-1..5 | EFN-1 | FR-VAL-1 | VLD-1 |
| FR-UTL-2 | TBL-1 | FR-RMT-1 | IO-2, IO-3 | FR-VAL-2 | VLD-1 |
| FR-UTL-3 | ERR-3 | FR-RMT-2 | RMT-1 | FR-TPL-1 | TPL-1 |
| FR-UTL-4 | NAME-1 | FR-RMT-3 | RMT-2 | FR-TPL-2 | FITS-1b |
| FR-UTL-5 | UTL-2 | FR-GRP-1 | GRP-1 | FR-ERR-1 | ERR-1 |
| FR-ERR-2 | ERR-1 | FR-GRP-2 | GRP-1 | FR-ERR-3 | ERR-2 |
| FR-ERR-4 | ERR-4 | | | | |

### Non-functional
| ID | Task | ID | Task |
|----|------|----|------|
| NFR-PERF-1 | IO-5, IMG-1, ITR-1, X-BENCH | NFR-API-1 | X-DOC |
| NFR-PERF-2 | END-1, CONV-1, X-BENCH | NFR-API-2 | SETUP-1, X-GUARD, X-DOCAPI |
| NFR-PERF-3 | IO-5, IMG-1, ITR-1 | NFR-BUILD-1 | SETUP-1 |
| NFR-MEM-1 | FITS-1a, *Global DoD* | NFR-BUILD-2 | SETUP-1 |
| NFR-MEM-2 | *Global DoD*, X-CORPUS | NFR-TEST-1 | X-SUM, IMG-1, BTB-1, IMG-2, IMG-4, VLA-1, SUM-1 |
| NFR-SAFE-1 | LIM-1, X-FUZZ | NFR-TEST-2 | X-CORPUS, X-FIXTURES |
| NFR-SAFE-2 | X-FUZZ | NFR-TEST-3 | X-XVAL, X-FIXTURES |
| NFR-PORT-1 | X-CI | NFR-TEST-4 | X-CONF |
| NFR-PORT-2 | END-1, X-CI | NFR-TEST-5 | X-CONC, X-INTEROP |
| NFR-PORT-3 | X-WASM | NFR-DOC-1 | X-DOCAPI, *Global DoD* |
| NFR-CONC-1 | X-CONC, FITS-1a | NFR-DOC-2 | X-DOC |
| NFR-INTEROP-1 | X-INTEROP, X-FIXTURES, CMP-3a | NFR-INTEROP-2 | X-CORPUS |

---

## Notes & open questions (from `design.md` §27 / `requirements.md` §7.2)

- **License** (`NFR-DOC-2`, X-DOC) — choose MIT / Apache-2.0 / BSD-3 before 1.0.
- **1.0 compression scope** — M2 ships GZIP only; Rice/PLIO/HCOMPRESS + write land in M3.
- **WCS breadth** — WCS-2 implements the common projection set first behind an extensible registry.
- **Remote/gzip in 1.0** — RMT-1/RMT-2 are leaf backends, so 1.0-vs-extension is a build-graph decision.
- **CFITSIO C-export shim** — out of scope now; ERR-4 keeps the status map ready.
- **Endianness verification** — proven by the X-CI big-endian QEMU cell, not the LE host matrix.
- **Fixture provenance** — all CFITSIO/Astropy goldens and malformed fixtures are owned by X-FIXTURES,
  which also declares the CI tool environment; no other task silently assumes them.

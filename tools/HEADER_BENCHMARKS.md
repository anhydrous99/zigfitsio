# Header binding A/B benchmarks

These tools measure the current card-at-a-time Python and TypeScript/Wasm paths against the
optional logical-header snapshot and batch-apply v1 C ABI. They do not require the candidate
symbols to exist: a legacy build emits a complete JSON report with candidate capabilities marked
unavailable. The fixture generator is duplicated byte-for-byte in the two drivers; SHA-256 values
in every case make fixture drift visible to the comparator.

Build optimized artifacts before collecting numbers:

```sh
zig build capi -Doptimize=ReleaseFast
npm run build --prefix bindings/typescript
```

In a source checkout the Python driver automatically selects the freshly built `zig-out` CAPI
library ahead of any older wheel-layout library beside the Python sources. An explicit
`ZIGFITSIO_LIBRARY` still takes precedence.

A short legacy smoke run is:

```sh
python3 tools/bench_header_native.py \
  --cards 6,36 --profiles scalar --edits 1,8 \
  --samples 3 --warmups 1 --target-ms 5 \
  --output .tmp/header-python.json

node tools/bench_header_wasm.mjs \
  --cards 6,36 --profiles scalar --edits 1,8 \
  --samples 3 --warmups 1 --target-ms 5 \
  --output .tmp/header-wasm.json

python3 tools/bench_header_compare.py \
  .tmp/header-python.json .tmp/header-wasm.json
```

Candidate cases are detected by the exported names `zf_header_snapshot_query_v1`,
`zf_header_snapshot_fill_v1`, and `zf_header_apply_v1`. The drivers inspect the source C header
to distinguish the explicit-`hdu_index` draft from a selected-HDU signature; packaged artifacts
without that header can select it explicitly with `--candidate-layout`.

When the TypeScript low-level prototype table contains the v1 functions, the Wasm driver uses the
package's real marshaller and its buffer-direction plan. A direct-export adapter remains only as a
fallback for a new Wasm core paired with an older TypeScript package; `capabilities.adapter` records
which path produced a report.

For a stable performance run, use an optimized build on an idle machine, retain the default 12
samples (or raise it), include `--cards 6,36,360,3600`, and repeat with meaningful data tails such
as `--tail-bytes 0,1048576,67108864`. Setup/open is outside timed regions. Variants within a case
are measured in alternating AB/BA order. Raw per-operation samples are retained; medians, MAD,
p95, FFI-call counts, and deterministic checksums are summaries only.

The checked-in thresholds are calibrated by runtime and candidate-optional. Native Python pays a
large per-call ctypes cost, while direct Wasm calls are cheap enough that small scalar snapshots may
be within 15% of the card path; the Wasm gates therefore bound overhead for tiny headers and
measured gains from 360 cards onward. Pass `--require-candidates` when testing a v1 build; missing
candidate cases then fail. Decisions use the lower bound of a deterministic 95% bootstrap confidence
interval, not the point estimate:

```sh
python3 tools/bench_header_compare.py --require-candidates \
  .tmp/header-python.json .tmp/header-wasm.json
```

The diagnostic variants separate costs:

- `legacy_abi`: `zf_card_count` plus N `zf_read_card` calls.
- `legacy_parse`: host parsing of already-read cards.
- `legacy_e2e`: both legacy phases.
- `snapshot_abi`: query/fill plus transfer into host-owned buffers.
- `snapshot_e2e`: snapshot plus host-object materialization.
- `legacy_individual`: K existing-key writes and therefore K header transactions.
- `batch_apply`: one transaction containing K staged upserts.

Do not mix debug and release artifacts in one comparison. Fixture hashes must match within each
baseline/candidate pair, and the comparator refuses mismatches.

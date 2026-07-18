# Fingerprint follow-ups

The fingerprint move centralizes BLAKE3-128 in Zig core for Python and TypeScript dirty-state
checks. This document records the measured binding follow-ups completed with that move and the
remaining work that stays profile-gated.

## Python arrays

Completed. Python now uses the same core fingerprint for contiguous and strided NumPy arrays. VLA
cells retain their existing little-endian byte-length framing; small updates are copied into a
bounded 8 MiB batch before crossing the C ABI, and non-contiguous cells stream in logical C order.

Across 31 alternating samples, an 8 MiB contiguous array was 1.34x faster and an 8 MiB transposed
array was 1.10x faster than the previous BLAKE2b path. A 6.83 MiB mixed-cell VLA fixture was 1.06x
faster. Run the proof with:

```sh
zig build capi -Doptimize=ReleaseFast
ZIGFITSIO_BENCH_SAMPLES=31 PYTHONPATH=bindings/python/src \
  uv run --no-project --with numpy python bindings/python/scripts/bench_fingerprint_followups.py
```

## TypeScript strings and variable-length arrays

Completed. Strings add explicit row-count and per-row length framing to their NUL-separated UTF-8
bytes, so embedded NULs cannot blur row boundaries. VLAs are framed as repeated little-endian
`u64` element counts followed by the exact cell bytes. VLA frames up to 64 MiB use one core call;
larger VLAs stream in bounded 64 MiB batches. The framing preserves cell order, empty cells,
boundaries, and typed-array subarray offsets.

The production-Wasm proof uses 15 alternating samples under Node and Bun. Across 100,000 short or
empty strings, an 8 MiB string payload, 100,000 tiny VLA cells, eight 1 MiB VLA cells, and a 65 MiB
threshold-crossing VLA, the core path was 3.94x to 18.60x faster on Node and 5.27x to 21.46x faster
on Bun. Run it with:

```sh
npm run build --prefix bindings/typescript
node --expose-gc bindings/typescript/scripts/bench-fingerprint-followups.mjs
bun bindings/typescript/scripts/bench-fingerprint-followups.mjs
```

## Fingerprint while reading

The first version fingerprints after `zf_read_img` or a column read completes. TypeScript therefore
copies an already-read buffer back into Wasm for the fingerprint call.

Add a versioned read API that optionally returns the baseline digest only when profiles show this
second transfer is material. The read and standalone fingerprint must return identical 16-byte
digests, and callers that do not request a digest must retain the current ABI and cost.

## Duplicate dirty-state scans

Completed. Pristine saves, changed image sections, compressed-image preflight, and reconciliation
now carry just-computed digests through that synchronous operation. No digest persists beyond the
operation, so separate flushes still detect direct typed-array mutations without cache invalidation
machinery.

The proof script asserts that an 8 MiB pristine image uses one 8 MiB fingerprint call and a table
with eight 1 MiB columns uses eight calls over 8 MiB total. Both previously hashed 16 MiB across two
passes. Across the same 15 samples, the resulting update-mode `toBytes()` medians were 8.92/9.00
ms on Node and 11.15/11.04 ms on Bun for the image/table fixtures.

## Very large Wasm buffers

The current image bridge still stages one complete input buffer in Wasm. Consider chunked streaming
only after an agreed supported fixture fails for memory, or staging dominates at 256 MiB and above.
Any change must retain bounded allocation, reject unrepresentable wasm32 lengths, and benchmark
copy count as well as hash throughput. VLA fingerprints already stream above 64 MiB.

## Out of scope

Fingerprints are ephemeral dirty-state sentinels. They are not FITS checksums, security APIs, file
identifiers, or persisted metadata. Those are separate problems and should not reuse this ABI.

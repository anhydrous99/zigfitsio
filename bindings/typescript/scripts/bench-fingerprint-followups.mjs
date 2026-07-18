#!/usr/bin/env node
/**
 * Opt-in proof for the deferred fingerprint work.
 *
 *   npm run build --prefix bindings/typescript
 *   node --expose-gc bindings/typescript/scripts/bench-fingerprint-followups.mjs
 *   bun bindings/typescript/scripts/bench-fingerprint-followups.mjs
 *
 * Set ZIGFITSIO_BENCH_SAMPLES to change the default 15 measured pairs.
 */
import assert from "node:assert/strict";

import * as zf from "../dist/index.js";
import * as ll from "../dist/lowlevel/index.js";
import { colFp as coreColFp } from "../dist/table.js";

const samples = Number(process.env.ZIGFITSIO_BENCH_SAMPLES ?? 15);
if (!Number.isInteger(samples) || samples < 3) throw new Error("ZIGFITSIO_BENCH_SAMPLES must be an integer >= 3");

const encoder = new TextEncoder();
const FNV_OFFSET = 0xcbf29ce484222325n;
const FNV_PRIME = 0x100000001b3n;
const U64_MASK = 0xffffffffffffffffn;
let sink = 0n;

function bytesOf(view) {
  return new Uint8Array(view.buffer, view.byteOffset, view.byteLength);
}

function fnv1a64(bytes) {
  let h = FNV_OFFSET;
  for (const byte of bytes) {
    h ^= BigInt(byte);
    h = (h * FNV_PRIME) & U64_MASK;
  }
  return h;
}

const mix = (h, value) => ((h ^ (value & U64_MASK)) * FNV_PRIME) & U64_MASK;

function legacyColFp(column) {
  if (column.kind === "string") return fnv1a64(encoder.encode(column.values.join("\0")));
  let h = FNV_OFFSET;
  for (const cell of column.values) {
    h = mix(h, BigInt(cell.length));
    h = mix(h, fnv1a64(bytesOf(cell)));
  }
  return h;
}

function percentile(values, fraction) {
  const sorted = [...values].sort((a, b) => a - b);
  return sorted[Math.ceil(sorted.length * fraction) - 1];
}

function timed(fn) {
  const start = process.hrtime.bigint();
  sink ^= fn();
  return Number(process.hrtime.bigint() - start) / 1e6;
}

function compare(name, column) {
  for (let i = 0; i < 3; i++) {
    sink ^= legacyColFp(column);
    sink ^= coreColFp(column);
  }

  const legacy = [];
  const core = [];
  for (let i = 0; i < samples; i++) {
    if ((i & 1) === 0) {
      legacy.push(timed(() => legacyColFp(column)));
      core.push(timed(() => coreColFp(column)));
    } else {
      core.push(timed(() => coreColFp(column)));
      legacy.push(timed(() => legacyColFp(column)));
    }
  }

  const legacyMedian = percentile(legacy, 0.5);
  const coreMedian = percentile(core, 0.5);
  return {
    workload: name,
    legacyMedianMs: legacyMedian.toFixed(3),
    legacyP95Ms: percentile(legacy, 0.95).toFixed(3),
    coreMedianMs: coreMedian.toFixed(3),
    coreP95Ms: percentile(core, 0.95).toFixed(3),
    speedup: `${(legacyMedian / coreMedian).toFixed(2)}x`,
  };
}

function verifyFraming() {
  const split = { kind: "vla", dtype: "i4", repeat: 1, values: [Int32Array.of(1), Int32Array.of(2)] };
  const joined = { kind: "vla", dtype: "i4", repeat: 1, values: [Int32Array.of(1, 2), new Int32Array()] };
  assert.notEqual(legacyColFp(split), legacyColFp(joined));
  assert.notEqual(coreColFp(split), coreColFp(joined));

  const strings = { kind: "string", dtype: "u1", repeat: 5, values: ["alpha", "beta"] };
  const changed = { kind: "string", dtype: "u1", repeat: 5, values: ["alpha", "Beta"] };
  assert.notEqual(coreColFp(strings), coreColFp(changed));
}

function measurePristine(label, hdul, expectedCalls) {
  const original = ll.native.fn.zf_fingerprint128_v1;
  if (typeof original !== "function") throw new Error("fingerprint ABI missing; run the TypeScript build first");
  let calls = 0;
  let bytes = 0;
  let fingerprintNs = 0n;
  ll.native.fn.zf_fingerprint128_v1 = (...args) => {
    calls++;
    bytes += Number(args[1]);
    const start = process.hrtime.bigint();
    try {
      return original(...args);
    } finally {
      fingerprintNs += process.hrtime.bigint() - start;
    }
  };

  try {
    for (let i = 0; i < 3; i++) sink ^= BigInt(hdul.toBytes().byteLength);
    const fingerprint = [];
    const total = [];
    for (let i = 0; i < samples; i++) {
      calls = 0;
      bytes = 0;
      fingerprintNs = 0n;
      const start = process.hrtime.bigint();
      const output = hdul.toBytes();
      total.push(Number(process.hrtime.bigint() - start) / 1e6);
      fingerprint.push(Number(fingerprintNs) / 1e6);
      sink ^= BigInt(output.byteLength);
      assert.equal(calls, expectedCalls);
      assert.equal(bytes, 8 * 1024 * 1024);
    }
    return {
      workload: label,
      calls: expectedCalls,
      hashedMiB: (bytes / 1048576).toFixed(1),
      fingerprintMedianMs: percentile(fingerprint, 0.5).toFixed(3),
      fingerprintP95Ms: percentile(fingerprint, 0.95).toFixed(3),
      totalMedianMs: percentile(total, 0.5).toFixed(3),
      totalP95Ms: percentile(total, 0.95).toFixed(3),
    };
  } finally {
    ll.native.fn.zf_fingerprint128_v1 = original;
    hdul.close();
  }
}

function imageFixture() {
  const pixels = new Int16Array(4 * 1024 * 1024);
  pixels[pixels.length - 1] = 1;
  const source = new zf.HDUList([new zf.PrimaryHDU({ data: new zf.FitsArray(pixels, [2048, 2048]) })]).toBytes();
  const hdul = zf.fromBytes(source, "update");
  void hdul.get(0).data;
  return hdul;
}

function tableFixture() {
  const columns = [];
  for (let i = 0; i < 8; i++) {
    const values = new Int32Array(256 * 1024);
    values[values.length - 1] = i + 1;
    columns.push(new zf.Column(`C${i}`, "1J", { array: values }));
  }
  const source = new zf.HDUList([new zf.PrimaryHDU(), zf.BinTableHDU.fromColumns(columns)]).toBytes();
  const hdul = zf.fromBytes(source, "update");
  void hdul.get(1).data;
  return hdul;
}

verifyFraming();

const shortStrings = Array.from({ length: 100_000 }, (_, i) => (i % 4 === 0 ? "" : `s${String(i).padStart(7, "0")}`));
const largeStrings = Array.from({ length: 8192 }, () => "x".repeat(1024));
const tinyVlas = Array.from({ length: 100_000 }, (_, i) => new Int32Array(i % 8));
const largeVlas = Array.from({ length: 8 }, () => new Uint8Array(1024 * 1024));
const thresholdCell = new Uint8Array(1024 * 1024);
const thresholdVlas = Array.from({ length: 65 }, () => thresholdCell);

const runtime = process.versions.bun ? `bun ${process.versions.bun}` : `${process.release.name} ${process.version}`;
console.log(`fingerprint follow-up proof (${samples} alternating samples, ${runtime})`);
console.table([
  compare("strings: 100k short/empty", { kind: "string", dtype: "u1", repeat: 8, values: shortStrings }),
  compare("strings: 8k x 1KiB ASCII", { kind: "string", dtype: "u1", repeat: 1024, values: largeStrings }),
  compare("VLA: 100k cells, lengths 0..7", { kind: "vla", dtype: "i4", repeat: 1, values: tinyVlas }),
  compare("VLA: 8 x 1MiB cells", { kind: "vla", dtype: "u1", repeat: 1, values: largeVlas }),
  compare("VLA: 65 x 1MiB cells (streamed)", { kind: "vla", dtype: "u1", repeat: 1, values: thresholdVlas }),
]);

console.log("pristine update-mode toBytes fingerprint traffic");
console.table([
  measurePristine("8 MiB image", imageFixture(), 1),
  measurePristine("8 x 1 MiB table columns", tableFixture(), 8),
]);

// Observable use of every digest, without making timing results into assertions.
if (sink === -1n) console.log("");

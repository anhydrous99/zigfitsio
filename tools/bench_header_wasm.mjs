#!/usr/bin/env node
/** A/B benchmark for the Node/Wasm header binding and the proposed Zig header ABI. */

import { createHash } from "node:crypto";
import { existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";

const ROOT = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const CARD = 80;
const BLOCK = 2880;
const SNAPSHOT_INFO_SIZE = 48;
const HEADER_ENTRY_SIZE = 96;
const HEADER_OP_SIZE = 88;
const APPLY_OPTS_SIZE = 16;
const APPLY_RESULT_SIZE = 32;
const encoder = new TextEncoder();
const decoder = new TextDecoder();

function csvInts(text) {
  const values = text.split(",").filter(Boolean).map((part) => Number(part.trim()));
  if (!values.length || values.some((value) => !Number.isSafeInteger(value) || value < 0)) {
    throw new Error(`expected comma-separated non-negative integers, got ${JSON.stringify(text)}`);
  }
  return values;
}

function csvNames(text) {
  const values = text.split(",").map((part) => part.trim()).filter(Boolean);
  if (!values.length) throw new Error(`expected a comma-separated list, got ${JSON.stringify(text)}`);
  return values;
}

function usage() {
  return `Usage: node tools/bench_header_wasm.mjs [options]

  --cards 6,36,360                 physical cards including END
  --profiles scalar,mixed,continuation
  --tail-bytes 0                    comma-separated data-tail sizes
  --edits 1,8,32
  --operations ffi,read,apply
  --samples 12 --warmups 3 --target-ms 50
  --module bindings/typescript/dist/index.js
  --wasm bindings/typescript/dist/zigfitsio.wasm
  --candidate-layout auto|hdu-index|selected-hdu
  --output result.json
`;
}

function parseArgs(argv) {
  const options = {
    cards: csvInts("6,36,360"), profiles: csvNames("scalar,mixed,continuation"),
    tailBytes: csvInts("0"), edits: csvInts("1,8,32"), operations: csvNames("ffi,read,apply"),
    samples: 12, warmups: 3, targetMs: 50, candidateLayout: "auto",
    module: resolve(ROOT, "bindings/typescript/dist/index.js"), wasm: null, output: null,
  };
  const mapping = {
    "--cards": ["cards", csvInts], "--profiles": ["profiles", csvNames],
    "--tail-bytes": ["tailBytes", csvInts], "--edits": ["edits", csvInts],
    "--operations": ["operations", csvNames], "--samples": ["samples", Number],
    "--warmups": ["warmups", Number], "--target-ms": ["targetMs", Number],
    "--module": ["module", (value) => resolve(value)], "--wasm": ["wasm", (value) => resolve(value)],
    "--candidate-layout": ["candidateLayout", String], "--output": ["output", (value) => resolve(value)],
  };
  for (let index = 0; index < argv.length; index++) {
    const flag = argv[index];
    if (flag === "--help" || flag === "-h") {
      process.stdout.write(usage());
      process.exit(0);
    }
    const spec = mapping[flag];
    if (!spec || index + 1 >= argv.length) throw new Error(`unknown or incomplete option ${flag}\n${usage()}`);
    options[spec[0]] = spec[1](argv[++index]);
  }
  if (!Number.isInteger(options.samples) || options.samples < 1 ||
      !Number.isInteger(options.warmups) || options.warmups < 0 || options.targetMs <= 0) {
    throw new Error("samples must be positive, warmups non-negative, and target-ms positive");
  }
  for (const profile of options.profiles) {
    if (!new Set(["scalar", "mixed", "continuation"]).has(profile)) throw new Error(`unknown profile ${profile}`);
  }
  for (const operation of options.operations) {
    if (!new Set(["ffi", "read", "apply"]).has(operation)) throw new Error(`unknown operation ${operation}`);
  }
  if (!new Set(["auto", "hdu-index", "selected-hdu"]).has(options.candidateLayout)) {
    throw new Error(`unknown candidate layout ${options.candidateLayout}`);
  }
  return options;
}

function card(text) {
  const bytes = encoder.encode(text);
  if (bytes.length > CARD) throw new Error(`card is ${bytes.length} bytes: ${text}`);
  const out = new Uint8Array(CARD).fill(32);
  out.set(bytes);
  return out;
}

function valueCard(keyword, literal, comment = "") {
  let body = `${keyword.padEnd(8)}= ${literal.padStart(20)}`;
  if (comment) body += ` / ${comment}`;
  return card(body);
}

function scientific(value) {
  return value.toExponential(6).toUpperCase().replace(/E([+-])(\d)$/, "E$10$2");
}

function concat(parts) {
  const length = parts.reduce((sum, part) => sum + part.length, 0);
  const out = new Uint8Array(length);
  let offset = 0;
  for (const part of parts) {
    out.set(part, offset);
    offset += part.length;
  }
  return out;
}

function makeFixture(physicalCards, profile, tailBytes) {
  if (physicalCards < 6) throw new Error("a 1-D primary fixture needs at least 6 cards including END");
  const cards = [
    valueCard("SIMPLE", "T"), valueCard("BITPIX", "8"), valueCard("NAXIS", "1"),
    valueCard("NAXIS1", String(tailBytes)), valueCard("EXTEND", "T"),
  ];
  const editKeys = [];
  let remaining = physicalCards - cards.length - 1;
  let item = 0;
  while (remaining) {
    const key = `K${String(item).padStart(7, "0")}`;
    if (profile === "scalar") {
      cards.push(valueCard(key, String(item), `scalar ${item}`));
      editKeys.push(encoder.encode(key));
      remaining--;
    } else if (profile === "mixed") {
      switch (item % 7) {
        case 0: cards.push(valueCard(key, String(item), "integer")); editKeys.push(encoder.encode(key)); break;
        case 1: cards.push(valueCard(key, scientific(item + 0.25), "float")); editKeys.push(encoder.encode(key)); break;
        case 2: cards.push(valueCard(key, item % 2 ? "T" : "F", "logical")); editKeys.push(encoder.encode(key)); break;
        case 3: cards.push(valueCard(key, `'value-${String(item).padStart(7, "0")}'`, "string")); editKeys.push(encoder.encode(key)); break;
        case 4: cards.push(card(`COMMENT deterministic commentary ${String(item).padStart(7, "0")}`)); break;
        case 5: cards.push(card(`HISTORY deterministic history ${String(item).padStart(7, "0")}`)); break;
        default: cards.push(card(`HIERARCH BENCH GROUP ITEM ${String(item).padStart(7, "0")} = ${item} / hierarch`));
      }
      remaining--;
    } else if (profile === "continuation") {
      if (remaining >= 2) {
        cards.push(valueCard(key, `'segment-${String(item).padStart(7, "0")}-aaaaaaaaaaaaaaaaaaaaaaaa&'`));
        cards.push(card("CONTINUE  'bbbbbbbbbbbbbbbbbbbbbbbb' / folded long string"));
        editKeys.push(encoder.encode(key));
        remaining -= 2;
      } else {
        cards.push(valueCard(key, String(item), "single-card remainder"));
        editKeys.push(encoder.encode(key));
        remaining--;
      }
    }
    item++;
  }
  cards.push(card("END"));
  const rawHeader = concat(cards);
  const header = new Uint8Array(rawHeader.length + ((-rawHeader.length % BLOCK) + BLOCK) % BLOCK).fill(32);
  header.set(rawHeader);
  const dataLength = tailBytes + ((-tailBytes % BLOCK) + BLOCK) % BLOCK;
  const data = new Uint8Array(dataLength);
  for (let index = 0; index < tailBytes; index++) data[index] = (index * 17 + 3) & 0xff;
  return { bytes: concat([header, data]), editKeys };
}

function checksumOf(value) {
  if (typeof value === "bigint") return Number(BigInt.asUintN(31, value));
  if (typeof value === "number") return value | 0;
  if (value && typeof value.length === "number") return value.length | 0;
  if (value?.info?.logicalCount !== undefined) return Number(value.info.logicalCount & 0x7fffffffn);
  return 0;
}

function nowNs() { return process.hrtime.bigint(); }

function calibrate(fn, targetNs) {
  let loops = 1;
  let checksum = 0;
  for (;;) {
    const start = nowNs();
    for (let index = 0; index < loops; index++) checksum ^= checksumOf(fn());
    const elapsed = Number(nowNs() - start);
    if (elapsed >= targetNs || loops >= (1 << 20)) return { loops, checksum };
    loops *= Math.max(2, Math.min(16, Math.ceil(targetNs / Math.max(elapsed, 1))));
  }
}

function benchInterleaved(variants, samples, warmups, targetNs) {
  const names = Object.keys(variants);
  const loops = {};
  const checksums = Object.fromEntries(names.map((name) => [name, 0]));
  const measured = Object.fromEntries(names.map((name) => [name, []]));
  for (let warmup = 0; warmup < warmups; warmup++) {
    for (const name of names) checksums[name] ^= checksumOf(variants[name]());
  }
  for (const name of names) {
    const result = calibrate(variants[name], targetNs);
    loops[name] = result.loops;
    checksums[name] ^= result.checksum;
  }
  for (let sample = 0; sample < samples; sample++) {
    const order = sample % 2 ? [...names].reverse() : names;
    for (const name of order) {
      const start = nowNs();
      for (let index = 0; index < loops[name]; index++) checksums[name] ^= checksumOf(variants[name]());
      measured[name].push(Number(nowNs() - start) / loops[name]);
    }
  }
  return Object.fromEntries(names.map((name) => [name, [measured[name], loops[name], checksums[name]]]));
}

function median(values) {
  const sorted = [...values].sort((a, b) => a - b);
  const middle = Math.floor(sorted.length / 2);
  return sorted.length % 2 ? sorted[middle] : (sorted[middle - 1] + sorted[middle]) / 2;
}

function percentile(values, fraction) {
  const sorted = [...values].sort((a, b) => a - b);
  const position = (sorted.length - 1) * fraction;
  const lower = Math.floor(position);
  const upper = Math.min(lower + 1, sorted.length - 1);
  return sorted[lower] + (sorted[upper] - sorted[lower]) * (position - lower);
}

function caseResult(group, variant, params, measured, ffiCalls, fixtureHash) {
  const [samples, loops, checksum] = measured;
  const center = median(samples);
  return {
    group, variant, operation: group.split("/", 1)[0], params,
    fixture_sha256: fixtureHash, ffi_calls_per_op: ffiCalls, iterations_per_sample: loops,
    samples_ns_per_op: samples, median_ns: center,
    mad_ns: median(samples.map((value) => Math.abs(value - center))), p95_ns: percentile(samples, 0.95), checksum,
  };
}

function chooseLayout(requested) {
  if (requested !== "auto") return requested;
  try {
    const text = readFileSync(resolve(ROOT, "bindings/c/zigfitsio.h"), "utf8");
    const start = text.indexOf("zf_header_snapshot_query_v1");
    return text.slice(start, start + 240).includes("hdu_index") ? "hdu-index" : "selected-hdu";
  } catch {
    return "hdu-index";
  }
}

function findWasm(explicit, modulePath) {
  const candidates = [explicit, process.env.ZIGFITSIO_WASM,
    resolve(dirname(modulePath), "zigfitsio.wasm"),
    resolve(ROOT, "bindings/typescript/dist/zigfitsio.wasm"), resolve(ROOT, "zig-out/bin/zigfitsio.wasm")].filter(Boolean);
  return candidates.find(existsSync) ?? null;
}

function snapshotInfoFromBytes(bytes) {
  const view = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
  const names = ["revision", "logicalCount", "physicalCount", "arenaBytes", "rawBytes", "flags"];
  return Object.fromEntries(names.map((name, index) => [name, view.getBigUint64(index * 8, true)]));
}

function materializeSnapshot(snapshot) {
  const entries = new DataView(snapshot.entries.buffer, snapshot.entries.byteOffset, snapshot.entries.byteLength);
  const result = [];
  for (let index = 0; index < Number(snapshot.info.logicalCount); index++) {
    const base = index * HEADER_ENTRY_SIZE;
    const kind = entries.getUint32(base, true);
    const valueType = entries.getUint32(base + 4, true);
    const flags = entries.getUint32(base + 8, true);
    const slice = (offsetAt, lengthAt) => {
      const offset = Number(entries.getBigUint64(base + offsetAt, true));
      const length = Number(entries.getBigUint64(base + lengthAt, true));
      return decoder.decode(snapshot.arena.subarray(offset, offset + length));
    };
    let value = null;
    if (valueType === 0 && entries.getBigUint64(base + 56, true) !== 0n) value = slice(48, 56);
    else if (valueType === 2) value = entries.getBigInt64(base + 80, true) !== 0n;
    else if (valueType === 3) {
      const integer = entries.getBigInt64(base + 80, true);
      const number = Number(integer);
      value = BigInt(number) === integer ? number : integer;
    } else if (valueType === 5) value = entries.getFloat64(base + 88, true);
    else if ([4, 6, 7].includes(valueType)) value = slice(48, 56);
    result.push([slice(32, 40), value, slice(64, 72), kind, flags]);
  }
  return result;
}

function makeIntegerUpsertBuffers(keys) {
  const arena = concat(keys);
  const ops = new Uint8Array(keys.length * HEADER_OP_SIZE);
  const view = new DataView(ops.buffer);
  let offset = 0;
  keys.forEach((key, index) => {
    const base = index * HEADER_OP_SIZE;
    view.setUint32(base, 1, true);       // UPSERT
    view.setUint32(base + 4, 3, true);   // INT64
    view.setBigUint64(base + 16, BigInt(offset), true);
    view.setBigUint64(base + 24, BigInt(key.length), true);
    view.setBigInt64(base + 80, -1n, true);
    offset += key.length;
  });
  return { arena, ops, view };
}

class RawCandidate {
  static QUERY = "zf_header_snapshot_query_v1";
  static FILL = "zf_header_snapshot_fill_v1";
  static APPLY = "zf_header_apply_v1";

  constructor(wasmPath, layout) {
    this.path = wasmPath;
    this.layout = layout;
    this.ex = null;
    this.exportNames = new Set();
    if (wasmPath) {
      const module = new WebAssembly.Module(readFileSync(wasmPath));
      this.exportNames = new Set(WebAssembly.Module.exports(module).map((entry) => entry.name));
      this.ex = new WebAssembly.Instance(module, {}).exports;
    }
    this.snapshotAvailable = this.exportNames.has(RawCandidate.QUERY) && this.exportNames.has(RawCandidate.FILL);
    this.applyAvailable = this.exportNames.has(RawCandidate.APPLY);
  }

  alloc(length) {
    if (!length) return 0;
    const pointer = this.ex.zf_walloc(length) >>> 0;
    if (!pointer) throw new Error(`candidate wasm allocation failed for ${length} bytes`);
    return pointer;
  }

  free(...pointers) {
    for (const pointer of pointers) if (pointer) this.ex.zf_wfree(pointer);
  }

  memory() { return new Uint8Array(this.ex.memory.buffer); }
  view() { return new DataView(this.ex.memory.buffer); }

  check(status, name) {
    if (Number(status) !== 0) throw new Error(`${name} failed with status ${status}`);
  }

  open(bytes, mode) {
    const input = this.alloc(bytes.length);
    const output = this.alloc(4);
    try {
      this.memory().set(bytes, input);
      this.check(this.ex.zf_open_memory(input, bytes.length, mode, 0, output), "zf_open_memory");
      const handle = this.view().getUint32(output, true);
      this.check(this.ex.zf_select(handle, 1), "zf_select");
      return handle;
    } finally {
      this.free(input, output);
    }
  }

  close(handle) { this.ex.zf_close(handle); }

  infoAt(pointer) {
    const view = this.view();
    const names = ["revision", "logicalCount", "physicalCount", "arenaBytes", "rawBytes", "flags"];
    return Object.fromEntries(names.map((name, index) => [name, view.getBigUint64(pointer + index * 8, true)]));
  }

  snapshot(handle) {
    const infoPointer = this.alloc(SNAPSHOT_INFO_SIZE);
    let entriesPointer = 0;
    let arenaPointer = 0;
    let outPointer = 0;
    try {
      const queryArgs = this.layout === "hdu-index" ? [handle, 1n, 0, infoPointer] : [handle, 0, infoPointer];
      this.check(this.ex[RawCandidate.QUERY](...queryArgs), RawCandidate.QUERY);
      const info = this.infoAt(infoPointer);
      const entryBytes = Number(info.logicalCount) * HEADER_ENTRY_SIZE;
      const arenaBytes = Number(info.arenaBytes);
      entriesPointer = this.alloc(entryBytes);
      arenaPointer = this.alloc(arenaBytes);
      outPointer = this.alloc(SNAPSHOT_INFO_SIZE);
      const tail = [0, info.revision, entriesPointer, Number(info.logicalCount), arenaPointer, arenaBytes, 0, 0, outPointer];
      const fillArgs = this.layout === "hdu-index" ? [handle, 1n, ...tail] : [handle, ...tail];
      this.check(this.ex[RawCandidate.FILL](...fillArgs), RawCandidate.FILL);
      const out = this.infoAt(outPointer);
      return {
        info: out,
        entries: this.memory().slice(entriesPointer, entriesPointer + entryBytes),
        arena: this.memory().slice(arenaPointer, arenaPointer + arenaBytes),
      };
    } finally {
      this.free(infoPointer, entriesPointer, arenaPointer, outPointer);
    }
  }

  materialize(snapshot) {
    return materializeSnapshot(snapshot);
  }

  makeApply(handle, keys) {
    const { arena, ops, view } = makeIntegerUpsertBuffers(keys);
    let counter = 0;
    return () => {
      counter++;
      keys.forEach((_, index) => view.setBigInt64(index * HEADER_OP_SIZE + 64, BigInt(counter + index), true));
      const optsPointer = this.alloc(APPLY_OPTS_SIZE);
      const opsPointer = this.alloc(ops.length);
      const arenaPointer = this.alloc(arena.length);
      const resultPointer = this.alloc(APPLY_RESULT_SIZE);
      try {
        this.memory().fill(0, optsPointer, optsPointer + APPLY_OPTS_SIZE);
        this.memory().set(ops, opsPointer);
        this.memory().set(arena, arenaPointer);
        const tail = [optsPointer, opsPointer, keys.length, arenaPointer, arena.length, resultPointer];
        const args = this.layout === "hdu-index" ? [handle, 1n, ...tail] : [handle, ...tail];
        this.check(this.ex[RawCandidate.APPLY](...args), RawCandidate.APPLY);
        const result = this.view();
        return Number((result.getBigUint64(resultPointer, true) ^ result.getBigUint64(resultPointer + 24, true)) & 0x7fffffffn);
      } finally {
        this.free(optsPointer, opsPointer, arenaPointer, resultPointer);
      }
    };
  }
}

/** Prefer the package's real low-level marshaller when its finalized prototypes are present. */
class BindingCandidate {
  constructor(ll, layout, rawProbe) {
    this.ll = ll;
    this.layout = layout;
    this.path = rawProbe.path;
    this.exportNames = rawProbe.exportNames;
    this.snapshotAvailable = true;
    this.applyAvailable = true;
    this.adapter = "binding-lowlevel";
  }

  open(bytes, mode) { return openLegacy(this.ll, bytes, mode); }
  close(handle) { this.ll.lib.zf_close(handle); }

  snapshot(handle) {
    const infoBytes = new Uint8Array(SNAPSHOT_INFO_SIZE);
    this.ll.check(this.ll.lib.zf_header_snapshot_query_v1(handle, 1n, 0, infoBytes));
    const info = snapshotInfoFromBytes(infoBytes);
    const entries = new Uint8Array(Number(info.logicalCount) * HEADER_ENTRY_SIZE);
    const arena = new Uint8Array(Number(info.arenaBytes));
    const outBytes = new Uint8Array(SNAPSHOT_INFO_SIZE);
    this.ll.check(this.ll.lib.zf_header_snapshot_fill_v1(
      handle, 1n, 0, info.revision,
      entries.length ? entries : null, Number(info.logicalCount),
      arena.length ? arena : null, arena.length,
      null, 0, outBytes,
    ));
    return { info: snapshotInfoFromBytes(outBytes), entries, arena };
  }

  materialize(snapshot) { return materializeSnapshot(snapshot); }

  makeApply(handle, keys) {
    const { arena, ops, view } = makeIntegerUpsertBuffers(keys);
    let counter = 0;
    return () => {
      counter++;
      keys.forEach((_, index) => view.setBigInt64(index * HEADER_OP_SIZE + 64, BigInt(counter + index), true));
      const opts = new Uint8Array(APPLY_OPTS_SIZE);
      const result = new Uint8Array(APPLY_RESULT_SIZE);
      this.ll.check(this.ll.lib.zf_header_apply_v1(
        handle, 1n, opts, ops, keys.length, arena, arena.length, result,
      ));
      const resultView = new DataView(result.buffer, result.byteOffset, result.byteLength);
      return Number((resultView.getBigUint64(0, true) ^ resultView.getBigUint64(24, true)) & 0x7fffffffn);
    };
  }
}

function openLegacy(ll, bytes, mode) {
  const out = ll.outU64();
  ll.check(ll.lib.zf_open_memory(bytes, bytes.length, mode, null, out));
  const handle = out[0];
  ll.check(ll.lib.zf_select(handle, 1));
  return handle;
}

function legacyRawReader(ll, handle) {
  return () => {
    const countOut = ll.newLongArray(1);
    ll.check(ll.lib.zf_card_count(handle, countOut));
    const count = ll.readLongAt(countOut, 0);
    const raws = [];
    for (let index = 0; index < count; index++) {
      const buffer = new Uint8Array(CARD);
      ll.check(ll.lib.zf_read_card(handle, index, buffer));
      raws.push(buffer);
    }
    return raws;
  };
}

async function main() {
  const args = parseArgs(process.argv.slice(2));
  if (!existsSync(args.module)) throw new Error(`binding module not found: ${args.module}; run npm run build --prefix bindings/typescript`);
  const zf = await import(pathToFileURL(args.module).href);
  await zf.ready();
  const ll = zf.lowlevel;
  const wasmPath = findWasm(args.wasm, args.module);
  const layout = chooseLayout(args.candidateLayout);
  const rawCandidate = new RawCandidate(wasmPath, layout);
  const hasBindingCandidate = layout === "hdu-index" &&
    typeof ll.lib.zf_header_snapshot_query_v1 === "function" &&
    typeof ll.lib.zf_header_snapshot_fill_v1 === "function" &&
    typeof ll.lib.zf_header_apply_v1 === "function";
  const candidate = hasBindingCandidate ? new BindingCandidate(ll, layout, rawCandidate) : rawCandidate;
  if (!candidate.adapter) candidate.adapter = "raw-wasm-fallback";
  const targetNs = args.targetMs * 1_000_000;
  const cases = [];
  const skips = [];

  if (args.operations.includes("ffi")) {
    const measured = benchInterleaved({ legacy_noop: ll.lib.zf_last_status }, args.samples, args.warmups, targetNs);
    cases.push(caseResult("ffi/noop", "legacy_noop", {}, measured.legacy_noop, 1, ""));
  }

  for (const profile of args.profiles) for (const physicalCards of args.cards) for (const tailBytes of args.tailBytes) {
    const fixture = makeFixture(physicalCards, profile, tailBytes);
    const fixtureHash = createHash("sha256").update(fixture.bytes).digest("hex");
    const params = { physical_cards: physicalCards, profile, tail_bytes: tailBytes };

    if (args.operations.includes("read")) {
      const handle = openLegacy(ll, fixture.bytes, ll.READONLY);
      const rawRead = legacyRawReader(ll, handle);
      const cachedRaws = rawRead();
      const variants = {
        legacy_abi: rawRead,
        legacy_parse: () => zf.parseCards(cachedRaws),
        legacy_e2e: () => zf.parseCards(rawRead()),
      };
      let candidateHandle = null;
      if (candidate.snapshotAvailable) {
        candidateHandle = candidate.open(fixture.bytes, ll.READONLY);
        const candidateProbe = candidate.materialize(candidate.snapshot(candidateHandle));
        const legacyProbe = zf.parseCards(cachedRaws);
        if (candidateProbe.length !== legacyProbe.length) {
          throw new Error(
            `snapshot logical count mismatch for ${profile}/${physicalCards}: ` +
            `candidate=${candidateProbe.length}, legacy=${legacyProbe.length}`,
          );
        }
        for (let index = 0; index < legacyProbe.length; index++) {
          const candidateValue = candidateProbe[index];
          const legacyValue = legacyProbe[index];
          if (candidateValue[0] !== legacyValue.keyword || candidateValue[1] !== legacyValue.value ||
              candidateValue[2] !== legacyValue.comment) {
            throw new Error(
              `snapshot semantic mismatch for ${profile}/${physicalCards} at logical entry ${index}: ` +
              `candidate=${String(candidateValue.slice(0, 3))}, ` +
              `legacy=${String([legacyValue.keyword, legacyValue.value, legacyValue.comment])}`,
            );
          }
        }
        variants.snapshot_abi = () => candidate.snapshot(candidateHandle);
        variants.snapshot_e2e = () => candidate.materialize(candidate.snapshot(candidateHandle));
      }
      const measured = benchInterleaved(variants, args.samples, args.warmups, targetNs);
      const group = `read/${profile}/cards-${String(physicalCards).padStart(4, "0")}/tail-${tailBytes}`;
      const calls = { legacy_abi: 1 + physicalCards, legacy_parse: 0, legacy_e2e: 1 + physicalCards, snapshot_abi: 2, snapshot_e2e: 2 };
      for (const variant of Object.keys(variants)) cases.push(caseResult(group, variant, params, measured[variant], calls[variant], fixtureHash));
      ll.lib.zf_close(handle);
      if (candidateHandle !== null) candidate.close(candidateHandle);
    }

    if (args.operations.includes("apply")) for (const editCount of args.edits) {
      const group = `apply/${profile}/cards-${String(physicalCards).padStart(4, "0")}/edits-${editCount}/tail-${tailBytes}`;
      if (!editCount || fixture.editKeys.length < editCount) {
        skips.push({ group, reason: `fixture has ${fixture.editKeys.length} editable standard keys` });
        continue;
      }
      const keys = fixture.editKeys.slice(0, editCount);
      const handle = openLegacy(ll, fixture.bytes, ll.READWRITE);
      let counter = 0;
      const variants = {
        legacy_individual: () => {
          counter++;
          keys.forEach((key, index) => ll.check(ll.lib.zf_write_key_lng(handle, key, key.length, BigInt(counter + index), null, 0)));
          return counter;
        },
      };
      let candidateHandle = null;
      if (candidate.applyAvailable) {
        candidateHandle = candidate.open(fixture.bytes, ll.READWRITE);
        variants.batch_apply = candidate.makeApply(candidateHandle, keys);
      }
      const measured = benchInterleaved(variants, args.samples, args.warmups, targetNs);
      const editParams = { ...params, edits: editCount };
      for (const variant of Object.keys(variants)) {
        cases.push(caseResult(group, variant, editParams, measured[variant], variant === "legacy_individual" ? editCount : 1, fixtureHash));
      }
      ll.lib.zf_close(handle);
      if (candidateHandle !== null) candidate.close(candidateHandle);
    }
  }

  const missingSnapshot = [RawCandidate.QUERY, RawCandidate.FILL].filter((name) => !candidate.exportNames.has(name));
  const missingApply = candidate.applyAvailable ? [] : [RawCandidate.APPLY];
  const document = {
    schema_version: 1, benchmark: "header-binding-ab",
    runtime: { id: "node-wasm", name: "node", version: process.versions.node, platform: process.platform, machine: process.arch },
    artifact: { zigfitsio_version: ll.version(), module: args.module, wasm: wasmPath },
    config: {
      cards: args.cards, profiles: args.profiles, tail_bytes: args.tailBytes, edits: args.edits,
      operations: args.operations, samples: args.samples, warmups: args.warmups, target_ms: args.targetMs,
    },
    capabilities: {
      candidate_layout: layout,
      adapter: candidate.adapter,
      snapshot_v1: { available: candidate.snapshotAvailable, missing_symbols: missingSnapshot },
      apply_v1: { available: candidate.applyAvailable, missing_symbols: missingApply },
    },
    cases, skips,
  };
  const encoded = `${JSON.stringify(document, null, 2)}\n`;
  if (args.output) {
    mkdirSync(dirname(args.output), { recursive: true });
    writeFileSync(args.output, encoded);
    process.stderr.write(`wrote ${cases.length} cases to ${args.output}\n`);
  } else process.stdout.write(encoded);
}

main().catch((error) => {
  process.stderr.write(`${error?.stack ?? error}\n`);
  process.exitCode = 1;
});

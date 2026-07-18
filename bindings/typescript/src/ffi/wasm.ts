/**
 * WebAssembly backend — the single-package runtime for `zigfitsio`.
 *
 * The `zf_*` C ABI is compiled to one `wasm32-freestanding` reactor module
 * (`zig build wasm` → `zigfitsio.wasm`, zero imports, exports `memory` + every
 * `zf_*` symbol + the `zf_walloc`/`zf_wfree` scratch allocator). This backend
 * adapts that module to the same neutral `NativeLibrary` shape the (now removed)
 * bun:ffi / koffi backends used, so `lowlevel/*` and the whole high-level API are
 * unchanged.
 *
 * ## Emulating pointers
 *
 * A WebAssembly export takes/returns only numbers; a "pointer" is an offset into
 * the module's linear memory. Native FFI let Zig write straight into a JS
 * TypedArray; here every string / buffer / out-parameter is staged inside linear
 * memory (allocated via `zf_walloc`), the offset is passed, and after the call the
 * bytes are copied back into the *same* caller view. Because the neutral IR labels
 * each argument kind and the high-level code reads results back from those same
 * views, this reproduces native pointer semantics transparently.
 *
 * ## Widths (wasm32)
 *
 * Pointers / `usize` / `handle` / C-`long` are 4 bytes here (vs 8 on the native
 * targets). Handles stay opaque (bridged `bigint` ↔ `i32`); `long` is `i32`
 * (see `lowlevel/platform.ts`); the three ABI structs are POD with fixed-width
 * fields, so `lowlevel/structs.ts` is unchanged. WebAssembly is always
 * little-endian, matching the x64/arm64 native-endian contract.
 */
import type { NativeArg, NativeFn, NativeLibrary, NativeResult, NativeType, Proto, Ptr } from "./types.js";

/** The exports this backend requires from the instantiated `zigfitsio.wasm`. */
export interface WasmExports {
  readonly memory: WebAssembly.Memory;
  readonly zf_walloc: (len: number) => number;
  readonly zf_wfree: (ptr: number) => void;
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  readonly [symbol: string]: any;
}

const encoder = new TextEncoder();
const decoder = new TextDecoder();

type BufDir = "in" | "out" | "inout";

// Copy-direction overrides for the large data buffers, keyed by symbol → arg index. A `buf` not
// listed here defaults to "inout" (copy in before the call + out after), which is always correct;
// these narrow the hot paths so a read does not stage its (unread) output buffer in, and a
// write/open does not copy its (unmodified) input buffer back out — halving the copies and the
// peak linear-memory footprint of a large image/table/byte transfer. Indices are explicit (not a
// positional heuristic) so they cannot silently mis-optimize if the ABI grows; they are pinned by
// the tripwire test in `tests/lowlevel.test.ts` and mirror `bindings/c/zigfitsio.h`.
export const BUF_DIRS: Readonly<Record<string, Readonly<Record<number, "in" | "out">>>> = {
  zf_fingerprint128_v1: { 0: "in", 2: "out" },
  zf_fingerprint128_update_v1: { 1: "in" },
  zf_fingerprint128_final_v1: { 1: "out" },
  zf_header_snapshot_query_v1: { 3: "out" },
  // snapshot_fill is deliberately left at the default "inout" direction. Its ABI is
  // failure-atomic: BUFFER_TOO_SMALL leaves every caller buffer untouched, so staging the
  // original bytes is required before the unconditional Wasm copy-back.
  zf_header_apply_v1: { 2: "in", 3: "in", 5: "in", 7: "out" },
  zf_read_img: { 6: "out" }, //           (handle, dtype, first, nelem, nulval, scaling, [array])
  zf_write_img: { 6: "in" },
  zf_read_subset: { 9: "out" }, //        (…, lower, upper, inc, nelem, nulval, scaling, [array])
  zf_write_subset: { 9: "in" },
  zf_read_col: { 6: "out" }, //           (handle, dtype, col, firstrow, nelem, nulval, [array])
  zf_write_col: { 6: "in" },
  // Strided reads leave padding untouched, so their buffers retain the safe "inout" default.
  zf_write_col_str: { 6: "in" },
  zf_read_col_vla_layout: { 4: "out", 6: "out" },
  zf_read_col_vla_packed: { 5: "out" },
  zf_write_col_vla_packed: { 5: "in", 7: "in" },
  zf_read_bytes: { 2: "out" }, //         (handle, offset, [dst], len, out_read)
  zf_open_memory: { 0: "in" }, //         ([bytes], len, mode, opts, out) — read-only source copy
  zf_open_gzip: { 0: "in" }, //           ([bytes], len, opts, out) — read-only source copy
};

// These C ABI additions are not used by the TypeScript high-level API. Treat them as optional so
// a pre-strided-ABI module can still use the legacy staged-copy paths below.
const OPTIONAL_WASM_SYMBOLS = new Set([
  "zf_read_col_strided_v1",
  "zf_read_col_str_strided_v1",
]);

/** Per-proto plan: the `buf` copy direction for each arg index (undefined ⇒ not a `buf`). */
function planDirs(proto: Proto): (BufDir | undefined)[] {
  const overrides = BUF_DIRS[proto.name];
  return proto.args.map((k, i) => (k === "buf" ? (overrides?.[i] ?? "inout") : undefined));
}

export function openWasmLibrary(ex: WasmExports, protos: readonly Proto[]): NativeLibrary {
  // Linear memory can be reallocated (detached) by any `zf_walloc` or by a `zf_*` call that grows
  // the in-RAM device, so every access re-derives its view from the current `memory.buffer`.
  const u8 = (): Uint8Array => new Uint8Array(ex.memory.buffer);
  const dv = (): DataView => new DataView(ex.memory.buffer);

  const validateLength = (len: number): void => {
    // `zf_walloc` takes a wasm32 `usize`. Never let JS-to-wasm i32 coercion wrap a malformed
    // or oversized request (in particular, 4 GiB used to become a zero-byte allocation via
    // `>>> 0`). Buffers at the exact 4-GiB boundary are also unaddressable as one wasm32 span.
    if (!Number.isSafeInteger(len) || len < 0 || len >= 0x1_0000_0000) {
      throw new RangeError(`zigfitsio(wasm): buffer length ${len} is not representable by wasm32`);
    }
  };

  const alloc = (len: number): number => {
    validateLength(len);
    // wasm i32 returns are signed in JS; `>>> 0` reads the offset as unsigned so a heap grown past
    // 2 GiB (offsets with the high bit set) does not surface as a negative index that would crash
    // `set`/`subarray` or silently address the wrong region.
    const p = ex.zf_walloc(len) >>> 0;
    if (p === 0 && len > 0) throw new Error(`zigfitsio(wasm): out of memory allocating ${len} bytes`);
    return p;
  };

  const checkedView = (ptr: number, len: number): Uint8Array => {
    const mem = u8();
    if (ptr > mem.length || len > mem.length - ptr) {
      throw new Error(`zigfitsio(wasm): invalid memory span ${ptr}+${len} (memory size ${mem.length})`);
    }
    return mem.subarray(ptr, ptr + len);
  };

  /** `handle`/pointer bigint (the u64 neutral contract) → wasm32 32-bit offset. */
  const toOffset = (v: bigint | number): number =>
    typeof v === "bigint" ? Number(BigInt.asUintN(32, v)) : v >>> 0;

  const readCStringAt = (p: number): string => {
    if (!p) return "";
    const mem = u8();
    let end = p;
    while (mem[end] !== 0) end++;
    return decoder.decode(mem.subarray(p, end));
  };

  const convertRet = (kind: NativeType, out: unknown): NativeResult => {
    switch (kind) {
      case "void":
        return undefined;
      case "cstring_ret":
        // Normalize the returned pointer to an unsigned offset (signed i32 return above 2 GiB).
        return readCStringAt(typeof out === "bigint" ? Number(BigInt.asUintN(32, out)) : (out as number) >>> 0);
      case "handle":
      case "i64":
      case "u64":
      case "usize":
        // wasm i64 returns arrive as bigint already; a 32-bit `usize`/`handle` return arrives as a
        // number — normalize to the bigint the neutral contract promises.
        return typeof out === "bigint" ? out : BigInt(out as number);
      default:
        return Number(out);
    }
  };

  const fn: Record<string, NativeFn> = {};
  for (const proto of protos) {
    const raw = ex[proto.name];
    if (typeof raw !== "function") {
      if (OPTIONAL_WASM_SYMBOLS.has(proto.name)) continue;
      throw new Error(`symbol ${proto.name} missing from the zigfitsio wasm module`);
    }
    const argKinds = proto.args;
    const retKind = proto.returns;
    const dirs = planDirs(proto);

    fn[proto.name] = (...args: NativeArg[]): NativeResult => {
      const frees: number[] = [];
      // Buffers to copy back into the caller's view after the call (out / inout `buf`s).
      const copyBacks: { off: number; view: ArrayBufferView }[] = [];
      const call: (number | bigint)[] = new Array(args.length);

      // `finally` frees every staged block even if marshalling or the call throws (e.g. an OOM
      // mid-argument) — the wasm heap only grows, so a leak would be permanent for the instance.
      try {
        for (let i = 0; i < args.length; i++) {
          const kind = argKinds[i];
          const v = args[i];
          switch (kind) {
            case "buf": {
              if (v === null || v === undefined) {
                call[i] = 0;
                break;
              }
              const view = v as ArrayBufferView;
              const len = view.byteLength;
              const off = alloc(len);
              const dir = dirs[i]!;
              if (dir !== "out" && len > 0) {
                // Stage the input bytes. Re-derive the view (a prior alloc may have grown memory).
                u8().set(new Uint8Array(view.buffer, view.byteOffset, len), off);
              }
              if (dir !== "in") copyBacks.push({ off, view });
              call[i] = off;
              frees.push(off);
              break;
            }
            case "cstr": {
              if (v === null || v === undefined) {
                call[i] = 0;
                break;
              }
              const bytes = encoder.encode(v as string);
              const off = alloc(bytes.length + 1);
              const mem = u8();
              mem.set(bytes, off);
              mem[off + bytes.length] = 0;
              call[i] = off;
              frees.push(off);
              break;
            }
            case "cstr_arr": {
              if (v === null || v === undefined) {
                call[i] = 0;
                break;
              }
              const entries = v as readonly (string | null)[];
              const table = alloc(entries.length * 4); // wasm32 pointer table (4 bytes/entry)
              frees.push(table);
              const ptrs = new Array<number>(entries.length);
              for (let j = 0; j < entries.length; j++) {
                const e = entries[j];
                if (e === null || e === undefined) {
                  ptrs[j] = 0;
                  continue;
                }
                const bytes = encoder.encode(e);
                const off = alloc(bytes.length + 1);
                const mem = u8();
                mem.set(bytes, off);
                mem[off + bytes.length] = 0;
                ptrs[j] = off;
                frees.push(off);
              }
              const view = dv(); // after all string allocs (memory may have grown)
              for (let j = 0; j < entries.length; j++) view.setUint32(table + j * 4, ptrs[j], true);
              call[i] = table;
              break;
            }
            case "handle":
              call[i] = v === null || v === undefined ? 0 : toOffset(v as bigint | number);
              break;
            case "i64":
            case "u64":
              // wasm i64 params require BigInt.
              call[i] = typeof v === "bigint" ? v : BigInt(v as number);
              break;
            case "usize": {
              const n = typeof v === "bigint" ? v : BigInt(v as number);
              if (n < 0n || n >= 0x1_0000_0000n) {
                throw new RangeError(`zigfitsio(wasm): usize ${String(v)} is not representable by wasm32`);
              }
              call[i] = Number(n);
              break;
            }
            case "long":
              // 32-bit on wasm32 → pass as an i32 number.
              call[i] = typeof v === "bigint" ? Number(v) : (v as number);
              break;
            default:
              // int / u32 / f32 / f64 pass straight through as numbers.
              call[i] = v as number;
          }
        }

        const out = raw(...call);

        if (copyBacks.length > 0) {
          const mem = u8(); // the call may have grown memory
          for (const cb of copyBacks) {
            const len = cb.view.byteLength;
            if (len > 0) new Uint8Array(cb.view.buffer, cb.view.byteOffset, len).set(mem.subarray(cb.off, cb.off + len));
          }
        }
        return convertRet(retKind, out);
      } finally {
        for (const off of frees) ex.zf_wfree(off);
      }
    };
  }

  const begin = ex.zf_wopen_memory_begin_v1;
  const commit = ex.zf_wopen_memory_commit_v1;
  const abort = ex.zf_wopen_memory_abort_v1;
  const openMemoryOwned: NativeLibrary["openMemoryOwned"] =
    typeof begin === "function" && typeof commit === "function" && typeof abort === "function"
      ? (data, mode, opts) => {
          // Two wasm32 out-pointers share one scratch block. The final device bytes are allocated
          // by begin(), so the input crosses the JS/Wasm boundary exactly once.
          const dataLength = data.byteLength;
          const wasmSourceOffset = data.buffer === ex.memory.buffer ? data.byteOffset : null;
          const frees: number[] = [];
          let builder = 0;
          let active = false;
          try {
            validateLength(dataLength);
            const scratch = alloc(8);
            frees.push(scratch);
            let optsOff = 0;
            if (opts !== null) {
              optsOff = alloc(opts.byteLength);
              frees.push(optsOff);
              u8().set(new Uint8Array(opts.buffer, opts.byteOffset, opts.byteLength), optsOff);
            }
            const status = Number(begin(dataLength, scratch, scratch + 4));
            const out = dv(); // begin may have grown memory
            builder = out.getUint32(scratch, true);
            const dataOff = out.getUint32(scratch + 4, true);
            active = builder !== 0;
            if (status !== 0) {
              if (active) abort(builder);
              active = false;
              return { status, handle: 0n };
            }
            const source = wasmSourceOffset === null ? data : checkedView(wasmSourceOffset, dataLength);
            checkedView(dataOff, dataLength).set(source);
            dv().setUint32(scratch, 0, true);
            // commit consumes the builder on every normal return, including a parse error.
            active = false;
            const commitStatus = Number(commit(builder, mode, optsOff, scratch));
            const handle = BigInt(dv().getUint32(scratch, true));
            return { status: commitStatus, handle };
          } finally {
            // Only failures between begin and commit leave a live builder for abort.
            if (active) abort(builder);
            for (let i = frees.length - 1; i >= 0; i--) ex.zf_wfree(frees[i]);
          }
        }
      : undefined;

  const memoryView = ex.zf_wmemory_view_v1;
  const withMemoryBytes: NativeLibrary["withMemoryBytes"] =
    typeof memoryView === "function"
      ? (handle, callback) => {
          const scratch = alloc(8);
          try {
            dv().setBigUint64(scratch, 0n, true);
            const status = Number(memoryView(toOffset(handle), scratch, scratch + 4));
            if (status !== 0) return status;
            const out = dv(); // the call may have grown memory
            const ptr = out.getUint32(scratch, true);
            const len = out.getUint32(scratch + 4, true);
            callback(checkedView(ptr, len));
            return 0;
          } finally {
            ex.zf_wfree(scratch);
          }
        }
      : undefined;

  const copyMemoryBytes: NativeLibrary["copyMemoryBytes"] = withMemoryBytes
    ? (handle) => {
        let bytes = new Uint8Array(0);
        const status = withMemoryBytes(handle, (view) => {
          bytes = view.slice();
        });
        return { status, bytes };
      }
    : undefined;

  return {
    backend: "wasm",
    fn,
    ...(openMemoryOwned ? { openMemoryOwned } : {}),
    ...(copyMemoryBytes ? { copyMemoryBytes } : {}),
    ...(withMemoryBytes ? { withMemoryBytes } : {}),
    readCString(p: Ptr, len: number): string {
      if (p === 0n || len === 0) return "";
      const start = Number(p);
      return decoder.decode(u8().subarray(start, start + len));
    },
    close() {
      /* nothing to unload; drop the reference to the instance instead */
    },
  };
}

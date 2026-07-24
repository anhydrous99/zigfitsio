import { describe, expect, test } from "./_harness/index.js";
import { openWasmLibrary } from "../src/ffi/wasm.js";
import { findWasm, wasmBytesSync } from "../src/loader.js";
import * as ll from "../src/lowlevel/index.js";

const PROTO = [{ name: "zf_version", returns: "cstring_ret", args: [] as const }] as const;

function instantiate(): WebAssembly.Exports {
  const inst = new WebAssembly.Instance(new WebAssembly.Module(wasmBytesSync()), {});
  return inst.exports;
}

describe("loader", () => {
  test("ZIGFITSIO_WASM env var is the first candidate honored", () => {
    const prev = process.env.ZIGFITSIO_WASM;
    process.env.ZIGFITSIO_WASM = "/definitely/not/there.wasm";
    try {
      // A bad explicit path falls through to the dev build under zig-out/bin.
      expect(findWasm()).toContain("zig-out");
    } finally {
      if (prev === undefined) delete process.env.ZIGFITSIO_WASM;
      else process.env.ZIGFITSIO_WASM = prev;
    }
  });

  test("findWasm locates the dev build", () => {
    expect(findWasm()).toContain("zigfitsio.wasm");
  });
});

describe("wasm backend", () => {
  test("backend is wasm and the module has zero imports", () => {
    const bytes = wasmBytesSync();
    expect(WebAssembly.Module.imports(new WebAssembly.Module(bytes)).length).toBe(0);
    const lib = openWasmLibrary(instantiate() as never, PROTO);
    expect(lib.backend).toBe("wasm");
  });

  test("zf_version returns a semver string", () => {
    const lib = openWasmLibrary(instantiate() as never, PROTO);
    const v = lib.fn.zf_version();
    expect(typeof v).toBe("string");
    expect(v).toMatch(/^\d+\.\d+\.\d+/);
  });

  test("scratch allocator rejects zero and overflowing wasm32 lengths (BUGHUNT 50)", () => {
    const ex = instantiate() as WebAssembly.Exports & {
      zf_walloc(len: number): number;
      zf_wfree(ptr: number): void;
    };
    expect(ex.zf_walloc(0)).toBe(0);
    expect(ex.zf_walloc(0xffff_ffff)).toBe(0);
    expect(ex.zf_walloc(0xffff_ffef)).toBe(0);

    const ptr = ex.zf_walloc(1) >>> 0;
    expect(ptr).not.toBe(0);
    expect(ptr % 16).toBe(0);
    ex.zf_wfree(ptr);
  });

  test("isReady() is true on Node/Bun (synchronous init at import)", () => {
    expect(ll.isReady()).toBe(true);
  });
});

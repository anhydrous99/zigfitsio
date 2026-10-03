/**
 * Mirror of `bindings/python/tests/test_bugfixes.py` (JS-adapted).
 *
 * Dropped: the numpy big-endian tests (non-native-endian TypedArrays do not
 * exist) and the pathlib test (paths are strings). The numpy-scalar keyword
 * tests become bigint/number keyword tests.
 */
import { afterAll, describe, expect, test, testIf } from "./_harness/index.js";
import * as zf from "../src/index.js";
import * as ll from "../src/lowlevel/index.js";
import { colFp } from "../src/table.js";
import { enc } from "../src/util.js";
import { fill, tmpFits } from "./_fixtures.js";
import { readFileSync, existsSync, writeFileSync, chmodSync, statSync, symlinkSync, lstatSync, readdirSync, appendFileSync } from "node:fs";
import { createRequire, syncBuiltinESMExports } from "node:module";
import { dirname } from "node:path";
import { gzipSync } from "node:zlib";
import { readFile as boundedReadFile } from "../src/fsbridge.js";

const tmp = tmpFits();
afterAll(() => tmp.cleanup());

const asNums = (a: ArrayLike<number | bigint>): number[] => Array.from(a, (v) => Number(v));

describe("atomic persistence and detached builder replacement", () => {
  const tableData = (values: number[]) => new zf.TableData(
    ["X"], new Map<string, zf.ColumnData>([["X", { kind: "numeric", dtype: "i4", repeat: 1, values: Int32Array.from(values) }]]), values.length,
  );

  for (const [type, format] of [[zf.BinTableHDU, "1J"], [zf.AsciiTableHDU, "I8"]] as const) {
    test(`${format} builder replacement and clearing use assigned data`, () => {
      const table = type.fromColumns([new zf.Column("X", format, { array: Int32Array.of(1, 2), unit: "s" })]);
      const replacement = tableData([41, 42, 43]);
      table.data = replacement;
      expect(() => { table.data = [1, 2] as unknown as zf.TableData; }).toThrow(zf.FitsTypeError);
      expect(table.data).toBe(replacement);
      const saved = zf.fromBytes(new zf.HDUList([new zf.PrimaryHDU(), table]).toBytes());
      try {
        expect(asNums((saved.get(1).data as zf.TableData).numeric("X"))).toEqual([41, 42, 43]);
        expect(saved.get(1).header.get("TFORM1")).toBe(format);
        expect(saved.get(1).header.get("TUNIT1")).toBe("s");
      } finally { saved.close(); }
      table.data = null;
      const cleared = zf.fromBytes(new zf.HDUList([new zf.PrimaryHDU(), table]).toBytes());
      try {
        expect(cleared.get(1).header.get("TFIELDS")).toBe(0);
        expect(cleared.get(1).header.get("NAXIS2")).toBe(0);
      } finally { cleared.close(); }
    });

    test(`${format} explicitly empty builder keeps rows`, () => {
      const table = type.fromColumns([], { nrows: 3 });
      const saved = zf.fromBytes(new zf.HDUList([new zf.PrimaryHDU(), table]).toBytes());
      try {
        expect(saved.get(1).header.get("TFIELDS")).toBe(0);
        expect(saved.get(1).header.get("NAXIS2")).toBe(3);
      } finally { saved.close(); }
    });
  }

  for (const format of ["1L", "1X"]) {
    test(`${format} blueprint survives compatible byte data replacement`, () => {
      const table = zf.BinTableHDU.fromColumns([new zf.Column("X", format, { array: Uint8Array.of(0), unit: "s" })]);
      table.data = new zf.TableData(["X"], new Map<string, zf.ColumnData>([
        ["X", { kind: "numeric", dtype: "u1", repeat: 1, values: Uint8Array.of(1, 0, 1) }],
      ]), 3);
      const saved = zf.fromBytes(new zf.HDUList([new zf.PrimaryHDU(), table]).toBytes());
      try {
        expect(saved.get(1).header.get("TFORM1")).toBe(format);
        expect(saved.get(1).header.get("TUNIT1")).toBe("s");
        expect(asNums((saved.get(1).data as zf.TableData).numeric("X"))).toEqual([1, 0, 1]);
      } finally { saved.close(); }
    });
  }

  test("VLA blueprint survives replacement", () => {
    const table = zf.BinTableHDU.fromColumns([new zf.Column("X", "1PJ", { unit: "m" })]);
    table.data = new zf.TableData(["X"], new Map<string, zf.ColumnData>([
      ["X", { kind: "vla", dtype: "i4", repeat: 1, values: [Int32Array.of(7, 8), Int32Array.of(9)] }],
    ]), 2);
    const saved = zf.fromBytes(new zf.HDUList([new zf.PrimaryHDU(), table]).toBytes());
    try {
      expect(saved.get(1).header.get("TFORM1")).toBe("1PJ");
      expect(saved.get(1).header.get("TUNIT1")).toBe("m");
      expect((saved.get(1).data as zf.TableData).vla("X").map(asNums)).toEqual([[7, 8], [9]]);
    } finally { saved.close(); }
  });

  test("unsigned blueprint replacement regenerates its offset", () => {
    const table = zf.BinTableHDU.fromColumns([new zf.Column("X", "1I", { array: Uint16Array.of(0), unit: "s" })]);
    table.data = new zf.TableData(["X"], new Map<string, zf.ColumnData>([
      ["X", { kind: "numeric", dtype: "u2", repeat: 1, values: Uint16Array.of(0, 32768, 65535) }],
    ]), 3);
    const saved = zf.fromBytes(new zf.HDUList([new zf.PrimaryHDU(), table]).toBytes());
    try {
      expect(saved.get(1).header.get("TFORM1")).toBe("1I");
      expect(saved.get(1).header.get("TZERO1")).toBe(32768);
      expect(asNums((saved.get(1).data as zf.TableData).numeric("X"))).toEqual([0, 32768, 65535]);
    } finally { saved.close(); }
  });

  for (const format of ["F12.5", "E16.8", "D20.12"]) {
    test(`${format} source precision survives reconstruction`, () => {
      const table = zf.AsciiTableHDU.fromColumns([new zf.Column("X", format, { array: Float64Array.of(1.23456, 9.87654), unit: "s" })]);
      const source = zf.fromBytes(new zf.HDUList([new zf.PrimaryHDU(), table]).toBytes());
      try {
        const original = asNums((source.get(1).data as zf.TableData).numeric("X"));
        source.get(1).header.set("NOTE", "force reconstruction");
        const saved = zf.fromBytes(source.toBytes());
        try {
          expect(saved.get(1).header.get("TFORM1")).toBe(format);
          expect(saved.get(1).header.get("TUNIT1")).toBe("s");
          expect(asNums((saved.get(1).data as zf.TableData).numeric("X"))).toEqual(original);
        } finally { saved.close(); }
      } finally { source.close(); }
    });
  }

  test("Q VLA descriptor and display metadata survive reconstruction", () => {
    const table = zf.BinTableHDU.fromColumns([new zf.Column("X", "1QJ", { array: [Int32Array.of(1, 2), Int32Array.of(3)], unit: "m" })]);
    table.header.set("TDISP1", "I8", "display comment");
    const source = zf.fromBytes(new zf.HDUList([new zf.PrimaryHDU(), table]).toBytes());
    try {
      source.get(1).header.set("NOTE", "force reconstruction");
      const saved = zf.fromBytes(source.toBytes());
      try {
        expect(saved.get(1).header.get("TFORM1")).toBe("1QJ");
        expect(saved.get(1).header.get("TUNIT1")).toBe("m");
        expect(saved.get(1).header.get("TDISP1")).toBe("I8");
        expect(saved.get(1).header.commentOf("TDISP1")).toBe("display comment");
        expect((saved.get(1).data as zf.TableData).vla("X").map(asNums)).toEqual([[1, 2], [3]]);
      } finally { saved.close(); }
    } finally { source.close(); }
  });

  test("ZIMAGE false remains a binary table; malformed logical raises a typed error", () => {
    const source = (bad: boolean) => bytesFrom((handle) => {
      ll.check(ll.lib.zf_create_img(handle, 8, 0, null));
      ll.check(ll.lib.zf_create_tbl(handle, ll.BINARY_TBL, 0n, 0, [], [], [], null));
      const key = enc("ZIMAGE");
      if (bad) {
        const value = enc("bad");
        ll.check(ll.lib.zf_write_key_str(handle, key, key.length, value, value.length, null, 0));
      } else {
        ll.check(ll.lib.zf_write_key_log(handle, key, key.length, 0, null, 0));
      }
    });
    const saved = zf.fromBytes(source(false));
    try { expect(saved.get(1)).toBeInstanceOf(zf.BinTableHDU); } finally { saved.close(); }
    expect(() => zf.fromBytes(source(true))).toThrow(zf.FitsTypeError);
  });

  for (const throughSymlink of [false, true]) {
    testIf(!throughSymlink || process.platform !== "win32")(
      `update close preserves mode and exact flushed bytes${throughSymlink ? " through a symlink" : ""}`, () => {
        const path = tmp.path(), source = throughSymlink ? tmp.path() : path;
        new zf.HDUList([new zf.PrimaryHDU(), new zf.ImageHDU({ data: new zf.FitsArray(Int16Array.of(4, 5), [2]) })]).writeTo(path);
        chmodSync(path, 0o640);
        const expectedMode = statSync(path).mode & 0o777;
        if (throughSymlink) symlinkSync(path, source);
        const hdul = zf.open(source, "update");
        hdul.get(0).header.set("OBSERVER", "Ada");
        hdul.hdus.splice(1, 1);
        const expected = hdul._sourceBytes();
        hdul.close();
        if (throughSymlink) expect(lstatSync(source).isSymbolicLink()).toBe(true);
        expect(statSync(path).mode & 0o777).toBe(expectedMode);
        expect(new Uint8Array(readFileSync(path))).toEqual(expected);
      },
    );
  }

  test("failed close keeps the original file and releases the handle", () => {
    const path = tmp.path();
    new zf.HDUList([new zf.PrimaryHDU()]).writeTo(path);
    const before = readFileSync(path);
    const hdul = zf.open(path, "update");
    hdul.get(0).header.set("NOTE", "edited");
    const injected = hdul as unknown as { _writeHandleBytes: (handle: bigint, fd: number) => void };
    injected._writeHandleBytes = (_handle, fd) => {
      writeFileSync(fd, "partial");
      throw new Error("injected save failure");
    };
    expect(() => hdul.close()).toThrow("injected save failure");
    expect(hdul._handle).toBe(null);
    expect(readFileSync(path)).toEqual(before);
    expect(readdirSync(dirname(path)).filter((name) => name.includes(".zigfitsio-"))).toEqual([]);
  });

  test("file input and gzip inflation respect allocation budgets", () => {
    const path = tmp.path();
    const bytes = new zf.HDUList([new zf.PrimaryHDU()]).toBytes();
    writeFileSync(path, bytes);
    expect(() => zf.open(path, "readonly", { maxOpenAlloc: BigInt(bytes.length - 1) })).toThrow(zf.FitsMemoryError);
    const exact = zf.open(path, "readonly", { maxOpenAlloc: BigInt(bytes.length) });
    exact.close();
    const compressed = path + ".gz";
    writeFileSync(compressed, gzipSync(bytes));
    expect(() => zf.open(compressed, "readonly", { maxOpenAlloc: 1024n })).toThrow(zf.FitsMemoryError);
  });

  testIf(!process.versions.bun)("file growth after stat fails without allocating more input", () => {
    const path = tmp.path();
    writeFileSync(path, Uint8Array.of(1, 2));
    const fs = createRequire(import.meta.url)("node:fs") as typeof import("node:fs");
    const original = fs.readSync;
    let grew = false;
    fs.readSync = ((...args: Parameters<typeof original>) => {
      if (!grew) { grew = true; appendFileSync(path, Uint8Array.of(3)); }
      return Reflect.apply(original, fs, args);
    }) as typeof original;
    syncBuiltinESMExports();
    try {
      expect(() => boundedReadFile(path, 3n)).toThrow(zf.FitsIOError);
      expect(grew).toBe(true);
    } finally {
      fs.readSync = original;
      syncBuiltinESMExports();
    }
  });
});

/** Run `build(handle)` against a fresh in-memory FITS handle; return the serialized bytes. */
function bytesFrom(build: (handle: bigint) => void): Uint8Array {
  const out = ll.outU64();
  ll.check(ll.lib.zf_create_memory(null, out));
  const handle = out[0];
  try {
    build(handle);
    ll.check(ll.lib.zf_flush(handle));
    const size = ll.outU64();
    ll.check(ll.lib.zf_data_size(handle, size));
    const buf = new Uint8Array(Number(size[0]));
    const got = ll.outU64();
    ll.check(ll.lib.zf_read_bytes(handle, 0n, buf, buf.length, got));
    return buf.subarray(0, Number(got[0]));
  } finally {
    ll.lib.zf_close(handle);
  }
}

/** A 1-column binary table whose stored ints carry TSCAL/TZERO scaling keywords. */
function scaledColBytes(tform: string, raw: zf.TypedArray, zfCode: number, tscal: number, tzero: number): Uint8Array {
  return bytesFrom((handle) => {
    ll.check(ll.lib.zf_create_img(handle, 8, 0, null));
    ll.check(ll.lib.zf_create_tbl(handle, ll.BINARY_TBL, BigInt(raw.length), 1, ["C1"], [tform], null, null));
    const tout = ll.outU64();
    ll.check(ll.lib.zf_table_open(handle, tout));
    ll.check(ll.lib.zf_write_col(tout[0], zfCode, 0, 1n, BigInt(raw.length), null, raw));
    ll.lib.zf_table_close(tout[0]);
    for (const [kw, val] of [
      ["TSCAL1", tscal],
      ["TZERO1", tzero],
    ] as const) {
      const kb = enc(kw);
      ll.check(ll.lib.zf_write_key_dbl(handle, kb, kb.length, val, null, 0));
    }
  });
}

/** A two-column table whose distinct physical columns share the effective name X. */
function duplicateNameTableBytes(tableType: number): Uint8Array {
  return bytesFrom((handle) => {
    ll.check(ll.lib.zf_create_img(handle, 8, 0, null));
    const formats = tableType === ll.ASCII_TBL ? ["I6", "I6"] : ["1J", "1J"];
    ll.check(ll.lib.zf_create_tbl(handle, tableType, 3n, 2, ["X", "X"], formats, null, null));
    const tout = ll.outU64();
    ll.check(ll.lib.zf_table_open(handle, tout));
    try {
      ll.check(ll.lib.zf_write_col(tout[0], ll.ZF_INT32, 0, 1n, 3n, null, Int32Array.from([1, 2, 3])));
      ll.check(ll.lib.zf_write_col(tout[0], ll.ZF_INT32, 1, 1n, 3n, null, Int32Array.from([10, 20, 30])));
    } finally {
      ll.lib.zf_table_close(tout[0]);
    }
  });
}

/** Read both columns by physical index, bypassing intentionally-ambiguous name lookup. */
function physicalIntColumns(bytes: Uint8Array): number[][] {
  const out = ll.outU64();
  ll.check(ll.lib.zf_open_memory(bytes, bytes.length, ll.READONLY, null, out));
  const handle = out[0];
  try {
    ll.check(ll.lib.zf_select(handle, 2));
    const tout = ll.outU64();
    ll.check(ll.lib.zf_table_open(handle, tout));
    try {
      const columns = [new Int32Array(3), new Int32Array(3)];
      for (let i = 0; i < columns.length; i++) {
        ll.check(ll.lib.zf_read_col(tout[0], ll.ZF_INT32, i, 1n, 3n, null, columns[i]));
      }
      return columns.map(asNums);
    } finally {
      ll.lib.zf_table_close(tout[0]);
    }
  } finally {
    ll.lib.zf_close(handle);
  }
}

const filterRows = (rec: zf.TableData, keep: number[]): zf.TableData => {
  const columns = new Map<string, zf.ColumnData>();
  for (const name of rec.names) {
    const col = rec.column(name);
    if (col.kind === "string") {
      columns.set(name, { ...col, values: keep.map((i) => (col.values as string[])[i]) });
    } else if (col.kind === "vla") {
      columns.set(name, { ...col, values: keep.map((i) => (col.values as zf.TypedArray[])[i]) });
    } else {
      const flat = col.values as zf.TypedArray;
      const per = col.kind === "complex" ? col.repeat * 2 : col.repeat;
      // eslint-disable-next-line @typescript-eslint/no-explicit-any
      const out: any = new (flat.constructor as new (n: number) => zf.TypedArray)(keep.length * per);
      keep.forEach((r, k) => out.set(flat.subarray(r * per, (r + 1) * per), k * per));
      columns.set(name, { ...col, values: out });
    }
  }
  return new zf.TableData(rec.names, columns, keep.length);
};

describe("copy preserves data (open → writeTo/toBytes)", () => {
  test("image copy via writeTo", () => {
    const orig = new zf.FitsArray(fill(new Int16Array(6), (i) => i), [2, 3]);
    const src = tmp.path();
    const out = tmp.path();
    zf.writeTo(src, orig);
    const hl = zf.open(src);
    try {
      hl.writeTo(out, { overwrite: true });
    } finally {
      hl.close();
    }
    const got = zf.getData(out) as zf.FitsArray;
    expect(asNums(got.data)).toEqual([0, 1, 2, 3, 4, 5]);
  });

  test("image copy via toBytes", () => {
    const orig = new zf.FitsArray(fill(new Int16Array(6), (i) => i), [2, 3]);
    const src = new zf.HDUList([new zf.PrimaryHDU({ data: orig })]).toBytes();
    const hl = zf.fromBytes(src);
    let copy: Uint8Array;
    try {
      copy = hl.toBytes();
    } finally {
      hl.close();
    }
    const reread = zf.fromBytes(copy);
    try {
      expect(asNums((reread.get(0).data as zf.FitsArray).data)).toEqual([0, 1, 2, 3, 4, 5]);
    } finally {
      reread.close();
    }
  });

  test("table copy preserves rows", () => {
    const col = new zf.Column("X", "1J", { array: fill(new Int32Array(4), (i) => i) });
    const src = new zf.HDUList([new zf.PrimaryHDU(), zf.BinTableHDU.fromColumns([col])]).toBytes();
    const hl = zf.fromBytes(src);
    let copy: Uint8Array;
    try {
      copy = hl.toBytes();
    } finally {
      hl.close();
    }
    const reread = zf.fromBytes(copy);
    try {
      expect(asNums((reread.get(1).data as zf.TableData).get("X") as Int32Array)).toEqual([0, 1, 2, 3]);
    } finally {
      reread.close();
    }
  });
});

describe("closed/detached handles raise, not crash", () => {
  test("use after close raises", () => {
    const src = new zf.HDUList([new zf.PrimaryHDU({ data: fill(new Int16Array(4), (i) => i) })]).toBytes();
    const hl = zf.fromBytes(src);
    const hdu = hl.get(0);
    hl.close();
    expect(() => hdu.data).toThrow(zf.FitsError);
  });

  test("verify of a detached HDUList raises", () => {
    expect(() => zf.verify(new zf.HDUList([new zf.PrimaryHDU({ data: new Int16Array(9) })]))).toThrow(zf.FitsError);
  });
});

describe("unsigned conventions", () => {
  const imgCases: [string, zf.TypedArray][] = [
    ["u2", Uint16Array.from([0, 40000, 65535])],
    ["u4", Uint32Array.from([0, 3000000000, 4294967295])],
    ["u8", BigUint64Array.from([0n, 2n ** 63n, 2n ** 64n - 1n])],
  ];
  for (const [dtype, vals] of imgCases) {
    test(`unsigned ${dtype} image roundtrips`, () => {
      const src = new zf.HDUList([new zf.PrimaryHDU({ data: vals })]).toBytes();
      const hl = zf.fromBytes(src);
      try {
        const got = hl.get(0).data as zf.FitsArray;
        expect(got.dtype).toBe(dtype);
        expect(Array.from(got.data)).toEqual(Array.from(vals));
      } finally {
        hl.close();
      }
    });
  }

  test("fractional scaled column reads float", () => {
    const b = scaledColBytes("1J", Int32Array.from([1, 2, 3, 5]), ll.ZF_INT32, 0.5, 0.25);
    const hl = zf.fromBytes(b);
    try {
      const col = (hl.get(1).data as zf.TableData).column("C1");
      expect(col.dtype).toBe("f8");
      expect(asNums(col.values as Float64Array)).toEqual([0.75, 1.25, 1.75, 2.75]);
    } finally {
      hl.close();
    }
  });

  test("unsigned int16 column reads uint", () => {
    const b = scaledColBytes("1I", Int16Array.from([-32768, 0, 32767]), ll.ZF_INT16, 1.0, 32768.0);
    const hl = zf.fromBytes(b);
    try {
      const col = (hl.get(1).data as zf.TableData).column("C1");
      expect(col.dtype).toBe("u2");
      expect(asNums(col.values as Uint16Array)).toEqual([0, 32768, 65535]);
    } finally {
      hl.close();
    }
  });

  const colCases: [string, string, zf.TypedArray][] = [
    ["u2", "I", Uint16Array.from([0, 40000, 65535])],
    ["u4", "J", Uint32Array.from([0, 3000000000, 4294967295])],
    ["u8", "K", BigUint64Array.from([0n, 2n ** 63n, 2n ** 64n - 1n])],
  ];
  for (const [dtype, tform, vals] of colCases) {
    test(`unsigned ${dtype} column write roundtrips`, () => {
      const src = new zf.HDUList([
        new zf.PrimaryHDU(),
        zf.BinTableHDU.fromColumns([new zf.Column("U", tform, { array: vals })]),
      ]).toBytes();
      const hl = zf.fromBytes(src);
      try {
        const col = (hl.get(1).data as zf.TableData).column("U");
        expect(col.dtype).toBe(dtype);
        expect(Array.from(col.values as zf.TypedArray)).toEqual(Array.from(vals));
      } finally {
        hl.close();
      }
    });
  }
});

describe("VLA columns", () => {
  test("core fingerprints preserve string values and VLA cell framing", () => {
    const strings: zf.StringColumn = { kind: "string", dtype: "u1", repeat: 8, values: ["alpha", "beta"] };
    const stringFp = colFp(strings);
    expect(colFp({ ...strings, values: [...strings.values] })).toBe(stringFp);
    expect(colFp({ ...strings, values: ["alpha", "gamma"] })).not.toBe(stringFp);
    expect(colFp({ ...strings, values: ["a", "b\u0000c"] })).not.toBe(
      colFp({ ...strings, values: ["a\u0000b", "c"] }),
    );

    const backing = Int32Array.from([1, 2]);
    const split: zf.VlaColumn = {
      kind: "vla",
      dtype: "i4",
      repeat: 1,
      values: [backing.subarray(0, 1), backing.subarray(1, 2)],
    };
    const splitFp = colFp(split);
    expect(colFp({ ...split, values: [Int32Array.of(1), Int32Array.of(2)] })).toBe(splitFp);
    expect(colFp({ ...split, values: [Int32Array.of(2), Int32Array.of(1)] })).not.toBe(splitFp);
    expect(colFp({ ...split, values: [Int32Array.of(1, 2), new Int32Array(0)] })).not.toBe(splitFp);
    expect(colFp({ ...split, values: [] })).not.toBe(colFp({ ...split, values: [new Int32Array(0)] }));
  });

  test("packed P/Q write/read keeps empty cells, BigInts, shared views, and mutations", () => {
    const p = [Int32Array.from([1, 2, 3]), Int32Array.from([4]), new Int32Array(0)];
    const q = [BigInt64Array.from([9007199254740993n]), BigInt64Array.from([-7n, 11n]), new BigInt64Array(0)];
    const src = new zf.HDUList([
      new zf.PrimaryHDU(),
      zf.BinTableHDU.fromColumns([
        new zf.Column("P", "1PJ", { array: p }),
        new zf.Column("Q", "1QK", { array: q }),
        new zf.Column("EMPTY", "1PB", { array: [new Uint8Array(0), new Uint8Array(0), new Uint8Array(0)] }),
      ]),
    ]).toBytes();
    const hl = zf.fromBytes(src);
    let retained: zf.TypedArray[] = [];
    try {
      const rec = hl.get(1).data as zf.TableData;
      const pcells = rec.vla("P");
      retained = pcells;
      expect(pcells.map(asNums)).toEqual([[1, 2, 3], [4], []]);
      expect(pcells[0].buffer).toBe(pcells[1].buffer);
      expect(pcells[0].byteOffset + pcells[0].byteLength).toBe(pcells[1].byteOffset);
      const qcells = rec.vla("Q") as BigInt64Array[];
      expect(qcells.map((c) => Array.from(c))).toEqual([[9007199254740993n], [-7n, 11n], []]);
      expect(qcells[0].buffer).toBe(qcells[1].buffer);
      expect(rec.vla("EMPTY").map((c) => c.length)).toEqual([0, 0, 0]);

      (pcells[1] as Int32Array)[0] = 99;
      expect(asNums(pcells[0])).toEqual([1, 2, 3]);
      const changed = hl.toBytes();
      const reopened = zf.fromBytes(changed);
      try {
        expect((reopened.get(1).data as zf.TableData).vla("P").map(asNums)).toEqual([[1, 2, 3], [99], []]);
      } finally {
        reopened.close();
      }
    } finally {
      hl.close();
    }
    expect(retained.map(asNums)).toEqual([[1, 2, 3], [99], []]);
  });

  test("packed complex VLA read uses scalar-slot boundaries and survives close", () => {
    const src = bytesFrom((handle) => {
      ll.check(ll.lib.zf_create_img(handle, 8, 0, null));
      ll.check(ll.lib.zf_create_tbl_heap(handle, ll.BINARY_TBL, 3n, 1, ["C"], ["1PC"], null, null, 24n));
      const tout = ll.outU64();
      ll.check(ll.lib.zf_table_open(handle, tout));
      try {
        ll.check(ll.lib.zf_write_col_vla(tout[0], ll.ZF_FLOAT32, 0, 1n, Float32Array.from([1, -2]), 2n));
        ll.check(ll.lib.zf_write_col_vla(tout[0], ll.ZF_FLOAT32, 0, 2n, Float32Array.from([3, 4, -5, 6]), 4n));
      } finally {
        ll.lib.zf_table_close(tout[0]);
      }
    });
    const hl = zf.fromBytes(src);
    const cells = (hl.get(1).data as zf.TableData).vla("C");
    expect((hl.get(1).data as zf.TableData).column("C").dtype).toBe("c8");
    expect(cells.map(asNums)).toEqual([[1, -2], [3, 4, -5, 6], []]);
    expect(cells[0].buffer).toBe(cells[1].buffer);
    hl.close();
    expect(cells.map(asNums)).toEqual([[1, -2], [3, 4, -5, 6], []]);
  });
});

describe("keyword values", () => {
  test("typed keyword values roundtrip (float / bigint / bool)", () => {
    const h = new zf.Header();
    h.set("FGAIN", 1.5);
    h.set("IGAIN", 1000n); // bigint in → integer card → safe number out
    h.set("FLAG", true);
    const raw = new zf.HDUList([new zf.PrimaryHDU({ data: new Float32Array(4), header: h })]).toBytes();
    const hl = zf.fromBytes(raw);
    try {
      const hh = hl.get(0).header;
      expect(hh.get("FGAIN")).toBeCloseTo(1.5);
      expect(hh.get("IGAIN")).toBe(1000);
      expect(hh.get("FLAG")).toBe(true);
    } finally {
      hl.close();
    }
  });

  test("out-of-range bigint keyword raises", () => {
    const h = new zf.Header();
    h.set("BIG", 2n ** 70n);
    expect(() => new zf.HDUList([new zf.PrimaryHDU({ data: new Float32Array(4), header: h })]).toBytes()).toThrow(
      zf.FitsError,
    );
  });

  test("structural keyword persist raises in update mode", () => {
    const p = tmp.path();
    zf.writeTo(p, new zf.FitsArray(Int16Array.from([1, 2, 3]), [1, 3]));
    const hl = zf.open(p, "update");
    try {
      expect(() => hl.get(0).header.set("BITPIX", 32)).toThrow(zf.FitsHeaderError);
    } finally {
      hl.close();
    }
  });
});

describe("long strings and HIERARCH", () => {
  test("CONTINUE long string reassembled", () => {
    const raw = bytesFrom((handle) => {
      ll.check(ll.lib.zf_create_img(handle, 8, 0, null));
      const kb = enc("LONGKEY");
      const vb = enc("X".repeat(120));
      ll.check(ll.lib.zf_write_key_longstr(handle, kb, kb.length, vb, vb.length, null, 0));
    });
    const hl = zf.fromBytes(raw);
    try {
      expect(hl.get(0).header.get("LONGKEY")).toBe("X".repeat(120));
    } finally {
      hl.close();
    }
  });

  test("HIERARCH keyword accessible", () => {
    const raw = bytesFrom((handle) => {
      ll.check(ll.lib.zf_create_img(handle, 8, 0, null));
      const card = enc("HIERARCH ESO DET GAIN = 2.15 / detector gain".padEnd(80));
      ll.check(ll.lib.zf_write_record(handle, card));
    });
    const hl = zf.fromBytes(raw);
    try {
      const hh = hl.get(0).header;
      expect(hh.get("ESO DET GAIN")).toBeCloseTo(2.15);
      expect(hh.keys()).toContain("ESO DET GAIN");
    } finally {
      hl.close();
    }
  });
});

describe("HIERARCH long-string write (multi-card)", () => {
  const headerCards = (blob: Uint8Array): string[] => {
    const text = new TextDecoder("ascii").decode(blob);
    const cards: string[] = [];
    for (let i = 0; i + 80 <= text.length; i += 80) {
      const card = text.slice(i, i + 80);
      if (card.slice(0, 8).trimEnd() === "END") break;
      cards.push(card);
    }
    return cards;
  };
  const continueCount = (blob: Uint8Array): number =>
    headerCards(blob).filter((c) => c.slice(0, 8) === "CONTINUE").length;

  test("long HIERARCH string round-trips through toBytes (was: silent truncation at 80)", () => {
    const value = "the quick brown fox ".repeat(12).trim(); // 239 chars
    const hdu = new zf.PrimaryHDU();
    hdu.header.set("ESO LONG STR", value, "my provenance comment");
    const blob = new zf.HDUList([hdu]).toBytes();

    // Raw layout: HIERARCH base fragment ends with the '&' sentinel, CONTINUE cards follow.
    const base = headerCards(blob).filter((c) => c.startsWith("HIERARCH ESO LONG STR = '"));
    expect(base).toHaveLength(1);
    expect(base[0].trimEnd().endsWith("&'")).toBe(true);
    expect(continueCount(blob)).toBeGreaterThanOrEqual(2);

    const hl = zf.fromBytes(blob);
    try {
      expect(hl.get(0).header.get("ESO LONG STR")).toBe(value);
      expect(hl.get(0).header.commentOf("ESO LONG STR")).toBe("my provenance comment");
    } finally {
      hl.close();
    }
  });

  test("quotes straddling the CONTINUE boundary round-trip (escaped-pair-safe split)", () => {
    for (const offset of [45, 51, 52, 53, 60]) {
      const value = "x".repeat(offset) + "'" + "y".repeat(120 - offset);
      const hdu = new zf.PrimaryHDU();
      hdu.header.set("ESO Q W", value);
      const hl = zf.fromBytes(new zf.HDUList([hdu]).toBytes());
      try {
        expect(hl.get(0).header.get("ESO Q W")).toBe(value);
      } finally {
        hl.close();
      }
    }
  });

  test("explicit HIERARCH prefix is not doubled; float exponent is uppercase (item 26)", () => {
    const hdu = new zf.PrimaryHDU();
    hdu.header.set("HIERARCH ESO DET ID", 42);
    hdu.header.set("ESO DET EXPTIME", 1.5e-7);
    const blob = new zf.HDUList([hdu]).toBytes();
    const cards = headerCards(blob);
    const idCard = cards.find((c) => c.includes("ESO DET ID"))!;
    expect(idCard.split("HIERARCH").length - 1).toBe(1);
    const expCard = cards.find((c) => c.includes("ESO DET EXPTIME"))!;
    expect(expCard).toContain("E-07");
    expect(expCard).not.toContain("e-7");
    const hl = zf.fromBytes(blob);
    try {
      expect(hl.get(0).header.get("ESO DET ID")).toBe(42);
      expect(hl.get(0).header.get("ESO DET EXPTIME")).toBeCloseTo(1.5e-7);
    } finally {
      hl.close();
    }
  });

  test("comment that cannot ride the last fragment gets a dedicated CONTINUE '' card", () => {
    // base takes 53 chars, the next CONTINUE 67; the final 60 exceed the comment-reserving
    // terminal window so they fill their own card and the comment spills to a '' card.
    const value = "A".repeat(180);
    const hdu = new zf.PrimaryHDU();
    hdu.header.set("ESO LONG STR", value, "trailing comment");
    const blob = new zf.HDUList([hdu]).toBytes();
    const cards = headerCards(blob);
    expect(cards.some((c) => c.startsWith("CONTINUE  '' / trailing comment"))).toBe(true);
    const hl = zf.fromBytes(blob);
    try {
      expect(hl.get(0).header.get("ESO LONG STR")).toBe(value);
      expect(hl.get(0).header.commentOf("ESO LONG STR")).toBe("trailing comment");
    } finally {
      hl.close();
    }
  });

  test("update-mode HIERARCH set + replace leaves no orphaned CONTINUE run", () => {
    const p = tmp.path();
    zf.writeTo(p, new zf.FitsArray(new Float32Array(16), [4, 4]));
    const longValue = "it's long ".repeat(20).trim();

    let hl = zf.open(p, "update");
    try {
      hl.get(0).header.set("ESO LONG KEY", longValue, "note"); // was: BadKeywordName from Zig
    } finally {
      hl.close();
    }
    expect(continueCount(readFileSync(p))).toBeGreaterThanOrEqual(2);
    hl = zf.open(p);
    try {
      expect(hl.get(0).header.get("ESO LONG KEY")).toBe(longValue);
      expect(hl.get(0).header.commentOf("ESO LONG KEY")).toBe("note");
    } finally {
      hl.close();
    }

    hl = zf.open(p, "update");
    try {
      hl.get(0).header.set("ESO LONG KEY", "short"); // replacement must remove the old run
    } finally {
      hl.close();
    }
    expect(continueCount(readFileSync(p))).toBe(0);
    hl = zf.open(p);
    try {
      expect(hl.get(0).header.get("ESO LONG KEY")).toBe("short");
    } finally {
      hl.close();
    }
  });

  test("update-mode standard-key long-string replace leaves no orphans (item 24, via wasm)", () => {
    const p = tmp.path();
    zf.writeTo(p, new zf.FitsArray(new Float32Array(16), [4, 4]));
    let hl = zf.open(p, "update");
    try {
      hl.get(0).header.set("LSTR", "z".repeat(150));
    } finally {
      hl.close();
    }
    expect(continueCount(readFileSync(p))).toBeGreaterThanOrEqual(2);
    hl = zf.open(p, "update");
    try {
      hl.get(0).header.set("LSTR", "tiny");
    } finally {
      hl.close();
    }
    expect(continueCount(readFileSync(p))).toBe(0);
    hl = zf.open(p);
    try {
      expect(hl.get(0).header.get("LSTR")).toBe("tiny");
    } finally {
      hl.close();
    }
  });
});

describe("construction guards", () => {
  test("ragged fromColumns raises", () => {
    expect(() =>
      zf.BinTableHDU.fromColumns([
        new zf.Column("A", "1J", { array: fill(new Int32Array(5), (i) => i) }),
        new zf.Column("B", "1J", { array: fill(new Int32Array(2), (i) => i) }),
      ]),
    ).toThrow(RangeError);
  });

  test("empty HDUList raises", () => {
    expect(() => new zf.HDUList([]).toBytes()).toThrow();
  });

  test("non-ASCII column raises", () => {
    const col = new zf.Column("S", "8A", { array: ["café", "ok"] });
    expect(() => new zf.HDUList([new zf.PrimaryHDU(), zf.BinTableHDU.fromColumns([col])]).toBytes()).toThrow(
      zf.FitsError,
    );
  });

  test("duplicate effective column names raise, while positional unnamed fallbacks remain unique", () => {
    const values = Int32Array.from([1, 2]);
    expect(() =>
      zf.BinTableHDU.fromColumns([
        new zf.Column("X", "1J", { array: values }),
        new zf.Column("X", "1J", { array: values }),
      ]),
    ).toThrow(zf.FitsTableError);
    expect(() =>
      zf.AsciiTableHDU.fromColumns([
        new zf.Column("col2", "I6", { array: values }),
        new zf.Column("", "I6", { array: values }),
      ]),
    ).toThrow(zf.FitsTableError);
    expect(() =>
      zf.BinTableHDU.fromColumns([
        new zf.Column("", "1J", { array: values }),
        new zf.Column("", "1J", { array: values }),
      ]),
    ).not.toThrow();
    expect(() => new zf.TableData(["X", "X"], new Map(), 0)).toThrow(zf.FitsTableError);
  });
});

describe("duplicate table column names", () => {
  for (const [label, tableType] of [
    ["binary", ll.BINARY_TBL],
    ["ASCII", ll.ASCII_TBL],
  ] as const) {
    test(`${label}: high-level read fails loud and update close preserves both physical columns`, () => {
      const p = tmp.path();
      const source = duplicateNameTableBytes(tableType);
      writeFileSync(p, source);
      const hl = zf.open(p, "update");
      expect((hl.get(1) as zf.TableHDU).columns).toEqual(["X", "X"]);
      expect(() => hl.get(1).data).toThrow(zf.FitsTableError);
      hl.close();
      expect(physicalIntColumns(readFileSync(p))).toEqual([[1, 2, 3], [10, 20, 30]]);
    });

    test(`${label}: assigned data cannot bypass the duplicate-name update guard`, () => {
      const p = tmp.path();
      writeFileSync(p, duplicateNameTableBytes(tableType));
      const hl = zf.open(p, "update");
      const columns = new Map<string, zf.ColumnData>([
        ["X", { kind: "numeric", dtype: "i4", repeat: 1, values: Int32Array.from([99, 98, 97]) }],
      ]);
      (hl.get(1) as zf.TableHDU).data = new zf.TableData(["X"], columns, 3);
      expect(() => hl.close()).toThrow(zf.FitsTableError);
      expect(physicalIntColumns(readFileSync(p))).toEqual([[1, 2, 3], [10, 20, 30]]);
    });

    test(`${label}: pristine copies stay byte-exact, but reconstruction fails loud`, () => {
      const source = duplicateNameTableBytes(tableType);
      const pristine = zf.fromBytes(source);
      try {
        expect(pristine.toBytes()).toEqual(source);
      } finally {
        pristine.close();
      }

      const dirty = zf.fromBytes(source);
      try {
        dirty.get(1).header.set("OBSERVER", "duplicate-name test");
        expect(() => dirty.toBytes()).toThrow(zf.FitsTableError);
      } finally {
        dirty.close();
      }

      const assigned = zf.fromBytes(source);
      try {
        const columns = new Map<string, zf.ColumnData>([
          ["X", { kind: "numeric", dtype: "i4", repeat: 1, values: Int32Array.from([99, 98, 97]) }],
        ]);
        (assigned.get(1) as zf.TableHDU).data = new zf.TableData(["X"], columns, 3);
        expect(() => assigned.toBytes()).toThrow(zf.FitsTableError);
      } finally {
        assigned.close();
      }
      expect(physicalIntColumns(source)).toEqual([[1, 2, 3], [10, 20, 30]]);
    });
  }
});

describe("update-mode write-back and lifecycle", () => {
  test("update mode writes image data back on flush", () => {
    const p = tmp.path();
    zf.writeTo(p, new zf.FitsArray(new Float32Array(6), [2, 3]));
    const hl = zf.open(p, "update");
    try {
      (hl.get(0).data as zf.FitsArray).set(999.0, 0, 0);
      hl.flush();
    } finally {
      hl.close();
    }
    expect((zf.getData(p) as zf.FitsArray).get(0, 0)).toBe(999.0);
  });

  test("update mode flushes on close (no explicit flush)", () => {
    const p = tmp.path();
    zf.writeTo(p, new zf.FitsArray(new Float32Array(4), [2, 2]));
    const hl = zf.open(p, "update");
    const img = hl.get(0).data as zf.FitsArray;
    (img.data as Float32Array).fill(7.0);
    hl.close();
    expect((zf.getData(p) as zf.FitsArray).get(0, 0)).toBe(7.0);
  });

  test("update-mode table write-back on close", () => {
    const p = tmp.path();
    const col = new zf.Column("FLUX", "1E", { array: Float32Array.from([1, 2, 3]) });
    new zf.HDUList([new zf.PrimaryHDU(), zf.BinTableHDU.fromColumns([col])]).writeTo(p);
    const hl = zf.open(p, "update");
    ((hl.get(1).data as zf.TableData).get("FLUX") as Float32Array).fill(99.0);
    hl.close();
    const chk = zf.open(p);
    try {
      expect(asNums((chk.get(1).data as zf.TableData).get("FLUX") as Float32Array)).toEqual([99, 99, 99]);
    } finally {
      chk.close();
    }
  });

  test("appended HDU persists on close", () => {
    const p = tmp.path();
    new zf.HDUList([new zf.PrimaryHDU({ data: new zf.FitsArray(fill(new Int16Array(4), () => 1), [2, 2]) })]).writeTo(p);
    const hl = zf.open(p, "update");
    hl.append(new zf.ImageHDU({ data: fill(new Int16Array(4), (i) => i), name: "NEW" }));
    hl.close();
    const chk = zf.open(p);
    try {
      expect(chk.length).toBe(2);
      expect(asNums((chk.get("NEW").data as zf.FitsArray).data)).toEqual([0, 1, 2, 3]);
    } finally {
      chk.close();
    }
  });

  test("in-place compressed update fails loud", () => {
    const p = tmp.path();
    const img = new zf.FitsArray(fill(new Int16Array(16), (i) => i), [4, 4]);
    new zf.HDUList([new zf.PrimaryHDU(), new zf.CompImageHDU({ data: img, compression: "RICE_1" })]).writeTo(p);
    const hl = zf.open(p, "update");
    (hl.get(1).data as zf.FitsArray).set(123, 0, 0);
    expect(() => hl.close()).toThrow(zf.NotSupportedError);
  });
});

describe("readonly-open edits and the pristine fast path", () => {
  test("readonly edit reflected in writeTo (reconstruction)", () => {
    const src = tmp.path();
    const out = tmp.path();
    new zf.HDUList([new zf.PrimaryHDU({ data: new zf.FitsArray(fill(new Int16Array(12), () => 1), [3, 4]) })]).writeTo(src);
    const hl = zf.open(src); // default read-only
    const scaled = (hl.get(0).data as zf.FitsArray).clone();
    (scaled.data as Int16Array).forEach((v, i) => ((scaled.data as Int16Array)[i] = v * 10));
    (hl.get(0) as zf.ImageHDU).data = scaled;
    hl.get(0).header.set("MYKEY", 42);
    hl.writeTo(out, { overwrite: true });
    hl.close();
    const chk = zf.open(out);
    try {
      expect((chk.get(0).data as zf.FitsArray).get(0, 1)).toBe(10);
      expect(chk.get(0).header.get("MYKEY")).toBe(42);
    } finally {
      chk.close();
    }
  });

  test("in-place mutation of a readonly open is saved (no stale fast path)", () => {
    const src = tmp.path();
    const out = tmp.path();
    new zf.HDUList([new zf.PrimaryHDU({ data: new zf.FitsArray(fill(new Int16Array(12), () => 1), [3, 4]) })]).writeTo(src);
    const hl = zf.open(src); // read-only
    ((hl.get(0).data as zf.FitsArray).data as Int16Array).fill(7); // in-place; does NOT call the setter
    hl.writeTo(out, { overwrite: true });
    hl.close();
    const chk = zf.open(out);
    try {
      expect((chk.get(0).data as zf.FitsArray).get(0, 0)).toBe(7);
    } finally {
      chk.close();
    }

    // In-place table cell edit on a read-only open, via toBytes.
    const src2 = tmp.path();
    const col = new zf.Column("FLUX", "1E", { array: Float32Array.from([1, 2, 3]) });
    new zf.HDUList([new zf.PrimaryHDU(), zf.BinTableHDU.fromColumns([col])]).writeTo(src2);
    const h2 = zf.open(src2);
    ((h2.get(1).data as zf.TableData).get("FLUX") as Float32Array).fill(42.0);
    const reread = zf.fromBytes(h2.toBytes());
    h2.close();
    try {
      expect(asNums((reread.get(1).data as zf.TableData).get("FLUX") as Float32Array)).toEqual([42, 42, 42]);
    } finally {
      reread.close();
    }
  });

  test("unchanged readonly open still copies verbatim (data preserved)", () => {
    const src = tmp.path();
    const out = tmp.path();
    new zf.HDUList([new zf.PrimaryHDU({ data: new zf.FitsArray(fill(new Int16Array(12), (i) => i), [3, 4]) })]).writeTo(src);
    const hl = zf.open(src);
    void hl.get(0).data; // materialize, but do not edit
    hl.writeTo(out, { overwrite: true });
    hl.close();
    // Verbatim copy: byte-identical to the source.
    expect(Buffer.compare(readFileSync(out), readFileSync(src))).toBe(0);
  });

  test("pristine update-mode saves fingerprint each materialized payload once", () => {
    const source = new zf.HDUList([
      new zf.PrimaryHDU({ data: Int16Array.from([1, 2, 3, 4]) }),
      zf.BinTableHDU.fromColumns([
        new zf.Column("A", "1J", { array: Int32Array.from([1, 2, 3]) }),
        new zf.Column("B", "1J", { array: Int32Array.from([4, 5, 6]) }),
      ]),
    ]).toBytes();

    for (const save of [
      (hl: zf.HDUList) => expect(hl.toBytes()).toEqual(source),
      (hl: zf.HDUList) => {
        const out = tmp.path();
        hl.writeTo(out, { overwrite: true });
        expect(Buffer.compare(readFileSync(out), Buffer.from(source))).toBe(0);
      },
    ]) {
      const hl = zf.fromBytes(source, "update");
      void hl.get(0).data;
      void hl.get(1).data;
      const fingerprint = ll.native.fn.zf_fingerprint128_v1;
      let calls = 0;
      let bytes = 0;
      ll.native.fn.zf_fingerprint128_v1 = (...args) => {
        calls += 1;
        bytes += Number(args[1]);
        return fingerprint(...args);
      };
      try {
        save(hl);
        expect(calls).toBe(3); // one image plus two table columns
        expect(bytes).toBe(32); // 8 image bytes plus two 12-byte columns
      } finally {
        ll.native.fn.zf_fingerprint128_v1 = fingerprint;
        hl.close();
      }
    }
  });

  test("failed writeTo leaves no partial file", () => {
    const p = tmp.path();
    new zf.HDUList([new zf.PrimaryHDU({ data: fill(new Int16Array(3), () => 1) })]).writeTo(p);
    const before = readFileSync(p);

    class Boom extends zf.PrimaryHDU {
      override _writeTo(): void {
        throw new Error("boom");
      }
    }
    expect(() => new zf.HDUList([new Boom({ data: new Int16Array(2) })]).writeTo(p, { overwrite: true })).toThrow("boom");
    expect(Buffer.compare(readFileSync(p), before)).toBe(0); // original intact
    expect(existsSync(p + ".zigfitsio.tmp")).toBe(false);
  });
});

describe("review regressions (2026-07-04)", () => {
  test("complex column write derives the transfer code from the buffer, not the TFORM", () => {
    // Float32Array into a 1M (c16) column: the old code declared f64 over an
    // f32 buffer — a 2x heap overread. Both mixed-width directions must
    // round-trip by value.
    const f32into1M = new zf.Column("C", "1M", { array: Float32Array.from([1, 2, -3, 4]) });
    const src1 = new zf.HDUList([new zf.PrimaryHDU(), zf.BinTableHDU.fromColumns([f32into1M])]).toBytes();
    const hl1 = zf.fromBytes(src1);
    try {
      const col = (hl1.get(1).data as zf.TableData).column("C");
      expect(col.dtype).toBe("c16");
      expect(asNums(col.values as Float64Array)).toEqual([1, 2, -3, 4]);
    } finally {
      hl1.close();
    }

    const f64into1C = new zf.Column("C", "1C", { array: Float64Array.from([1.5, -2, 3, 4.25]) });
    const src2 = new zf.HDUList([new zf.PrimaryHDU(), zf.BinTableHDU.fromColumns([f64into1C])]).toBytes();
    const hl2 = zf.fromBytes(src2);
    try {
      const col = (hl2.get(1).data as zf.TableData).column("C");
      expect(col.dtype).toBe("c8");
      const got = col.values as Float32Array;
      [1.5, -2, 3, 4.25].forEach((w, i) => expect(Math.abs(got[i] - w)).toBeLessThan(1e-6));
    } finally {
      hl2.close();
    }
  });

  test("plain number[] into a K column: rounds via f8, overflows loudly (no BigInt wrap)", () => {
    const ok = new zf.Column("X", "1K", { array: [1.4, 2.6] });
    const src = new zf.HDUList([new zf.PrimaryHDU(), zf.BinTableHDU.fromColumns([ok])]).toBytes();
    const hl = zf.fromBytes(src);
    try {
      expect(Array.from((hl.get(1).data as zf.TableData).get("X") as BigInt64Array)).toEqual([1n, 3n]);
    } finally {
      hl.close();
    }

    const big = new zf.Column("X", "1K", { array: [1e20] });
    expect(() => new zf.HDUList([new zf.PrimaryHDU(), zf.BinTableHDU.fromColumns([big])]).toBytes()).toThrow(
      zf.FitsError,
    );
  });

  test("non-integer / out-of-range VLA K cells: typed rounding and overflow", () => {
    const ok = new zf.Column("V", "1PK", { array: [[1.4], [2.6]] });
    const src = new zf.HDUList([new zf.PrimaryHDU(), zf.BinTableHDU.fromColumns([ok])]).toBytes();
    const hl = zf.fromBytes(src);
    try {
      const cells = (hl.get(1).data as zf.TableData).get("V") as zf.TypedArray[];
      expect(Array.from(cells[0] as BigInt64Array)).toEqual([1n]);
      expect(Array.from(cells[1] as BigInt64Array)).toEqual([3n]);
    } finally {
      hl.close();
    }

    const over = new zf.Column("V", "1PK", { array: [[1e20]] });
    expect(() => new zf.HDUList([new zf.PrimaryHDU(), zf.BinTableHDU.fromColumns([over])]).toBytes()).toThrow(
      zf.FitsOverflowError,
    );
  });

  test("non-numeric values in a numeric column throw FitsTypeError, not silent NaN", () => {
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    const bad = new zf.Column("X", "1J", { array: ["a", "b"] as any });
    expect(() => new zf.HDUList([new zf.PrimaryHDU(), zf.BinTableHDU.fromColumns([bad])]).toBytes()).toThrow(
      zf.FitsTypeError,
    );
  });

  test("integer keywords in (2^53, 2^63) stay integer cards through reconstruction", () => {
    const h = new zf.Header();
    h.set("OBSID", 9007199254740994); // 2^53+2, exact as a double
    const raw = new zf.HDUList([new zf.PrimaryHDU({ data: new Int16Array(4), header: h })]).toBytes();
    const hl = zf.fromBytes(raw);
    try {
      expect(hl.get(0).header.get("OBSID")).toBe(9007199254740994);
      const handle = hl._handle as bigint;
      ll.check(ll.lib.zf_select(handle, 1));
      const n = ll.newLongArray(1);
      ll.check(ll.lib.zf_card_count(handle, n));
      let card = "";
      for (let i = 0; i < ll.readLongAt(n, 0); i++) {
        const buf = new Uint8Array(80);
        ll.check(ll.lib.zf_read_card(handle, i, buf));
        const s = new TextDecoder().decode(buf);
        if (s.startsWith("OBSID")) card = s;
      }
      expect(card).toContain("9007199254740994");
      expect(card.includes("E")).toBe(false); // an integer card, not 9.00719...E15
    } finally {
      hl.close();
    }
  });

  test("a valueless BSCALE card marks the image as scaled (reads f8, mirroring Python)", () => {
    const raw = bytesFrom((handle) => {
      const axes = ll.longArray([4]);
      ll.check(ll.lib.zf_create_img(handle, 16, 1, axes));
      const pix = Int16Array.from([1, 2, 3, 4]);
      ll.check(ll.lib.zf_write_img(handle, ll.ZF_INT16, 1n, 4n, null, null, pix));
      ll.check(ll.lib.zf_write_record(handle, enc("BSCALE  = ".padEnd(80))));
    });
    const hl = zf.fromBytes(raw);
    try {
      const img = hl.get(0).data as zf.FitsArray;
      expect(img.dtype).toBe("f8");
      expect(asNums(img.data)).toEqual([1, 2, 3, 4]);
    } finally {
      hl.close();
    }
  });

  test("a zero-width (0A) string column reads as empty strings, not an error", () => {
    const raw = bytesFrom((handle) => {
      ll.check(ll.lib.zf_create_img(handle, 8, 0, null));
      ll.check(ll.lib.zf_create_tbl(handle, ll.BINARY_TBL, 2n, 1, ["S"], ["0A"], null, null));
    });
    const hl = zf.fromBytes(raw);
    try {
      expect((hl.get(1).data as zf.TableData).get("S")).toEqual(["", ""]);
    } finally {
      hl.close();
    }
  });
});

describe("misc parity", () => {
  test("getData falls through an empty primary", () => {
    const p = tmp.path();
    new zf.HDUList([
      new zf.PrimaryHDU(),
      zf.BinTableHDU.fromColumns([new zf.Column("X", "1J", { array: fill(new Int32Array(3), (i) => i) })]),
    ]).writeTo(p);
    const data = zf.getData(p);
    expect(data).not.toBeNull();
    expect((data as zf.TableData).names).toContain("X");
  });

  test("PRIMARY name alias", () => {
    const p = tmp.path();
    zf.writeTo(p, new zf.FitsArray(Int16Array.from([1, 2]), [1, 2]));
    const hl = zf.open(p);
    try {
      expect(hl.get("PRIMARY")).toBe(hl.get(0));
    } finally {
      hl.close();
    }
  });

  test("unknown open mode raises", () => {
    const p = tmp.path();
    zf.writeTo(p, new Int16Array(2));
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    expect(() => zf.open(p, "rw" as any)).toThrow();
  });

  test("bit 'X' column roundtrips under the one-byte-per-bit convention", () => {
    const bits = Uint8Array.from([1, 0, 1, 0, 1, 0, 1, 0]);
    const src = new zf.HDUList([
      new zf.PrimaryHDU(),
      zf.BinTableHDU.fromColumns([new zf.Column("B", "8X", { array: bits })]),
    ]).toBytes();
    const hl = zf.fromBytes(src);
    try {
      const col = (hl.get(1).data as zf.TableData).column("B");
      expect(col.repeat).toBe(8);
      expect(asNums(col.values as Uint8Array)).toEqual([1, 0, 1, 0, 1, 0, 1, 0]);
    } finally {
      hl.close();
    }
  });

  test("table data setter replaces rows (filter / same-count update / count-change fails loud)", () => {
    const mk = (p: string, n: number): void => {
      const cols = [
        new zf.Column("IDX", "1J", { array: fill(new Int32Array(n), (i) => i) }),
        new zf.Column("V", "1E", { array: fill(new Float32Array(n), (i) => i * 1.5) }),
      ];
      new zf.HDUList([new zf.PrimaryHDU(), zf.BinTableHDU.fromColumns(cols)]).writeTo(p, { overwrite: true });
    };

    // Filter rows via the setter; writeTo reconstructs.
    const src = tmp.path();
    const out = tmp.path();
    mk(src, 6);
    const h = zf.open(src);
    const rec = h.get(1).data as zf.TableData;
    const idx = rec.get("IDX") as Int32Array;
    const keep = [...idx.keys()].filter((i) => idx[i] % 2 === 0);
    (h.get(1) as zf.BinTableHDU).data = filterRows(rec, keep);
    h.writeTo(out, { overwrite: true });
    h.close();
    const chk = zf.open(out);
    try {
      expect(asNums((chk.get(1).data as zf.TableData).get("IDX") as Int32Array)).toEqual([0, 2, 4]);
    } finally {
      chk.close();
    }

    // update-mode assignment with the SAME row count persists on close.
    const u = tmp.path();
    mk(u, 4);
    {
      const hu = zf.open(u, "update");
      const r = hu.get(1).data as zf.TableData;
      const filtered = filterRows(r, [0, 1, 2, 3]);
      (filtered.get("IDX") as Int32Array).set([10, 20, 30, 40]);
      (hu.get(1) as zf.BinTableHDU).data = filtered;
      hu.close();
    }
    const chk2 = zf.open(u);
    try {
      expect(asNums((chk2.get(1).data as zf.TableData).get("IDX") as Int32Array)).toEqual([10, 20, 30, 40]);
    } finally {
      chk2.close();
    }

    // update-mode row-count change in place is unsupported -> fail loud, file intact.
    const r2 = tmp.path();
    mk(r2, 5);
    {
      const hr = zf.open(r2, "update");
      const rec5 = hr.get(1).data as zf.TableData;
      (hr.get(1) as zf.BinTableHDU).data = filterRows(rec5, [0, 1, 2]);
      expect(() => hr.close()).toThrow(zf.NotSupportedError);
    }
    const chk3 = zf.open(r2);
    try {
      expect((chk3.get(1).data as zf.TableData).nrows).toBe(5);
    } finally {
      chk3.close();
    }
  });
});

// BUGHUNT-2026-07-06 HIGH #9: _emitColumns paired file-position TFORMs with
// data-position column names, so writeTo/toBytes of a reassigned reordered or
// filtered TableData emitted each column under whatever format sat at its
// index in the file — silently coercing floats to ints. Columns must resolve
// to their file counterpart by NAME, synthesizing a format for a column the
// file does not have (mirrors core.py _emit_columns / _binary_tform_for).
describe("writeTo reconstructs a reassigned TableData by column name", () => {
  /** Reassign hdu 1's data via `reassign` and return the re-serialized bytes. */
  const reassigned = (src: Uint8Array, reassign: (hdu: zf.TableHDU, d: zf.TableData) => void): Uint8Array => {
    const hl = zf.fromBytes(src);
    try {
      const hdu = hl.get(1) as zf.TableHDU;
      reassign(hdu, hdu.data as zf.TableData);
      return hl.toBytes();
    } finally {
      hl.close();
    }
  };

  const intFloatBytes = (): Uint8Array =>
    new zf.HDUList([
      new zf.PrimaryHDU(),
      zf.BinTableHDU.fromColumns([
        new zf.Column("A", "1J", { array: Int32Array.from([1, 2, 3]) }),
        new zf.Column("B", "1E", { array: Float32Array.from([1.5, 2.5, 3.5]) }),
      ]),
    ]).toBytes();

  test("reordered TableData keeps each column's own format", () => {
    const copy = reassigned(intFloatBytes(), (hdu, d) => {
      hdu.data = new zf.TableData(["B", "A"], d.columns, d.nrows);
    });
    const chk = zf.fromBytes(copy);
    try {
      const got = chk.get(1).data as zf.TableData;
      expect([...got.names]).toEqual(["B", "A"]);
      expect(got.get("B")).toBeInstanceOf(Float32Array);
      expect(asNums(got.get("B") as zf.TypedArray)).toEqual([1.5, 2.5, 3.5]);
      expect(asNums(got.get("A") as zf.TypedArray)).toEqual([1, 2, 3]);
    } finally {
      chk.close();
    }
  });

  test("subset TableData emits only the kept column, format intact", () => {
    const copy = reassigned(intFloatBytes(), (hdu, d) => {
      hdu.data = new zf.TableData(["B"], d.columns, d.nrows);
    });
    const chk = zf.fromBytes(copy);
    try {
      const got = chk.get(1).data as zf.TableData;
      expect([...got.names]).toEqual(["B"]);
      expect(got.get("B")).toBeInstanceOf(Float32Array);
      expect(asNums(got.get("B") as zf.TypedArray)).toEqual([1.5, 2.5, 3.5]);
    } finally {
      chk.close();
    }
  });

  test("added column synthesizes its TFORM from the column data", () => {
    const src = new zf.HDUList([
      new zf.PrimaryHDU(),
      zf.BinTableHDU.fromColumns([new zf.Column("A", "1J", { array: Int32Array.from([1, 2, 3]) })]),
    ]).toBytes();
    const copy = reassigned(src, (hdu, d) => {
      const columns = new Map<string, zf.ColumnData>(d.columns);
      columns.set("Z", { kind: "numeric", dtype: "f8", repeat: 1, values: Float64Array.from([0.25, 0.5, 0.75]) });
      hdu.data = new zf.TableData(["A", "Z"], columns, d.nrows);
    });
    const chk = zf.fromBytes(copy);
    try {
      const got = chk.get(1).data as zf.TableData;
      expect([...got.names]).toEqual(["A", "Z"]);
      expect(asNums(got.get("A") as zf.TypedArray)).toEqual([1, 2, 3]);
      expect(got.get("Z")).toBeInstanceOf(Float64Array);
      expect(asNums(got.get("Z") as zf.TypedArray)).toEqual([0.25, 0.5, 0.75]);
    } finally {
      chk.close();
    }
  });

  test("widened dtype is not truncated by the stale file TFORM", () => {
    const src = new zf.HDUList([
      new zf.PrimaryHDU(),
      zf.BinTableHDU.fromColumns([new zf.Column("V", "1I", { array: Int16Array.from([1, 2, 3]) })]),
    ]).toBytes();
    const copy = reassigned(src, (hdu, d) => {
      const columns = new Map<string, zf.ColumnData>();
      columns.set("V", { kind: "numeric", dtype: "i8", repeat: 1, values: BigInt64Array.from([40000n, 50000n, 60000n]) });
      hdu.data = new zf.TableData(["V"], columns, d.nrows);
    });
    const chk = zf.fromBytes(copy);
    try {
      expect(asNums((chk.get(1).data as zf.TableData).get("V") as zf.TypedArray)).toEqual([40000, 50000, 60000]);
    } finally {
      chk.close();
    }
  });

  test("logical column keeps its 1L TFORM through reconstruction", () => {
    const src = new zf.HDUList([
      new zf.PrimaryHDU(),
      zf.BinTableHDU.fromColumns([new zf.Column("FLAG", "1L", { array: [true, false, true] })]),
    ]).toBytes();
    // Same data, reassigned: dirties the HDU so toBytes reconstructs via _emitColumns.
    const copy = reassigned(src, (hdu, d) => {
      hdu.data = new zf.TableData(d.names, d.columns, d.nrows);
    });
    const chk = zf.fromBytes(copy);
    try {
      expect(chk.get(1).header.get("TFORM1")).toBe("1L");
      expect(asNums((chk.get(1).data as zf.TableData).get("FLAG") as zf.TypedArray)).toEqual([1, 0, 1]);
    } finally {
      chk.close();
    }
  });

  test("TNULLn/TDISPn/TUNITn follow their column through a reorder", () => {
    // Plant indexed metadata on column A (index 1 in the file) in a first
    // pass, then reorder in a second — the cards must land at A's NEW index.
    const seeded = zf.fromBytes(intFloatBytes());
    seeded.get(1).header.set("TNULL1", -999, "null marker for A");
    seeded.get(1).header.set("TDISP1", "I8");
    seeded.get(1).header.set("TUNIT1", "adu");
    const src = seeded.toBytes();
    seeded.close();
    const copy = reassigned(src, (hdu, d) => {
      hdu.data = new zf.TableData(["B", "A"], d.columns, d.nrows);
    });
    const chk = zf.fromBytes(copy);
    try {
      const h = chk.get(1).header;
      expect(h.get("TNULL2")).toBe(-999);
      expect(h.get("TDISP2")).toBe("I8");
      expect(h.get("TUNIT2")).toBe("adu");
      // Nothing may stay behind labeling B (a TNULL on a float column is spec-invalid).
      expect(h.get("TNULL1")).toBeUndefined();
      expect(h.get("TDISP1")).toBeUndefined();
      expect(h.get("TUNIT1")).toBeUndefined();
      const got = chk.get(1).data as zf.TableData;
      expect(asNums(got.get("A") as zf.TypedArray)).toEqual([1, 2, 3]);
      expect(asNums(got.get("B") as zf.TypedArray)).toEqual([1.5, 2.5, 3.5]);
    } finally {
      chk.close();
    }
  });

  test("renamed column synthesizes its format and drops stale indexed metadata", () => {
    const seeded = zf.fromBytes(
      new zf.HDUList([
        new zf.PrimaryHDU(),
        zf.BinTableHDU.fromColumns([new zf.Column("A", "1J", { array: Int32Array.from([1, 2, 3]) })]),
      ]).toBytes(),
    );
    seeded.get(1).header.set("TNULL1", -999);
    const src = seeded.toBytes();
    seeded.close();
    const copy = reassigned(src, (hdu, d) => {
      hdu.data = new zf.TableData(["R"], new Map([["R", d.column("A")]]), d.nrows);
    });
    const chk = zf.fromBytes(copy);
    try {
      expect(chk.get(1).header.get("TTYPE1")).toBe("R");
      expect(chk.get(1).header.get("TFORM1")).toBe("1J");
      expect(chk.get(1).header.get("TNULL1")).toBeUndefined();
      expect(asNums((chk.get(1).data as zf.TableData).get("R") as zf.TypedArray)).toEqual([1, 2, 3]);
    } finally {
      chk.close();
    }
  });

  test("retyped column keeps its unit but drops the stale TNULL", () => {
    const seeded = zf.fromBytes(
      new zf.HDUList([
        new zf.PrimaryHDU(),
        zf.BinTableHDU.fromColumns([new zf.Column("V", "1I", { array: Int16Array.from([1, 2, 3]) })]),
      ]).toBytes(),
    );
    seeded.get(1).header.set("TNULL1", -9);
    seeded.get(1).header.set("TUNIT1", "ct");
    const src = seeded.toBytes();
    seeded.close();
    const copy = reassigned(src, (hdu, d) => {
      const columns = new Map<string, zf.ColumnData>();
      columns.set("V", { kind: "numeric", dtype: "i8", repeat: 1, values: BigInt64Array.from([40000n, 50000n, 60000n]) });
      hdu.data = new zf.TableData(["V"], columns, d.nrows);
    });
    const chk = zf.fromBytes(copy);
    try {
      expect(chk.get(1).header.get("TFORM1")).toBe("1K");
      expect(chk.get(1).header.get("TUNIT1")).toBe("ct"); // the physical quantity did not change
      expect(chk.get(1).header.get("TNULL1")).toBeUndefined(); // the i2 sentinel no longer describes the stored type
      expect(asNums((chk.get(1).data as zf.TableData).get("V") as zf.TypedArray)).toEqual([40000, 50000, 60000]);
    } finally {
      chk.close();
    }
  });

  test("ASCII-table add/rename fails loud instead of guessing a format", () => {
    const src = new zf.HDUList([
      new zf.PrimaryHDU(),
      zf.AsciiTableHDU.fromColumns([new zf.Column("A", "I6", { array: Int32Array.from([1, 2, 3]) })]),
    ]).toBytes();
    expect(() =>
      reassigned(src, (hdu, d) => {
        hdu.data = new zf.TableData(["R"], new Map([["R", d.column("A")]]), d.nrows);
      }),
    ).toThrow(zf.NotSupportedError);
  });

  test("added VLA column synthesizes its 1P format from the element dtype", () => {
    const src = new zf.HDUList([
      new zf.PrimaryHDU(),
      zf.BinTableHDU.fromColumns([new zf.Column("A", "1J", { array: Int32Array.from([1, 2, 3]) })]),
    ]).toBytes();
    const copy = reassigned(src, (hdu, d) => {
      const columns = new Map<string, zf.ColumnData>(d.columns);
      columns.set("W", {
        kind: "vla",
        dtype: "i4",
        repeat: 1,
        values: [Int32Array.from([7]), Int32Array.from([8, 9]), Int32Array.from([])],
      });
      hdu.data = new zf.TableData(["A", "W"], columns, d.nrows);
    });
    const chk = zf.fromBytes(copy);
    try {
      expect(String(chk.get(1).header.get("TFORM2"))).toContain("PJ");
      const got = chk.get(1).data as zf.TableData;
      expect(got.vla("W").map((cell) => asNums(cell))).toEqual([[7], [8, 9], []]);
      expect(asNums(got.get("A") as zf.TypedArray)).toEqual([1, 2, 3]);
    } finally {
      chk.close();
    }
  });
});

// BUGHUNT-2026-07-06 CRIT #1 (table) and HIGH #7 (compressed image): the
// reconstruction write path rebuilt the HDU via the C ABI but never re-emitted
// the user's non-structural header cards, so every writeTo/toBytes silently
// erased scientific metadata while the data survived. Mirrors the image path,
// which has always called _applyUserKeys.
describe("user header keywords survive reconstruction (table + compressed image)", () => {
  const dup = (h: zf.Header, kw: string): number => h.keys().filter((k) => k === kw).length;

  test("plain-image reconstruction preserves ordered table-looking extra cards", () => {
    const source = bytesFrom((handle) => {
      ll.check(ll.lib.zf_create_img(handle, 8, 0, null));
      for (const [key, value] of [
        ["BEFORE", 1n],
        ["TFIELDS", 0n],
        ["MIDDLE", 2n],
        ["ZTABLE", true],
        ["ZFORM1", "1J"],
        ["ZCTYP1", "PIXEL"],
        ["ZTILELEN", 32n],
        ["AFTER", 3n],
      ] as const) {
        const kb = enc(key);
        if (typeof value === "bigint") {
          ll.check(ll.lib.zf_write_key_lng(handle, kb, kb.length, value, null, 0));
        } else if (typeof value === "boolean") {
          ll.check(ll.lib.zf_write_key_log(handle, kb, kb.length, value ? 1 : 0, null, 0));
        } else {
          const vb = enc(value);
          ll.check(ll.lib.zf_write_key_str(handle, kb, kb.length, vb, vb.length, null, 0));
        }
      }
    });
    const original = zf.fromBytes(source);
    let rebuilt: Uint8Array;
    try {
      expect(original.get(0).header.get("TFIELDS")).toBe(0);
      expect(zf.verify(original).filter((f) => f.severity === "error")).toEqual([]);
      original.get(0).header.set("DIRTY", true); // read-only edit forces image reconstruction
      rebuilt = original.toBytes();
    } finally {
      original.close();
    }

    const reopened = zf.fromBytes(rebuilt);
    try {
      const hdr = reopened.get(0).header;
      expect(hdr.get("TFIELDS")).toBe(0);
      expect(hdr.get("ZTABLE")).toBe(true);
      expect(hdr.get("ZFORM1")).toBe("1J");
      expect(hdr.get("ZCTYP1")).toBe("PIXEL");
      expect(hdr.get("ZTILELEN")).toBe(32);
      expect(hdr.get("DIRTY")).toBe(true);
      const keys = hdr.keys();
      const extras = ["BEFORE", "TFIELDS", "MIDDLE", "ZTABLE", "ZFORM1", "ZCTYP1", "ZTILELEN", "AFTER"];
      expect(keys.filter((key) => extras.includes(key))).toEqual(extras);
      expect(zf.verify(reopened).filter((f) => f.severity === "error")).toEqual([]);
    } finally {
      reopened.close();
    }
  });

  test("#1 detached table: user keyword + COMMENT + HISTORY survive writeTo", () => {
    const idx = Int32Array.from([10, 20, 30]);
    const hdu = zf.BinTableHDU.fromColumns([new zf.Column("INDEX", "J", { array: idx })], { name: "EVENTS" });
    hdu.header.set("OBSERVER", "Hubble", "who");
    hdu.header.set("COMMENT", "provenance note");
    hdu.header.set("HISTORY", "reduced with pipeline");
    const p = tmp.path();
    new zf.HDUList([new zf.PrimaryHDU(), hdu]).writeTo(p);
    const hdul = zf.open(p);
    try {
      const h = hdul.get(1).header;
      expect(h.get("OBSERVER")).toBe("Hubble");
      expect(h.commentOf("OBSERVER")).toBe("who");
      expect(h.comments).toContain("provenance note");
      expect(h.history).toContain("reduced with pipeline");
      // Data still round-trips, and the structural cards zf_create_tbl emits are
      // not duplicated by the re-applied user header.
      expect(asNums((hdul.get(1).data as zf.TableData).get("INDEX") as Int32Array)).toEqual([10, 20, 30]);
      expect(dup(h, "EXTNAME")).toBe(1);
      expect(dup(h, "TFORM1")).toBe(1);
      expect(dup(h, "TTYPE1")).toBe(1);
    } finally {
      hdul.close();
    }
  });

  test("#1 attached table: checksum:true on an untouched file reconstructs without dropping keys", () => {
    // Fixture: a plain table (the columns/EXTNAME path was never broken), then
    // add OBSERVER in update mode — an in-place write independent of the
    // reconstruction path, so the source provably carries the keyword.
    const src = tmp.path();
    new zf.HDUList([new zf.PrimaryHDU(), zf.BinTableHDU.fromColumns([new zf.Column("INDEX", "J", { array: Int32Array.from([1, 2, 3]) })], { name: "EVENTS" })]).writeTo(src);
    {
      const up = zf.open(src, "update");
      up.get(1).header.set("OBSERVER", "Kepler", "who");
      up.close();
    }
    const out = tmp.path();
    const ro = zf.open(src); // read-only, untouched
    try {
      expect(ro.get(1).header.get("OBSERVER")).toBe("Kepler"); // sanity: fixture carries it
      ro.writeTo(out, { checksum: true, overwrite: true }); // checksum bypasses the pristine fast path
    } finally {
      ro.close();
    }
    const chk = zf.open(out);
    try {
      expect(chk.get(1).header.get("OBSERVER")).toBe("Kepler");
      expect(chk.get(1).header.commentOf("OBSERVER")).toBe("who");
      expect(dup(chk.get(1).header, "EXTNAME")).toBe(1);
    } finally {
      chk.close();
    }
  });

  test("#7 attached compressed image: a header edit reconstructs, keeps EXTNAME, and does not duplicate Z* cards", () => {
    const ramp = new zf.FitsArray(fill(new Int32Array(256), (i) => i), [16, 16]);
    const src = tmp.path();
    new zf.HDUList([new zf.PrimaryHDU(), new zf.CompImageHDU({ data: ramp, compression: "RICE_1", name: "COMP" })]).writeTo(src);
    const out = tmp.path();
    const hl = zf.open(src);
    hl.get(1).header.set("MYKEY", 7); // read-only edit → dirty → reconstruction
    hl.writeTo(out, { overwrite: true });
    hl.close();
    const chk = zf.open(out);
    try {
      const h = chk.get(1).header;
      expect(h.get("MYKEY")).toBe(7); // the edit survives reconstruction
      expect(chk.get(1).name).toBe("COMP"); // EXTNAME preserved (no manual block needed)
      expect(dup(h, "ZCMPTYPE")).toBe(1); // the ZIMAGE-convention cards are not re-emitted
      const got = chk.get(1).data as zf.FitsArray; // still a decompressable image
      expect(got.shape).toEqual([16, 16]);
      expect(asNums(got.data)).toEqual(asNums(ramp.data));
    } finally {
      chk.close();
    }
  });

  test("#7 detached compressed image: a header keyword survives writeTo", () => {
    const ramp = new zf.FitsArray(fill(new Int32Array(256), (i) => i), [16, 16]);
    const hdr = new zf.Header();
    hdr.set("BUNIT", "adu", "brightness unit");
    const p = tmp.path();
    new zf.HDUList([new zf.PrimaryHDU(), new zf.CompImageHDU({ data: ramp, compression: "RICE_1", header: hdr, name: "COMP" })]).writeTo(p);
    const hdul = zf.open(p);
    try {
      const h = hdul.get(1).header;
      expect(h.get("BUNIT")).toBe("adu");
      expect(h.commentOf("BUNIT")).toBe("brightness unit");
      expect(hdul.get(1).name).toBe("COMP");
      expect(dup(h, "ZCMPTYPE")).toBe(1);
    } finally {
      hdul.close();
    }
  });

  test("stale CHECKSUM/DATASUM are dropped on checksum:false reconstruction (verify stays clean)", () => {
    // A checksummed table file; an unrelated header edit then forces the
    // reconstruction path with checksum:false (the default). The source's
    // per-HDU CHECKSUM/DATASUM describe the original bytes and must not be
    // carried forward — a copied one no longer verifies.
    const src = tmp.path();
    new zf.HDUList([
      new zf.PrimaryHDU(),
      zf.BinTableHDU.fromColumns([new zf.Column("INDEX", "J", { array: Int32Array.from([1, 2, 3]) })], { name: "EVENTS" }),
    ]).writeTo(src, { checksum: true });
    expect(zf.verify(src).filter((f) => f.severity === "error")).toEqual([]); // sanity: source is clean

    const out = tmp.path();
    const hl = zf.open(src);
    hl.get(1).header.set("OBSERVER", "Rubin"); // edit → dirty → reconstruction
    hl.writeTo(out, { overwrite: true }); // checksum:false (default)
    hl.close();

    const chk = zf.open(out);
    try {
      expect(chk.get(1).header.keys()).not.toContain("CHECKSUM"); // stale card not copied
      expect(chk.get(1).header.keys()).not.toContain("DATASUM");
      expect(chk.get(1).header.get("OBSERVER")).toBe("Rubin"); // the edit still survives
    } finally {
      chk.close();
    }
    expect(zf.verify(out).filter((f) => f.severity === "error")).toEqual([]); // no invalid-checksum error
  });
});

// ════════════════════════════════════════════════════════════════════════════
// 2026-07-07: BUGHUNT-2026-07-06 item 4 (TS sibling) — flush()/close() must
// persist structural HDUList mutations (insert/delete/reorder), not just pure
// appends. Shifted attached HDUs travel as exact byte copies (zf_copy_hdu) so
// keywords/VLA heaps/compression bytes survive verbatim. Mirrors the Python
// structural-flush section of test_bugfixes.py.
// ════════════════════════════════════════════════════════════════════════════
describe("structural flush reconcile (insert/delete/reorder persist)", () => {
  const threeHduFile = (): string => {
    const p = tmp.path();
    new zf.HDUList([
      new zf.PrimaryHDU({ data: fill(new Int16Array(4), (i) => i) }),
      new zf.ImageHDU({ data: fill(new Int16Array(6), (i) => i), name: "A" }),
      new zf.ImageHDU({ data: fill(new Int32Array(8), (i) => i), name: "B" }),
    ]).writeTo(p);
    return p;
  };
  const names = (hl: zf.HDUList): string[] => [...hl].map((h) => h.name);
  const withOpen = <T>(p: string, fn: (hl: zf.HDUList) => T): T => {
    const hl = zf.open(p);
    try {
      return fn(hl);
    } finally {
      hl.close();
    }
  };

  test("insert persists on close", () => {
    const p = threeHduFile();
    const hl = zf.open(p, "update");
    hl.hdus.splice(1, 0, new zf.ImageHDU({ data: fill(new Float32Array(3), (i) => i), name: "NEW" }));
    hl.close();
    withOpen(p, (chk) => {
      expect(names(chk)).toEqual(["PRIMARY", "NEW", "A", "B"]);
      expect(asNums((chk.get("NEW").data as zf.FitsArray).data)).toEqual([0, 1, 2]);
      expect(asNums((chk.get("A").data as zf.FitsArray).data)).toEqual([0, 1, 2, 3, 4, 5]);
      expect(asNums((chk.get("B").data as zf.FitsArray).data)).toEqual([0, 1, 2, 3, 4, 5, 6, 7]);
    });
  });

  test("delete persists on close", () => {
    const p = threeHduFile();
    const hl = zf.open(p, "update");
    hl.hdus.splice(1, 1);
    hl.close();
    withOpen(p, (chk) => {
      expect(names(chk)).toEqual(["PRIMARY", "B"]);
      expect(asNums((chk.get("B").data as zf.FitsArray).data)).toEqual([0, 1, 2, 3, 4, 5, 6, 7]);
    });
  });

  test("deleting the last HDU only truncates (head bytes untouched)", () => {
    const p = threeHduFile();
    const before = readFileSync(p);
    const hl = zf.open(p, "update");
    hl.hdus.pop();
    hl.close();
    const after = readFileSync(p);
    expect(after.length).toBeLessThan(before.length);
    expect(before.subarray(0, after.length).equals(after)).toBe(true);
    withOpen(p, (chk) => expect(names(chk)).toEqual(["PRIMARY", "A"]));
  });

  test("reorder persists on close", () => {
    const p = threeHduFile();
    const hl = zf.open(p, "update");
    [hl.hdus[1], hl.hdus[2]] = [hl.hdus[2], hl.hdus[1]];
    hl.close();
    withOpen(p, (chk) => {
      expect(names(chk)).toEqual(["PRIMARY", "B", "A"]);
      expect(asNums((chk.get(1).data as zf.FitsArray).data)).toEqual([0, 1, 2, 3, 4, 5, 6, 7]);
    });
  });

  test("shifted table keeps user keywords, TSCAL, and VLA heap (byte-copy route)", () => {
    // The reconstruct route would drop the keywords and raise on the scaled
    // column — this proves the exact-byte-copy route is taken for shifted HDUs.
    const p = tmp.path();
    const cols = [
      new zf.Column("A", "1J", { array: Int32Array.from([1, 2, 3]) }),
      new zf.Column("V", "1PJ", { array: [Int32Array.from([1]), Int32Array.from([2, 3]), new Int32Array(0)] }),
    ];
    new zf.HDUList([new zf.PrimaryHDU(), zf.BinTableHDU.fromColumns(cols, { name: "T" })]).writeTo(p);
    let hl = zf.open(p, "update");
    hl.get(1).header.set("OBSNOTE", "keepme");
    hl.get(1).header.set("TSCAL1", 2.5); // makes the column unreconstructable via _writeTo
    hl.close();
    hl = zf.open(p, "update");
    hl.hdus.splice(1, 0, new zf.ImageHDU({ data: new Int16Array(2), name: "NEW" }));
    hl.close();
    withOpen(p, (chk) => {
      expect(names(chk)).toEqual(["PRIMARY", "NEW", "T"]);
      expect(chk.get(2).header.get("OBSNOTE")).toBe("keepme");
      expect(Number(chk.get(2).header.get("TSCAL1"))).toBe(2.5);
      const v = (chk.get(2).data as zf.TableData).get("V") as ArrayLike<unknown>[];
      expect(asNums(v[1] as Int32Array)).toEqual([2, 3]);
    });
  });

  test("shifted quantized CompImage bytes survive exactly (no requantization)", () => {
    const p = tmp.path();
    const data = new zf.FitsArray(fill(new Float32Array(64), (i) => i * 1.37 + 0.1), [8, 8]);
    new zf.HDUList([
      new zf.PrimaryHDU(),
      new zf.CompImageHDU({ data, compression: "RICE_1", quantize: "SUBTRACTIVE_DITHER_1" }),
    ]).writeTo(p);
    const before = readFileSync(p);
    const compBlock = before.subarray(2880); // empty primary is exactly one block
    const hl = zf.open(p, "update");
    hl.hdus.splice(1, 0, new zf.ImageHDU({ data: new Int16Array(2), name: "NEW" }));
    hl.close();
    const after = readFileSync(p);
    expect(after.subarray(after.length - compBlock.length).equals(compBlock)).toBe(true);
    withOpen(p, (chk) => {
      expect(chk.length).toBe(3); // ...and the insert really landed
      expect(chk.get(1).name).toBe("NEW");
      expect((chk.get(2).data as zf.FitsArray).shape).toEqual([8, 8]); // shifted comp still decodes
    });
  });

  test("header + in-place data edits on a shifted HDU both persist", () => {
    const p = threeHduFile();
    const hl = zf.open(p, "update");
    hl.get("A").header.set("NEWKEY", 5);
    ((hl.get("A").data as zf.FitsArray).data as Int16Array)[0] = 42;
    hl.hdus.splice(1, 0, new zf.ImageHDU({ data: new Int16Array(2), name: "NEW" }));
    hl.close();
    withOpen(p, (chk) => {
      expect(names(chk)).toEqual(["PRIMARY", "NEW", "A", "B"]);
      expect(chk.get("A").header.get("NEWKEY")).toBe(5);
      expect((chk.get("A").data as zf.FitsArray).data[0]).toBe(42);
    });
  });

  test("foreign HDU (attached to another open file) persists on flush", () => {
    const p1 = threeHduFile();
    const p2 = tmp.path();
    new zf.HDUList([
      new zf.PrimaryHDU(),
      new zf.ImageHDU({ data: fill(new Int32Array(5), (i) => i), name: "DONOR" }),
    ]).writeTo(p2);
    const other = zf.open(p2);
    const hl = zf.open(p1, "update");
    try {
      hl.append(other.get(1));
      hl.close();
    } finally {
      other.close();
    }
    withOpen(p1, (chk) => {
      expect(chk.get(3).name).toBe("DONOR");
      expect(asNums((chk.get(3).data as zf.FitsArray).data)).toEqual([0, 1, 2, 3, 4]);
    });
  });

  test("mid-append failure restores the file; corrected retry flushes cleanly", () => {
    // Complex VLA columns are unwritable — the failure fires AFTER zf_create_tbl,
    // so the count-driven rollback must remove the partially-built HDU.
    const p = threeHduFile();
    const before = readFileSync(p);
    const bad = zf.BinTableHDU.fromColumns(
      [new zf.Column("C", "1PC", { array: [Float32Array.from([1, 2])] })],
      { name: "BAD" },
    );
    const hl = zf.open(p, "update");
    hl.hdus.splice(1, 0, bad);
    expect(() => hl.flush()).toThrow(zf.NotSupportedError);
    expect(readFileSync(p).equals(before)).toBe(true); // partial tail rolled back
    hl.hdus[1] = new zf.ImageHDU({ data: fill(new Int16Array(3), (i) => i), name: "GOOD" });
    hl.close();
    withOpen(p, (chk) => expect(names(chk)).toEqual(["PRIMARY", "GOOD", "A", "B"]));
  });

  const primaryMutations: [string, (hl: zf.HDUList) => void][] = [
    ["insert at 0", (hl) => hl.hdus.splice(0, 0, new zf.PrimaryHDU({ data: new Int16Array(2) }))],
    ["delete primary", (hl) => hl.hdus.splice(0, 1)],
    ["reverse", (hl) => void hl.hdus.reverse()],
  ];
  for (const [label, mutate] of primaryMutations) {
    test(`primary-slot change fails loud, file intact: ${label}`, () => {
      const p = threeHduFile();
      const before = readFileSync(p);
      const hl = zf.open(p, "update");
      mutate(hl);
      expect(() => hl.close()).toThrow(zf.NotSupportedError);
      expect(readFileSync(p).equals(before)).toBe(true);
    });
  }

  test("aliased HDU object (same object at two positions) fails loud", () => {
    const p = threeHduFile();
    const before = readFileSync(p);
    const hl = zf.open(p, "update");
    hl.append(hl.get(1));
    expect(() => hl.close()).toThrow(zf.FitsTypeError);
    expect(readFileSync(p).equals(before)).toBe(true);
  });

  test("compressed HDU with replaced data + structural change raises BEFORE restructuring", () => {
    const p = tmp.path();
    const img = new zf.FitsArray(fill(new Int16Array(16), (i) => i), [4, 4]);
    new zf.HDUList([
      new zf.PrimaryHDU(),
      new zf.CompImageHDU({ data: img, compression: "RICE_1" }),
      new zf.ImageHDU({ data: new Int16Array(2), name: "A" }),
    ]).writeTo(p);
    const before = readFileSync(p);
    const hl = zf.open(p, "update");
    const doubled = (hl.get(1).data as zf.FitsArray).clone();
    (doubled.data as Int16Array).forEach((v, i) => ((doubled.data as Int16Array)[i] = v * 2));
    (hl.get(1) as zf.CompImageHDU).data = doubled;
    hl.hdus.splice(2, 1);
    expect(() => hl.close()).toThrow(zf.NotSupportedError);
    expect(readFileSync(p).equals(before)).toBe(true);
  });

  test("double flush is idempotent (second takes the no-op fast path)", () => {
    // The wasm handle's device is in RAM (the disk file is only written back on
    // close), so idempotence is asserted on the handle's own bytes.
    const p = threeHduFile();
    const hl = zf.open(p, "update");
    hl.hdus.splice(1, 0, new zf.ImageHDU({ data: fill(new Float32Array(3), (i) => i), name: "NEW" }));
    hl.flush();
    const first = Buffer.from(hl._sourceBytes());
    const parsed = zf.fromBytes(first);
    try {
      expect(names(parsed)).toEqual(["PRIMARY", "NEW", "A", "B"]);
    } finally {
      parsed.close();
    }
    hl.flush();
    expect(Buffer.from(hl._sourceBytes()).equals(first)).toBe(true);
    hl.close();
    expect(readFileSync(p).equals(first)).toBe(true); // close() wrote exactly those bytes back
  });

  test("fromBytes update-mode reconcile makes the handle pristine again", () => {
    const p = threeHduFile();
    const hl = zf.fromBytes(readFileSync(p), "update");
    hl.hdus.splice(1, 0, new zf.ImageHDU({ data: fill(new Int16Array(3), (i) => i), name: "NEW" }));
    hl.flush();
    expect(hl._isPristineAttached()).toBe(true); // handle bytes now match the list
    const out = hl.toBytes(); // ...so this is the verbatim byte-copy path
    hl.close();
    const parsed = zf.fromBytes(out);
    try {
      expect(names(parsed)).toEqual(["PRIMARY", "NEW", "A", "B"]);
    } finally {
      parsed.close();
    }
  });

  test("foreign checksummed HDU drops stale CHECKSUM on flush (reconstruct route)", () => {
    // Review follow-up (PR #29): a foreign HDU serialized through the reconstruct
    // path must not carry its source file's CHECKSUM/DATASUM — those describe the
    // ORIGINAL bytes and would no longer verify. (Byte-copied shifted HDUs keep
    // theirs, which stay valid.)
    const p1 = threeHduFile();
    const p2 = tmp.path();
    new zf.HDUList([
      new zf.PrimaryHDU(),
      new zf.ImageHDU({ data: fill(new Int32Array(5), (i) => i), name: "D" }),
    ]).writeTo(p2, { checksum: true });
    const other = zf.open(p2);
    const hl = zf.open(p1, "update");
    try {
      expect(other.get(1).header.get("CHECKSUM")).toBeDefined(); // donor really is checksummed
      hl.append(other.get(1));
      hl.close();
    } finally {
      other.close();
    }
    withOpen(p1, (chk) => {
      expect(chk.get(3).header.get("CHECKSUM")).toBeUndefined(); // stale card dropped, not copied
      expect(chk.get(3).header.get("DATASUM")).toBeUndefined();
    });
    expect(zf.verify(p1).filter((f) => f.severity === "error")).toEqual([]);
  });

  test("non-HDU at the primary slot raises FitsTypeError, not the primary-first error", () => {
    const p = threeHduFile();
    const before = readFileSync(p);
    const hl = zf.open(p, "update");
    hl.hdus[0] = "not an hdu" as unknown as zf.PrimaryHDU;
    expect(() => hl.close()).toThrow(zf.FitsTypeError);
    expect(readFileSync(p).equals(before)).toBe(true);
  });

  test("writeTo of an unflushed structural list leaves the source intact", () => {
    const p = threeHduFile();
    const out = tmp.path();
    const before = readFileSync(p);
    const hl = zf.open(p, "update");
    hl.hdus.splice(1, 0, new zf.ImageHDU({ data: fill(new Int16Array(3), (i) => i), name: "NEW" }));
    hl.writeTo(out, { overwrite: true });
    expect(readFileSync(p).equals(before)).toBe(true); // source untouched so far
    hl.close(); // now the structural change lands
    withOpen(out, (chk) => expect(names(chk)).toEqual(["PRIMARY", "NEW", "A", "B"]));
    withOpen(p, (chk) => expect(names(chk)).toEqual(["PRIMARY", "NEW", "A", "B"]));
  });
});

// BUGHUNT-2026-07-06 HIGH #6: repeated header COMMENT/HISTORY sets overwrote in
// place (in memory) and persisted a malformed valued `COMMENT = 'text'` card,
// silently dropping provenance. Commentary must accumulate, wrap >72 chars, and
// support a mutable view — mirroring the Python fix.
describe("commentary cards accumulate and persist (BUGHUNT #6)", () => {
  const img = (): zf.FitsArray => new zf.FitsArray(fill(new Int16Array(4), () => 1), [2, 2]);
  const read = <T>(p: string, fn: (hl: zf.HDUList) => T): T => {
    const hl = zf.open(p);
    try {
      return fn(hl);
    } finally {
      hl.close();
    }
  };
  const update = (p: string, fn: (hl: zf.HDUList) => void): void => {
    const hl = zf.open(p, "update");
    try {
      fn(hl);
    } finally {
      hl.close();
    }
  };

  test("detached: repeated COMMENT/HISTORY accumulate through writeTo", () => {
    const hdu = new zf.PrimaryHDU({ data: img() });
    hdu.header.set("COMMENT", "first note");
    hdu.header.set("COMMENT", "second note");
    hdu.header.addHistory("step 1");
    hdu.header.addHistory("step 2");
    expect(hdu.header.comments).toEqual(["first note", "second note"]);
    expect(hdu.header.history).toEqual(["step 1", "step 2"]);
    expect(hdu.header.keys().includes("COMMENT")).toBe(false);
    const p = tmp.path();
    new zf.HDUList([hdu]).writeTo(p);
    read(p, (hl) => {
      expect(hl.get(0).header.comments).toEqual(["first note", "second note"]);
      expect(hl.get(0).header.history).toEqual(["step 1", "step 2"]);
    });
  });

  test("update mode: eager commentary writes accumulate; no malformed valued card", () => {
    const p = tmp.path();
    zf.writeTo(p, new zf.FitsArray(new Float32Array(9), [3, 3]));
    update(p, (hl) => {
      hl.get(0).header.set("COMMENT", "a");
      hl.get(0).header.set("COMMENT", "b");
      hl.get(0).header.addHistory("h1");
    });
    read(p, (hl) => {
      expect(hl.get(0).header.comments).toEqual(["a", "b"]);
      expect(hl.get(0).header.history).toEqual(["h1"]);
    });
    expect(readFileSync(p).includes(Buffer.from("COMMENT = '"))).toBe(false);
  });

  test("long commentary text wraps into ≤72-char cards", () => {
    const long = "x".repeat(100);
    const hdu = new zf.PrimaryHDU({ data: img() });
    hdu.header.set("COMMENT", long);
    expect(hdu.header.comments).toEqual([long.slice(0, 72), long.slice(72)]);
    const p = tmp.path();
    new zf.HDUList([hdu]).writeTo(p);
    read(p, (hl) => {
      const chunks = hl.get(0).header.comments;
      expect(chunks.every((c) => c.length <= 72)).toBe(true);
      expect(chunks.join("")).toBe(long);
    });
  });

  test("mutable view in-place edit, replace-all, and delete-all persist in update mode", () => {
    const p = tmp.path();
    zf.writeTo(p, new zf.FitsArray(new Float32Array(9), [3, 3]));
    update(p, (hl) => {
      const hdr = hl.get(0).header;
      hdr.addComment("one");
      hdr.addComment("two");
      const v = hdr.commentary("COMMENT");
      expect(v.length).toBe(2);
      expect(v.toArray()).toEqual(["one", "two"]);
      v.setAt(0, "ONE");
    });
    read(p, (hl) => expect(hl.get(0).header.comments).toEqual(["ONE", "two"]));
    update(p, (hl) => hl.get(0).header.set("COMMENT", ["x", "y", "z"]));
    read(p, (hl) => expect(hl.get(0).header.comments).toEqual(["x", "y", "z"]));
    update(p, (hl) => hl.get(0).header.delete("COMMENT"));
    read(p, (hl) => expect(hl.get(0).header.comments).toEqual([]));
  });

  test("blank-keyword ('') commentary append/edit/delete persist in update mode (finding 1)", () => {
    const p = tmp.path();
    zf.writeTo(p, new zf.FitsArray(new Float32Array(9), [3, 3]));
    const blanks = (hdr: zf.Header): zf.HeaderValue[] =>
      hdr.cards().filter(([kw]) => kw === "").map(([, v]) => v);
    update(p, (hl) => {
      hl.get(0).header.set("", "blank one");
      hl.get(0).header.set("", "blank two");
    });
    read(p, (hl) => expect(blanks(hl.get(0).header)).toEqual(["blank one", "blank two"]));
    update(p, (hl) => hl.get(0).header.commentary("").setAt(0, "EDITED"));
    read(p, (hl) => expect(blanks(hl.get(0).header)).toEqual(["EDITED", "blank two"]));
    update(p, (hl) => hl.get(0).header.delete(""));
    read(p, (hl) => expect(blanks(hl.get(0).header)).toEqual([]));
  });
});

describe("flat plain arrays on vector columns count rows by repeat (BUGHUNT 61)", () => {
  const tableBytes = (col: zf.Column): Uint8Array =>
    new zf.HDUList([new zf.PrimaryHDU(), zf.BinTableHDU.fromColumns([col])]).toBytes();

  test("flat plain number[] on '3J' makes 2 rows, not 6", () => {
    const src = tableBytes(new zf.Column("V", "3J", { array: [1, 2, 3, 4, 5, 6] }));
    const hl = zf.fromBytes(src);
    try {
      const rec = hl.get(1).data as zf.TableData;
      expect(rec.nrows).toBe(2);
      expect(asNums(rec.row(0).V as zf.TypedArray)).toEqual([1, 2, 3]);
      expect(asNums(rec.row(1).V as zf.TypedArray)).toEqual([4, 5, 6]);
    } finally {
      hl.close();
    }
  });

  test("plain-array and TypedArray spellings of a vector column are byte-identical", () => {
    const plain = tableBytes(new zf.Column("V", "3J", { array: [1, 2, 3, 4, 5, 6] }));
    const typed = tableBytes(new zf.Column("V", "3J", { array: Int32Array.from([1, 2, 3, 4, 5, 6]) }));
    expect(plain).toEqual(typed);
  });

  test("flat plain interleaved floats on complex '3C' count re/im pairs per row", () => {
    const src = tableBytes(new zf.Column("C", "3C", { array: [1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12] }));
    const hl = zf.fromBytes(src);
    try {
      const rec = hl.get(1).data as zf.TableData;
      expect(rec.nrows).toBe(2);
      expect(asNums(rec.complex("C"))).toEqual([1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12]);
    } finally {
      hl.close();
    }
  });

  test("flat plain bits on '8X' count one row per 8 elements", () => {
    const src = tableBytes(new zf.Column("B", "8X", { array: [1, 0, 1, 0, 1, 0, 1, 0] }));
    const hl = zf.fromBytes(src);
    try {
      const rec = hl.get(1).data as zf.TableData;
      expect(rec.nrows).toBe(1);
      expect(asNums(rec.get("B") as Uint8Array)).toEqual([1, 0, 1, 0, 1, 0, 1, 0]);
    } finally {
      hl.close();
    }
  });

  test("a flat length that is not a multiple of the repeat fails loud", () => {
    expect(() => zf.BinTableHDU.fromColumns([new zf.Column("V", "3J", { array: [1, 2, 3, 4, 5] })])).toThrow(
      RangeError,
    );
    expect(() =>
      zf.BinTableHDU.fromColumns([new zf.Column("V", "3J", { array: Int32Array.from([1, 2, 3, 4, 5]) })]),
    ).toThrow(RangeError);
  });

  test("unaffected shapes keep their row counts", () => {
    const nrowsOf = (col: zf.Column): number => {
      const hl = zf.fromBytes(tableBytes(col));
      try {
        return (hl.get(1).data as zf.TableData).nrows;
      } finally {
        hl.close();
      }
    };
    expect(nrowsOf(new zf.Column("S", "1J", { array: [1, 2, 3] }))).toBe(3); // scalar plain
    expect(nrowsOf(new zf.Column("N", "3J", { array: [[1, 2, 3], [4, 5, 6]] }))).toBe(2); // rows-of-arrays
    expect(nrowsOf(new zf.Column("T", "10A", { array: ["a", "bb"] }))).toBe(2); // strings
    expect(nrowsOf(new zf.Column("L", "1L", { array: [true, false] }))).toBe(2); // scalar logical
    // rows-of-arrays and the flat spelling of the same data are byte-identical
    expect(tableBytes(new zf.Column("V", "3J", { array: [[1, 2, 3], [4, 5, 6]] }))).toEqual(
      tableBytes(new zf.Column("V", "3J", { array: [1, 2, 3, 4, 5, 6] })),
    );
    // an empty plain array is an empty table
    const hl = zf.fromBytes(tableBytes(new zf.Column("E", "3J", { array: [] })));
    try {
      expect((hl.get(1).data as zf.TableData).nrows).toBe(0);
    } finally {
      hl.close();
    }
  });
});

// ── BUGHUNT-2026-07-06 #47: hostile Z* geometry must throw, never trap the wasm module ───────
describe("zf_img_param hostile Z* geometry (finding 47)", () => {
  /** A binary table posing as a tile-compressed image (ZIMAGE=T) with the given Z* integers. */
  function zimageBytes(zkeys: Record<string, bigint>): Uint8Array {
    return bytesFrom((handle) => {
      ll.check(ll.lib.zf_create_img(handle, 8, 0, null));
      ll.check(ll.lib.zf_create_tbl(handle, ll.BINARY_TBL, 1n, 1, ["COMPRESSED_DATA"], ["1J"], null, null));
      const zi = enc("ZIMAGE");
      ll.check(ll.lib.zf_write_key_log(handle, zi, zi.length, 1, null, 0));
      for (const [name, val] of Object.entries(zkeys)) {
        const kb = enc(name);
        ll.check(ll.lib.zf_write_key_lng(handle, kb, kb.length, val, null, 0));
      }
    });
  }

  test("ZBITPIX outside i32 throws instead of trapping", () => {
    const hl = zf.fromBytes(zimageBytes({ ZBITPIX: 1n << 40n }));
    const hdu = hl.get(1);
    expect(hdu).toBeInstanceOf(zf.CompImageHDU);
    expect(() => (hdu as zf.CompImageHDU).shape).toThrow(zf.FitsError);
  });

  test("in-range but illegal ZBITPIX throws", () => {
    const hl = zf.fromBytes(zimageBytes({ ZBITPIX: 7n }));
    expect(() => (hl.get(1) as zf.CompImageHDU).shape).toThrow(zf.FitsError);
  });

  test("negative ZNAXISn throws", () => {
    const hl = zf.fromBytes(zimageBytes({ ZBITPIX: 16n, ZNAXIS: 1n, ZNAXIS1: -5n }));
    expect(() => (hl.get(1) as zf.CompImageHDU).shape).toThrow(zf.FitsCompressError);
  });

  test("out-of-range ZNAXIS throws instead of silently reporting zero axes", () => {
    const hl = zf.fromBytes(zimageBytes({ ZBITPIX: 16n, ZNAXIS: 5000n }));
    expect(() => (hl.get(1) as zf.CompImageHDU).shape).toThrow(zf.FitsCompressError);
  });

  test("ZNAXISn above the wasm32 c_long range throws (the i32 ABI cannot represent it)", () => {
    const hl = zf.fromBytes(zimageBytes({ ZBITPIX: 16n, ZNAXIS: 1n, ZNAXIS1: 1n << 33n }));
    expect(() => (hl.get(1) as zf.CompImageHDU).shape).toThrow(zf.FitsError);
  });
});

describe("malformed gzip tiles (BUGHUNT 49)", () => {
  const malformedGzip = Uint8Array.from([
    0x1f, 0x8b, 0x08, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xff,
    0x03, 0x02, 0x00,
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
  ]);

  function malformedZimageBytes(codec: string, fallback: boolean): Uint8Array {
    return bytesFrom((handle) => {
      const names = fallback ? ["COMPRESSED_DATA", "GZIP_COMPRESSED_DATA"] : ["COMPRESSED_DATA"];
      ll.check(ll.lib.zf_create_img(handle, 8, 0, null));
      ll.check(ll.lib.zf_create_tbl_heap(
        handle, ll.BINARY_TBL, 1n, names.length, names, names.map(() => "1PB"), null, null,
        BigInt(malformedGzip.length),
      ));
      const table = ll.outU64();
      ll.check(ll.lib.zf_table_open(handle, table));
      try {
        ll.check(ll.lib.zf_write_col_vla(
          table[0], ll.ZF_UINT8, fallback ? 1 : 0, 1n, malformedGzip, BigInt(malformedGzip.length),
        ));
      } finally {
        ll.lib.zf_table_close(table[0]);
      }
      const zimage = enc("ZIMAGE");
      ll.check(ll.lib.zf_write_key_log(handle, zimage, zimage.length, 1, null, 0));
      const zcmptype = enc("ZCMPTYPE");
      ll.check(ll.lib.zf_write_key_str(handle, zcmptype, zcmptype.length, enc(codec), codec.length, null, 0));
      for (const [name, value] of [["ZBITPIX", 16n], ["ZNAXIS", 1n], ["ZNAXIS1", 1n], ["ZTILE1", 1n]] as const) {
        const key = enc(name);
        ll.check(ll.lib.zf_write_key_lng(handle, key, key.length, value, null, 0));
      }
    });
  }

  test("GZIP_1, GZIP_2, and the gzip fallback throw status 414 instead of trapping", () => {
    for (const [codec, fallback] of [["GZIP_1", false], ["GZIP_2", false], ["GZIP_1", true]] as const) {
      const hl = zf.fromBytes(malformedZimageBytes(codec, fallback));
      try {
        let caught: unknown;
        try {
          void (hl.get(1) as zf.CompImageHDU).data;
        } catch (err) {
          caught = err;
        }
        expect(caught).toBeInstanceOf(zf.FitsCompressError);
        expect((caught as zf.FitsError).status).toBe(414);
      } finally {
        hl.close();
      }
    }
  });
});

describe("undefined header values (finding 13)", () => {
  test("null value writes an undefined card and round-trips", () => {
    const h = new zf.Header();
    h.set("UNDEF", null, "no value");
    const raw = new zf.HDUList([new zf.PrimaryHDU({ header: h })]).toBytes();
    // astropy's compact undefined form: blank value field, then `/ comment`.
    expect(new TextDecoder().decode(raw)).toContain("UNDEF   =  / no value");
    const hl = zf.fromBytes(raw);
    try {
      const hh = hl.get(0).header;
      expect(hh.get("UNDEF")).toBeNull();
      expect(hh.commentOf("UNDEF")).toBe("no value");
    } finally {
      hl.close();
    }
  });

  test("update-mode set and reconstruction preserve the undefined card", () => {
    const p = tmp.path();
    zf.writeTo(p, new zf.FitsArray(Int32Array.from([1, 2, 3, 4]), [2, 2]));
    const hl = zf.open(p, "update");
    try {
      hl.get(0).header.set("UNDEF2", null, "cleared");
    } finally {
      hl.close();
    }
    const hl2 = zf.open(p);
    let copy: Uint8Array;
    try {
      expect(hl2.get(0).header.get("UNDEF2")).toBeNull();
      expect(hl2.get(0).header.commentOf("UNDEF2")).toBe("cleared");
      hl2.get(0).header.set("OTHER", 1); // read-only edit → writeTo reconstructs every card
      copy = hl2.toBytes();
    } finally {
      hl2.close();
    }
    const hl3 = zf.fromBytes(copy);
    try {
      expect(hl3.get(0).header.get("UNDEF2")).toBeNull();
      expect(hl3.get(0).header.commentOf("UNDEF2")).toBe("cleared");
    } finally {
      hl3.close();
    }
  });
});

describe("data = null clears the HDU (finding 14)", () => {
  test("image clear sticks and writeTo/toBytes emit an empty HDU", () => {
    const p = tmp.path();
    zf.writeTo(p, new zf.FitsArray(Int32Array.from([0, 1, 2, 3, 4, 5]), [2, 3]));

    const out = tmp.path();
    const hl = zf.open(p);
    try {
      hl.get(0).data = null;
      expect(hl.get(0).data).toBeNull(); // the assignment sticks; no lazy re-read
      hl.writeTo(out, { overwrite: true });
    } finally {
      hl.close();
    }
    const reread = zf.open(out);
    try {
      expect(reread.get(0).data).toBeNull();
      expect(reread.get(0).header.get("NAXIS")).toBe(0);
    } finally {
      reread.close();
    }

    const hl2 = zf.open(p);
    let blob: Uint8Array;
    try {
      hl2.get(0).data = null;
      blob = hl2.toBytes();
    } finally {
      hl2.close();
    }
    const hl3 = zf.fromBytes(blob);
    try {
      expect(hl3.get(0).data).toBeNull();
    } finally {
      hl3.close();
    }
  });

  test("update-mode clear fails loud and leaves the file intact", () => {
    const p = tmp.path();
    zf.writeTo(p, new zf.FitsArray(Int32Array.from([0, 1, 2, 3, 4, 5]), [2, 3]));
    const before = readFileSync(p);
    const hl = zf.open(p, "update");
    hl.get(0).data = null;
    expect(() => hl.close()).toThrow(zf.NotSupportedError);
    expect(readFileSync(p).equals(before)).toBe(true);

    // Regression guards: reading an ALREADY-empty HDU's data (null), or clearing
    // it, is not an update-mode error — there is nothing on disk to clear.
    const pe = tmp.path();
    new zf.HDUList([new zf.PrimaryHDU()]).writeTo(pe, { overwrite: true });
    const h1 = zf.open(pe, "update");
    try {
      expect(h1.get(0).data).toBeNull();
    } finally {
      h1.close();
    }
    const h2 = zf.open(pe, "update");
    h2.get(0).data = null;
    h2.close(); // no throw
  });

  test("table clear empties on writeTo and fails loud in update mode", () => {
    const p = tmp.path();
    new zf.HDUList([
      new zf.PrimaryHDU(),
      zf.BinTableHDU.fromColumns([new zf.Column("X", "J", { array: Int32Array.from([1, 2, 3, 4]) })], { name: "T" }),
    ]).writeTo(p, { overwrite: true });

    const out = tmp.path();
    const hl = zf.open(p);
    try {
      hl.table(1).data = null;
      expect(hl.table(1).data).toBeNull();
      hl.writeTo(out, { overwrite: true });
    } finally {
      hl.close();
    }
    const reread = zf.open(out);
    try {
      expect(reread.get(1).header.get("TFIELDS")).toBe(0);
      expect(reread.get(1).header.get("NAXIS2")).toBe(0);
    } finally {
      reread.close();
    }

    const before = readFileSync(p);
    const h = zf.open(p, "update");
    h.table(1).data = null;
    expect(() => h.close()).toThrow(zf.NotSupportedError);
    expect(readFileSync(p).equals(before)).toBe(true);
  });

  test("section() on a pending clear fails loud in update mode (review follow-up)", () => {
    const p = tmp.path();
    zf.writeTo(p, new zf.FitsArray(Int32Array.from([0, 1, 2, 3, 4, 5]), [2, 3]));

    // Update mode: a pending clear cannot be flushed, so section() cannot honor its
    // "consistent with .data" promise — it throws like a pending geometry change.
    const hl = zf.open(p, "update");
    const orig = hl.image(0).data!;
    hl.image(0).data = null;
    expect(() =>
      hl.image(0).section({
        window: [
          [0, 1],
          [0, 2],
        ],
      }),
    ).toThrow(zf.NotSupportedError);
    hl.image(0).data = orig; // unblock close()
    hl.close();

    // Read-only mode: in-memory edits (including a clear) are documented as not visible
    // to section(), which reads the file as opened.
    const ro = zf.open(p);
    try {
      ro.image(0).data = null;
      const sec = ro.image(0).section({
        window: [
          [0, 1],
          [0, 2],
        ],
      });
      expect(asNums(sec.data)).toEqual([0, 1]);
    } finally {
      ro.close();
    }
  });
});

describe("table data validation + detached TableData writes (finding 15)", () => {
  test("non-TableData assignment throws instead of writing an empty table", () => {
    const hdu = new zf.BinTableHDU();
    expect(() => {
      (hdu as { data: unknown }).data = new Int32Array(5);
    }).toThrow(zf.FitsTypeError);
    expect(() => new zf.BinTableHDU({ data: new Int32Array(5) as unknown as zf.TableData })).toThrow(
      zf.FitsTypeError,
    );
  });

  test("detached BinTableHDU with TableData serializes its rows", () => {
    const cols = new Map<string, zf.ColumnData>([
      ["A", { kind: "numeric", dtype: "i4", repeat: 1, values: Int32Array.from([1, 2, 3]) }],
      ["B", { kind: "numeric", dtype: "f8", repeat: 1, values: Float64Array.from([0.5, 1.5, 2.5]) }],
    ]);
    const hdu = new zf.BinTableHDU({ data: new zf.TableData(["A", "B"], cols, 3), name: "D" });
    const blob = new zf.HDUList([new zf.PrimaryHDU(), hdu]).toBytes();
    const hl = zf.fromBytes(blob);
    try {
      const rec = hl.table(1).data!;
      expect(asNums(rec.numeric("A"))).toEqual([1, 2, 3]);
      expect(asNums(rec.numeric("B"))).toEqual([0.5, 1.5, 2.5]);
      expect(hl.get(1).name).toBe("D");
    } finally {
      hl.close();
    }

    // The .data-setter path on a detached HDU serializes the same way.
    const hdu2 = new zf.BinTableHDU({ name: "D2" });
    hdu2.data = new zf.TableData(["A", "B"], cols, 3);
    const hl2 = zf.fromBytes(new zf.HDUList([new zf.PrimaryHDU(), hdu2]).toBytes());
    try {
      expect(asNums(hl2.table(1).data!.numeric("A"))).toEqual([1, 2, 3]);
    } finally {
      hl2.close();
    }
  });

  test("detached AsciiTableHDU with TableData fails loud", () => {
    const cols = new Map<string, zf.ColumnData>([
      ["A", { kind: "numeric", dtype: "i4", repeat: 1, values: Int32Array.from([1, 2]) }],
    ]);
    const hdu = new zf.AsciiTableHDU();
    hdu.data = new zf.TableData(["A"], cols, 2);
    expect(() => new zf.HDUList([new zf.PrimaryHDU(), hdu]).toBytes()).toThrow(zf.NotSupportedError);
  });
});

describe("non-finite float header values are rejected on write (BUGHUNT 25/27)", () => {
  test("NaN/Infinity keyword write throws in create mode", () => {
    for (const bad of [NaN, Infinity, -Infinity]) {
      const h = new zf.Header();
      h.set("KNAN", bad);
      expect(() => new zf.HDUList([new zf.PrimaryHDU({ data: new Float32Array(4), header: h })]).toBytes()).toThrow(
        zf.FitsError,
      );
    }
  });

  test("Infinity keyword write throws immediately in update mode and leaves the file unchanged", () => {
    const p = tmp.path();
    zf.writeTo(p, new zf.FitsArray(Float32Array.from([1, 2, 3, 4]), [4]));
    let hl = zf.open(p, "update");
    try {
      expect(() => hl.get(0).header.set("KINF", Infinity)).toThrow(zf.FitsHeaderError);
    } finally {
      hl.close();
    }
    hl = zf.open(p);
    try {
      expect(hl.get(0).header.get("KINF")).toBeUndefined();
    } finally {
      hl.close();
    }
  });

  test("HIERARCH float -Infinity is rejected before batch packing", () => {
    const h = new zf.Header();
    h.set("ESO DET BAD GAIN", -Infinity);
    expect(() => new zf.HDUList([new zf.PrimaryHDU({ data: new Float32Array(4), header: h })]).toBytes()).toThrow(
      zf.FitsHeaderError,
    );
  });

  test("finite numbers are unaffected: non-integer, exact-integer double, bigint", () => {
    const h = new zf.Header();
    h.set("FVAL", 1.5);
    h.set("BIGI", 2 ** 40);
    h.set("BINT", 123n);
    const hl = zf.fromBytes(new zf.HDUList([new zf.PrimaryHDU({ data: new Float32Array(4), header: h })]).toBytes());
    const hh = hl.get(0).header;
    expect(hh.get("FVAL")).toBe(1.5);
    expect(Number(hh.get("BIGI"))).toBe(2 ** 40);
    expect(Number(hh.get("BINT"))).toBe(123);
  });

  test("a bare 'nan' value token parses as a string, not a float (parser regression pin)", () => {
    // The TS parser was already strict (FITS-real regex + Number.isFinite); pin it as the model
    // the Python parser now mirrors: an invalid bare token falls through as a string.
    const cards = [
      "SIMPLE  =                    T",
      "BITPIX  =                    8",
      "NAXIS   =                    0",
      "BADF    =                  nan / not a FITS real",
      "BADI    =                  inf",
      "GOODF   =                 1.5E2",
      "END",
    ];
    const raw = cards
      .map((s) => s.padEnd(80))
      .join("")
      .padEnd(2880);
    const hl = zf.fromBytes(enc(raw));
    const hh = hl.get(0).header;
    expect(hh.get("BADF")).toBe("nan");
    expect(hh.get("BADI")).toBe("inf");
    expect(hh.get("GOODF")).toBe(150);
  });
});

describe("BLANK/ZBLANK semantics: int images with BLANK read as NaN-masked floats (BUGHUNT 28)", () => {
  function blankI16Bytes(values: number[], shape: number[], blank = -32768): Uint8Array {
    const h = new zf.Header();
    h.set("BLANK", blank);
    const hdu = new zf.PrimaryHDU({ data: new zf.FitsArray(Int16Array.from(values), shape), header: h });
    return new zf.HDUList([hdu]).toBytes();
  }

  test("BLANK int image promotes to f4 with NaN at the sentinels", () => {
    const hl = zf.fromBytes(blankI16Bytes([1, -32768, 3, 4, 5, -32768], [2, 3]));
    const d = hl.get(0).data as zf.FitsArray;
    expect(d.dtype).toBe("f4");
    const vals = d.data as Float32Array;
    expect(Number.isNaN(vals[1])).toBe(true);
    expect(Number.isNaN(vals[5])).toBe(true);
    expect([vals[0], vals[2], vals[3], vals[4]]).toEqual([1, 3, 4, 5]);
  });

  test("all-blank image is all NaN", () => {
    const hl = zf.fromBytes(blankI16Bytes([-32768, -32768], [1, 2]));
    const vals = (hl.get(0).data as zf.FitsArray).data as Float32Array;
    expect(Number.isNaN(vals[0]) && Number.isNaN(vals[1])).toBe(true);
  });

  test("BLANK=0 substitutes too (spec/CFITSIO behavior; astropy 8 has a falsy-zero quirk)", () => {
    const hl = zf.fromBytes(blankI16Bytes([0, 7], [1, 2], 0));
    const vals = (hl.get(0).data as zf.FitsArray).data as Float32Array;
    expect(Number.isNaN(vals[0])).toBe(true);
    expect(vals[1]).toBe(7);
  });

  test("unsigned-BZERO convention wins: BLANK ignored, raw u2 returned (astropy parity)", () => {
    const h = new zf.Header();
    h.set("BLANK", -32768);
    const hdu = new zf.PrimaryHDU({ data: new zf.FitsArray(Uint16Array.from([1, 0, 3]), [1, 3]), header: h });
    const hl = zf.fromBytes(new zf.HDUList([hdu]).toBytes());
    const d = hl.get(0).data as zf.FitsArray;
    expect(d.dtype).toBe("u2");
    expect(asNums(d.data)).toEqual([1, 0, 3]);
  });

  test("dtype widths match astropy: f4 for BITPIX 16, f8 for 32/64", () => {
    for (const [arr, want] of [
      [Int32Array.from([1, -9, 3]), "f8"],
      [BigInt64Array.from([1n, -9n, 3n]), "f8"],
    ] as const) {
      const h = new zf.Header();
      h.set("BLANK", -9);
      const hdu = new zf.PrimaryHDU({ data: new zf.FitsArray(arr, [1, 3]), header: h });
      const hl = zf.fromBytes(new zf.HDUList([hdu]).toBytes());
      const d = hl.get(0).data as zf.FitsArray;
      expect(d.dtype).toBe(want);
      expect(Number.isNaN((d.data as Float64Array)[1])).toBe(true);
    }
  });

  test("section() honors BLANK (the zf_read_subset path)", () => {
    const p = tmp.path();
    const bytes = blankI16Bytes([1, -32768, 3, 4, 5, -32768], [2, 3]);
    writeFileSync(p, bytes);
    const hl = zf.open(p);
    try {
      const img = hl.image(0);
      const cut = img.section({ window: [[0, 2], [1, 3]] }); // cols 1..2 of both rows
      expect(cut.dtype).toBe("f4");
      const vals = cut.data as Float32Array;
      expect(Number.isNaN(vals[0])).toBe(true); // (0,1) is the sentinel
      expect(vals[1]).toBe(3);
      expect(Number.isNaN(vals[3])).toBe(true); // (1,2) is the sentinel
      expect(vals[2]).toBe(5);
    } finally {
      hl.close();
    }
  });

  test("promoted write-back drops the stale BLANK card; pristine copy keeps the original bytes", () => {
    const src = tmp.path();
    const bytes = blankI16Bytes([1, -32768, 3], [1, 3]);
    writeFileSync(src, bytes);

    // Untouched HDU: pristine byte-copy preserves the original int+BLANK bytes verbatim.
    const copyPath = tmp.path();
    let hl = zf.open(src);
    try {
      expect((hl.get(0).data as zf.FitsArray).dtype).toBe("f4"); // promoted on read
      hl.writeTo(copyPath, { overwrite: true });
    } finally {
      hl.close();
    }
    hl = zf.open(copyPath);
    try {
      expect(hl.get(0).header.get("BITPIX")).toBe(16);
      expect(hl.get(0).header.get("BLANK")).toBe(-32768);
    } finally {
      hl.close();
    }

    // Dirtied HDU reconstructs: the emitted data unit is float, so BLANK must be dropped.
    const dstPath = tmp.path();
    hl = zf.open(src);
    try {
      void hl.get(0).data;
      hl.get(0).header.set("NOTE", "edited"); // force the reconstruction (non-pristine) path
      hl.writeTo(dstPath, { overwrite: true });
    } finally {
      hl.close();
    }
    hl = zf.open(dstPath);
    try {
      expect(Number(hl.get(0).header.get("BITPIX"))).toBeLessThan(0);
      expect(hl.get(0).header.get("BLANK")).toBeUndefined();
      const vals = (hl.get(0).data as zf.FitsArray).data as Float32Array;
      expect(Number.isNaN(vals[1])).toBe(true);
      expect([vals[0], vals[2]]).toEqual([1, 3]);
    } finally {
      hl.close();
    }
  });
});

describe("indexed table metadata", () => {
  const sourceBytes = (): Uint8Array => {
    const table = zf.BinTableHDU.fromColumns([
      new zf.Column("A", "1J", { array: Int32Array.of(1, 2), unit: "s" }),
      new zf.Column("B", "1J", { array: Int32Array.of(101, 102), unit: "s" }),
      new zf.Column("C", "1J", { array: Int32Array.of(201, 202), unit: "s" }),
    ]);
    const cards = {
      TNULL1: -99, TDISP2: "I8", TDIM3: "(1)", TLMIN1: 0, TLMAX2: 109, TDBIN2: 0.5, TDMIN1: 1, TDMAX1: 2,
      TCTYP1: "LINEAR", TCTYP2: "LINEAR", TCUNI1: "s", TCRVL2: 20,
      TCTY1A: "LINEAR", TCTY2A: "LINEAR", TCRP1A: 2, TCDE2A: 0.1,
      TP1_2A: 0.25, TCD1_2D: 0.5, TPV1_0A: 4, TPS2_1A: "parameter",
      TCTY3B: "LINEAR", TCRD3B: 0.01, EQUI3B: 2000,
      "1CTYP3": "LINEAR", "1CUNI3": "m", "1CTY3C": "LINEAR", "2CNA3C": "axis two",
      "12PC3C": 0.125, "21CD3D": 0.25, "1PV3_0C": 3, "2S3_1C": "lookup",
      "1V3_XC": 7, WCAX3C: 2, WCSN3C: "array coordinates", LONP3C: 180,
      DOBS3: "2026-09-30", TRPOS3: "TOPOCENTER",
      TLMIN0: 7, TLMIN01: 8, "1000PC1": 9, TCTYP1A: "custom", PC1_2A: 0.75, "OBS CAMERA": "camera",
    };
    for (const [key, value] of Object.entries(cards)) table.header.set(key, value, `comment for ${key}`);
    table.header.addHistory("metadata provenance");
    return new zf.HDUList([new zf.PrimaryHDU(), table]).toBytes();
  };

  test("reordering maps columns while retaining axis and parameter indices", () => {
    const source = zf.fromBytes(sourceBytes());
    try {
      const table = source.get(1) as zf.TableHDU;
      const data = table.data as zf.TableData;
      table.data = new zf.TableData(["C", "A", "B"], data.columns, data.nrows);
      const saved = zf.fromBytes(source.toBytes());
      try {
        const header = saved.get(1).header;
        const expected = {
          TNULL2: -99, TDISP3: "I8", TDIM1: "(1)", TLMIN2: 0, TLMAX3: 109, TDBIN3: 0.5,
          TCTYP2: "LINEAR", TCUNI2: "s", TCRVL3: 20, TCRP2A: 2, TCDE3A: 0.1,
          TP2_3A: 0.25, TCD2_3D: 0.5, TPV2_0A: 4, TPS3_1A: "parameter",
          TCTY1B: "LINEAR", TCRD1B: 0.01, EQUI1B: 2000,
          "1CTYP1": "LINEAR", "1CUNI1": "m", "1CTY1C": "LINEAR", "2CNA1C": "axis two",
          "12PC1C": 0.125, "21CD1D": 0.25, "1PV1_0C": 3, "2S1_1C": "lookup",
          "1V1_XC": 7, WCAX1C: 2, WCSN1C: "array coordinates", LONP1C: 180,
          DOBS1: "2026-09-30", TRPOS1: "TOPOCENTER",
          TLMIN0: 7, TLMIN01: 8, "1000PC1": 9, TCTYP1A: "custom", PC1_2A: 0.75, "OBS CAMERA": "camera",
        };
        for (const [key, value] of Object.entries(expected)) expect(header.get(key)).toBe(value);
        expect(header.commentOf("TP2_3A")).toBe("comment for TP1_2A");
        expect(header.commentOf("12PC1C")).toBe("comment for 12PC3C");
        for (const key of ["TDMIN1", "TDMAX1", "TP1_2A", "1PV3_0C"]) expect(header.get(key)).toBeUndefined();
        expect((saved.get(1).data as zf.TableData).names).toEqual(["C", "A", "B"]);
      } finally { saved.close(); }
    } finally { source.close(); }
  });

  test("ASCII ranges and pixel-list WCS follow reordered columns", () => {
    const table = zf.AsciiTableHDU.fromColumns([
      new zf.Column("A", "I8", { array: Int32Array.of(1, 2) }),
      new zf.Column("B", "I8", { array: Int32Array.of(101, 102) }),
    ]);
    for (const [key, value] of Object.entries({ TLMIN1: 0, TLMIN2: 100, TCTY1A: "LINEAR", TCTY2A: "LINEAR", TP1_2A: 0.25 })) {
      table.header.set(key, value);
    }
    const source = zf.fromBytes(new zf.HDUList([new zf.PrimaryHDU(), table]).toBytes());
    try {
      const hdu = source.get(1) as zf.TableHDU;
      const data = hdu.data as zf.TableData;
      hdu.data = new zf.TableData(["B", "A"], data.columns, data.nrows);
      const saved = zf.fromBytes(source.toBytes());
      try {
        expect(saved.get(1).header.get("TLMIN1")).toBe(100);
        expect(saved.get(1).header.get("TLMIN2")).toBe(0);
        expect(saved.get(1).header.get("TP2_1A")).toBe(0.25);
        expect(saved.get(1).header.get("TP1_2A")).toBeUndefined();
      } finally { saved.close(); }
    } finally { source.close(); }
  });

  for (const change of ["remove", "retype", "rename", "clear"]) {
    test(`${change} drops incomplete WCS and stale metadata`, () => {
      const source = zf.fromBytes(sourceBytes());
      try {
        const table = source.get(1) as zf.TableHDU;
        const data = table.data as zf.TableData;
        if (change === "remove") table.data = new zf.TableData(["A", "C"], data.columns, data.nrows);
        else if (change === "clear") table.data = null;
        else {
          const middle = change === "rename" ? "D" : "B";
          table.data = new zf.TableData(["A", middle, "C"], new Map<string, zf.ColumnData>([
            ["A", data.column("A")],
            [middle, { kind: "numeric", dtype: "f8", repeat: 1, values: Float64Array.of(101, 102) }],
            ["C", data.column("C")],
          ]), data.nrows);
        }
        const saved = zf.fromBytes(source.toBytes());
        try {
          const header = saved.get(1).header;
          for (const key of ["TCTYP1", "TCTYP2", "TCTY1A", "TCTY2A", "TP1_2A", "TCD1_2D", "TPV1_0A", "TPS2_1A", "TLMAX2", "TDISP2"]) {
            expect(header.get(key)).toBeUndefined();
          }
          if (change !== "clear") {
            const index = change === "remove" ? 2 : 3;
            expect(header.get(`TCTY${index}B`)).toBe("LINEAR");
            expect(header.get(`1CTY${index}C`)).toBe("LINEAR");
            expect(header.get(`WCSN${index}C`)).toBe("array coordinates");
          } else {
            expect(header.get("TFIELDS")).toBe(0);
            expect(header.get("TCTY3B")).toBeUndefined();
            expect(header.get("1CTY3C")).toBeUndefined();
          }
          expect(header.get("1000PC1")).toBe(9);
          expect(header.get("OBS CAMERA")).toBe("camera");
        } finally { saved.close(); }
      } finally { source.close(); }
    });
  }

  for (const attached of [false, true]) {
    test(`scaling change invalidates metadata provenance (${attached ? "attached" : "builder"})`, () => {
      const table = zf.BinTableHDU.fromColumns([new zf.Column("X", "1I", { array: Uint16Array.of(1, 2), unit: "s" })]);
      table.header.set("TNULL1", -99);
      table.header.set("TLMIN1", 0);
      table.header.set("TCTYP1", "LINEAR");
      let hdul = new zf.HDUList([new zf.PrimaryHDU(), table]);
      if (attached) hdul = zf.fromBytes(hdul.toBytes());
      try {
        (hdul.get(1) as zf.TableHDU).data = new zf.TableData(["X"], new Map<string, zf.ColumnData>([
          ["X", { kind: "numeric", dtype: "i2", repeat: 1, values: Int16Array.of(1, 2) }],
        ]), 2);
        const saved = zf.fromBytes(hdul.toBytes());
        try {
          const header = saved.get(1).header;
          expect(header.get("TFORM1")).toBe("1I");
          expect(header.get("TUNIT1")).toBe("s");
          for (const key of ["TZERO1", "TNULL1", "TLMIN1", "TCTYP1"]) expect(header.get(key)).toBeUndefined();
        } finally { saved.close(); }
      } finally { hdul.close(); }
    });
  }

  test("fresh detached metadata uses the new schema and explicit measured bounds", () => {
    const table = new zf.BinTableHDU({ data: new zf.TableData(["X"], new Map<string, zf.ColumnData>([
      ["X", { kind: "numeric", dtype: "i4", repeat: 1, values: Int32Array.of(3, 4) }],
    ]), 2) });
    for (const [key, value] of Object.entries({ TDMIN1: 3, TDMAX1: 4, TLMIN1: 0, TNULL9: -99 })) table.header.set(key, value);
    const saved = zf.fromBytes(new zf.HDUList([new zf.PrimaryHDU(), table]).toBytes());
    try {
      expect(saved.get(1).header.get("TDMIN1")).toBe(3);
      expect(saved.get(1).header.get("TDMAX1")).toBe(4);
      expect(saved.get(1).header.get("TLMIN1")).toBe(0);
      expect(saved.get(1).header.get("TNULL9")).toBeUndefined();
    } finally { saved.close(); }
  });

  test("WCS keyword growth uses a short alias or raises a typed error", () => {
    const table = zf.BinTableHDU.fromColumns(Array.from({ length: 103 }, (_, i) =>
      new zf.Column(`C${i}`, "1J", { array: Int32Array.of(i) })));
    table.header.set("TPC1_2A", 0.25);
    const source = zf.fromBytes(new zf.HDUList([new zf.PrimaryHDU(), table]).toBytes());
    try {
      const hdu = source.get(1) as zf.TableHDU;
      const data = hdu.data as zf.TableData;
      const order = ["C1", ...Array.from({ length: 99 }, (_, i) => `C${i + 2}`), "C0", "C101", "C102"];
      hdu.data = new zf.TableData(order, data.columns, data.nrows);
      const saved = zf.fromBytes(source.toBytes());
      try { expect(saved.get(1).header.get("TP101_1A")).toBe(0.25); } finally { saved.close(); }
      hdu.data = new zf.TableData([...Array.from({ length: 101 }, (_, i) => `C${i + 2}`), "C0", "C1"], data.columns, data.nrows);
      expect(() => source.toBytes()).toThrow(zf.FitsHeaderError);
    } finally { source.close(); }
  });
});

describe("stored table formats", () => {
  for (const [type, format, override, values] of [
    [zf.BinTableHDU, "1J", "1I", Int32Array.of(40000)],
    [zf.AsciiTableHDU, "F12.5", "I3", Float64Array.of(1.23456)],
  ] as const) {
    test(`attached ${format} comes from the native source layout`, () => {
      const table = type.fromColumns([new zf.Column("X", format, { array: values, unit: "m" })]);
      table.header.set("TDISP1", "I8");
      const source = zf.fromBytes(new zf.HDUList([new zf.PrimaryHDU(), table]).toBytes());
      try {
        const expected = asNums((source.get(1).data as zf.TableData).numeric("X"));
        source.get(1).header.set("TFORM1", override);
        source.get(1).header.set("TUNIT1", "s");
        const saved = zf.fromBytes(source.toBytes());
        try {
          expect(saved.get(1).header.get("TFORM1")).toBe(format);
          expect(saved.get(1).header.get("TUNIT1")).toBe("s");
          expect(saved.get(1).header.get("TDISP1")).toBe("I8");
          expect(asNums((saved.get(1).data as zf.TableData).numeric("X"))).toEqual(expected);
        } finally { saved.close(); }
      } finally { source.close(); }
    });
  }

  for (const descriptor of ["P", "Q"]) {
    for (const emission of ["attached", "builder_arrays", "builder_replacement"]) {
      test(`materialized ${descriptor} VLA omits stale maximum (${emission})`, () => {
        const format = `1${descriptor}J(2)`;
        const cells = [Int32Array.of(1, 2)];
        let table: zf.TableHDU = zf.BinTableHDU.fromColumns([new zf.Column("X", format, { array: cells, unit: "m" })]);
        table.header.set("TDISP1", "I8", "display comment");
        let hdul = new zf.HDUList([new zf.PrimaryHDU(), table]);
        if (emission === "attached") {
          const raw = bytesFrom((handle) => {
            ll.check(ll.lib.zf_create_img(handle, 8, 0, null));
            ll.check(ll.lib.zf_create_tbl_heap(handle, ll.BINARY_TBL, 1n, 1, ["X"], [format], ["m"], null, 8n));
            const tout = ll.outU64();
            ll.check(ll.lib.zf_table_open(handle, tout));
            try {
              ll.check(ll.lib.zf_write_col_vla(tout[0], ll.ZF_INT32, 0, 1n, cells[0], 2n));
            } finally { ll.lib.zf_table_close(tout[0]); }
            const key = enc("TDISP1"), value = enc("I8"), comment = enc("display comment");
            ll.check(ll.lib.zf_write_key_str(handle, key, key.length, value, value.length, comment, comment.length));
          });
          hdul = zf.fromBytes(raw);
          expect(hdul.toBytes()).toEqual(raw); // pristine bounded descriptors remain exact
          table = hdul.get(1) as zf.TableHDU;
          (table.data!.column("X") as zf.VlaColumn).values[0] = Int32Array.of(1, 2, 3, 4, 5);
        } else if (emission === "builder_arrays") {
          cells[0] = Int32Array.of(1, 2, 3, 4, 5);
        } else {
          table.data = new zf.TableData(["X"], new Map<string, zf.ColumnData>([
            ["X", { kind: "vla", dtype: "i4", repeat: 1, values: [Int32Array.of(1, 2, 3, 4, 5)] }],
          ]), 1);
        }
        try {
          const saved = zf.fromBytes(hdul.toBytes());
          try {
            expect(saved.get(1).header.get("TFORM1")).toBe(`1${descriptor}J`);
            expect(saved.get(1).header.get("TUNIT1")).toBe("m");
            expect(saved.get(1).header.get("TDISP1")).toBe("I8");
            expect(saved.get(1).header.commentOf("TDISP1")).toBe("display comment");
            expect((saved.get(1).data as zf.TableData).vla("X").map(asNums)).toEqual([[1, 2, 3, 4, 5]]);
          } finally { saved.close(); }
        } finally { hdul.close(); }
      });
    }
  }
});

describe("table WCS cross-references", () => {
  for (const change of ["reorder", "remove", "retype"]) {
    test(`${change} tracks case-sensitive targets across alternate descriptors`, () => {
      const table = zf.BinTableHDU.fromColumns(["A", "B", "C"].map((name, i) =>
        new zf.Column(name, "1J", { array: Int32Array.of(i) })));
      for (const [key, value] of Object.entries({
        "1CTY1B": "LINEAR", WCST1B: "XREF", WCSX2A: "XREF", WCSX3A: "xref", "1CTY2C": "LINEAR", CUSTOM: "XREF",
      })) table.header.set(key, value, `comment for ${key}`);
      const source = zf.fromBytes(new zf.HDUList([new zf.PrimaryHDU(), table]).toBytes());
      try {
        const hdu = source.get(1) as zf.TableHDU;
        const data = hdu.data as zf.TableData;
        if (change === "reorder") hdu.data = new zf.TableData(["C", "B", "A"], data.columns, data.nrows);
        else if (change === "remove") hdu.data = new zf.TableData(["B", "C"], data.columns, data.nrows);
        else hdu.data = new zf.TableData(["A", "B", "C"], new Map<string, zf.ColumnData>([
          ["A", { kind: "numeric", dtype: "f8", repeat: 1, values: Float64Array.of(0) }],
          ["B", data.column("B")], ["C", data.column("C")],
        ]), data.nrows);
        const saved = zf.fromBytes(source.toBytes());
        try {
          const header = saved.get(1).header;
          if (change === "reorder") {
            expect(header.get("WCST3B")).toBe("XREF");
            expect(header.get("WCSX2A")).toBe("XREF");
            expect(header.get("1CTY3B")).toBe("LINEAR");
            expect(header.get("WCSX1A")).toBe("xref");
            expect(header.commentOf("WCSX2A")).toBe("comment for WCSX2A");
          } else {
            const [refIndex, caseIndex] = change === "remove" ? [1, 2] : [2, 3];
            expect(header.get(`WCSX${refIndex}A`)).toBeUndefined();
            expect(header.get("WCST1B")).toBeUndefined();
            expect(header.get("1CTY1B")).toBeUndefined();
            expect(header.get(`WCSX${caseIndex}A`)).toBe("xref");
          }
          expect(header.get(`1CTY${change === "remove" ? 1 : 2}C`)).toBe("LINEAR");
          expect(header.get("CUSTOM")).toBe("XREF");
        } finally { saved.close(); }
      } finally { source.close(); }
    });
  }
});

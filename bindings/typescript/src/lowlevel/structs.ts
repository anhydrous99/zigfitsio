/**
 * Codecs for the fixed-layout C structs the ABI passes by pointer (never by value),
 * so neither FFI backend needs struct support: each struct is one
 * `ArrayBuffer` written/read through native-endian typed-array views (every
 * field is naturally aligned, and the C side reads native endianness).
 *
 * Layouts follow C natural alignment on 64-bit targets and are identical on
 * SysV and Win64 (all fields are fixed-width except `int`, which is 4 bytes
 * on both). Field order must match `bindings/capi/abi.zig` /
 * `bindings/c/zigfitsio.h`; the offset math is guarded by runtime tripwire
 * tests in `tests/lowlevel.test.ts`.
 */

/**
 * Open/create options (mirrors `ZfOpenOpts`, size 72). A `0`/unset limit
 * field means "use the library default"; passing `null`/`undefined` to the
 * open call means all defaults with checksums off (`abi.zig optsFrom`).
 */
export interface OpenOptions {
  checksumOnClose?: boolean;
  maxHeaderBlocks?: number;
  maxHduCount?: number;
  maxNaxisProduct?: number | bigint;
  maxHeapBytes?: number | bigint;
  maxVlaElems?: number | bigint;
  maxStringValue?: number;
  maxTileBytes?: number | bigint;
  maxOpenAlloc?: number | bigint;
  maxMatches?: number;
}

const toU64 = (v: number | bigint | undefined): bigint => (v === undefined ? 0n : BigInt(v));

/** Encode `opts` as a 72-byte ZfOpenOpts, or return null (⇒ NULL pointer, all defaults). */
export function encodeOpenOpts(opts?: OpenOptions | null): Uint8Array | null {
  if (opts == null) return null;
  const buf = new ArrayBuffer(72);
  const i32 = new Int32Array(buf); // element index = byte offset / 4
  const u32 = new Uint32Array(buf);
  const u64 = new BigUint64Array(buf); // element index = byte offset / 8
  i32[0] = opts.checksumOnClose ? 1 : 0; // @0
  u32[1] = opts.maxHeaderBlocks ?? 0; // @4
  u32[2] = opts.maxHduCount ?? 0; // @8, pad @12
  u64[2] = toU64(opts.maxNaxisProduct); // @16
  u64[3] = toU64(opts.maxHeapBytes); // @24
  u64[4] = toU64(opts.maxVlaElems); // @32
  u32[10] = opts.maxStringValue ?? 0; // @40, pad @44
  u64[6] = toU64(opts.maxTileBytes); // @48
  u64[7] = toU64(opts.maxOpenAlloc); // @56
  u32[16] = opts.maxMatches ?? 0; // @64, tail pad @68
  return new Uint8Array(buf);
}

/**
 * Per-call BSCALE/BZERO/BLANK override (mirrors `ZfScaling`, size 32).
 * `raw` exposes stored values unscaled.
 */
export interface Scaling {
  bscale?: number;
  bzero?: number;
  blank?: number | bigint;
  raw?: boolean;
}

export function encodeScaling(s: Scaling): Uint8Array {
  const buf = new ArrayBuffer(32);
  const f64 = new Float64Array(buf);
  const i64 = new BigInt64Array(buf);
  const i32 = new Int32Array(buf);
  f64[0] = s.bscale ?? 1; // @0
  f64[1] = s.bzero ?? 0; // @8
  i64[2] = s.blank === undefined ? 0n : BigInt(s.blank); // @16
  i32[6] = s.blank === undefined ? 0 : 1; // has_blank @24
  i32[7] = s.raw ? 1 : 0; // raw @28
  return new Uint8Array(buf);
}

/** Per-column metadata (mirrors `ZfColInfo`, size 64; filled by `zf_table_col_info`). */
export interface ColInfo {
  /** Natural element ZfType. */
  typecode: number;
  /** Elements per cell (bytes for 'A', bits for 'X'); -1 for VLA. */
  repeat: number;
  /** Field byte width (binary) or text width (ASCII). */
  width: number;
  isVla: boolean;
  /** Raw TFORM letter, e.g. "J". */
  tformChar: string;
  tscal: number;
  tzero: number;
  tnull: bigint;
  hasTnull: boolean;
}

export function newColInfoBuf(): Uint8Array {
  return new Uint8Array(64);
}

export function decodeColInfo(bytes: Uint8Array): ColInfo {
  const buf = bytes.buffer as ArrayBuffer;
  const off = bytes.byteOffset;
  const i32 = new Int32Array(buf, off, 16);
  const i64 = new BigInt64Array(buf, off, 8);
  const f64 = new Float64Array(buf, off, 8);
  return {
    typecode: i32[0], // @0, pad @4
    repeat: Number(i64[1]), // @8
    width: Number(i64[2]), // @16
    isVla: i32[6] !== 0, // @24
    tformChar: String.fromCharCode(i32[7]), // @28
    tscal: f64[4], // @32
    tzero: f64[5], // @40
    tnull: i64[6], // @48
    hasTnull: i32[14] !== 0, // @56, tail pad @60
  };
}

// ── Logical-header snapshot/edit V1 ──

/** Fixed ABI sizes; kept explicit so Wasm marshalling never depends on JS object layout. */
export const HEADER_SNAPSHOT_INFO_V1_SIZE = 48;
export const HEADER_ENTRY_V1_SIZE = 96;
export const HEADER_OP_V1_SIZE = 88;
export const HEADER_APPLY_OPTS_V1_SIZE = 16;
export const HEADER_APPLY_RESULT_V1_SIZE = 32;

function requireBytes(bytes: Uint8Array, needed: number, what: string): DataView {
  if (bytes.byteLength < needed) {
    throw new RangeError(`${what} requires ${needed} bytes, got ${bytes.byteLength}`);
  }
  return new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
}

export interface HeaderSnapshotInfoV1 {
  revision: bigint;
  logicalCount: bigint;
  physicalCount: bigint;
  arenaBytes: bigint;
  rawBytes: bigint;
  flags: bigint;
}

export function newHeaderSnapshotInfoV1Buf(): Uint8Array {
  return new Uint8Array(HEADER_SNAPSHOT_INFO_V1_SIZE);
}

export function decodeHeaderSnapshotInfoV1(bytes: Uint8Array): HeaderSnapshotInfoV1 {
  const view = requireBytes(bytes, HEADER_SNAPSHOT_INFO_V1_SIZE, "ZfHeaderSnapshotInfoV1");
  return {
    revision: view.getBigUint64(0, true),
    logicalCount: view.getBigUint64(8, true),
    physicalCount: view.getBigUint64(16, true),
    arenaBytes: view.getBigUint64(24, true),
    rawBytes: view.getBigUint64(32, true),
    flags: view.getBigUint64(40, true),
  };
}

export interface HeaderEntryV1 {
  kind: number;
  valueType: number;
  flags: number;
  reserved: number;
  physicalFirst: bigint;
  physicalCount: bigint;
  keywordOff: bigint;
  keywordLen: bigint;
  valueOff: bigint;
  valueLen: bigint;
  commentOff: bigint;
  commentLen: bigint;
  intValue: bigint;
  floatValue: number;
}

/** Decode entry `index` from a packed array of ZfHeaderEntryV1 descriptors. */
export function decodeHeaderEntryV1(bytes: Uint8Array, index = 0): HeaderEntryV1 {
  if (!Number.isSafeInteger(index) || index < 0) throw new RangeError(`invalid header-entry index ${index}`);
  const base = index * HEADER_ENTRY_V1_SIZE;
  const view = requireBytes(bytes, base + HEADER_ENTRY_V1_SIZE, "ZfHeaderEntryV1 array");
  return {
    kind: view.getUint32(base, true),
    valueType: view.getUint32(base + 4, true),
    flags: view.getUint32(base + 8, true),
    reserved: view.getUint32(base + 12, true),
    physicalFirst: view.getBigUint64(base + 16, true),
    physicalCount: view.getBigUint64(base + 24, true),
    keywordOff: view.getBigUint64(base + 32, true),
    keywordLen: view.getBigUint64(base + 40, true),
    valueOff: view.getBigUint64(base + 48, true),
    valueLen: view.getBigUint64(base + 56, true),
    commentOff: view.getBigUint64(base + 64, true),
    commentLen: view.getBigUint64(base + 72, true),
    intValue: view.getBigInt64(base + 80, true),
    floatValue: view.getFloat64(base + 88, true),
  };
}

export function decodeHeaderEntriesV1(bytes: Uint8Array, count: number): HeaderEntryV1[] {
  if (!Number.isSafeInteger(count) || count < 0 || count * HEADER_ENTRY_V1_SIZE > bytes.byteLength) {
    throw new RangeError(`invalid ZfHeaderEntryV1 count ${count} for ${bytes.byteLength} bytes`);
  }
  return Array.from({ length: count }, (_, i) => decodeHeaderEntryV1(bytes, i));
}

export interface HeaderOpV1 {
  opcode: number;
  valueType?: number;
  flags?: number;
  reserved?: number;
  nameOff?: bigint;
  nameLen?: bigint;
  valueOff?: bigint;
  valueLen?: bigint;
  commentOff?: bigint;
  commentLen?: bigint;
  intValue?: bigint;
  floatValue?: number;
  position?: bigint;
}

/** Encode a packed caller-owned array of ZfHeaderOpV1 descriptors. */
export function encodeHeaderOpsV1(ops: readonly HeaderOpV1[]): Uint8Array {
  const bytes = new Uint8Array(ops.length * HEADER_OP_V1_SIZE);
  const view = new DataView(bytes.buffer);
  for (let i = 0; i < ops.length; i++) {
    const op = ops[i];
    const base = i * HEADER_OP_V1_SIZE;
    view.setUint32(base, op.opcode, true);
    view.setUint32(base + 4, op.valueType ?? 0, true);
    view.setUint32(base + 8, op.flags ?? 0, true);
    view.setUint32(base + 12, op.reserved ?? 0, true);
    view.setBigUint64(base + 16, op.nameOff ?? 0n, true);
    view.setBigUint64(base + 24, op.nameLen ?? 0n, true);
    view.setBigUint64(base + 32, op.valueOff ?? 0n, true);
    view.setBigUint64(base + 40, op.valueLen ?? 0n, true);
    view.setBigUint64(base + 48, op.commentOff ?? 0n, true);
    view.setBigUint64(base + 56, op.commentLen ?? 0n, true);
    view.setBigInt64(base + 64, op.intValue ?? 0n, true);
    view.setFloat64(base + 72, op.floatValue ?? 0, true);
    view.setBigInt64(base + 80, op.position ?? -1n, true);
  }
  return bytes;
}

export interface HeaderApplyOptsV1 {
  expectedRevision?: bigint;
  flags?: number;
  reserved?: number;
}

export function encodeHeaderApplyOptsV1(opts: HeaderApplyOptsV1 = {}): Uint8Array {
  const bytes = new Uint8Array(HEADER_APPLY_OPTS_V1_SIZE);
  const view = new DataView(bytes.buffer);
  view.setBigUint64(0, opts.expectedRevision ?? 0n, true);
  view.setUint32(8, opts.flags ?? 0, true);
  view.setUint32(12, opts.reserved ?? 0, true);
  return bytes;
}

export interface HeaderApplyResultV1 {
  newRevision: bigint;
  failedOp: bigint;
  cardsBefore: bigint;
  cardsAfter: bigint;
}

export function newHeaderApplyResultV1Buf(): Uint8Array {
  return new Uint8Array(HEADER_APPLY_RESULT_V1_SIZE);
}

export function decodeHeaderApplyResultV1(bytes: Uint8Array): HeaderApplyResultV1 {
  const view = requireBytes(bytes, HEADER_APPLY_RESULT_V1_SIZE, "ZfHeaderApplyResultV1");
  return {
    newRevision: view.getBigUint64(0, true),
    failedOp: view.getBigUint64(8, true),
    cardsBefore: view.getBigUint64(16, true),
    cardsAfter: view.getBigUint64(24, true),
  };
}

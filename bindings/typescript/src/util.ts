/** Small shared helpers (no native dependencies). */

const encoder = new TextEncoder();
const decoder = new TextDecoder();

/** UTF-8 encode a string for a (ptr, len) ABI argument pair. */
export function enc(s: string): Uint8Array {
  return encoder.encode(s);
}

/** Decode `buf[0..min(outLen, buf.length)]` from a fixed-buffer string getter. */
export function decOut(buf: Uint8Array, outLen: number | bigint): string {
  const n = Math.min(Number(outLen), buf.length);
  return decoder.decode(buf.subarray(0, n));
}

/** The raw bytes backing any TypedArray (view over the same memory, no copy). */
export function viewBytes(a: ArrayBufferView): Uint8Array {
  return new Uint8Array(a.buffer, a.byteOffset, a.byteLength);
}

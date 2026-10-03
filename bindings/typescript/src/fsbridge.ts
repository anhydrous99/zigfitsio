/**
 * Filesystem bridge (Node/Bun). Every path-based file operation in the
 * high-level API funnels through this one module so the browser build can swap
 * it — via the package `browser` export condition — for `fsbridge.browser.ts`,
 * which throws. That keeps `node:fs` out of the browser bundle; in the browser
 * use the in-memory APIs (`fromBytes()` / `toBytes()`) instead of the path-based
 * `open()` / `writeTo()`.
 *
 * The wasm module itself never touches the filesystem (it is
 * `wasm32-freestanding`): these helpers read/write the FITS bytes on the JS side
 * and hand them to the in-memory `zf_open_memory` / `zf_read_bytes` ABI.
 */
import {
  closeSync, existsSync as _existsSync, fchmodSync, fstatSync, linkSync, openSync, readSync,
  realpathSync, renameSync, statSync, unlinkSync, writeFileSync,
} from "node:fs";
import { randomUUID } from "node:crypto";
import { basename, dirname, join } from "node:path";
import { constants as bufferConstants } from "node:buffer";
import { gunzipSync } from "node:zlib";
import { FitsCompressError, FitsIOError, FitsMemoryError } from "./errors.js";

/** Read a file into a `Uint8Array` (Node's Buffer already is one). */
export function readFile(path: string, maxBytes: bigint): Uint8Array {
  const fd = openSync(path, "r");
  try {
    const size = fstatSync(fd, { bigint: true }).size;
    if (size > maxBytes || size > BigInt(bufferConstants.MAX_LENGTH)) {
      throw new FitsMemoryError(113, "FITS file exceeds the allocation limit");
    }
    const bytes = new Uint8Array(Number(size));
    let used = 0;
    while (used < bytes.length) {
      const n = readSync(fd, bytes, used, bytes.length - used, null);
      if (n === 0) return bytes.subarray(0, used);
      used += n;
    }
    // Never allocate based on growth after the checked stat. A changing input
    // must be reopened rather than bypassing its allocation budget.
    if (readSync(fd, new Uint8Array(1), 0, 1, null) !== 0) {
      throw new FitsIOError(107, "FITS file grew while it was being read");
    }
    return bytes;
  } finally {
    closeSync(fd);
  }
}

/**
 * Inflate whole-file gzip (`*.fits.gz`) bytes. The wasm module's own gzip inflate
 * is an excluded OS leaf, so `.gz` decompression happens here on the JS side (like
 * file reads) and the plain FITS bytes go to `zf_open_memory`.
 */
export function gunzip(data: Uint8Array, maxBytes: bigint): Uint8Array {
  const maxOutputLength = Number(maxBytes < BigInt(bufferConstants.MAX_LENGTH) ? maxBytes : BigInt(bufferConstants.MAX_LENGTH));
  try {
    return gunzipSync(data, { maxOutputLength });
  } catch (e) {
    if ((e as NodeJS.ErrnoException).code === "ERR_BUFFER_TOO_LARGE") {
      throw new FitsMemoryError(113, "inflated FITS file exceeds the allocation limit");
    }
    throw new FitsCompressError(414, `could not inflate FITS gzip: ${(e as Error).message}`);
  }
}

/** Write bytes to a file (overwriting). */
export function writeFile(path: string | number, data: Uint8Array): void {
  writeFileSync(path, data);
}

/** Replace a complete file from an exclusively created sibling temporary file. */
export function atomicWrite(
  path: string,
  write: (fd: number) => void,
  options: { overwrite?: boolean; followSymlink?: boolean } = {},
): void {
  const target = options.followSymlink ? realpathSync(path) : path;
  const mode = _existsSync(target) ? statSync(target).mode & 0o7777 : null;
  const tmp = join(dirname(target), `.${basename(target)}.zigfitsio-${randomUUID()}.tmp`);
  const fd = openSync(tmp, "wx", mode ?? 0o666);
  try {
    try {
      write(fd);
      if (mode !== null) fchmodSync(fd, mode);
    } finally {
      closeSync(fd);
    }
    if (options.overwrite === false) {
      // Linking publishes without replacing a concurrently created target.
      linkSync(tmp, target);
    } else {
      renameSync(tmp, target);
    }
  } finally {
    try { unlinkSync(tmp); } catch (e) {
      if ((e as NodeJS.ErrnoException).code !== "ENOENT") throw e;
    }
  }
}

export function existsSync(path: string): boolean {
  return _existsSync(path);
}

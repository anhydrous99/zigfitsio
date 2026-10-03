#!/usr/bin/env node
// Install the packed artifact outside the checkout. No dev dependencies or test runner needed.
import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { copyFileSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { createRequire } from "node:module";
import { tmpdir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";

if (process.argv[2] === "--consumer") {
  assert.equal(process.env.ZIGFITSIO_WASM, undefined);
  const require = createRequire(join(process.cwd(), "package.json"));
  const entry = require.resolve("zigfitsio");
  const packagedWasm = require.resolve("zigfitsio/zigfitsio.wasm");
  assert.ok(entry.startsWith(join(process.cwd(), "node_modules", "zigfitsio") + "/"));
  const loader = await import(pathToFileURL(join(dirname(entry), "loader.js")));
  assert.equal(resolve(loader.findWasm()), resolve(packagedWasm));
  assert.ok(readFileSync(packagedWasm).length > 0);
  const zf = await import(pathToFileURL(entry));
  await zf.ready();
  const data = new zf.FitsArray(new Int16Array([11, 22, 33, 44]), [2, 2]);
  const bytes = new zf.HDUList([new zf.PrimaryHDU({ data })]).toBytes();
  const hdul = zf.fromBytes(bytes);
  try {
    assert.deepEqual([...hdul.get(0).data.data], [...data.data]);
    assert.deepEqual(hdul.get(0).data.shape, [2, 2]);
  } finally {
    hdul.close();
  }
  console.log(`PASS: installed zigfitsio on ${process.version}; wasm=${packagedWasm}`);
} else {
  const tarball = resolve(process.argv[2] ?? assert.fail("usage: artifact-smoke.mjs <package.tgz>"));
  const consumer = mkdtempSync(join(tmpdir(), "zigfitsio-consumer-"));
  try {
    writeFileSync(join(consumer, "package.json"), '{"private":true,"type":"module"}');
    const env = { ...process.env };
    delete env.ZIGFITSIO_WASM;
    execFileSync(process.platform === "win32" ? "npm.cmd" : "npm", ["install", "--ignore-scripts", "--no-audit", "--no-fund", tarball], { cwd: consumer, env, stdio: "inherit" });
    const script = join(consumer, "smoke.mjs");
    copyFileSync(fileURLToPath(import.meta.url), script);
    execFileSync(process.execPath, [script, "--consumer"], { cwd: consumer, env, stdio: "inherit" });
  } finally {
    rmSync(consumer, { recursive: true, force: true });
  }
}

#!/usr/bin/env node
// Vite and Chrome exercise the installed package's browser mappings and default wasm fetch.
import assert from "node:assert/strict";
import { execFileSync, spawn } from "node:child_process";
import { existsSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { once } from "node:events";
import { tmpdir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { setTimeout as delay } from "node:timers/promises";

const tarball = resolve(process.argv[2] ?? assert.fail("usage: browser-smoke.mjs <package.tgz>"));
const chrome = process.env.CHROME_BIN ?? "google-chrome";
const vite = resolve(dirname(fileURLToPath(import.meta.url)), "../node_modules/vite/bin/vite.js");
const consumer = mkdtempSync(join(tmpdir(), "zigfitsio-browser-"));
let server;
let browser;
let socket;
try {
  writeFileSync(join(consumer, "package.json"), '{"private":true,"type":"module"}');
  const env = { ...process.env };
  delete env.ZIGFITSIO_WASM;
  execFileSync("npm", ["install", "--ignore-scripts", "--no-audit", "--no-fund", tarball], { cwd: consumer, env, stdio: "inherit" });
  writeFileSync(join(consumer, "index.html"), '<!doctype html><html><body><output id="result">WAITING</output><script type="module" src="/main.js"></script></body></html>');
  writeFileSync(join(consumer, "main.js"), `import * as zf from "zigfitsio";
const result = document.getElementById("result");
try {
  await zf.ready();
  const original = [11, 22, 33, 44];
  const data = new zf.FitsArray(new Int16Array(original), [2, 2]);
  const hdul = zf.fromBytes(new zf.HDUList([new zf.PrimaryHDU({ data })]).toBytes());
  try {
    if (JSON.stringify([...hdul.get(0).data.data]) !== JSON.stringify(original)) throw new Error("pixel mismatch");
    if (JSON.stringify(hdul.get(0).data.shape) !== "[2,2]") throw new Error("shape mismatch");
  } finally { hdul.close(); }
  result.textContent = "ZIGFITSIO_BROWSER_PASS";
} catch (error) { result.textContent = "ZIGFITSIO_BROWSER_FAIL: " + error.stack; }
`);
  execFileSync(process.execPath, [vite, "build"], { cwd: consumer, env, stdio: "inherit" });
  server = spawn(process.execPath, [vite, "preview", "--host", "127.0.0.1", "--port", "4173", "--strictPort"], { cwd: consumer, env, stdio: ["ignore", "inherit", "inherit"] });
  const url = "http://127.0.0.1:4173";
  let listening = false;
  for (let i = 0; i < 100; i++) {
    if (server.exitCode !== null) throw new Error(`Vite preview exited ${server.exitCode}`);
    try { listening = (await fetch(url)).ok; } catch {}
    if (listening) break;
    await delay(100);
  }
  assert.ok(listening, "Vite preview did not start");
  const profile = join(consumer, "chrome");
  browser = spawn(chrome, ["--headless", "--no-sandbox", "--disable-gpu", "--disable-background-networking", "--no-first-run", `--user-data-dir=${profile}`, "--remote-debugging-port=0", "about:blank"], { env, stdio: ["ignore", "ignore", "pipe"] });
  let chromeLog = "";
  browser.stderr.on("data", (data) => { chromeLog = (chromeLog + data).slice(-8192); });
  const portFile = join(profile, "DevToolsActivePort");
  for (let i = 0; i < 100 && !existsSync(portFile); i++) {
    if (browser.exitCode !== null) throw new Error(`Chrome exited ${browser.exitCode}: ${chromeLog}`);
    await delay(100);
  }
  assert.ok(existsSync(portFile), `Chrome debugging port did not start: ${chromeLog}`);
  const port = readFileSync(portFile, "utf8").split("\n")[0];
  const response = await fetch(`http://127.0.0.1:${port}/json/new?${encodeURIComponent(url)}`, { method: "PUT", signal: AbortSignal.timeout(10000) });
  assert.ok(response.ok, "Chrome could not open the consumer page");
  const target = await response.json();
  socket = new WebSocket(target.webSocketDebuggerUrl);
  await once(socket, "open", { signal: AbortSignal.timeout(10000) });
  let id = 0;
  const resultText = () => new Promise((resolve, reject) => {
    const requestId = ++id;
    const finish = (error, value) => {
      clearTimeout(timer);
      socket.removeEventListener("message", onMessage);
      if (error) reject(error); else resolve(value);
    };
    const onMessage = (event) => {
      const message = JSON.parse(event.data);
      if (message.id !== requestId) return;
      if (message.error) finish(new Error(message.error.message));
      else finish(null, message.result.result.value);
    };
    const timer = setTimeout(() => finish(new Error("Chrome evaluation timed out")), 5000);
    socket.addEventListener("message", onMessage);
    socket.send(JSON.stringify({ id: requestId, method: "Runtime.evaluate", params: { expression: 'document.getElementById("result")?.textContent', returnByValue: true } }));
  });
  let result;
  for (let i = 0; i < 100; i++) {
    result = await resultText();
    if (result?.startsWith("ZIGFITSIO_BROWSER_")) break;
    await delay(200);
  }
  assert.equal(result, "ZIGFITSIO_BROWSER_PASS", `Browser round trip did not pass: ${result}; ${chromeLog}`);
  console.log("PASS: packed package, Vite production build, Chrome, default ready() wasm fetch");
} finally {
  socket?.close();
  for (const child of [browser, server]) {
    if (child && child.exitCode === null) {
      const exited = once(child, "exit");
      child.kill();
      await Promise.race([exited, delay(1000)]);
    }
  }
  rmSync(consumer, { recursive: true, force: true });
}

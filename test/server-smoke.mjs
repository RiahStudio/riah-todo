// The board listens on loopback, which every website in the browser can reach.
// This proves a page cannot use that to rewrite the list, and that the board's
// own requests still work.
//
//   node test/server-smoke.mjs

import { spawn } from "node:child_process";
import { mkdtempSync, writeFileSync } from "node:fs";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";

const here = path.dirname(fileURLToPath(import.meta.url));
const app = path.join(here, "..");
const dir = mkdtempSync(path.join(os.tmpdir(), "riah-todo-server-"));
const file = path.join(dir, "today.json");

// Ask the OS for a free port rather than hard-coding one: a leftover server on
// a fixed port would answer these probes from a different file and quietly turn
// the whole test into a lie.
const { createServer } = await import("node:net");
const PORT = await new Promise((resolve, reject) => {
  const probe = createServer();
  probe.once("error", reject);
  probe.listen(0, "127.0.0.1", () => {
    const { port } = probe.address();
    probe.close(() => resolve(port));
  });
});
const base = `http://127.0.0.1:${PORT}`;

writeFileSync(file, JSON.stringify({ date: new Date().toISOString().slice(0, 10), items: [] }));

function fail(message) {
  console.error(`SERVER_SMOKE_FAILED: ${message}`);
  server.kill();
  process.exit(1);
}

const server = spawn(process.execPath, [path.join(app, "server.mjs")], {
  env: { ...process.env, RIAH_TODO_FILE: file, RIAH_TODO_PORT: String(PORT) },
  stdio: "ignore",
});
process.on("exit", () => server.kill());

async function waitForBoard() {
  for (let attempt = 0; attempt < 60; attempt += 1) {
    try {
      const res = await fetch(`${base}/api/list`);
      if (res.ok) return;
    } catch { /* not up yet */ }
    await new Promise((resolve) => setTimeout(resolve, 100));
  }
  fail("the board never came up.");
}
await waitForBoard();

async function count() {
  const payload = await (await fetch(`${base}/api/list`)).json();
  return payload.priorities.items.length;
}

// 1. The attack that worked on 2026-07-29: a "simple request" that dodges CORS
//    preflight entirely, carrying a foreign Origin.
const simple = await fetch(`${base}/api/add`, {
  method: "POST",
  headers: { "content-type": "text/plain", origin: "https://example.invalid" },
  body: JSON.stringify({ label: "INJECTED BY A WEBSITE" }),
});
if (simple.status === 200) fail("a cross-origin text/plain POST was accepted.");
if (await count() !== 0) fail("a website managed to add a task.");

// 2. Correct content type but still someone else's page.
const foreignJson = await fetch(`${base}/api/add`, {
  method: "POST",
  headers: { "content-type": "application/json", origin: "https://example.invalid" },
  body: JSON.stringify({ label: "ALSO INJECTED" }),
});
if (foreignJson.status === 200) fail("a cross-origin JSON POST was accepted.");
if (await count() !== 0) fail("a website managed to add a task with a JSON content type.");

// 3. A rebound DNS name pointing at loopback must not be served at all.
//    This has to go through node:http — fetch() treats Host as a forbidden
//    header and silently drops it, so a fetch-based probe proves nothing.
const { request } = await import("node:http");
const rebindStatus = await new Promise((resolve, reject) => {
  const req = request(
    { host: "127.0.0.1", port: PORT, path: "/api/list", method: "GET", headers: { Host: "evil.example" } },
    (res) => { res.resume(); resolve(res.statusCode); },
  );
  req.on("error", reject);
  req.end();
});
if (rebindStatus !== 403) fail(`a foreign Host header was served (${rebindStatus}).`);

// 4. The board's own request must still work.
const ours = await fetch(`${base}/api/add`, {
  method: "POST",
  headers: { "content-type": "application/json", origin: base },
  body: JSON.stringify({ label: "Added by the board" }),
});
if (!ours.ok) fail(`the board's own request was rejected (${ours.status}).`);
if (await count() !== 1) fail("the board's own add did not land.");

// 5. And a local script with no Origin at all (the tray's health check, curl).
const noOrigin = await fetch(`${base}/api/add`, {
  method: "POST",
  headers: { "content-type": "application/json" },
  body: JSON.stringify({ label: "Added by a local script" }),
});
if (!noOrigin.ok) fail(`a local no-Origin request was rejected (${noOrigin.status}).`);
if (await count() !== 2) fail("the local script's add did not land.");

server.kill();
console.log(
  "SERVER_SMOKE_OK cross_origin_simple=blocked cross_origin_json=blocked "
  + "dns_rebind=blocked own_page=allowed local_script=allowed",
);

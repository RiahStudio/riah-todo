// The board listens on loopback, which every website in the browser can reach.
// This proves a page cannot use that to rewrite the list, and that the board's
// own requests still work.
//
//   node test/server-smoke.mjs

import { spawn } from "node:child_process";
import { mkdtempSync, rmSync, writeFileSync } from "node:fs";
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

// 6. Path traversal. A string-prefix containment check passes for a sibling
//    folder whose name merely starts the same way, and misses encoded and
//    backslash forms entirely.
// A plain "/../x" is normalised to "/x" by the URL parser before it ever
// reaches us, so the forms that actually matter are the encoded ones the parser
// leaves alone. A sentinel is dropped one level up: nothing may ever return it.
const sentinelName = `riah-todo-traversal-${Date.now()}.txt`;
const sentinelBody = "IF-YOU-CAN-READ-THIS-THE-SERVER-ESCAPED-ITS-FOLDER";
const sentinel = path.join(app, "..", sentinelName);
writeFileSync(sentinel, sentinelBody);

const traversals = [
  `/..%2f${sentinelName}`,
  `/%2e%2e%2f${sentinelName}`,
  `/..%5c${sentinelName}`,                 // encoded Windows backslash
  `/%2e%2e%5c${sentinelName}`,
  `/%2e%2e%2f%2e%2e%2f${sentinelName}`,
  `/....//${sentinelName}`,
  `/%252e%252e%252f${sentinelName}`,       // double-encoded
  "/%2e%2e%2f%2e%2e%2f%2e%2e%2fWindows/win.ini",
  "/C:/Windows/win.ini",
];
try {
  for (const attempt of traversals) {
    const res = await fetch(`${base}${attempt}`);
    const body = await res.text();
    if (body.includes(sentinelBody)) fail(`path traversal escaped the app folder: ${attempt}`);
    if (body.includes("[extensions]") || body.includes("[fonts]")) {
      fail(`path traversal reached a system file: ${attempt}`);
    }
    if (res.status === 200) fail(`traversal attempt was answered 200 instead of refused: ${attempt}`);
  }
} finally {
  rmSync(sentinel, { force: true });
}

// And the files it SHOULD serve still work.
const page = await fetch(`${base}/`);
if (!page.ok) fail("the board page itself stopped being served.");
const asset = await fetch(`${base}/assets/riah-todo.svg`);
if (!asset.ok) fail("a legitimate asset stopped being served.");

server.kill();
console.log(
  "SERVER_SMOKE_OK cross_origin_simple=blocked cross_origin_json=blocked "
  + `dns_rebind=blocked traversal=blocked(${traversals.length}) own_page=allowed local_script=allowed`,
);

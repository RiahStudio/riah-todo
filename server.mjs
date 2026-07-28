// Riah To-Do — the board.
//
// Optional. The tray sticky note talks straight to the file, so nothing here
// needs to be running for Captain to tick something off. This server exists so
// the same list can be opened as a full page (and so a phone on the LAN could
// read it later without a rewrite).

import { createReadStream, existsSync, statSync } from "node:fs";
import http from "node:http";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { MAX_ITEMS, MAX_SUBTASKS, ops, readPriorities, readSettings, storePath } from "./lib/store.mjs";

const here = path.dirname(fileURLToPath(import.meta.url));
const PORT = Number(process.env.RIAH_TODO_PORT || 8779);
const HOST = "127.0.0.1";

const TYPES = {
  ".html": "text/html; charset=utf-8",
  ".css": "text/css; charset=utf-8",
  ".js": "text/javascript; charset=utf-8",
  ".svg": "image/svg+xml",
  ".png": "image/png",
  ".woff2": "font/woff2",
  ".json": "application/json; charset=utf-8",
};

function sendJson(res, status, body) {
  const payload = JSON.stringify(body);
  res.writeHead(status, {
    "content-type": "application/json; charset=utf-8",
    "cache-control": "no-store",
    "content-length": Buffer.byteLength(payload),
  });
  res.end(payload);
}

async function readBody(req) {
  const chunks = [];
  let size = 0;
  for await (const chunk of req) {
    size += chunk.length;
    if (size > 64 * 1024) throw new Error("Request is too large.");
    chunks.push(chunk);
  }
  if (chunks.length === 0) return {};
  return JSON.parse(Buffer.concat(chunks).toString("utf8"));
}

function serveStatic(req, res, urlPath) {
  const rel = urlPath === "/" ? "index.html" : decodeURIComponent(urlPath).replace(/^\/+/, "");
  const file = path.join(here, rel);
  // Never serve outside the app folder, whatever the URL claims.
  if (!file.startsWith(here) || !existsSync(file) || !statSync(file).isFile()) {
    res.writeHead(404, { "content-type": "text/plain; charset=utf-8" });
    res.end("Not found");
    return;
  }
  res.writeHead(200, {
    "content-type": TYPES[path.extname(file).toLowerCase()] || "application/octet-stream",
    "cache-control": "no-store",
  });
  createReadStream(file).pipe(res);
}

async function handleApi(req, res, urlPath) {
  if (req.method === "GET" && urlPath === "/api/list") {
    sendJson(res, 200, {
      ok: true,
      priorities: readPriorities(),
      settings: readSettings(),
      max: MAX_ITEMS,
      maxSubtasks: MAX_SUBTASKS,
    });
    return;
  }
  if (req.method !== "POST") {
    sendJson(res, 405, { ok: false, error: "Method not allowed." });
    return;
  }
  const body = await readBody(req);
  switch (urlPath) {
    case "/api/add":
      sendJson(res, 200, { ok: true, priorities: ops.add(body.label, { parentId: body.parentId ?? null }) });
      return;
    case "/api/move":
      sendJson(res, 200, { ok: true, priorities: ops.moveBefore(body.id, body.beforeId ?? null) });
      return;
    case "/api/set-parent":
      sendJson(res, 200, { ok: true, priorities: ops.setParent(body.id, body.parentId ?? null) });
      return;
    case "/api/settings":
      sendJson(res, 200, { ok: true, settings: ops.saveSettings(body), priorities: readPriorities() });
      return;
    case "/api/toggle":
      sendJson(res, 200, { ok: true, priorities: ops.toggle(body.id) });
      return;
    case "/api/rename":
      sendJson(res, 200, { ok: true, priorities: ops.rename(body.id, body.label) });
      return;
    case "/api/remove":
      sendJson(res, 200, { ok: true, priorities: ops.remove(body.id) });
      return;
    case "/api/reorder":
      sendJson(res, 200, { ok: true, priorities: ops.reorder(body.ids) });
      return;
    case "/api/replace":
      sendJson(res, 200, { ok: true, priorities: ops.replace(body.labels) });
      return;
    case "/api/clear-completed":
      sendJson(res, 200, { ok: true, priorities: ops.clearCompleted() });
      return;
    default:
      sendJson(res, 404, { ok: false, error: "Unknown endpoint." });
  }
}

const server = http.createServer((req, res) => {
  const urlPath = new URL(req.url || "/", `http://${HOST}`).pathname;
  if (urlPath.startsWith("/api/")) {
    handleApi(req, res, urlPath).catch((error) => {
      // A rejected change is a message, not a stack trace: the board shows this
      // text straight to Captain.
      sendJson(res, 400, { ok: false, error: error instanceof Error ? error.message : String(error) });
    });
    return;
  }
  serveStatic(req, res, urlPath);
});

server.on("error", (error) => {
  if (error && error.code === "EADDRINUSE") {
    console.log(`Riah To-Do is already open on http://${HOST}:${PORT}`);
    process.exit(0);
  }
  console.error(`Riah To-Do could not start: ${error.message}`);
  process.exit(1);
});

server.listen(PORT, HOST, () => {
  console.log(`Riah To-Do board  http://${HOST}:${PORT}`);
  console.log(`List file              ${storePath()}`);
});

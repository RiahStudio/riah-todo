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
import {
  MAX_DEPTH, MAX_ITEMS, MAX_SUBTASKS, ops, readFiled, readPriorities, readPrioritiesForDisplay, readSettings,
  SECTIONS, SECTION_LABELS,
  storePath, undoAvailable,
} from "./lib/store.mjs";

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

/**
 * Refuse anything a web page could aim at this server.
 *
 * A loopback server is reachable by every site the browser has open. Without
 * this, `fetch("http://127.0.0.1:8779/api/add", {method:"POST", body:...})` from
 * any page rewrites Captain's list — proved on 2026-07-29 with a `text/plain`
 * POST carrying a foreign Origin, which sails past CORS preflight entirely
 * because it is a "simple request".
 *
 * Two gates, both required for state-changing routes:
 *   1. An Origin, if present, must be this server. Cross-site fetches always
 *      carry one; the board's own fetches carry ours.
 *   2. The content type must be application/json, which a form or a simple
 *      request cannot set without triggering a preflight we never answer.
 */
function sameOrigin(req) {
  const origin = req.headers.origin;
  if (!origin) return true; // curl, the tray's health check, a local script.
  const allowed = [
    `http://127.0.0.1:${PORT}`,
    `http://localhost:${PORT}`,
    `http://[::1]:${PORT}`,
  ];
  return allowed.includes(origin.toLowerCase());
}

function jsonRequest(req) {
  const type = String(req.headers["content-type"] || "").split(";")[0].trim().toLowerCase();
  return type === "application/json";
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
  let rel;
  try {
    rel = urlPath === "/" ? "index.html" : decodeURIComponent(urlPath).replace(/^[/\\]+/, "");
  } catch {
    // A malformed percent-escape is not a path.
    res.writeHead(400, { "content-type": "text/plain; charset=utf-8" });
    res.end("Bad request");
    return;
  }
  const file = path.resolve(here, rel);
  // A string prefix is not containment: "…\Riah To-Do-evil" starts with
  // "…\Riah To-Do". Ask the path module whether it is genuinely inside, which
  // also settles encoded traversal and Windows backslashes.
  const inside = path.relative(here, file);
  const escapes = inside === "" || inside.startsWith("..") || path.isAbsolute(inside);
  if (escapes || !existsSync(file) || !statSync(file).isFile()) {
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
    // An unreadable list is reported as needing recovery. Rendering a convincing
    // empty list is how somebody types work on top of the file they just lost.
    const shown = readPrioritiesForDisplay();
    if (!shown.ok) {
      sendJson(res, 200, {
        ok: true, needsRecovery: true, error: shown.error, file: shown.file,
        priorities: { date: "", items: [] }, settings: readSettings(),
        max: MAX_ITEMS, maxSubtasks: MAX_SUBTASKS, maxDepth: MAX_DEPTH,
      });
      return;
    }
    sendJson(res, 200, {
      ok: true,
      priorities: shown.priorities,
      undo: undoAvailable(),
      settings: readSettings(),
      max: MAX_ITEMS,
      maxSubtasks: MAX_SUBTASKS,
      maxDepth: MAX_DEPTH,
      sections: SECTIONS,
      sectionLabels: SECTION_LABELS,
    });
    return;
  }
  if (req.method === "GET" && urlPath === "/api/filed") {
    sendJson(res, 200, { ok: true, filed: readFiled() });
    return;
  }
  if (req.method !== "POST") {
    sendJson(res, 405, { ok: false, error: "Method not allowed." });
    return;
  }
  if (!sameOrigin(req)) {
    sendJson(res, 403, { ok: false, error: "This list only takes changes from its own page." });
    return;
  }
  if (!jsonRequest(req)) {
    sendJson(res, 415, { ok: false, error: "Changes must be sent as application/json." });
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
    case "/api/set-section":
      sendJson(res, 200, { ok: true, priorities: ops.setSection(body.id, body.section) });
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
    case "/api/undo":
      sendJson(res, 200, { ok: true, priorities: ops.undo() });
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
  // DNS rebinding: a hostile name can resolve to 127.0.0.1 and then read the
  // page and the list as same-origin. Only answer to loopback names.
  const host = String(req.headers.host || "").split(":")[0].toLowerCase();
  if (host && !["127.0.0.1", "localhost", "[::1]", "::1"].includes(host)) {
    res.writeHead(403, { "content-type": "text/plain; charset=utf-8" });
    res.end("Riah To-Do only answers on localhost.");
    return;
  }
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

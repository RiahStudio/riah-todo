#!/usr/bin/env node
// Customer launcher: start the board with no terminal left open.
// Windows keeps the tray note as the main surface (use Open The Board.bat
// when you want this page). Mac and Linux have no tray — this opens the board.

import { exec, spawn } from "node:child_process";
import fs from "node:fs";
import net from "node:net";
import path from "node:path";
import { fileURLToPath } from "node:url";

const ROOT = path.dirname(fileURLToPath(import.meta.url));
const PORT = Number(process.env.RIAH_TODO_PORT) || 8779;
const HOST = "127.0.0.1";
const URL = `http://${HOST}:${PORT}/`;
const SCRATCH = path.join(ROOT, "scratch");
const PID_FILE = path.join(SCRATCH, "board.pid");
const LOG_FILE = path.join(SCRATCH, "board.log");

function isUp() {
  return new Promise((resolve) => {
    const s = net.connect({ host: HOST, port: PORT }, () => {
      s.end();
      resolve(true);
    });
    s.on("error", () => resolve(false));
  });
}

function sleep(ms) {
  return new Promise((r) => setTimeout(r, ms));
}

function shouldOpenBrowser() {
  if (process.env.RIAH_TODO_NO_BROWSER === "1") return false;
  if (process.env.RIAH_TODO_OPEN_BROWSER === "1") return true;
  return process.platform !== "win32";
}

function openBrowser(url) {
  if (!shouldOpenBrowser()) return;
  const plat = process.platform;
  if (plat === "win32") exec(`start "" "${url}"`);
  else if (plat === "darwin") exec(`open "${url}"`);
  else exec(`xdg-open "${url}"`);
}

async function waitUntilUp(ms) {
  const end = Date.now() + ms;
  while (Date.now() < end) {
    if (await isUp()) return true;
    await sleep(200);
  }
  return false;
}

async function main() {
  if (await isUp()) {
    openBrowser(URL);
    return;
  }

  fs.mkdirSync(SCRATCH, { recursive: true });
  const out = fs.openSync(LOG_FILE, "a");
  fs.writeSync(out, `\n--- start ${new Date().toISOString()} ---\n`);

  const child = spawn(process.execPath, [path.join(ROOT, "server.mjs")], {
    cwd: ROOT,
    detached: true,
    stdio: ["ignore", out, out],
    windowsHide: true,
    env: {
      ...process.env,
      RIAH_TODO_PORT: String(PORT),
    },
  });

  fs.writeFileSync(PID_FILE, String(child.pid), "utf8");
  child.unref();

  const ready = await waitUntilUp(15 * 1000);
  if (!ready) {
    process.exitCode = 1;
    return;
  }
  openBrowser(URL);
}

main().catch((e) => {
  try {
    fs.appendFileSync(LOG_FILE, String(e && e.stack ? e.stack : e) + "\n");
  } catch {
    /* ignore */
  }
  process.exit(1);
});

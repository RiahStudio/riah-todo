// Drives the real tray note the way a click drives it, then checks the file.
//
// This is the proof that the PowerShell side and the Node side agree: the note
// writes the list, and `lib/store.mjs` reads back exactly what it wrote. It also
// leaves a PNG of the note so the look can be checked without touching a mouse.
//
//   node test/note-smoke.mjs

import { spawnSync } from "node:child_process";
import { existsSync, mkdtempSync, readFileSync, readdirSync, writeFileSync } from "node:fs";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";

const here = path.dirname(fileURLToPath(import.meta.url));
const trayScript = path.join(here, "..", "tray", "riah-todo-tray.ps1");
const dir = mkdtempSync(path.join(os.tmpdir(), "riah-todo-note-"));
const file = path.join(dir, "today.json");
const shot = path.join(dir, "note.png");
const vault = path.join(dir, "vault");

function fail(message) {
  console.error(`TRAY_NOTE_SMOKE_FAILED: ${message}`);
  process.exit(1);
}

writeFileSync(file, JSON.stringify({
  date: new Date().toISOString().slice(0, 10),
  items: [
    { id: "seed-1", label: "Gumroad Shovels", completed: false, completedAt: null },
    { id: "seed-2", label: "Finish the Selah gauntlet brief", completed: true, completedAt: new Date().toISOString() },
    { id: "seed-3", label: "Call the accountant back about the quarterly filing", completed: false, completedAt: null },
  ],
}, null, 2));

function runTray(env) {
  const result = spawnSync("powershell.exe", [
    "-NoProfile", "-ExecutionPolicy", "Bypass", "-STA", "-File", trayScript,
  ], {
    env: { ...process.env, RIAH_TODO_FILE: file, ...env },
    encoding: "utf8",
    windowsHide: true,
    timeout: 120_000,
  });
  return `${result.stdout || ""}${result.stderr || ""}`.trim();
}

const output = runTray({ RIAH_TODO_TRAY_SHOT: shot, RIAH_TODO_TRAY_EXERCISE: "1" });
if (!output.includes("TRAY_NOTE_OK")) fail(`the note never drew itself: ${output || "(no output)"}`);
if (!existsSync(shot)) fail(`no picture of the note was saved at ${shot}`);

// Read it back through the Node store — if the two sides disagree on the format,
// this is where it shows up.
process.env.RIAH_TODO_FILE = file;
const { readPriorities } = await import("../lib/store.mjs");
const list = readPriorities({ sweep: false });
const labels = list.items.map((item) => item.label);

if (!labels.includes("Added by the note")) {
  fail(`the note's add never reached the file: ${JSON.stringify(labels)}`);
}
if (labels.length !== 6) fail(`expected 6 items after the exercise, got ${JSON.stringify(labels)}`);

const ticked = list.items.find((item) => item.label === "Gumroad Shovels");
if (!ticked?.completed) fail("the note's tick never reached the file.");
if (!ticked.completedAt || Number.isNaN(Date.parse(ticked.completedAt))) {
  fail(`the note wrote an unusable completion stamp: ${ticked.completedAt}`);
}
const untouched = list.items.find((item) => item.label === "Finish the Selah gauntlet brief");
if (!untouched?.completed) fail("the note lost a tick that was already in the file.");

// Threads: the subtasks must exist, hang off the right task, and sit under it.
const host = list.items.find((item) => item.label === "Added by the note");
const steps = list.items.filter((item) => item.parentId === host?.id);
if (steps.length !== 2) {
  fail(`the note's subtasks did not survive the write: ${JSON.stringify(list.items, null, 2)}`);
}
if (labels[0] !== "Added by the note" || labels[1] !== "Step one" || labels[2] !== "Step two") {
  fail(`dragging the task to the top did not bring its thread: ${JSON.stringify(labels)}`);
}
if (!host.completed || !steps.every((step) => step.completed)) {
  fail("ticking the task did not tick its thread.");
}

// --- auto-filing, with a vault trail ---
// Second pass: turn the window down to nothing and point it at a vault. On the
// next start the note should file everything ticked and leave a dated markdown
// trail behind — the thing Captain actually asked for.
writeFileSync(path.join(dir, "settings.json"), JSON.stringify({
  fileAfterMinutes: 0,
  vaultPath: vault,
  vaultSubfolder: "done",
}, null, 2));

const second = runTray({ RIAH_TODO_TRAY_SHOT: path.join(dir, "note-2.png") });
if (!second.includes("TRAY_NOTE_OK")) fail(`the note failed on the filing pass: ${second || "(no output)"}`);

const afterFiling = readPriorities({ sweep: false });
const leftBehind = afterFiling.items.filter((item) => item.completed);
if (leftBehind.length > 0) {
  fail(`"file straight away" left ticked items on the list: ${JSON.stringify(leftBehind.map((i) => i.label))}`);
}
if (!afterFiling.items.some((item) => item.label.startsWith("Call the accountant"))) {
  fail("filing took an item that was never ticked.");
}

const trailDir = path.join(vault, "done");
if (!existsSync(trailDir)) fail(`no vault trail folder at ${trailDir}`);
const notes = readdirSync(trailDir).filter((name) => name.endsWith(".md"));
if (notes.length !== 1) fail(`expected one dated note in the vault, got ${JSON.stringify(notes)}`);
const trail = readFileSync(path.join(trailDir, notes[0]), "utf8");
if (!/^# Done - \d{4}-\d\d-\d\d/m.test(trail)) fail(`the vault note has no dated heading:\n${trail}`);
if (!trail.includes("Added by the note")) fail(`the vault note is missing a filed task:\n${trail}`);
if (!/^ {2}- \[x\] .*Step one$/m.test(trail)) {
  fail(`subtasks are not indented under their task in the vault note:\n${trail}`);
}

const filed = JSON.parse(readFileSync(path.join(dir, "today-filed.json"), "utf8"));
if (!filed.some((item) => item.label === "Step one" && item.parentId)) {
  fail("the JSON archive lost which task a filed step belonged to.");
}

console.log(
  `TRAY_NOTE_SMOKE_OK add=true tick=true stamp=true read_back=true `
  + `subtasks=true thread_tick=true drag_reorder=true auto_file=true vault_trail=true shot=${shot}`,
);

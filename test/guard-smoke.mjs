// The one unacceptable failure: a bad read turning into a good write, and a
// day's priorities getting flattened.
//
// On 2026-07-29 the note booted, logged "items=0" against a file that held three
// open priorities, and did not throw. Nothing was lost that time because nothing
// wrote afterwards. This proves that even when the note believes the list is
// empty, it cannot overwrite a file that still has work in it.
//
//   node test/guard-smoke.mjs

import { spawnSync } from "node:child_process";
import { mkdtempSync, readFileSync, writeFileSync } from "node:fs";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";

const here = path.dirname(fileURLToPath(import.meta.url));
const trayScript = path.join(here, "..", "tray", "riah-todo-tray.ps1");

function fail(message) {
  console.error(`GUARD_SMOKE_FAILED: ${message}`);
  process.exit(1);
}

// A PowerShell harness that loads the tray's own functions without starting the
// UI, then asks Write-Store to flatten a real list. Dot-sourcing is not possible
// (the script runs a message loop), so it takes the file up to the marker.
const dir = mkdtempSync(path.join(os.tmpdir(), "riah-todo-guard-"));
const file = path.join(dir, "today.json");
const real = {
  date: new Date().toISOString().slice(0, 10),
  items: [
    { id: "a", label: "Gumroad Shovels", completed: false, completedAt: null, parentId: null },
    { id: "b", label: "Selah Launch", completed: false, completedAt: null, parentId: null },
    { id: "c", label: "Riah Swipe", completed: false, completedAt: null, parentId: null },
  ],
};
writeFileSync(file, JSON.stringify(real, null, 2));

const source = readFileSync(trayScript, "utf8");
const cut = source.indexOf("# --- look: the Riah interface signature, drawn ---");
if (cut < 0) fail("could not find the marker that separates the data layer from the UI.");
const dataLayer = source.slice(0, cut);

const harness = `
$ErrorActionPreference = 'SilentlyContinue'
${dataLayer}

# 1. A healthy read must see all three.
$list = Read-Store
Write-Host ("read=" + @($list.items).Count)

# 2. Now play the incident: the note thinks the list is empty and tries to save.
$empty = @{ date = $list.date; items = @() }
$blocked = Write-Store $empty
Write-Host ("blocked=" + ($blocked -eq $false))

# 3. And a DELIBERATE empty (last item removed) must still be allowed through.
$script:AllowEmptyWrite = $true
$ok = Write-Store $empty
Write-Host ("deliberate=" + ($ok -eq $true))
`;
const harnessFile = path.join(dir, "harness.ps1");
writeFileSync(harnessFile, harness, "utf8");

const run = spawnSync("powershell.exe", [
  // -STA or the copied header relaunches the harness and exits with no output.
  "-NoProfile", "-ExecutionPolicy", "Bypass", "-STA", "-File", harnessFile,
], {
  env: {
    ...process.env,
    RIAH_TODO_FILE: file,
    // Skips the single-instance mutex, which the live note is holding. Nothing
    // in the copied slice draws anything, so no window is ever created.
    RIAH_TODO_TRAY_SHOT: path.join(dir, "unused.png"),
  },
  encoding: "utf8",
  windowsHide: true,
  timeout: 120_000,
});
const out = `${run.stdout || ""}${run.stderr || ""}`;

if (!out.includes("read=3")) fail(`the data layer could not read a healthy file: ${out.trim()}`);

// The file must still hold all three after the blocked write.
const afterBlock = JSON.parse(readFileSync(file, "utf8"));
if (!out.includes("blocked=True")) {
  fail(`an empty list was allowed to overwrite a real one. File now: ${JSON.stringify(afterBlock.items)}`);
}

if (!out.includes("deliberate=True")) {
  fail(`a deliberate clear was blocked too — that would make removing the last item impossible: ${out.trim()}`);
}
const afterDeliberate = JSON.parse(readFileSync(file, "utf8"));
if (afterDeliberate.items.length !== 0) {
  fail("a deliberate clear did not actually clear the file.");
}

console.log("GUARD_SMOKE_OK healthy_read=3 accidental_empty=blocked deliberate_empty=allowed");

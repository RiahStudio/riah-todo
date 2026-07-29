// Four surfaces share one file — the note, the board, Riah Code and the MCP
// tools. Before locking, twelve simultaneous adds reliably left five to eight:
// each writer read the same "before" state and overwrote the others' work.
//
// This runs the same race and demands all twelve survive.
//
//   node test/concurrency-smoke.mjs [trials]

import { spawn } from "node:child_process";
import { mkdtempSync, writeFileSync } from "node:fs";
import os from "node:os";
import path from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";

const here = path.dirname(fileURLToPath(import.meta.url));
const storeUrl = pathToFileURL(path.join(here, "..", "lib", "store.mjs")).href;
const WRITERS = 12;
const TRIALS = Number(process.argv[2] || 3);

const dir = mkdtempSync(path.join(os.tmpdir(), "riah-todo-race-"));
const file = path.join(dir, "today.json");

/**
 * Each writer reports what happened, because "the task is not there" has two
 * very different causes: a SILENT LOSS (the bug) or an honest REFUSAL because
 * the lock could not be had (safe, but it means the timeout is too tight).
 * A test that cannot tell them apart sends you hunting the wrong thing.
 */
function writer(label) {
  return new Promise((resolve) => {
    const code = `import(${JSON.stringify(storeUrl)})`
      + `.then((s) => s.ops.add(${JSON.stringify(label)}))`
      + `.then(() => process.stdout.write("ok"))`
      + `.catch((e) => process.stdout.write("ERR:" + e.message));`;
    const child = spawn(process.execPath, ["--input-type=module", "-e", code], {
      env: { ...process.env, RIAH_TODO_FILE: file },
      stdio: ["ignore", "pipe", "ignore"],
    });
    let out = "";
    child.stdout.on("data", (chunk) => { out += chunk; });
    child.on("exit", () => resolve(out));
  });
}

process.env.RIAH_TODO_FILE = file;
const { readPriorities } = await import(storeUrl);

const survivors = [];
const refusals = [];
const silentLosses = [];
for (let trial = 0; trial < TRIALS; trial += 1) {
  writeFileSync(file, JSON.stringify({ date: new Date().toISOString().slice(0, 10), items: [] }));
  // All twelve are launched before any of them finishes — that is the race.
  const results = await Promise.all(Array.from({ length: WRITERS }, (_, i) => writer(`Task ${i + 1}`)));
  const refused = results.filter((r) => r.startsWith("ERR:")).length;
  const claimedOk = results.filter((r) => r === "ok").length;
  const landed = readPriorities({ sweep: false, file }).items.length;
  survivors.push(landed);
  refusals.push(refused);
  // The unforgivable case: a writer was told it succeeded and the work is gone.
  if (landed < claimedOk) silentLosses.push({ trial, claimedOk, landed });
}

if (silentLosses.length > 0) {
  console.error(
    `CONCURRENCY_SMOKE_FAILED: work vanished after a successful write — ${JSON.stringify(silentLosses)}.`
    + " This is a genuine lost update, not a refusal.",
  );
  process.exit(1);
}
const totalRefused = refusals.reduce((a, b) => a + b, 0);
if (totalRefused > 0) {
  console.error(
    `CONCURRENCY_SMOKE_FAILED: ${totalRefused} writer(s) were refused the lock across ${TRIALS} trial(s)`
    + ` (survivors: ${survivors.join(", ")}). Nothing was lost, but ordinary contention should not`
    + " turn a person's tick into an error — the lock timeout is too tight.",
  );
  process.exit(1);
}
console.log(
  `CONCURRENCY_SMOKE_OK writers=${WRITERS} trials=${TRIALS} survivors=${survivors.join(",")}`
  + " no_lost_updates=true no_refusals=true",
);

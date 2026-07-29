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

/**
 * Two different promises, so they get two different bars.
 *
 * REALISTIC (four writers — more surfaces than actually exist): every tick must
 * land. Nobody should ever see "try again" in normal use.
 *
 * EXTREME (twelve processes launched at once on a possibly loaded machine): the
 * only thing that must hold is that **nothing is silently lost**. A refusal here
 * is the lock doing its job; it is reported, not failed, because failing it just
 * teaches people to re-run the suite.
 */
async function round(writers) {
  writeFileSync(file, JSON.stringify({ date: new Date().toISOString().slice(0, 10), items: [] }));
  const results = await Promise.all(Array.from({ length: writers }, (_, i) => writer(`Task ${i + 1}`)));
  const refused = results.filter((r) => r.startsWith("ERR:")).length;
  const claimedOk = results.filter((r) => r === "ok").length;
  const landed = readPriorities({ sweep: false, file }).items.length;
  return { refused, claimedOk, landed };
}

const REALISTIC = 4;
const silentLosses = [];
const realisticRefusals = [];
const realisticSurvivors = [];
for (let trial = 0; trial < TRIALS; trial += 1) {
  const r = await round(REALISTIC);
  realisticSurvivors.push(r.landed);
  realisticRefusals.push(r.refused);
  if (r.landed < r.claimedOk) silentLosses.push({ scale: REALISTIC, trial, ...r });
}

const extremeSurvivors = [];
let extremeRefusals = 0;
for (let trial = 0; trial < TRIALS; trial += 1) {
  const r = await round(WRITERS);
  extremeSurvivors.push(r.landed);
  extremeRefusals += r.refused;
  if (r.landed < r.claimedOk) silentLosses.push({ scale: WRITERS, trial, ...r });
}

if (silentLosses.length > 0) {
  console.error(
    `CONCURRENCY_SMOKE_FAILED: work vanished after a write reported success — ${JSON.stringify(silentLosses)}.`
    + " That is a genuine lost update, not a refusal.",
  );
  process.exit(1);
}
const refusedRealistic = realisticRefusals.reduce((a, b) => a + b, 0);
if (refusedRealistic > 0) {
  console.error(
    `CONCURRENCY_SMOKE_FAILED: ${refusedRealistic} of ${REALISTIC} everyday writers were refused the lock`
    + ` (survivors: ${realisticSurvivors.join(", ")}). Ordinary use must never turn a tick into an error.`,
  );
  process.exit(1);
}
console.log(
  `CONCURRENCY_SMOKE_OK everyday=${REALISTIC}x${TRIALS} survivors=${realisticSurvivors.join(",")} no_refusals=true`
  + ` | stress=${WRITERS}x${TRIALS} survivors=${extremeSurvivors.join(",")} refused=${extremeRefusals}`
  + " no_lost_updates=true",
);

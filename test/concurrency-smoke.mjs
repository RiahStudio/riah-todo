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

function writer(label) {
  return new Promise((resolve) => {
    const code = `import(${JSON.stringify(storeUrl)}).then((s) => s.ops.add(${JSON.stringify(label)})).catch(() => {});`;
    const child = spawn(process.execPath, ["--input-type=module", "-e", code], {
      env: { ...process.env, RIAH_TODO_FILE: file },
      stdio: "ignore",
    });
    child.on("exit", resolve);
  });
}

process.env.RIAH_TODO_FILE = file;
const { readPriorities } = await import(storeUrl);

const survivors = [];
for (let trial = 0; trial < TRIALS; trial += 1) {
  writeFileSync(file, JSON.stringify({ date: new Date().toISOString().slice(0, 10), items: [] }));
  // All twelve are launched before any of them finishes — that is the race.
  await Promise.all(Array.from({ length: WRITERS }, (_, i) => writer(`Task ${i + 1}`)));
  survivors.push(readPriorities({ sweep: false, file }).items.length);
}

const lost = survivors.filter((n) => n !== WRITERS);
if (lost.length > 0) {
  console.error(
    `CONCURRENCY_SMOKE_FAILED: ${WRITERS} writers, survivors per trial: ${survivors.join(", ")}`
    + " — work is being lost to unlocked read-modify-write.",
  );
  process.exit(1);
}
console.log(`CONCURRENCY_SMOKE_OK writers=${WRITERS} trials=${TRIALS} survivors=${survivors.join(",")} no_lost_updates=true`);

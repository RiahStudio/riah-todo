// Today / Tomorrow / Later — so something worth doing but not now has a place
// to sit instead of being forgotten.
import assert from "node:assert/strict";
import { mkdtempSync, writeFileSync } from "node:fs";
import os from "node:os";
import path from "node:path";
import test from "node:test";
import { localDateKey, ops, readPriorities, SECTIONS } from "../lib/store.mjs";

function scratch() {
  const dir = mkdtempSync(path.join(os.tmpdir(), "riah-todo-sections-"));
  process.env.RIAH_TODO_FILE = path.join(dir, "today.json");
  return process.env.RIAH_TODO_FILE;
}

test("anything added without saying otherwise is for today", () => {
  scratch();
  assert.equal(ops.add("Gumroad Shovels").items[0].section, "today");
});

test("a task can be parked for later and comes back in its own group", () => {
  scratch();
  ops.add("Gumroad Shovels");
  ops.add("Riah Money", { section: "future" });
  ops.add("Selah launch", { section: "tomorrow" });
  ops.add("Call the bank");

  // Today first, then tomorrow, then later — order within a group is kept.
  assert.deepEqual(readPriorities().items.map((i) => `${i.section}:${i.label}`), [
    "today:Gumroad Shovels",
    "today:Call the bank",
    "tomorrow:Selah launch",
    "future:Riah Money",
  ]);
});

test("a whole thread moves between sections together", () => {
  scratch();
  const top = ops.add("Riah Money").items[0];
  ops.add("Work out pricing", { parentId: top.id });
  const list = ops.add("Ask about tax", { parentId: top.id });
  assert.ok(list.items.every((i) => i.section === "today"));

  const moved = ops.setSection(top.id, "future");
  assert.ok(moved.items.every((i) => i.section === "future"), "the steps went with it");
});

test("sectioning a step sections its whole task — a thread is never split", () => {
  scratch();
  const top = ops.add("Riah Money").items[0];
  const step = ops.add("Work out pricing", { parentId: top.id }).items[1];

  const moved = ops.setSection(step.id, "tomorrow");
  assert.equal(moved.items.find((i) => i.id === top.id).section, "tomorrow",
    "the task moved, not just the step");
  assert.ok(moved.items.every((i) => i.section === "tomorrow"));
});

test("a subtask cannot sit in a different section from its task", () => {
  const file = scratch();
  // A hand-edited file that tries to split a thread.
  writeFileSync(file, JSON.stringify({
    date: localDateKey(),
    items: [
      { id: "p", label: "Riah Money", completed: false, parentId: null, section: "future" },
      { id: "c", label: "Work out pricing", completed: false, parentId: "p", section: "today" },
    ],
  }));
  assert.ok(readPriorities().items.every((i) => i.section === "future"),
    "the child is pulled back into its task's section");
});

test("an unknown or missing section falls back to today rather than vanishing", () => {
  const file = scratch();
  writeFileSync(file, JSON.stringify({
    date: localDateKey(),
    items: [
      { id: "a", label: "No section at all", completed: false, parentId: null },
      { id: "b", label: "Nonsense section", completed: false, parentId: null, section: "someday" },
    ],
  }));
  const list = readPriorities();
  assert.equal(list.items.length, 2);
  assert.ok(list.items.every((i) => i.section === "today"));
});

test("sections survive a round trip to disk", () => {
  scratch();
  ops.add("Riah Money", { section: "future" });
  assert.equal(readPriorities().items[0].section, "future");
});

test("a section has to be one we know about", () => {
  scratch();
  const item = ops.add("Riah Money").items[0];
  assert.throws(() => ops.setSection(item.id, "whenever"), /Not a section/);
  assert.deepEqual(SECTIONS, ["today", "tomorrow", "future"]);
});

// Sleep — hide a task without completing it or taking it off the list.
import assert from "node:assert/strict";
import { mkdtempSync, writeFileSync } from "node:fs";
import os from "node:os";
import path from "node:path";
import test from "node:test";
import { localDateKey, ops, readPriorities } from "../lib/store.mjs";

function scratch() {
  const dir = mkdtempSync(path.join(os.tmpdir(), "riah-todo-sleep-"));
  process.env.RIAH_TODO_FILE = path.join(dir, "today.json");
  return process.env.RIAH_TODO_FILE;
}

test("a task can sleep and wake without being ticked or removed", () => {
  scratch();
  const item = ops.add("Riah Usage").items[0];
  const slept = ops.setSlept(item.id, true);
  const usage = slept.items.find((entry) => entry.id === item.id);
  assert.equal(usage.slept, true);
  assert.equal(usage.completed, false);
  assert.ok(usage.sleptAt);

  const awake = ops.setSlept(item.id, false);
  const back = awake.items.find((entry) => entry.id === item.id);
  assert.equal(back.slept, false);
  assert.equal(back.sleptAt, null);
  assert.equal(back.label, "Riah Usage");
});

test("a whole thread sleeps together", () => {
  scratch();
  const top = ops.add("Selah Launch").items[0];
  ops.add("Make the songs", { parentId: top.id });
  ops.add("Tiktok vid", { parentId: top.id });

  const slept = ops.setSlept(top.id, true);
  assert.ok(slept.items.every((entry) => entry.slept === true), "the steps went with it");
});

test("sleeping a step sleeps its whole task — a thread is never split", () => {
  scratch();
  const top = ops.add("Selah Launch").items[0];
  const step = ops.add("Make the songs", { parentId: top.id }).items[1];

  const slept = ops.setSlept(step.id, true);
  assert.equal(slept.items.find((entry) => entry.id === top.id).slept, true,
    "the task slept, not just the step");
  assert.ok(slept.items.every((entry) => entry.slept === true));
});

test("a subtask cannot stay awake under a sleeping task", () => {
  const file = scratch();
  writeFileSync(file, JSON.stringify({
    date: localDateKey(),
    items: [
      { id: "p", label: "Riah Usage", completed: false, parentId: null, slept: true },
      { id: "c", label: "Make video for Insta story", completed: false, parentId: "p", slept: false },
    ],
  }));
  assert.ok(readPriorities().items.every((entry) => entry.slept === true),
    "the child is pulled back into its task's sleep");
});

test("missing or false slept stays on the note", () => {
  const file = scratch();
  writeFileSync(file, JSON.stringify({
    date: localDateKey(),
    items: [
      { id: "a", label: "No sleep field", completed: false, parentId: null },
      { id: "b", label: "Awake on purpose", completed: false, parentId: null, slept: false },
    ],
  }));
  const list = readPriorities();
  assert.ok(list.items.every((entry) => entry.slept === false));
});

test("sleep survives a round trip to disk", () => {
  scratch();
  const item = ops.add("Gumroad Shovels").items[0];
  ops.setSlept(item.id, true);
  assert.equal(readPriorities().items[0].slept, true);
  assert.equal(readPriorities().items[0].section, "today");
});

test("sleeping does not file the task as finished", () => {
  scratch();
  const item = ops.add("Riah Swipe").items[0];
  ops.setSlept(item.id, true);
  const stillThere = readPriorities().items.find((entry) => entry.id === item.id);
  assert.ok(stillThere, "sleeping must not sweep the task away");
  assert.equal(stillThere.completed, false);
});

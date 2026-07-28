import assert from "node:assert/strict";
import { mkdtempSync, readFileSync, writeFileSync } from "node:fs";
import os from "node:os";
import path from "node:path";
import test from "node:test";
import {
  appendVaultTrail,
  childrenOf,
  localDateKey,
  ops,
  readPriorities,
  readSettings,
  sweepCompleted,
  topLevel,
  writePriorities,
  writeSettings,
} from "../lib/store.mjs";

// Every test gets its own file so a failure can never touch Captain's real list.
function scratch() {
  const dir = mkdtempSync(path.join(os.tmpdir(), "riah-todo-"));
  process.env.RIAH_TODO_FILE = path.join(dir, "today.json");
  return process.env.RIAH_TODO_FILE;
}

test("an empty machine starts with an empty list dated today", () => {
  scratch();
  const list = readPriorities();
  assert.equal(list.date, localDateKey());
  assert.deepEqual(list.items, []);
});

test("adding, ticking, renaming, and removing all survive a round trip", () => {
  const file = scratch();
  ops.add("Ship Riah To-Do");
  const added = ops.add("Call the bank");
  assert.equal(added.items.length, 2);

  const id = added.items[0].id;
  const ticked = ops.toggle(id);
  assert.equal(ticked.items[0].completed, true);
  assert.ok(ticked.items[0].completedAt, "a tick records when it happened");

  const renamed = ops.rename(added.items[1].id, "Call the bank back");
  assert.equal(renamed.items[1].label, "Call the bank back");

  const onDisk = JSON.parse(readFileSync(file, "utf8"));
  assert.equal(onDisk.items.length, 2);
  assert.equal(onDisk.items[1].label, "Call the bank back");

  const removed = ops.remove(id);
  assert.equal(removed.items.length, 1);
});

test("the list refuses duplicates, blank text, and a thirteenth item", () => {
  scratch();
  ops.add("One thing");
  assert.throws(() => ops.add("one THING"), /already on today's list/);
  assert.throws(() => ops.add("   "), /cannot be empty/);
  for (let i = 2; i <= 12; i += 1) ops.add(`Item ${i}`);
  assert.throws(() => ops.add("Thirteen"), /full at 12/);
});

test("yesterday's unfinished work carries over and gets today's date", () => {
  const file = scratch();
  writeFileSync(file, JSON.stringify({
    date: "2020-01-01",
    items: [{ id: "a", label: "Still not done", completed: false }],
  }));
  const list = readPriorities();
  assert.equal(list.date, localDateKey());
  assert.equal(list.items[0].label, "Still not done");
});

test("a ticked item is swept two hours later, not before", () => {
  const now = Date.parse("2026-07-28T12:00:00.000Z");
  const list = {
    date: "2026-07-28",
    items: [
      { id: "a", label: "Fresh tick", completed: true, completedAt: "2026-07-28T11:30:00.000Z" },
      { id: "b", label: "Old tick", completed: true, completedAt: "2026-07-28T09:00:00.000Z" },
      { id: "c", label: "Untouched", completed: false, completedAt: null },
      { id: "d", label: "Ticked before we stamped them", completed: true, completedAt: null },
    ],
  };
  const removed = sweepCompleted(list, now);
  assert.deepEqual(removed.map((item) => item.id), ["b", "d"]);
  assert.deepEqual(list.items.map((item) => item.id), ["a", "c"]);
});

test("a swept item is filed rather than lost", () => {
  const file = scratch();
  writePriorities({
    date: localDateKey(),
    items: [{ id: "old", label: "Finished ages ago", completed: true, completedAt: "2020-01-01T00:00:00.000Z" }],
  });
  const list = readPriorities();
  assert.deepEqual(list.items, []);
  const filed = JSON.parse(readFileSync(path.join(path.dirname(file), "today-filed.json"), "utf8"));
  assert.equal(filed.length, 1);
  assert.equal(filed[0].label, "Finished ages ago");
  assert.ok(filed[0].filedAt);
});

test("replacing the list keeps ticks and ids for items that stay", () => {
  scratch();
  const first = ops.add("Keep me");
  ops.toggle(first.items[0].id);
  ops.add("Drop me");
  const replaced = ops.replace(["Keep me", "Brand new"]);
  assert.deepEqual(replaced.items.map((item) => item.label), ["Keep me", "Brand new"]);
  assert.equal(replaced.items[0].id, first.items[0].id);
  assert.equal(replaced.items[0].completed, true, "replacing must not un-complete finished work");
  assert.equal(replaced.items[1].completed, false);
  assert.throws(() => ops.replace(["Same", "same"]), /duplicates/);
});

test("reorder moves what it names and keeps what it does not", () => {
  scratch();
  ops.add("A");
  ops.add("B");
  const three = ops.add("C");
  const ids = three.items.map((item) => item.id);
  const reordered = ops.reorder([ids[2], ids[0]]);
  assert.deepEqual(reordered.items.map((item) => item.label), ["C", "A", "B"]);
});

test("a torn or unreadable file reads as empty instead of throwing", () => {
  const file = scratch();
  writeFileSync(file, '{"date": "2026-07-28", "items": [{"label": "hal');
  assert.deepEqual(readPriorities().items, []);
  // And the next write repairs it.
  const fixed = ops.add("Back in business");
  assert.equal(fixed.items.length, 1);
});

test("setCompleted works by label so an agent can tick things off by name", () => {
  scratch();
  ops.add("Pay the invoice");
  const done = ops.setCompleted("pay the INVOICE", true);
  assert.equal(done.items[0].completed, true);
  const reopened = ops.setCompleted("Pay the invoice", false);
  assert.equal(reopened.items[0].completed, false);
  assert.equal(reopened.items[0].completedAt, null);
  assert.throws(() => ops.setCompleted("Nothing like this", true), /not found/);
});

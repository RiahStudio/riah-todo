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
  readPrioritiesForDisplay,
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

test("the same wording is allowed twice — under different tasks it is different work", () => {
  scratch();
  // Captain, 2026-07-29: "post on socials" under Gumroad Shovels AND under
  // Riah To-Do. Refusing the second was obnoxious, so this used to throw.
  const a = ops.add("Ship the launch").items[0];
  const b = ops.add("Riah To-Do").items[1];
  ops.add("Post on socials", { parentId: a.id });
  const both = ops.add("post on SOCIALS", { parentId: b.id });

  const posts = both.items.filter((item) => item.label.toLowerCase() === "post on socials");
  assert.equal(posts.length, 2, "both survived");
  assert.notEqual(posts[0].parentId, posts[1].parentId, "under different tasks");
  // Ticking one by name acts on a single item — the other stays open. (Its own
  // parent completing is the thread cascade doing its job, not a mix-up.)
  const ticked = ops.setCompleted("Post on socials", true);
  const after = ticked.items.filter((item) => item.label.toLowerCase() === "post on socials");
  assert.equal(after.filter((item) => item.completed).length, 1, "one ticked");
  assert.equal(after.filter((item) => !item.completed).length, 1, "the other untouched");
});

test("blank text is refused, and the cap is a backstop rather than a rule", () => {
  scratch();
  ops.add("One thing");
  assert.throws(() => ops.add("   "), /cannot be empty/);
  // Well past any real day, and nowhere near the backstop.
  for (let i = 2; i <= 30; i += 1) ops.add(`Item ${i}`);
  assert.equal(topLevel(readPriorities()).length, 30);
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

test("a torn file is refused, not silently emptied and overwritten", () => {
  const file = scratch();
  // This test used to assert the opposite — that a torn file "reads as empty".
  // That was the bug: the next write then replaced real work with one new task.
  const torn = '{"date": "2026-07-28", "items": [{"label": "hal';
  writeFileSync(file, torn);

  assert.throws(() => readPriorities(), /could not read your list/);
  assert.throws(() => ops.add("Back in business"), /could not read your list/);
  assert.equal(readFileSync(file, "utf8"), torn, "the file must be left byte-for-byte alone");

  // A surface that has to render something is told to ask for recovery.
  const shown = readPrioritiesForDisplay({ file });
  assert.equal(shown.ok, false);
  assert.equal(shown.needsRecovery, true);
  assert.match(shown.error, /could not read your list/);
  assert.ok(shown.error.includes(file), "the message must name the file");

  // Once the file is sane again, everything works.
  writeFileSync(file, JSON.stringify({ date: localDateKey(), items: [] }));
  assert.equal(ops.add("Back in business").items.length, 1);
});

test("a missing file still starts an empty list", () => {
  const file = scratch();
  // Nothing written at all — this is a first run, not a corruption.
  assert.deepEqual(readPriorities({ file }).items, []);
  assert.equal(ops.add("First ever task").items.length, 1);
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

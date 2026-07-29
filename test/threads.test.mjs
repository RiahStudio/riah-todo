// Subtasks, dragging, the filing window, and the vault trail.
import assert from "node:assert/strict";
import { mkdtempSync, readFileSync, writeFileSync } from "node:fs";
import os from "node:os";
import path from "node:path";
import test from "node:test";
import {
  appendVaultTrail,
  childrenOf,
  descendantsOf,
  localDateKey,
  MAX_DEPTH,
  ops,
  readPriorities,
  readSettings,
  sweepCompleted,
  topLevel,
  writePriorities,
  writeSettings,
} from "../lib/store.mjs";

function scratch() {
  const dir = mkdtempSync(path.join(os.tmpdir(), "riah-todo-threads-"));
  process.env.RIAH_TODO_FILE = path.join(dir, "today.json");
  return process.env.RIAH_TODO_FILE;
}

test("a subtask sits directly under its task, whatever order the file is in", () => {
  const file = scratch();
  const first = ops.add("Ship the launch");
  ops.add("Call the bank");
  const parentId = first.items[0].id;
  ops.add("Write the email", { parentId });
  ops.add("Check the pricing page", { parentId });

  assert.deepEqual(readPriorities().items.map((item) => item.label), [
    "Ship the launch", "Write the email", "Check the pricing page", "Call the bank",
  ]);

  // Even if the file lands out of order, reading it threads it back.
  const raw = JSON.parse(readFileSync(file, "utf8"));
  raw.items.reverse();
  writeFileSync(file, JSON.stringify(raw));
  assert.deepEqual(readPriorities().items.map((item) => item.label), [
    "Call the bank", "Ship the launch", "Check the pricing page", "Write the email",
  ]);
});

test("a thread can keep nesting, and each item knows how deep it is", () => {
  scratch();
  // Captain, 2026-07-29: sub-threads under sub-points are fine — the widget resizes.
  let list = ops.add("Ship the launch");
  let parentId = list.items[0].id;
  const labels = ["Write the email", "Draft the subject", "Try a shorter one", "Ask Zach"];
  for (const label of labels) {
    list = ops.add(label, { parentId });
    parentId = list.items.find((item) => item.label === label).id;
  }
  assert.deepEqual(list.items.map((item) => item.label), [
    "Ship the launch", ...labels,
  ], "the thread reads top down, deepest last");
  assert.deepEqual(list.items.map((item) => item.depth), [0, 1, 2, 3, 4]);
});

test("nesting stops at a readable depth instead of going for ever", () => {
  scratch();
  let list = ops.add("Level 0");
  let parentId = list.items[0].id;
  for (let level = 1; level <= MAX_DEPTH; level += 1) {
    list = ops.add(`Level ${level}`, { parentId });
    parentId = list.items.find((item) => item.label === `Level ${level}`).id;
  }
  assert.equal(list.items.at(-1).depth, MAX_DEPTH);
  assert.throws(() => ops.add("One too far", { parentId }), /as deep as it goes/);
});

test("a task cannot be moved inside its own thread", () => {
  scratch();
  const top = ops.add("Ship the launch").items[0];
  const mid = ops.add("Write the email", { parentId: top.id }).items[1];
  const deep = ops.add("Draft the subject", { parentId: mid.id }).items[2];

  assert.throws(() => ops.setParent(top.id, top.id), /its own subtask/);
  assert.throws(() => ops.setParent(top.id, mid.id), /inside its own thread/);
  assert.throws(() => ops.setParent(top.id, deep.id), /inside its own thread/);
  // And the list survived all that intact.
  assert.equal(readPriorities().items.length, 3);
});

test("a loop written into the file is broken, not obeyed", () => {
  const file = scratch();
  writeFileSync(file, JSON.stringify({
    date: localDateKey(),
    items: [
      { id: "a", label: "A", completed: false, parentId: "b" },
      { id: "b", label: "B", completed: false, parentId: "a" },
    ],
  }));
  const list = readPriorities();
  assert.equal(list.items.length, 2, "neither task is lost");
  assert.ok(list.items.some((item) => item.parentId === null), "the loop is cut");
});

test("moving a whole thread under another respects the depth limit", () => {
  scratch();
  // A three-deep thread...
  const top = ops.add("Thread top").items[0];
  const mid = ops.add("Middle", { parentId: top.id }).items[1];
  ops.add("Bottom", { parentId: mid.id });
  // ...and a chain to hang it off.
  let list = ops.add("Other");
  let deepest = list.items.find((item) => item.label === "Other").id;
  for (let level = 1; level <= MAX_DEPTH; level += 1) {
    list = ops.add(`Deep ${level}`, { parentId: deepest });
    deepest = list.items.find((item) => item.label === `Deep ${level}`).id;
  }
  assert.throws(() => ops.setParent(top.id, deepest), /deeper than/);
});

test("a subtask whose task vanished is promoted, not dropped", () => {
  const file = scratch();
  writeFileSync(file, JSON.stringify({
    date: localDateKey(),
    items: [{ id: "orphan", label: "Left behind", completed: false, parentId: "nobody" }],
  }));
  const list = readPriorities();
  assert.equal(list.items.length, 1);
  assert.equal(list.items[0].parentId, null);
});

test("ticking a task ticks its thread, and the last subtask finishes the task", () => {
  scratch();
  const parent = ops.add("Ship the launch").items[0];
  ops.add("Write the email", { parentId: parent.id });
  const both = ops.add("Check the pricing", { parentId: parent.id });
  const emailId = both.items.find((item) => item.label === "Write the email").id;
  const pricingId = both.items.find((item) => item.label === "Check the pricing").id;

  const allDone = ops.toggle(parent.id);
  assert.ok(allDone.items.every((item) => item.completed), "ticking the task ticks the thread");

  const oneOpen = ops.toggle(emailId);
  assert.equal(oneOpen.items.find((item) => item.id === parent.id).completed, false,
    "reopening a subtask reopens the task — it is not done while a step is open");

  const backToDone = ops.toggle(emailId);
  assert.equal(backToDone.items.find((item) => item.id === parent.id).completed, true,
    "ticking the last open subtask finishes the task");
  assert.ok(backToDone.items.find((item) => item.id === pricingId).completed);
});

test("removing a task takes its subtasks with it", () => {
  scratch();
  const parent = ops.add("Ship the launch").items[0];
  ops.add("Write the email", { parentId: parent.id });
  ops.add("Call the bank");
  assert.deepEqual(ops.remove(parent.id).items.map((item) => item.label), ["Call the bank"]);
});

test("the twelve cap counts tasks, not subtasks", () => {
  scratch();
  const first = ops.add("Task 1").items[0];
  for (let i = 2; i <= 12; i += 1) ops.add(`Task ${i}`);
  assert.throws(() => ops.add("Task 13"), /full at 12/);
  const withChild = ops.add("A step", { parentId: first.id });
  assert.equal(topLevel(withChild).length, 12);
  assert.equal(childrenOf(withChild, first.id).length, 1);
});

test("dragging a task above another moves its subtasks with it", () => {
  scratch();
  ops.add("First");
  const second = ops.add("Second").items[1];
  ops.add("A step", { parentId: second.id });
  const all = ops.add("Third");
  const firstId = all.items.find((item) => item.label === "First").id;

  assert.deepEqual(ops.moveBefore(second.id, firstId).items.map((item) => item.label),
    ["Second", "A step", "First", "Third"]);
  assert.deepEqual(ops.moveBefore(second.id, null).items.map((item) => item.label),
    ["First", "Third", "Second", "A step"]);
});

test("settings default to the behaviour from before settings existed", () => {
  scratch();
  assert.deepEqual(readSettings(), { fileAfterMinutes: 120, vaultPath: "", vaultSubfolder: "" });
});

test("the filing window is configurable, and never means never", () => {
  const file = scratch();
  const settingsFile = path.join(path.dirname(file), "settings.json");
  const old = new Date(Date.now() - 30 * 60 * 1000).toISOString();
  const seed = () => writePriorities({
    date: localDateKey(),
    items: [{ id: "a", label: "Ticked half an hour ago", completed: true, completedAt: old }],
  });

  seed();
  assert.equal(readPriorities().items.length, 1, "two hours by default, so it is still there");

  writeSettings({ fileAfterMinutes: 15 }, { file: settingsFile });
  seed();
  assert.equal(readPriorities().items.length, 0, "fifteen minutes, so it is filed");

  writeSettings({ fileAfterMinutes: "never" }, { file: settingsFile });
  seed();
  assert.equal(readPriorities().items.length, 1, "never means never");
  assert.equal(readSettings().fileAfterMinutes, null);
});

test("filing zero minutes files a tick immediately", () => {
  const file = scratch();
  writeSettings({ fileAfterMinutes: 0 }, { file: path.join(path.dirname(file), "settings.json") });
  writePriorities({
    date: localDateKey(),
    items: [{ id: "a", label: "Just ticked", completed: true, completedAt: new Date().toISOString() }],
  });
  assert.equal(readPriorities().items.length, 0);
});

test("a task is not filed while one of its subtasks is still open", () => {
  const longAgo = new Date(Date.now() - 5 * 60 * 60 * 1000).toISOString();
  const list = {
    date: localDateKey(),
    items: [
      { id: "p", label: "Ship the launch", completed: true, completedAt: longAgo, parentId: null },
      { id: "c", label: "Still to do", completed: false, completedAt: null, parentId: "p" },
    ],
  };
  assert.deepEqual(sweepCompleted(list, Date.now(), 2 * 60 * 60 * 1000), []);
  assert.equal(list.items.length, 2);
});

test("filing a task files its subtasks with it", () => {
  const longAgo = new Date(Date.now() - 5 * 60 * 60 * 1000).toISOString();
  const list = {
    date: localDateKey(),
    items: [
      { id: "p", label: "Ship the launch", completed: true, completedAt: longAgo, parentId: null },
      { id: "c", label: "Write the email", completed: true, completedAt: longAgo, parentId: "p" },
      { id: "o", label: "Untouched", completed: false, completedAt: null, parentId: null },
    ],
  };
  const removed = sweepCompleted(list, Date.now(), 2 * 60 * 60 * 1000);
  assert.deepEqual(removed.map((item) => item.id), ["p", "c"]);
  assert.deepEqual(list.items.map((item) => item.id), ["o"]);
});

test("the vault trail is a dated markdown file, indented under its task", () => {
  const file = scratch();
  const vault = path.join(path.dirname(file), "vault");
  const settings = { fileAfterMinutes: 120, vaultPath: vault, vaultSubfolder: "done" };
  const at = new Date("2026-07-28T12:00:00.000Z");

  const written = appendVaultTrail([
    { id: "p", label: "Ship the launch", completed: true, completedAt: "2026-07-28T09:05:00.000Z", parentId: null },
    { id: "c", label: "Write the email", completed: true, completedAt: "2026-07-28T09:06:00.000Z", parentId: "p" },
  ], settings, at);

  assert.ok(written, "it returns the file it wrote");
  const text = readFileSync(written, "utf8");
  assert.match(text, /^# Done - \d{4}-\d\d-\d\d$/m);
  assert.match(text, /^- \[x\] \d\d:\d\d Ship the launch$/m);
  assert.match(text, /^ {2}- \[x\] \d\d:\d\d Write the email$/m);

  appendVaultTrail([
    { id: "x", label: "Call the bank", completed: true, completedAt: "2026-07-28T10:00:00.000Z", parentId: null },
  ], settings, at);
  const after = readFileSync(written, "utf8");
  assert.match(after, /Ship the launch/, "a second filing appends rather than replacing the day");
  assert.match(after, /Call the bank/);
});

test("a vault that is not set, or has moved, costs nothing", () => {
  scratch();
  const done = [{ id: "a", label: "Done", completed: true, completedAt: null, parentId: null }];
  assert.equal(appendVaultTrail(done, { vaultPath: "", vaultSubfolder: "" }), null);
  assert.equal(appendVaultTrail(done, { vaultPath: "\u0000not a path", vaultSubfolder: "" }), null);
});

test("ticking a deep task ticks everything beneath it", () => {
  scratch();
  const top = ops.add("Ship the launch").items[0];
  const mid = ops.add("Write the email", { parentId: top.id }).items[1];
  ops.add("Draft the subject", { parentId: mid.id });
  const list = ops.add("Pick a send time", { parentId: mid.id });
  const deepIds = descendantsOf(list, mid.id).map((item) => item.id);
  assert.equal(deepIds.length, 2);

  const afterMid = ops.toggle(mid.id);
  assert.ok(
    afterMid.items.filter((item) => deepIds.includes(item.id)).every((item) => item.completed),
    "the whole sub-thread went with it",
  );
  assert.equal(afterMid.items.find((item) => item.id === top.id).completed, true,
    "and the task above it is finished, since that was its only branch");
});

test("reopening something deep reopens every task above it", () => {
  scratch();
  const top = ops.add("Ship the launch").items[0];
  const mid = ops.add("Write the email", { parentId: top.id }).items[1];
  const deep = ops.add("Draft the subject", { parentId: mid.id }).items[2];

  ops.toggle(top.id);
  const reopened = ops.toggle(deep.id);
  assert.equal(reopened.items.find((item) => item.id === deep.id).completed, false);
  assert.equal(reopened.items.find((item) => item.id === mid.id).completed, false,
    "its parent reopened");
  assert.equal(reopened.items.find((item) => item.id === top.id).completed, false,
    "and so did the top of the thread");
});

test("removing a task takes the whole thread beneath it", () => {
  scratch();
  const top = ops.add("Ship the launch").items[0];
  const mid = ops.add("Write the email", { parentId: top.id }).items[1];
  ops.add("Draft the subject", { parentId: mid.id });
  ops.add("Call the bank");
  assert.deepEqual(ops.remove(top.id).items.map((item) => item.label), ["Call the bank"]);
});

test("a deep task is not filed while anything under it is still open", () => {
  const longAgo = new Date(Date.now() - 5 * 60 * 60 * 1000).toISOString();
  const list = {
    date: localDateKey(),
    items: [
      { id: "a", label: "Top", completed: true, completedAt: longAgo, parentId: null },
      { id: "b", label: "Middle", completed: true, completedAt: longAgo, parentId: "a" },
      { id: "c", label: "Still going", completed: false, completedAt: null, parentId: "b" },
    ],
  };
  assert.deepEqual(sweepCompleted(list, Date.now(), 2 * 60 * 60 * 1000), [],
    "nothing may be filed while work remains three levels down");
  assert.equal(list.items.length, 3);
});

test("filing a finished thread files all of it, at any depth", () => {
  const longAgo = new Date(Date.now() - 5 * 60 * 60 * 1000).toISOString();
  const list = {
    date: localDateKey(),
    items: [
      { id: "a", label: "Top", completed: true, completedAt: longAgo, parentId: null },
      { id: "b", label: "Middle", completed: true, completedAt: longAgo, parentId: "a" },
      { id: "c", label: "Deep", completed: true, completedAt: longAgo, parentId: "b" },
      { id: "d", label: "Untouched", completed: false, completedAt: null, parentId: null },
    ],
  };
  const removed = sweepCompleted(list, Date.now(), 2 * 60 * 60 * 1000);
  assert.deepEqual(removed.map((item) => item.id), ["a", "b", "c"]);
  assert.deepEqual(list.items.map((item) => item.id), ["d"]);
});

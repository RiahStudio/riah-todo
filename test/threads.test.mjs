// Subtasks, dragging, the filing window, and the vault trail.
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

test("nesting only goes one deep", () => {
  scratch();
  const parent = ops.add("Ship the launch").items[0];
  const child = ops.add("Write the email", { parentId: parent.id }).items[1];
  assert.throws(() => ops.add("Draft it", { parentId: child.id }), /cannot have subtasks/);
  assert.throws(() => ops.setParent(parent.id, child.id), /cannot have subtasks/);
  assert.throws(() => ops.setParent(parent.id, parent.id), /its own subtask/);
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

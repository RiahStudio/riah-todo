// The record of what actually got done — grouped by day, newest day first.
import assert from "node:assert/strict";
import { mkdtempSync, writeFileSync } from "node:fs";
import os from "node:os";
import path from "node:path";
import test from "node:test";
import { localDateKey, readFiled } from "../lib/store.mjs";

function scratch() {
  const dir = mkdtempSync(path.join(os.tmpdir(), "riah-todo-finished-"));
  process.env.RIAH_TODO_FILE = path.join(dir, "today.json");
  return path.join(dir, "today-filed.json");
}

test("an empty or missing archive is simply nothing finished", () => {
  scratch();
  assert.deepEqual(readFiled().days, []);
  assert.equal(readFiled().total, 0);
});

test("finished work is grouped by the day it was ticked, newest day first", () => {
  const archive = scratch();
  writeFileSync(archive, JSON.stringify([
    { id: "a", label: "Older thing", completedAt: "2026-07-27T09:00:00.000Z", filedAt: "2026-07-27T11:00:00.000Z" },
    { id: "b", label: "Newer thing", completedAt: "2026-07-29T08:00:00.000Z", filedAt: "2026-07-29T10:00:00.000Z" },
    { id: "c", label: "Same day as newer", completedAt: "2026-07-29T09:30:00.000Z", filedAt: "2026-07-29T11:00:00.000Z" },
  ]));
  const filed = readFiled({ file: archive });
  assert.equal(filed.total, 3);
  assert.equal(filed.days.length, 2, "two distinct days");
  assert.ok(filed.days[0].day > filed.days[1].day, "newest day comes first");
  assert.equal(filed.days[0].items.length, 2);
  assert.deepEqual(
    filed.days[0].items.map((i) => i.label),
    ["Newer thing", "Same day as newer"],
    "within a day, in the order they were finished",
  );
});

test("subtasks keep the task they belonged to", () => {
  const archive = scratch();
  writeFileSync(archive, JSON.stringify([
    { id: "p", label: "Ship it", completedAt: "2026-07-29T08:00:00.000Z", parentId: null },
    { id: "s", label: "Write the email", completedAt: "2026-07-29T08:01:00.000Z", parentId: "p" },
  ]));
  const day = readFiled({ file: archive }).days[0];
  assert.equal(day.items.find((i) => i.id === "s").parentId, "p");
});

test("the view is bounded — an archive of many days does not all come back", () => {
  const archive = scratch();
  const entries = [];
  for (let d = 1; d <= 40; d += 1) {
    const day = String(d).padStart(2, "0");
    entries.push({ id: `x${d}`, label: `Task ${d}`, completedAt: `2026-06-${day}T09:00:00.000Z` });
  }
  writeFileSync(archive, JSON.stringify(entries));
  const filed = readFiled({ file: archive, days: 14 });
  assert.equal(filed.total, 40, "the count is honest about everything on file");
  assert.equal(filed.days.length, 14, "but only recent days are returned");
});

test("an entry with no usable timestamp is kept, not dropped", () => {
  const archive = scratch();
  writeFileSync(archive, JSON.stringify([
    { id: "old", label: "From before we stamped things" },
  ]));
  const filed = readFiled({ file: archive });
  assert.equal(filed.total, 1);
  assert.equal(filed.days[0].day, "earlier");
  assert.equal(filed.days[0].items[0].label, "From before we stamped things");
});

test("a corrupt archive reads as nothing finished rather than throwing", () => {
  const archive = scratch();
  writeFileSync(archive, "{not json");
  assert.deepEqual(readFiled({ file: archive }).days, []);
});

test("today's filing shows up under today", () => {
  const archive = scratch();
  const now = new Date().toISOString();
  writeFileSync(archive, JSON.stringify([{ id: "n", label: "Just done", completedAt: now }]));
  assert.equal(readFiled({ file: archive }).days[0].day, localDateKey());
});

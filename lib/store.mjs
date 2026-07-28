// Riah To-Do — the one list, on disk.
//
// Every surface (tray sticky note, board page, MCP tools, Riah Code) reads and
// writes THIS file. There is no server in the middle: the tray must keep working
// when nothing else is running, so the file is the source of truth and each
// writer does a read-modify-atomic-write.
//
// The rules below are the ones Riah Code already enforced (12 items, 120 chars,
// no duplicates, completed items file themselves away after two hours). They are
// duplicated here on purpose — this file is now the definition, and Riah Code
// defers to it.

import { randomUUID } from "node:crypto";
import {
  closeSync, mkdirSync, openSync, readFileSync, renameSync, rmSync, statSync, writeFileSync,
} from "node:fs";
import os from "node:os";
import path from "node:path";

export const MAX_ITEMS = 12;
export const MAX_SUBTASKS = 12;
export const MAX_LABEL_LENGTH = 120;
export const COMPLETED_TTL_MS = 2 * 60 * 60 * 1000;

/**
 * Settings live beside the list. Defaults are what the app did before settings
 * existed, so an absent file changes nothing.
 *
 * fileAfterMinutes — how long a ticked item stays visible before it is filed.
 *   0 files it the moment it is ticked; null (or "never") leaves it on the list
 *   until it is cleared by hand.
 * vaultPath — a folder to leave a dated markdown trail in, e.g. an Obsidian
 *   vault. Empty means no trail; the JSON archive is always written either way.
 */
export const DEFAULT_SETTINGS = {
  fileAfterMinutes: 120,
  vaultPath: "",
  vaultSubfolder: "",
};

/** Local calendar day, not UTC — "today" means Captain's today. */
export function localDateKey(date = new Date()) {
  const year = date.getFullYear();
  const month = String(date.getMonth() + 1).padStart(2, "0");
  const day = String(date.getDate()).padStart(2, "0");
  return `${year}-${month}-${day}`;
}

/**
 * One fixed location every surface can compute without config. Kept out of the
 * repo because it is daily state, not a deliverable, and because Riah Code may
 * be running from a packaged build that cannot see the workspace.
 */
export function dataDir() {
  if (process.env.RIAH_TODO_DIR) return path.resolve(process.env.RIAH_TODO_DIR);
  const appData = process.env.APPDATA || path.join(os.homedir(), "AppData", "Roaming");
  return path.join(appData, "Riah To-Do");
}

export function storePath() {
  if (process.env.RIAH_TODO_FILE) return path.resolve(process.env.RIAH_TODO_FILE);
  return path.join(dataDir(), "today.json");
}

export function filedPath() {
  return path.join(path.dirname(storePath()), "today-filed.json");
}

export function settingsPath() {
  return path.join(path.dirname(storePath()), "settings.json");
}

function emptyList(today = localDateKey()) {
  return { date: today, items: [] };
}

function normalizeItem(raw) {
  if (!raw || typeof raw !== "object") return null;
  const label = typeof raw.label === "string" ? raw.label.trim() : "";
  if (!label) return null;
  return {
    id: typeof raw.id === "string" && raw.id ? raw.id : randomUUID(),
    label: label.slice(0, MAX_LABEL_LENGTH),
    completed: raw.completed === true,
    completedAt: typeof raw.completedAt === "string" ? raw.completedAt : null,
    // One level of nesting: a task can have subtasks, a subtask cannot.
    parentId: typeof raw.parentId === "string" && raw.parentId ? raw.parentId : null,
  };
}

/**
 * The array order IS the display order, and a child always sits directly under
 * its parent. Sorting it here means every surface can just walk the array — no
 * tree building in the note, the board, or Riah Code.
 */
function threadItems(items) {
  const byId = new Map(items.map((item) => [item.id, item]));
  const childrenOf = new Map();
  const roots = [];
  for (const item of items) {
    const parent = item.parentId ? byId.get(item.parentId) : null;
    // A subtask whose parent is gone, or that points at another subtask, is
    // promoted rather than dropped. Losing a task to a bad link is not on.
    if (!parent || parent.id === item.id || parent.parentId) {
      item.parentId = null;
      roots.push(item);
      continue;
    }
    if (!childrenOf.has(parent.id)) childrenOf.set(parent.id, []);
    childrenOf.get(parent.id).push(item);
  }
  const threaded = [];
  for (const root of roots.slice(0, MAX_ITEMS)) {
    threaded.push(root);
    for (const child of (childrenOf.get(root.id) || []).slice(0, MAX_SUBTASKS)) {
      threaded.push(child);
    }
  }
  return threaded;
}

function normalize(raw, today = localDateKey()) {
  if (!raw || typeof raw !== "object") return emptyList(today);
  const items = Array.isArray(raw.items) ? raw.items.map(normalizeItem).filter(Boolean) : [];
  // Yesterday's unfinished work is still today's work — carry it over and
  // restamp the date rather than starting Captain at zero every morning.
  return { date: today, items: threadItems(items) };
}

export function childrenOf(list, id) {
  return list.items.filter((item) => item.parentId === id);
}

export function topLevel(list) {
  return list.items.filter((item) => !item.parentId);
}

function normalizeSettings(raw) {
  const source = (raw && typeof raw === "object") ? raw : {};
  let after = source.fileAfterMinutes;
  if (after === "never" || after === null) after = null;
  else if (!Number.isFinite(Number(after))) after = DEFAULT_SETTINGS.fileAfterMinutes;
  else after = Math.max(0, Math.round(Number(after)));
  return {
    fileAfterMinutes: after,
    vaultPath: typeof source.vaultPath === "string" ? source.vaultPath.trim() : "",
    vaultSubfolder: typeof source.vaultSubfolder === "string" ? source.vaultSubfolder.trim() : "",
  };
}

export function readSettings({ file = settingsPath() } = {}) {
  try {
    return normalizeSettings(JSON.parse(readFileSync(file, "utf8")));
  } catch {
    return { ...DEFAULT_SETTINGS };
  }
}

export function writeSettings(next, { file = settingsPath() } = {}) {
  const settings = normalizeSettings(next);
  atomicWrite(file, `${JSON.stringify(settings, null, 2)}\n`);
  return settings;
}

/**
 * Completed items disappear two hours after they are ticked, so the note stays a
 * list of what is left rather than a monument to what is done. They are handed
 * back so the caller can file them.
 */
export function sweepCompleted(list, nowMs = Date.now(), ttlMs = COMPLETED_TTL_MS) {
  // null means "leave them until they are cleared by hand".
  if (ttlMs === null) return [];
  const removed = [];
  const filedIds = new Set();
  list.items = list.items.filter((item) => {
    // A subtask goes when its parent goes, whatever its own stamp says —
    // otherwise it would be left behind as an orphan with no context.
    if (item.parentId && filedIds.has(item.parentId)) {
      removed.push(item);
      return false;
    }
    if (!item.completed) return true;
    // No stamp means it predates the stamp — already older than the window.
    const stamped = item.completedAt ? new Date(item.completedAt).getTime() : NaN;
    if (!Number.isFinite(stamped) || nowMs - stamped >= ttlMs) {
      // Never file a parent out from under work that is still open.
      const openChild = list.items.some(
        (other) => other.parentId === item.id && !other.completed,
      );
      if (openChild) return true;
      removed.push(item);
      filedIds.add(item.id);
      return false;
    }
    return true;
  });
  return removed;
}

/** The sweep window as configured, in ms. `null` means never. */
export function sweepWindowMs(settings = readSettings()) {
  if (settings.fileAfterMinutes === null) return null;
  return Math.max(0, settings.fileAfterMinutes) * 60 * 1000;
}

/**
 * Cross-process lock.
 *
 * An atomic rename stops a reader seeing half a file, but it does nothing about
 * two writers who both read "3 items", both append one, and both write "4" —
 * one of those tasks is gone. With four surfaces on one file (note, board, Riah
 * Code, MCP) that is a real way to lose work, not a theoretical one: twelve
 * simultaneous writers reliably left five to eight.
 *
 * So every read-modify-write takes this lock first. `wx` fails if the file
 * exists, which is the atomic test-and-set. The tray does the same dance in
 * PowerShell — keep the two in step.
 */
export const LOCK_STALE_MS = 10_000;

function lockPath(file) {
  return `${file}.lock`;
}

function sleepSync(ms) {
  // No async here on purpose: the whole point is that nothing else in this
  // process interleaves between read and write.
  Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, ms);
}

export function withLock(file, work, { timeoutMs = 5_000 } = {}) {
  const lock = lockPath(file);
  mkdirSync(path.dirname(file), { recursive: true });
  const started = Date.now();
  let handle = null;
  for (;;) {
    try {
      handle = openSync(lock, "wx");
      break;
    } catch (error) {
      if (error.code !== "EEXIST") throw error;
      // A lock left behind by something that died must not block the app for
      // ever. Anything older than the stale window is fair game.
      try {
        if (Date.now() - statSync(lock).mtimeMs > LOCK_STALE_MS) {
          rmSync(lock, { force: true });
          continue;
        }
      } catch {
        continue;
      }
      if (Date.now() - started > timeoutMs) {
        // Better to do the work unlocked than to refuse Captain a tick.
        return work();
      }
      sleepSync(15);
    }
  }
  try {
    return work();
  } finally {
    try {
      closeSync(handle);
    } catch {
      // Already closed; the unlink below is what matters.
    }
    try {
      rmSync(lock, { force: true });
    } catch {
      // A lock we cannot remove goes stale on its own within LOCK_STALE_MS.
    }
  }
}

function atomicWrite(file, contents) {
  mkdirSync(path.dirname(file), { recursive: true });
  const temp = `${file}.${process.pid}.tmp`;
  writeFileSync(temp, contents, "utf8");
  // Rename is the atomic step: a reader either sees the whole old file or the
  // whole new one, never a half-written list.
  renameSync(temp, file);
}

function readRaw(file) {
  try {
    return JSON.parse(readFileSync(file, "utf8"));
  } catch {
    // Missing, empty, or torn — an unreadable list is an empty list, never a crash.
    return null;
  }
}

/**
 * The markdown trail. One file per day in the configured vault, appended to, so
 * a second brain ends up holding what actually got done rather than only what
 * was planned. Subtasks are indented under the task they belonged to.
 */
export function appendVaultTrail(removed, settings = readSettings(), now = new Date()) {
  if (removed.length === 0) return null;
  if (!settings.vaultPath) return null;
  try {
    const folder = settings.vaultSubfolder
      ? path.join(settings.vaultPath, settings.vaultSubfolder)
      : settings.vaultPath;
    mkdirSync(folder, { recursive: true });
    const day = localDateKey(now);
    const file = path.join(folder, `${day}.md`);
    let out = "";
    try {
      out = readFileSync(file, "utf8");
    } catch {
      // Plain hyphen, not an em-dash: the tray writes this same header from an
      // ASCII-only PowerShell file, and the two must agree on it.
      out = `# Done - ${day}\n\n`;
    }
    const byId = new Map(removed.map((item) => [item.id, item]));
    for (const item of removed) {
      const time = item.completedAt ? new Date(item.completedAt) : now;
      const stamp = Number.isNaN(time.getTime())
        ? ""
        : `${String(time.getHours()).padStart(2, "0")}:${String(time.getMinutes()).padStart(2, "0")} `;
      const indent = item.parentId && byId.has(item.parentId) ? "  " : "";
      out += `${indent}- [x] ${stamp}${item.label}\n`;
    }
    // Not atomic on purpose: appending to a note a person may have open is
    // friendlier than swapping the file out from under their editor.
    writeFileSync(file, out, "utf8");
    return file;
  } catch {
    // A vault that has moved or is offline must never cost Captain a tick.
    return null;
  }
}

function fileCompleted(removed, settings = readSettings()) {
  if (removed.length === 0) return;
  const file = filedPath();
  const existing = readRaw(file);
  const filedAt = new Date().toISOString();
  const archive = [
    ...(Array.isArray(existing) ? existing : []),
    ...removed.map((item) => ({ ...item, filedAt })),
  ];
  try {
    atomicWrite(file, `${JSON.stringify(archive, null, 2)}\n`);
  } catch {
    // Losing the archive must never cost Captain the tick he just made.
  }
  appendVaultTrail(removed, settings);
}

/** Read today's list, rolling the date and filing anything past its window. */
export function readPriorities({ sweep = true, file = storePath(), settings } = {}) {
  const list = normalize(readRaw(file));
  if (!sweep) return list;
  const config = settings ?? readSettings();
  const removed = sweepCompleted(list, Date.now(), sweepWindowMs(config));
  if (removed.length > 0) {
    fileCompleted(removed, config);
    try {
      atomicWrite(file, `${JSON.stringify(list, null, 2)}\n`);
    } catch {
      // Best effort — the sweep will be retried on the next read.
    }
  }
  return list;
}

export function writePriorities(list, { file = storePath() } = {}) {
  const next = normalize(list);
  atomicWrite(file, `${JSON.stringify(next, null, 2)}\n`);
  return next;
}

function validLabel(value) {
  const label = typeof value === "string" ? value.trim() : "";
  if (!label) throw new Error("Priority text cannot be empty.");
  if (label.length > MAX_LABEL_LENGTH) {
    throw new Error(`Keep each priority under ${MAX_LABEL_LENGTH} characters.`);
  }
  return label;
}

function assertNoDuplicate(list, label, exceptId = null) {
  const lowered = label.toLowerCase();
  if (list.items.some((item) => item.id !== exceptId && item.label.toLowerCase() === lowered)) {
    throw new Error("That priority is already on today's list.");
  }
}

/**
 * Ticking a task ticks everything under it — a task is not done while its own
 * steps are open. Ticking the last subtask ticks the parent, and un-ticking any
 * subtask reopens it, so the parent always tells the truth about its thread.
 */
function setDone(list, item, done) {
  const stamp = done ? new Date().toISOString() : null;
  item.completed = done;
  item.completedAt = stamp;
  if (!item.parentId) {
    for (const child of childrenOf(list, item.id)) {
      child.completed = done;
      child.completedAt = stamp;
    }
    return;
  }
  const parent = list.items.find((entry) => entry.id === item.parentId);
  if (!parent) return;
  const siblings = childrenOf(list, parent.id);
  const allDone = siblings.every((child) => child.completed);
  parent.completed = allDone;
  parent.completedAt = allDone ? (parent.completedAt ?? stamp ?? new Date().toISOString()) : null;
}

/**
 * Read, change, write — all three inside one lock, so a second writer cannot
 * read the same "before" state and overwrite this change.
 */
export function mutate(change, { file = storePath() } = {}) {
  return withLock(file, () => {
    const list = readPriorities({ file });
    change(list);
    return writePriorities(list, { file });
  });
}

export const ops = {
  /** `parentId` makes it a subtask of that item. */
  add(label, options = {}) {
    const value = validLabel(label);
    const parentId = options.parentId ?? null;
    return mutate((list) => {
      if (parentId) {
        const parent = list.items.find((entry) => entry.id === parentId);
        if (!parent) throw new Error("That task is no longer on today's list.");
        if (parent.parentId) throw new Error("A subtask cannot have subtasks of its own.");
        if (childrenOf(list, parentId).length >= MAX_SUBTASKS) {
          throw new Error(`That task is full at ${MAX_SUBTASKS} subtasks.`);
        }
      } else if (topLevel(list).length >= MAX_ITEMS) {
        throw new Error(`Today's list is full at ${MAX_ITEMS} priorities.`);
      }
      assertNoDuplicate(list, value);
      list.items.push({
        id: randomUUID(), label: value, completed: false, completedAt: null, parentId,
      });
    }, options);
  },

  /** Move an item under a task, or back out to the top level with null. */
  setParent(id, parentId, options) {
    return mutate((list) => {
      const item = list.items.find((entry) => entry.id === id);
      if (!item) throw new Error("That priority is no longer on today's list.");
      if (!parentId) {
        if (topLevel(list).length >= MAX_ITEMS && item.parentId) {
          throw new Error(`Today's list is full at ${MAX_ITEMS} priorities.`);
        }
        item.parentId = null;
        return;
      }
      if (parentId === id) throw new Error("A task cannot be its own subtask.");
      const parent = list.items.find((entry) => entry.id === parentId);
      if (!parent) throw new Error("That task is no longer on today's list.");
      if (parent.parentId) throw new Error("A subtask cannot have subtasks of its own.");
      if (childrenOf(list, id).length > 0) {
        throw new Error("Move its subtasks out first — nesting only goes one deep.");
      }
      if (childrenOf(list, parentId).length >= MAX_SUBTASKS) {
        throw new Error(`That task is full at ${MAX_SUBTASKS} subtasks.`);
      }
      item.parentId = parentId;
    }, options);
  },

  rename(id, label, options) {
    const value = validLabel(label);
    return mutate((list) => {
      const item = list.items.find((entry) => entry.id === id);
      if (!item) throw new Error("That priority is no longer on today's list.");
      assertNoDuplicate(list, value, id);
      item.label = value;
    }, options);
  },

  toggle(id, options) {
    return mutate((list) => {
      const item = list.items.find((entry) => entry.id === id);
      if (!item) throw new Error("That priority is no longer on today's list.");
      setDone(list, item, !item.completed);
    }, options);
  },

  setCompleted(label, completed, options) {
    const value = validLabel(label);
    return mutate((list) => {
      const item = list.items.find((entry) => entry.label.toLowerCase() === value.toLowerCase());
      if (!item) throw new Error(`Priority not found: ${value}`);
      setDone(list, item, completed === true);
    }, options);
  },

  remove(id, options) {
    return mutate((list) => {
      // A task takes its subtasks with it. Leaving them behind as orphans would
      // silently promote work Captain thought he had just deleted.
      list.items = list.items.filter((entry) => entry.id !== id && entry.parentId !== id);
    }, options);
  },

  removeByLabel(label, options) {
    const value = validLabel(label);
    return mutate((list) => {
      const item = list.items.find((entry) => entry.label.toLowerCase() === value.toLowerCase());
      if (!item) throw new Error(`Priority not found: ${value}`);
      list.items = list.items.filter(
        (entry) => entry.id !== item.id && entry.parentId !== item.id,
      );
    }, options);
  },

  reorder(ids, options) {
    return mutate((list) => {
      const byId = new Map(list.items.map((item) => [item.id, item]));
      const ordered = [];
      for (const id of Array.isArray(ids) ? ids : []) {
        const item = byId.get(id);
        if (item && !ordered.includes(item)) ordered.push(item);
      }
      // Anything the caller did not mention keeps its place at the end rather
      // than silently vanishing.
      for (const item of list.items) if (!ordered.includes(item)) ordered.push(item);
      // normalize() re-threads children under their parents afterwards, so a
      // caller only has to get the task order right.
      list.items = ordered;
    }, options);
  },

  /** Drag a task above another one. Its subtasks travel with it. */
  moveBefore(id, beforeId, options) {
    return mutate((list) => {
      const item = list.items.find((entry) => entry.id === id);
      if (!item) throw new Error("That priority is no longer on today's list.");
      const moving = [item, ...childrenOf(list, item.id)];
      const movingIds = new Set(moving.map((entry) => entry.id));
      const rest = list.items.filter((entry) => !movingIds.has(entry.id));
      const at = beforeId ? rest.findIndex((entry) => entry.id === beforeId) : -1;
      if (at < 0) rest.push(...moving);
      else rest.splice(at, 0, ...moving);
      list.items = rest;
    }, options);
  },

  replace(labels, options) {
    if (!Array.isArray(labels)) throw new Error("Replacement priorities must be a list of labels.");
    if (labels.length > MAX_ITEMS) throw new Error(`Today's list is full at ${MAX_ITEMS} priorities.`);
    const values = labels.map(validLabel);
    const lowered = values.map((label) => label.toLowerCase());
    if (new Set(lowered).size !== lowered.length) {
      throw new Error("Replacement priorities contain duplicates.");
    }
    return mutate((list) => {
      // Keep the id and the tick of anything already on the list, so replacing
      // the list does not silently un-complete work Captain already finished.
      const existing = new Map(list.items.map((item) => [item.label.toLowerCase(), item]));
      // Replacing the list replaces the tasks. Subtasks of a task that survives
      // come with it; subtasks of one that does not go with their parent.
      const kept = new Set(values.map((label) => existing.get(label.toLowerCase())?.id).filter(Boolean));
      const children = list.items.filter((item) => item.parentId && kept.has(item.parentId));
      list.items = [
        ...values.map((label) => {
          const previous = existing.get(label.toLowerCase());
          return {
            id: previous?.id ?? randomUUID(),
            label,
            completed: previous?.completed ?? false,
            completedAt: previous?.completedAt ?? null,
            parentId: null,
          };
        }),
        ...children,
      ];
    }, options);
  },

  clearCompleted(options) {
    return mutate((list) => {
      const removed = list.items.filter((item) => item.completed);
      list.items = list.items.filter((item) => !item.completed);
      fileCompleted(removed);
    }, options);
  },

  saveSettings(next, options = {}) {
    const settings = writeSettings(next, options.settingsFile ? { file: options.settingsFile } : {});
    // A shorter window can make things due for filing right now, so run a read
    // straight away rather than waiting for the next poll.
    readPriorities({ ...options, settings });
    return settings;
  },
};

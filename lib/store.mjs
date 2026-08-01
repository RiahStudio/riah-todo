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
  closeSync, existsSync, mkdirSync, openSync, readFileSync, renameSync, rmSync, statSync, writeFileSync,
} from "node:fs";
import os from "node:os";
import path from "node:path";

/**
 * Captain, 2026-07-29: *"we absolutely should not have a 12-task limit… like a
 * hundred or something."*
 *
 * These are not an opinion about how many things a person should have on today —
 * they are a backstop against a paste or a runaway agent turning the file into
 * something the note cannot draw. Set high enough that nobody meets them by
 * working normally.
 */
export const MAX_ITEMS = 100;
export const MAX_SUBTASKS = 100;
/**
 * How deep a thread may go. 0 is a top-level task, so this allows six levels.
 *
 * Captain, 2026-07-29: "we should be able to use sub-threads and keep nesting if
 * we want to, because people can adjust the sizing of the widget."
 *
 * Not unlimited, because the note indents and something has to stop a paste or a
 * bad link producing a thread nobody can read. Six is past the point most people
 * ever go, and the note narrows its indent as it descends so the words keep their
 * room.
 */
export const MAX_DEPTH = 5;

/**
 * When a task is for. Captain, 2026-07-29: *"I want to put in something like
 * Riah Money, but it doesn't make any sense for me to do Riah Money right now,
 * and I don't want to forget to get it done."*
 *
 * A task carries its section; subtasks inherit it from the task they hang off,
 * so a thread can never be split across two days.
 */
export const SECTIONS = ["today", "tomorrow", "future"];
export const SECTION_LABELS = {
  today: "Today",
  tomorrow: "Tomorrow",
  future: "Later",
};
const DEFAULT_SECTION = "today";
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

export function undoPath() {
  return path.join(path.dirname(storePath()), "undo.json");
}

/**
 * One level of undo, kept on disk so it survives closing the note.
 *
 * Removing a task takes its whole thread with it, instantly, with no
 * confirmation — which is right for something you use fifty times a day, but
 * only if the mistake is cheap to reverse. Restoring the entire previous list
 * puts the task, its subtasks AND their order back exactly as they were.
 */
function rememberForUndo(items, what) {
  try {
    atomicWrite(undoPath(), `${JSON.stringify({ at: new Date().toISOString(), what, items }, null, 2)}\n`);
  } catch {
    // An undo we cannot save is a smaller problem than refusing the removal.
  }
}

/**
 * What has been ticked off and filed, newest first, grouped by the day it was
 * finished. Bounded on purpose: the archive grows for ever, and a list you
 * cannot scan is not a record you will look at.
 */
export function readFiled({ days = 14, file = filedPath() } = {}) {
  const read = readRaw(file);
  const all = read.state === "ok" && Array.isArray(read.data) ? read.data : [];
  const byDay = new Map();
  for (const item of all) {
    if (!item || typeof item.label !== "string") continue;
    const when = item.completedAt || item.filedAt;
    const stamp = when ? new Date(when) : null;
    const day = stamp && !Number.isNaN(stamp.getTime()) ? localDateKey(stamp) : "earlier";
    if (!byDay.has(day)) byDay.set(day, []);
    byDay.get(day).push({
      id: item.id,
      label: item.label,
      parentId: item.parentId ?? null,
      completedAt: item.completedAt ?? null,
    });
  }
  const ordered = [...byDay.entries()]
    .sort((a, b) => b[0].localeCompare(a[0]))
    .slice(0, days)
    .map(([day, items]) => ({
      day,
      items: items.sort((a, b) => String(a.completedAt).localeCompare(String(b.completedAt))),
    }));
  return { days: ordered, total: all.length };
}

export function undoAvailable() {
  const read = readRaw(undoPath());
  if (read.state !== "ok" || !Array.isArray(read.data?.items)) return null;
  return { what: read.data.what, at: read.data.at };
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
    parentId: typeof raw.parentId === "string" && raw.parentId ? raw.parentId : null,
    section: SECTIONS.includes(raw.section) ? raw.section : DEFAULT_SECTION,
    // Derived, and recomputed on every read — see threadItems.
    depth: 0,
  };
}

/**
 * The array order IS the display order: a depth-first walk, so every item sits
 * directly under its parent with its whole thread beneath it. Each item carries
 * a derived `depth` (0 = a top-level task) so no surface has to build a tree.
 *
 * `depth` is recomputed on every read, so a stale or hand-edited value heals
 * itself and can never send a surface off a cliff.
 */
function threadItems(items) {
  const byId = new Map(items.map((item) => [item.id, item]));
  const childrenOf = new Map();
  const roots = [];

  /** Does following parentId from here reach `id` again? */
  const wouldLoop = (item) => {
    const seen = new Set([item.id]);
    let cursor = item.parentId ? byId.get(item.parentId) : null;
    while (cursor) {
      if (seen.has(cursor.id)) return true;
      seen.add(cursor.id);
      cursor = cursor.parentId ? byId.get(cursor.parentId) : null;
    }
    return false;
  };

  for (const item of items) {
    const parent = item.parentId ? byId.get(item.parentId) : null;
    // A subtask whose parent is gone, or that is part of a loop, is promoted to
    // the top rather than dropped. Losing a task to a bad link is not on.
    if (!parent || parent.id === item.id || wouldLoop(item)) {
      item.parentId = null;
      roots.push(item);
      continue;
    }
    if (!childrenOf.has(parent.id)) childrenOf.set(parent.id, []);
    childrenOf.get(parent.id).push(item);
  }

  const threaded = [];
  const walk = (item, depth, section) => {
    item.depth = depth;
    // A thread belongs to one section — the task's. A child cannot wander off
    // to another day on its own.
    item.section = section;
    threaded.push(item);
    if (depth >= MAX_DEPTH) {
      // Too deep to show. Keep the work, flatten it to this level rather than
      // hiding it somewhere nobody will look.
      for (const child of childrenOf.get(item.id) || []) {
        child.parentId = item.parentId;
        walk(child, depth, section);
      }
      return;
    }
    for (const child of (childrenOf.get(item.id) || []).slice(0, MAX_SUBTASKS)) {
      walk(child, depth + 1, section);
    }
  };
  // Today first, then tomorrow, then later — order within a section is kept.
  const capped = roots.slice(0, MAX_ITEMS);
  for (const section of SECTIONS) {
    for (const root of capped) {
      if ((root.section ?? DEFAULT_SECTION) === section) walk(root, 0, section);
    }
  }
  return threaded;
}

/** Everything beneath an item, in display order. */
export function descendantsOf(list, id) {
  const out = [];
  const stack = [id];
  while (stack.length > 0) {
    const current = stack.pop();
    for (const item of list.items) {
      if (item.parentId === current) {
        out.push(item);
        stack.push(item.id);
      }
    }
  }
  return out;
}

/** Walk up from an item to its top-level task. */
function ancestorsOf(list, item) {
  const out = [];
  const byId = new Map(list.items.map((entry) => [entry.id, entry]));
  let cursor = item.parentId ? byId.get(item.parentId) : null;
  while (cursor && !out.includes(cursor)) {
    out.push(cursor);
    cursor = cursor.parentId ? byId.get(cursor.parentId) : null;
  }
  return out;
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
  // The array is in depth-first order, so a parent is always decided before its
  // descendants — which is what lets the "goes with its parent" rule below work
  // at any depth.
  list.items = list.items.filter((item) => {
    // Anything under something already filed goes with it, whatever its own
    // stamp says, or it would be left an orphan with no context.
    if (item.parentId && filedIds.has(item.parentId)) {
      removed.push(item);
      filedIds.add(item.id);
      return false;
    }
    if (!item.completed) return true;
    // No stamp means it predates the stamp — already older than the window.
    const stamped = item.completedAt ? new Date(item.completedAt).getTime() : NaN;
    if (!Number.isFinite(stamped) || nowMs - stamped >= ttlMs) {
      // Never file a task out from under work that is still open, however deep.
      const openBelow = descendantsOf(list, item.id).some((other) => !other.completed);
      if (openBelow) return true;
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

/** Is the process that wrote this lock still running? */
function ownerAlive(pid) {
  if (!Number.isInteger(pid) || pid <= 0) return false;
  try {
    process.kill(pid, 0);
    return true;
  } catch (error) {
    // EPERM means it exists but belongs to someone else — still alive.
    return error.code === "EPERM";
  }
}

/**
 * Fifteen seconds, not five. The lock is held for milliseconds, so a real person
 * never waits — but a busy machine spawning several writers at once made 5s
 * marginal, and a refused tick is a bad way to learn that. A dead owner is
 * reclaimed immediately via its PID, so this only stretches genuine contention.
 */
export const LOCK_TIMEOUT_MS = 15_000;

export function withLock(file, work, { timeoutMs = LOCK_TIMEOUT_MS } = {}) {
  const lock = lockPath(file);
  mkdirSync(path.dirname(file), { recursive: true });
  const started = Date.now();
  let handle = null;
  for (;;) {
    try {
      handle = openSync(lock, "wx");
      // Stamp who owns it. Age alone is not evidence of abandonment: a busy
      // holder can take longer than any window you pick, and stealing its lock
      // puts two writers on one file — which is the bug this whole thing exists
      // to prevent. It showed up as 11-of-12 survivors under load.
      try {
        writeFileSync(handle, JSON.stringify({ pid: process.pid, at: Date.now() }));
      } catch {
        // An unstamped lock is still a lock; it just cannot be reclaimed early.
      }
      break;
    } catch (error) {
      if (error.code !== "EEXIST") throw error;
      // Only reclaim a lock whose owner is genuinely gone.
      try {
        const held = JSON.parse(readFileSync(lock, "utf8"));
        const age = Date.now() - (held.at ?? 0);
        if (!ownerAlive(held.pid) && age > 250) {
          rmSync(lock, { force: true });
          continue;
        }
      } catch {
        // Unreadable or unstamped (an older version, or mid-write). Fall back to
        // age only, and be generous about it.
        try {
          if (Date.now() - statSync(lock).mtimeMs > LOCK_STALE_MS) {
            rmSync(lock, { force: true });
            continue;
          }
        } catch {
          // It vanished between the failed open and the stat — just retry.
        }
        // fall through to the timeout check
      }
      if (Date.now() - started > timeoutMs) {
        // Proceeding unlocked here would quietly cancel the whole guarantee at
        // exactly the moment it matters — under contention. Refusing loudly is
        // the safe failure: nothing is written, nothing is lost, and the caller
        // can say so.
        throw new Error(
          `Riah To-Do could not get exclusive access to your list at ${file} — another window is mid-change. `
          + "Nothing was altered. Try again in a moment.",
        );
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
  // Keep the previous good list beside the live one so a bad rewrite can be
  // undone. One rolling backup is enough — losing threads on reboot / a
  // flat rewrite is worse than an extra small file.
  try {
    if (existsSync(file)) {
      const prev = `${file}.prev`;
      writeFileSync(prev, readFileSync(file));
    }
  } catch {
    // Backup is best-effort; never block the real write.
  }
  const temp = `${file}.${process.pid}.tmp`;
  writeFileSync(temp, contents, "utf8");
  // Rename is the atomic step: a reader either sees the whole old file or the
  // whole new one, never a half-written list.
  renameSync(temp, file);
}

/**
 * "Missing" and "unreadable" are not the same thing, and treating them the same
 * is how work disappears: a half-written file parsed as an empty list, then
 * confidently overwritten with one new task. A file that does not exist yet may
 * start empty. A file that exists but cannot be read is a stop sign.
 */
export class ListUnreadableError extends Error {
  constructor(file, cause) {
    super(
      `Riah To-Do could not read your list at ${file}, so nothing was changed and the file was left exactly as it is. `
      + `Fix or move that file and try again. (${cause})`,
    );
    this.name = "ListUnreadableError";
    this.file = file;
    this.needsRecovery = true;
  }
}

function readRaw(file) {
  let text;
  try {
    text = readFileSync(file, "utf8");
  } catch (error) {
    if (error.code === "ENOENT") return { state: "missing" };
    // Locked, permission-denied, a directory — real, and not an empty list.
    return { state: "corrupt", why: error.message };
  }
  if (!text.trim()) return { state: "missing" };
  try {
    // Shape is the caller's business: this file holds the list (an object) and
    // the archive (an array), and judging both by one shape marked every archive
    // corrupt.
    return { state: "ok", data: JSON.parse(text) };
  } catch (error) {
    return { state: "corrupt", why: error.message };
  }
}

/** Parsed list, or a throw naming the file. Never silently empty. */
function loadList(file) {
  const read = readRaw(file);
  if (read.state === "corrupt") throw new ListUnreadableError(file, read.why);
  if (read.state === "missing") return normalize(null);
  const { data } = read;
  if (!data || typeof data !== "object" || !Array.isArray(data.items)) {
    throw new ListUnreadableError(file, "the file is not a Riah To-Do list");
  }
  return normalize(data);
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
    /** How far under its task this sits, counting only what is being filed. */
    const depthOf = (item) => {
      let depth = 0;
      let cursor = item.parentId ? byId.get(item.parentId) : null;
      while (cursor && depth < 20) {
        depth += 1;
        cursor = cursor.parentId ? byId.get(cursor.parentId) : null;
      }
      return depth;
    };
    for (const item of removed) {
      const time = item.completedAt ? new Date(item.completedAt) : now;
      const stamp = Number.isNaN(time.getTime())
        ? ""
        : `${String(time.getHours()).padStart(2, "0")}:${String(time.getMinutes()).padStart(2, "0")} `;
      // Indent by real depth, so a six-level thread reads in the vault the way
      // it reads in the note — not flattened to one level.
      out += `${"  ".repeat(depthOf(item))}- [x] ${stamp}${item.label}\n`;
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

/**
 * File completed work into the archive. THROWS if the archive cannot be written.
 *
 * The README promises ticked items are filed, not deleted. Swallowing an archive
 * failure and then trimming the active list anyway breaks that promise silently:
 * the task is gone from both files. So the caller only removes items from the
 * live list once this has returned.
 *
 * Appending is idempotent on (id, completedAt), so a retry after a half-finished
 * sweep files each task exactly once instead of duplicating it.
 */
function fileCompleted(removed, settings = readSettings()) {
  if (removed.length === 0) return;
  const file = filedPath();
  let existing = [];
  const read = readRaw(file);
  if (read.state === "ok") {
    if (!Array.isArray(read.data)) {
      // Something else is living at that path. Do not clobber it, and do not
      // pretend the filing worked.
      throw new Error(
        `Riah To-Do could not file finished work into ${file} — that file is not an archive, `
        + "so the finished items were left on your list instead of being lost.",
      );
    }
    existing = read.data;
  } else if (read.state === "corrupt") {
    throw new Error(
      `Riah To-Do could not file finished work into ${file}, so it was left on your list `
      + `instead of being lost. (${read.why})`,
    );
  }
  const seen = new Set(existing.map((item) => `${item?.id}@${item?.completedAt ?? ""}`));
  const fresh = removed.filter((item) => !seen.has(`${item.id}@${item.completedAt ?? ""}`));
  if (fresh.length > 0) {
    const filedAt = new Date().toISOString();
    atomicWrite(file, `${JSON.stringify([...existing, ...fresh.map((item) => ({ ...item, filedAt }))], null, 2)}\n`);
  }
  // The vault trail is a convenience, not the record — a moved or offline vault
  // must not hold up filing.
  appendVaultTrail(removed, settings);
}

/** Read today's list, rolling the date and filing anything past its window. */
export function readPriorities({ sweep = true, file = storePath(), settings } = {}) {
  const list = loadList(file);
  if (!sweep) return list;
  const config = settings ?? readSettings();
  const before = structuredClone(list.items);
  const removed = sweepCompleted(list, Date.now(), sweepWindowMs(config));
  if (removed.length > 0) {
    try {
      // Archive FIRST. Only if that lands does the live list lose them.
      fileCompleted(removed, config);
      atomicWrite(file, `${JSON.stringify(list, null, 2)}\n`);
    } catch (error) {
      // Put them back. Finished work stays visible and gets retried rather than
      // evaporating because a disk was full or a folder went missing.
      list.items = before;
      process.emitWarning(`Riah To-Do kept finished work on the list: ${error.message}`);
    }
  }
  return list;
}

/**
 * For surfaces that must render something rather than crash. A list that cannot
 * be read is reported as needing recovery — never drawn as a convincing empty
 * list, which is what makes a person add work on top of the file they just lost.
 */
export function readPrioritiesForDisplay(options = {}) {
  try {
    return { ok: true, priorities: readPriorities(options) };
  } catch (error) {
    if (error instanceof ListUnreadableError) {
      return { ok: false, error: error.message, file: error.file, needsRecovery: true };
    }
    throw error;
  }
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

/**
 * Duplicate labels are ALLOWED.
 *
 * Captain, 2026-07-29: *"I wrote 'post on socials' under Gumroad Shovels, and
 * 'post on socials' under Riah To-Do. There shouldn't be anything that stops you
 * from doing that."* Quite right — the same job under two different tasks is two
 * different jobs, and refusing it was obnoxious.
 *
 * The knock-on: tools that address an item BY LABEL can now match more than one.
 * They take the first, and say so, rather than refusing to act.
 */
function findByLabel(list, label) {
  const lowered = label.toLowerCase();
  const matches = list.items.filter((item) => item.label.toLowerCase() === lowered);
  return { first: matches[0] ?? null, count: matches.length };
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

  // Down: the whole thread beneath it, however deep.
  for (const child of descendantsOf(list, item.id)) {
    child.completed = done;
    child.completedAt = stamp;
  }

  // Up: each ancestor is done only while every one of ITS children is, and
  // reopening anything reopens the line above it all the way to the top.
  for (const ancestor of ancestorsOf(list, item)) {
    const allDone = childrenOf(list, ancestor.id).every((child) => child.completed);
    ancestor.completed = allDone;
    ancestor.completedAt = allDone
      ? (ancestor.completedAt ?? stamp ?? new Date().toISOString())
      : null;
  }
}

/**
 * Read, change, write — all three inside one lock, so a second writer cannot
 * read the same "before" state and overwrite this change.
 */
export function mutate(change, { file = storePath(), timeoutMs } = {}) {
  return withLock(file, () => {
    const list = readPriorities({ file });
    change(list);
    return writePriorities(list, { file });
  }, timeoutMs === undefined ? {} : { timeoutMs });
}

export const ops = {
  /** `parentId` makes it a subtask of that item. */
  add(label, options = {}) {
    const value = validLabel(label);
    const parentId = options.parentId ?? null;
    const section = SECTIONS.includes(options.section) ? options.section : DEFAULT_SECTION;
    return mutate((list) => {
      if (parentId) {
        const parent = list.items.find((entry) => entry.id === parentId);
        if (!parent) throw new Error("That task is no longer on today's list.");
        if ((parent.depth ?? 0) >= MAX_DEPTH) {
          throw new Error(`That thread is as deep as it goes (${MAX_DEPTH + 1} levels).`);
        }
        if (childrenOf(list, parentId).length >= MAX_SUBTASKS) {
          throw new Error(`That task is full at ${MAX_SUBTASKS} subtasks.`);
        }
      } else if (topLevel(list).length >= MAX_ITEMS) {
        throw new Error(`Today's list is full at ${MAX_ITEMS} priorities.`);
      }
      list.items.push({
        id: randomUUID(), label: value, completed: false, completedAt: null, parentId,
        section,
      });
    }, options);
  },

  /** Move a task to another section. Its whole thread goes with it. */
  setSection(id, section, options) {
    if (!SECTIONS.includes(section)) throw new Error(`Not a section: ${section}`);
    return mutate((list) => {
      const item = list.items.find((entry) => entry.id === id);
      if (!item) throw new Error("That priority is no longer on today's list.");
      // Always section the TASK, never a step: a thread stays whole.
      const byId = new Map(list.items.map((entry) => [entry.id, entry]));
      let root = item;
      while (root.parentId && byId.has(root.parentId)) root = byId.get(root.parentId);
      root.section = section;
      for (const child of descendantsOf(list, root.id)) child.section = section;
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
      // Dropping something into its own thread would orphan the lot.
      if (descendantsOf(list, id).some((entry) => entry.id === parentId)) {
        throw new Error("A task cannot be moved inside its own thread.");
      }
      if (childrenOf(list, parentId).length >= MAX_SUBTASKS) {
        throw new Error(`That task is full at ${MAX_SUBTASKS} subtasks.`);
      }
      // The whole thread moves, so it is the DEEPEST part that has to fit.
      const own = descendantsOf(list, id);
      const ownDepth = own.reduce((max, entry) => Math.max(max, (entry.depth ?? 0) - (item.depth ?? 0)), 0);
      if ((parent.depth ?? 0) + 1 + ownDepth > MAX_DEPTH) {
        throw new Error(`That would nest deeper than ${MAX_DEPTH + 1} levels.`);
      }
      item.parentId = parentId;
    }, options);
  },

  rename(id, label, options) {
    const value = validLabel(label);
    return mutate((list) => {
      const item = list.items.find((entry) => entry.id === id);
      if (!item) throw new Error("That priority is no longer on today's list.");
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
      const { first: item } = findByLabel(list, value);
      if (!item) throw new Error(`Priority not found: ${value}`);
      setDone(list, item, completed === true);
    }, options);
  },

  remove(id, options) {
    return mutate((list) => {
      const going = list.items.find((entry) => entry.id === id);
      // Snapshot the whole list, so undo restores order as well as content.
      // Just the label — surfaces supply their own "Removed …" wording.
      rememberForUndo(structuredClone(list.items), going ? going.label : "that item");
      // A task takes its WHOLE thread with it, however deep. Leaving descendants
      // behind would silently promote work Captain thought he had just deleted.
      const doomed = new Set([id, ...descendantsOf(list, id).map((entry) => entry.id)]);
      list.items = list.items.filter((entry) => !doomed.has(entry.id));
    }, options);
  },

  /** Put back exactly what the last removal took — task, thread and order. */
  undo(options) {
    const read = readRaw(undoPath());
    if (read.state !== "ok" || !Array.isArray(read.data?.items)) {
      throw new Error("There is nothing to undo.");
    }
    const restored = read.data.items;
    const result = mutate((list) => { list.items = restored; }, options);
    try {
      rmSync(undoPath(), { force: true });
    } catch {
      // A leftover undo file only means the offer lingers; harmless.
    }
    return result;
  },

  removeByLabel(label, options) {
    const value = validLabel(label);
    return mutate((list) => {
      const { first: item } = findByLabel(list, value);
      if (!item) throw new Error(`Priority not found: ${value}`);
      const doomed = new Set([item.id, ...descendantsOf(list, item.id).map((entry) => entry.id)]);
      list.items = list.items.filter((entry) => !doomed.has(entry.id));
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
      // The whole thread travels, however deep.
      const moving = [item, ...descendantsOf(list, item.id)];
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

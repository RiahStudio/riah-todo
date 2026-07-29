# Hardening pass — 2026-07-29

Handoff record for the second audit round. Every fault below was **reproduced
before it was fixed**, and each fix has a test that fails on the old code.

Release head: `6aedb1f` · repo **private** · publish sweep 0 blockers.

## Root causes

**1. Corrupt and missing were the same thing.** `readRaw()` returned `null` for a
missing file *and* for a torn one. `normalize(null)` is an empty list, so a
half-written file became "you have no tasks" — and the next add wrote one task
over the top. Repro: a truncated `today.json` holding `REAL WORK`, then
`ops.add()`; the original was gone.

*Fix:* `readRaw` reports `missing | ok | corrupt`. Missing may start empty;
corrupt throws `ListUnreadableError` naming the file. Every mutation refuses and
leaves the bytes alone. `readPrioritiesForDisplay()` gives surfaces a recovery
state instead of a lie. The board shows a banner and disables the add box; the
tray paints "LIST FILE UNREADABLE".

**2. Filing swallowed its own failure.** `fileCompleted()` caught archive-write
errors and returned; the caller then wrote the trimmed list. The task left
`today.json` and never reached `today-filed.json` — the opposite of what the
README promises. Repro: a directory placed where the archive file goes.

*Fix:* the archive write must succeed before anything leaves the live list. On
failure the items are put back and a warning is emitted. Appends dedupe on
`(id, completedAt)`, so retrying after a half-finished sweep files each task
exactly once. The vault trail stays non-fatal — it is a convenience, not the
record.

**3. The lock let go under pressure.** Both implementations gave up after 5s and
proceeded **unlocked**, which cancels the guarantee at the only moment it
matters. PowerShell's `Exit-StoreLock` also deleted the lock file even when it
had never acquired it, freeing another process's live lock.

*Fix:* a writer that cannot get the lock **refuses**. PowerShell only removes a
lock it holds. And reclaiming is now based on the recorded PID being gone, not on
age — the age-only check was stealing live locks, which the concurrency test
caught as 11-of-12 survivors on the release tree.

**4. Deletion was instant and irreversible**, and removing a parent took its
whole thread.

*Fix:* one level of undo, kept on disk so it survives closing the note, restoring
the exact tasks *and their order*. Coarse-pointer CSS shows destructive controls
without requiring hover.

## Also

- Path containment: `startsWith` → `path.relative`, plus nine encoded and
  backslash traversal probes.
- `.gitignore`: project patterns **merged into** the hardened release set.
- `private: true`, repository/bugs/homepage metadata.
- README: download-and-install, Windows-only, backup and recovery, reporting.
- `Open The Board.bat` refuses when Node is missing or 8779 is another program's.
- CI for the Node surface; `RELEASE-CHECKLIST.md` for the Windows-only GUI gates.

## Validation

From a clean checkout of the published commit (`npm ci`):

| Gate | Result |
| --- | --- |
| `npm test` | 36/36 |
| `smoke:race` | 12 writers × 8 trials, 12 survivors every time |
| `smoke:server` | cross-origin, DNS rebind, 9 traversals — all blocked |
| `smoke:guard` | accidental empty blocked, deliberate allowed |
| `smoke:note` | real tray: add, tick, subtasks, thread, reorder, filing, vault |
| `npm audit --omit=dev` | 0 vulnerabilities |
| publish sweep `--publishing` | 0 blocked / 0 notes / 0 warnings |

Board checked in-browser: undo restores a thread and its order; the recovery
banner names the file and suppresses the empty state; contrast 5.66/5.44; 26px
targets; focus reveals hover-only controls.

## Honest limitations

- **The tray note is not screen-reader accessible.** Its rows are painted, not
  controls. Documented, with the board as the accessible surface.
- **CI cannot run the GUI smokes** — no interactive desktop. They are a
  release-machine gate in `RELEASE-CHECKLIST.md`, not a green tick on GitHub.
- **One level of undo**, not a history.
- The lock is advisory: a program that ignores it can still corrupt the file.
  Every surface *we* ship honours it.

## Source vs release

Identical but for `.gitignore`, which intentionally carries the release-only
hardened credential/profile patterns on top of the project ones.

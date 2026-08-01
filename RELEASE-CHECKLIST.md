# Release checklist — Riah To-Do

CI covers the Node surface. The tray note needs a real interactive Windows
desktop to draw itself, so **the two GUI gates below must be run on a Windows
machine before any release.** CI cannot do them, and saying otherwise would make
a green tick mean less than it should.

## On a Windows machine

```bash
npm ci
```

```bash
npm run check
```

That is the full suite: rules, threading, safety (corruption / archive failure /
lock ownership), the 12-writer race, the loopback server's origin, DNS-rebinding
and traversal defences, the empty-write guard, and the real tray note driven
through add, tick, subtasks, thread completion, reorder, filing and vault trail —
including a screenshot that is checked for actual pixels.

```bash
npm audit --omit=dev
```

Then, by hand, with the note open:

- Click the icon; click a box; click the words; drag a row; drag an edge.
- Dark and light on the board; 390px width; keyboard-only pass with visible focus.
- Empty, full, completed, nested, unreadable-file and undo states.

## Publication gate

```bash
node "Riah Build Playbook/bin/publish-readiness-sweep.js" --project "_public-repos/riah-todo" --publishing
```

Then read `Riah Build Playbook/PUBLISH-GATE.md`. Zero blockers, or stop.

Rebuild the release tree from the workshop rather than editing it:

```bash
node "Riah Build Playbook/bin/New-PublicRelease.ps1" -Project "Riah To-Do" -RepoName riah-todo -Confirm
```

**Two things that bite every time:**

1. The tool **overwrites `.gitignore`** with the generic hardened set, dropping
   the project patterns. Re-append them after every rebuild — `today.json`,
   `today-filed.json`, `settings.json`, `undo.json`, `*.lock`, `*.tmp`,
   `_REJECTED_/` — *alongside* the credential/profile patterns, never instead.
2. The tool **exits non-zero on a harmless git line-ending warning**, which stops
   the rest of your command. Run the copy-into-the-mirror step separately, and
   check the mirror actually changed before committing.

Then check the published commit out clean, `npm ci`, and run `npm run check`
there. Ship what you tested, not what you meant to test.

**Build the release ZIP from a fresh clone, never from `_public-repos/riah-todo`.**
Running the suite in the mirror leaves `node_modules/` and a `scratch/tray.log`
behind. Git ignores both, so they will not reach GitHub — but a ZIP made by
right-clicking the folder would carry them.

## The public face

Same pattern as Riah Usage: the **README on the GitHub repo** is the product
page (shots, pitch, quick start). `docs/index.html` is only a redirect to that
README, kept so old `github.io` links still land somewhere useful. Clear the
repo homepage field (or leave it empty) — do not point visitors at a marketing
shell.

## Suggested repository topics

Prepared, **not applied** — setting them is Captain's call:

`todo` · `windows` · `tray` · `system-tray` · `productivity` · `powershell` ·
`nodejs` · `mcp` · `local-first` · `no-cloud`

## v1.0.0

- [x] `npm run check` green on Windows
- [x] `npm audit --omit=dev` clean
- [x] Publish sweep: 0 blockers
- [x] Release tree rebuilt, pushed, and re-tested from a clean checkout
- [x] **GitHub Actions actually green.** It was red on every run for a week —
      `node --test test/*.test.mjs` relies on shell globbing, and the runner uses
      pwsh with Node 20. Test files are listed explicitly now.
- [x] A bare download runs with nothing installed: tray and board both work with
      no `node_modules`, on a first-run empty data folder.
- [x] README shows the app as it actually looks, and offers **Code → Download
      ZIP** so the instructions are true before any release exists.

- [x] Release mirror synced with the workshop and re-audited from a clean clone
      (`e34e9af`): sections, caps of 100, sub-thread reorder, duplicate labels,
      depth-indented filing, and the public page. CI green on that commit.

## Launched 2026-07-29

- [x] `v1.0.0` tagged at `875f012`, with `riah-todo-v1.0.0.zip` attached. The ZIP
      is `git archive` of the tag, so it carries tracked files only.
- [x] Repository is **public**, with topics and description applied
- [x] GitHub Pages serving `/docs` at <https://riahstudio.github.io/riah-todo/>
- [x] `repo-map.mjs write` run — the map now lists riah-todo as public
- [x] Both **Get Riah To-Do** buttons resolve to the release

Still open, and all Captain's call:
- [ ] Keep or trim the studio commentary in the source. Riah Usage ships public
      with the same voice, so the recommendation is **keep** — it is honest
      engineering history, and no path in it is secret.

## v1.0.1 — 2026-08-01

- [x] Rolling `.prev` backup in store + tray — nested sub-threads survive reboot /
      a flat rewrite
- [x] Public page restyled to the shared Riah signature (Usage dark/light: grid,
      reg marks, theme toggle, product shots up front)
- [x] `v1.0.1` tagged at `94d4ce5`, ZIP + release notes with screenshots
- [x] 64/64 `npm test` green before push

## Re-release (v1.0.x)

The first release is done, so the gate for the next one is shorter. Run it in
this order — the point of the order is that the cheap checks fail before the
expensive ones.

1. `npm ci`
2. `npm run check` **on Windows**. The two GUI gates in `smoke:note` still need a
   real interactive desktop; a headless or automated session cannot run them and
   should say so rather than pass by omission.
3. `npm audit --omit=dev`
4. The by-hand pass at the top of this file — click, drag, both themes, 390px,
   keyboard-only, and the unreadable-file state.
5. `node "Riah Build Playbook/bin/publish-readiness-sweep.js" --project "_public-repos/riah-todo" --publishing`
6. Rebuild the mirror with `New-PublicRelease.ps1`, then **re-append the project
   `.gitignore` patterns** — the tool overwrites that file every single time.
7. Fresh clone, `npm ci`, `npm run check` there. Ship what you tested.
8. Tag, and build the ZIP with `git archive` from the tag — never by
   right-clicking the mirror folder.

Docs-only changes (README, `docs/index.html`) still go through steps 5–7. The
publish sweep is what catches a secret or a private path sneaking into a public
tree, and a docs edit is perfectly capable of carrying one.

### Non-GUI validation, 2026-07-29

Run in the workshop on Node 18+. These four are safe to run anywhere and need no
desktop, no network and no credentials:

| Command | Result |
| --- | --- |
| `npm test` | 64/64 pass |
| `npm run smoke:race` | OK — `everyday=4x3`, `stress=12x3`, 0 refusals, no lost updates |
| `npm run smoke:server` | OK — cross-origin, DNS-rebind and traversal all blocked; own page allowed |
| `npm run smoke:guard` | OK — accidental empty write blocked, deliberate empty allowed |

`npm run smoke:note` was **not** run in that pass — it draws the real tray note
and needs an interactive desktop. It is still a required gate for any release.


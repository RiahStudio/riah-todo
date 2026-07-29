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

## The public page

`docs/index.html` is the sales page: Captain's approved copy, self-contained,
follows the reader's light or dark theme. It is served by turning on GitHub
Pages (Settings → Pages → branch `main`, folder `/docs`) once the repo is public.

Both **Get Riah To-Do** buttons point at `releases/latest`. **That link 404s
until `v1.0.0` exists.** Cut the tag before, or in the same sitting as, turning
the page on.

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


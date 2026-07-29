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

Then check the published commit out clean, `npm ci`, and run `npm run check`
there. Ship what you tested, not what you meant to test.

## Suggested repository topics

Prepared, **not applied** — setting them is Captain's call:

`todo` · `windows` · `tray` · `system-tray` · `productivity` · `powershell` ·
`nodejs` · `mcp` · `local-first` · `no-cloud`

## v1.0.0

- [ ] `npm run check` green on Windows
- [ ] `npm audit --omit=dev` clean
- [ ] Publish sweep: 0 blockers
- [ ] Release tree rebuilt, pushed, and re-tested from a clean checkout
- [ ] README download link points at a release that exists
- [ ] Repository visibility flipped to public — **Captain only**
- [ ] `node "_shared-agent-rules/bin/repo-map.mjs" write` after the flip
- [ ] Tag `v1.0.0` and attach a ZIP of the release tree

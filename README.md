# Riah To-Do

<p align="center">
  <img src="docs/screenshots/note-dark.png" width="49%" alt="Riah To-Do — the note open on a Windows desktop above the clock, with today&rsquo;s nested tasks" />
  <img src="docs/screenshots/note-scrolling.png" width="49%" alt="Riah To-Do — same desktop, a longer list scrolling inside a shorter note" />
</p>

**The to-do list you'll actually open.**

It sits by the Windows clock. Click the tray icon, write today's list, click away.

We all want to be organized. We've all downloaded twenty different to-do apps to prove it. And most of us never opened one of them twice. Not because we stopped caring, but because opening it was a chore.

This one lives where you already look. Checked-off tasks clear themselves, and land in your Obsidian vault (adjustable, of course). It's one small JSON file on your own PC.

**Free, and running in about a minute.**

## Quick start

1. Download the latest ZIP from [Releases](https://github.com/RiahStudio/riah-todo/releases), or use **Code → Download ZIP**.
2. Extract it somewhere you'll keep it — `Documents\Riah To-Do` is fine.
3. Double-click **`Start Riah To-Do.bat`**.

An icon appears by the clock. Click it.

To stop later: **`Stop Riah To-Do.bat`**. For every morning: put a shortcut to `Start Riah To-Do.bat` in `shell:startup`.

## Requirements

- **Windows** 10 or 11 (PowerShell 5.1 ships with Windows — nothing else to install for the note)
- **Node.js** 18+ is optional — only for the board page and the AI tools. The note never needs it.

No accounts with us. No sync. No telemetry.

## System tray (Windows)

Click the tray icon to open the note. **Hover does nothing** — click-to-open on purpose. Click away (or Esc / the `x`) and it closes.

- Drag the note to move it; drag an edge or corner to resize
- Drag the top or bottom edge to lock a height — then the list scrolls inside
- Right-click the tray icon for the list, the board, what you've finished, settings, file the finished ones, quit

The icon is the status: one bar per item, green once ticked, and a single green check when the list is clear.

## Using it

| You do | It does |
| --- | --- |
| Click the tray icon | The note opens |
| Click the box | Ticks it off — or un-ticks it |
| Click the words | Edits them in place. Enter saves, Esc cancels |
| Right-click a row | Same — straight into editing |
| Shift + right-click a task | Moves it Today → Tomorrow → Later → Today |
| Drag a row | Reorders among its siblings |
| Hover a row, click `+` | Starts a subtask (up to six levels) |
| Type at the bottom, Enter | Adds an item |
| Hover a row, click the `x` | Removes it |

Ticking a task ticks its whole thread. Unfinished work carries over tomorrow. Checked-off tasks leave the list after two hours by default (adjustable) and can also land in an Obsidian vault — right-click the tray → **Settings**.

## The board

Optional fuller page for when a note isn't enough: **`Open The Board.bat`**, or `npm start` then <http://127.0.0.1:8779>. Same list, more room, keyboard-friendly. Prefer the board if you use a screen reader — the note is painted, not real controls.

## Privacy

- One JSON file in your own `%APPDATA%\Riah To-Do\`
- Nothing leaves your machine
- No accounts, no sync, no telemetry

Point somewhere else with `RIAH_TODO_FILE` or `RIAH_TODO_DIR` — a synced folder works fine.

## Letting an AI set your list

```bash
npm install
node bin/todo-mcp-server.mjs
```

Five MCP tools write the same file, so the note updates a second later.

## Checking it still works

```bash
npm test
```

`npm run smoke:note` needs a real Windows desktop (see `RELEASE-CHECKLIST.md`).

## From the maker

This is a vibe-coded project — I'm not a real developer and probably won't become one. It's just something cool I wanted for myself, to make my life easier, so I made it. I would love feedback if it's not too technical or aggressive 😅.
Hope you guys like it!

## License

MIT — free to use, fork, and ship. Keep the license file. Bundled fonts are under the SIL Open Font License (see `assets/fonts/`).

Something wrong? Open an issue and attach `scratch/tray.log` from the app folder if you can.

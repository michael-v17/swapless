# Swapless

A native macOS menu-bar app that keeps a 16 GB Mac out of swap. It measures every process the way
Activity Monitor does, names the real culprit (system processes, Safari tabs and booted simulators
included), and fixes it only when you have set a rule for that app.

**Status:** pre-code (repo born 2026-11-05). Private.

## v1 (planned)
- **Known-leak guard.** Quietly restarts macOS's leaking wallpaper process (`WallpaperImageExtension`).
- **Real culprits in the menu bar.** Footprint per app, plus a map of what grows the most.
- **Quiet, actionable alerts.** An alert names the cause and offers the fix.
- **Quit on last window close.** Opt-in, with exceptions.
- **Per-app rules.** Watch only, restart above a threshold, quit when idle, or quit on last
  window close. Unknown apps are never touched.

## Pointers
- `CLAUDE.md`: the operating manual and its hard walls.
- `DECISIONS.md`: why things are the way they are, and what is still open.
- `WORKFLOW.md`: how changes reach `main` (PRs only).
- `docs/research/`: prior art and API findings.
- `specs/`: one contract per task, written with `/wingman`.

## License
MIT. See `LICENSE`.

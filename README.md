# Swapless

A native macOS menu-bar app that keeps a 16 GB Mac out of swap. It measures every process the way
Activity Monitor does, names the real culprit (system processes, Safari tabs and booted simulators
included), and fixes it only when you have set a rule for that app.

**Status:** slice 1 of v1 (`v1-core`) implemented on its branch, pending the owner's acceptance
(2026-11-05). Private.

## Build, run, verify
```
swift build && swift test                    # compile + unit tests
./scripts/make-cert.sh                       # once per Mac (owner only: keychain prompt)
./scripts/make-app.sh release [--adhoc]      # wrap, sign, install to /Applications, relaunch
./scripts/leak-rig.sh [--only N | --budget | --sim | --live-wallpaper]   # the rig (exit 0 = pass)
```
`./scripts/leak-rig.sh --on-screen-menu` opens the real menu on the screen: only in an announced
session the owner approved, never in the done-gate (DECISIONS.md, 2026-11-05).
Headless contract: `SWAPLESS_STATE_DIR=$(mktemp -d) .build/debug/Swapless --headless` prints JSON
lines; `--print-menu` prints the menu as text; `--dump-snapshot <file>` writes a sanitized fixture.

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

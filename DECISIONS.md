# DECISIONS — rationale log (context for future sessions; never spec)

Newest first. Each entry: what was decided, why, and what it replaced. Settled knobs are
not silently reopened — challenge them here, in writing, if evidence demands it.

**Mandatory triggers — an entry is NOT optional when:** a hard wall was bypassed (via
`ALLOW_MAIN_COMMIT=1` or otherwise) · a rule this repo had settled was overridden in
practice · a degraded pass shipped (a fallback fired, a check was skipped, a result scored
"partially done"). This domain adds three triggers, from asking "what can this repo's output do to
the owner if it's wrong?":
- **Swapless acted on a process with no owner rule.** It quit, restarted or signalled
  something outside a rule, even during a test on the real Mac.
- **A user app lost unsaved work or was force-killed** because of Swapless.
- **A shipped build exceeded its own overhead budget** (CPU or footprint, as measured).

`/ship-task` step 3 checks these on every shipment. Discretionary entries stay welcome —
the triggers are a floor, not a ceiling.

## 2026-11-05 · License: MIT, and GPL code is read, never copied

**Decided:** MIT. The repo is private for now. The owner asked for the license that fits best.

**Why:** MIT is short and permissive, and it keeps every option open: staying private, going
public later, mixing in MIT prior art. The prior art closest to v1 is GPL-3: MagicQuit and
SwiftQuit. Copying their code would force this repo to be GPL-3. So we read them for ideas
and write our own code; approaches and ideas aren't copyrightable. mac-memory-guard is MIT;
check the license of any other source before taking more than an idea from it.

## 2026-11-05 · What v1 is, in the owner's words

**Decided (owner, 2026-11-05):**
- **Name: Swapless.** Checked against live products: "Headroom" is already a macOS menu-bar app
  for developers, so it was dropped. Nothing called "Swapless" turned up.
- **Native menu-bar app, like TypeFlow, in a private repo. Everything in the repo is in English.**
- **v1 has all four features:** known-leak guard, real culprits in the menu bar, quiet
  actionable alerts, quit on last window close.
- **On top of them, per-app rules:**
  - a map of what grows the most;
  - per app, the owner chooses: only tell, restart it, or quit it;
  - exceptions;
  - new heavy apps the owner is working in never restart or close on their own;
  - quit-on-last-window acts only when the owner turns it on.
- **No stopgap:** mac-memory-guard was not patched to restart the wallpaper; v1 replaces it.
- **Portal stays.** The owner needs it to work. The leak is in macOS's `WallpaperImageExtension`,
  not in Portal. Restarting that process leaves Portal playing (measured: 3.3 GB → 118 MB,
  memory free 46 % → 62 %).

**Why:** the off-the-shelf tools failed on this Mac. MagicQuit's quit-on-last-window never
fired (Notes in 3 tests, Slack in the owner's test). mac-memory-guard alerted at "warning"
pressure 8 times in 22 h and listed only `/Applications` apps by RSS, so it never named the
wallpaper leak.

## 2026-11-05 · Repo genesis: harness before code

**Decided:** Swapless is born with the harness kit (task/worktree commands, PR-only `main`
hook, personal observer + `/retro`, `/wingman` spec sessions) *before* any product code
exists.

**Why:** porting a proven harness beats inventing one ("port, not invent" — the kit's
templates trace back through three earlier app repos). Specs → unattended runs →
executable gates pay from the first task.

**Open (deliberately undecided, for the first specs):**
- **Rules model.** What a rule looks like: an app or process match, a condition (footprint above
  X, growth slope, idle for N, last window closed), an action (tell / restart / quit), a
  cooldown, exceptions. Where the rules live (UserDefaults vs a JSON file the owner can edit).
  Settled: an unknown app defaults to tell only.
- **The "map of what grows".** How long samples are kept, where (JSON vs SQLite), and which views
  (top growers today, per-app history).
- **Sampling interval and overhead budget.** Candidates: 10–30 s, under 40 MB, under 1 % of
  a core on average. The first spec fixes the numbers, and the rig enforces them.
- **Quit-on-last-window detection.** MagicQuit's AX-observer approach failed here; see
  `docs/research/2026-11-05-quit-on-last-window.md`: the installed v2.0 counted helper windows, and
  Slack hides its window instead of closing it. Candidate: an AX event plus a captured red-X click,
  a per-window ledger, decide-then-confirm. Run the probe on Notes and Slack first.
- **Alert channel.** Notification Center with actions, a menu-bar badge, or both. Which signals
  fire one. Candidate from research: "warning" measures compressor headroom, not slowness. Alert on
  "critical", on the **swap-in rate**, and on a confirmed leak slope.
- **Safari attribution depth.** Per WebContent process only, or per tab or site if an API
  allows it.
- **Private APIs.** May Swapless rely on `coalition_info_resource_usage` (the only unprivileged way
  to read WindowServer and other root processes) and `responsibility_get_pid_responsible_for_pid`?
  Candidate: yes for a private app, loaded with `dlsym`, checked at launch, falling back to `top`.
  See `docs/research/2026-11-05-memory-measurement.md`.
- **Deployment target.** macOS 26 (as TypeFlow) or 27 (this Mac).
- **Replacing MagicQuit's idle quit** (4 h): as one more rule type, off by default.

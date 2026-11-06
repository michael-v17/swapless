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

## 2026-11-06 · v1-menu-today: the footer measures idle CPU, the open menu refreshes every 5 s, and a "Today" row

**Decided (owner, in the `/wingman` session for `specs/v1-menu-today.md`):**
- **The footer's CPU number is the menu-closed 10-minute average, labelled `idle`**, and
  "over budget" compares that number: `Swapless 0.11 % CPU idle · 33 MB · measuring: full`.
  The CPU budget's limits don't change; this is the quantity they were always defined on, and
  the one rig check 5 measures. It closes the entry below.
- **The Today row's 7-day submenu ends with a 7-day total row.**
- **The unattended run installs ad hoc; the owner re-signs at acceptance** with
  `./scripts/make-app.sh release` and checks that `Open at login` is still on. The installed app
  is self-signed, and an ad hoc build may not match the login item until then.
- **"Freed"** (owner's input): before → after of the wallpaper extension plus WindowServer, as
  the `actions` table records them.

**Settled by the spec (argued there; numbers in `docs/research/2026-11-05-menu-cost-probes.md`):**
- **A sweep costs ~20–25 ms of CPU in the app**: 24 ms per tick headless at 30 s, 30 ms at
  2 s with JSON output. It is not the 1.7–5.1 ms in the v1-core entry below and `specs/v1-core.md`
  § B. Idle still sits at a median 0.118 % of a core (54 closed 5-min intervals on 2026-11-05).
  Making the sweep cheaper is deferred.
- **The open menu cost ~6 % of a core on screen** (6.1 % and 6.7 %, from the installed app's own
  `self` lines). That splits into one ~25 ms display sweep plus ~90 ms of on-screen redraws per
  2 s: the menu refreshed twice per 2 s and rewrote every item each time.
- **Open-menu cadence: one sweep when the menu opens, then every 5 s (was 2 s); one refresh
  per sweep; unchanged items are not rewritten.** At 5 s a row lags p95 ≈ 45 MB, against
  32 MB at 2 s, and big moves are steps a faster cadence only shows a few seconds sooner.
  10 s is the fallback, and only the owner switches to it.
- **Menu-open limits:** ≤ 2 % of a core on screen (owner's acceptance, from the `self`
  lines), and ≤ 1 % in-process in the rig's offscreen test.
- **Constraint for every later slice:** from now on, a `history.sqlite` schema change migrates
  `actions` **in place**. The Today row shows that table, and the v1-core "unknown version →
  move aside and start fresh" path would silently empty it. `v1-quit-on-close` adds quits as a
  second `ActivityKind`.

**Open:** in the two 5-min windows right after the owner's menu use (21:55–22:05), with the
menu closed, the installed app spent 0.855 % and then 0.377 % of a core, while PR #1 was being
merged. The offscreen probe shows no tail after close, so it is unattributed. The owner's
acceptance for this slice watches for it.

**Measured by the implementation run (2026-11-06, ad hoc release, `--budget` report in
`docs/proof/v1-menu-today/rig-budget.txt`; all checks PASS):**
- **Idle agreement (check 5):** `cpuPct10mIdle` 0.107 % against the window's 0.107 % from `ps`
  (|Δ| 0.000 pp, limit 0.02) over 600 s, menu closed. The 5 closed intervals in
  `self-report.txt` read 0.095–0.126 % (0.110 % overall).
- **Offscreen menu open (check 5), 60 s, three group submenus:** `cpuPercentOpen` **0.585 %**
  (limit 1.0; projected ~0.6), displaySweeps 12, publishes 13, refreshes 14 (the limit is
  publishes + 1 = 14: the open refresh plus one per publish, so it sits exactly at the cap by
  construction), compressedReadBatches 3, 0 windows. **Tail** 120 s after close: **0.084 %**
  (limit 0.3). A debug trial run measured 0.858 % open and 0.122 % tail.
- **4b:** a relaunch on check 4's state dir reads the action back: recorded, 1 restart, 0
  failed, freed null, 7 days, today running.
- The on-screen cost (≤ 2 %) and the tail on the real screen are still the owner's acceptance.

**Owner's acceptance on screen (2026-11-06, self-signed release, `self-report-on-screen.txt`):**
- Re-signed: `Authority=Swapless Self-Signed`, leaf `H"3699…"`; `Open at login` checked in the
  menu (`--print-menu` never reads it: CLAUDE.md §3 corrected).
- Screenshot: `Yesterday: 2 restarts · 2.8 GB freed` matches the two 2026-11-05 restarts
  (2,851.1 MB); footer `0.10 % CPU idle · 31 MB`.
- Open CPU over the session: **1.25 %** (999 s open) against the 2 % limit. Active use with
  hovering cost **~3 %** (3.2 % over 173 s, 2.6 % over 29 s); left open untouched, 0.6–0.8 %.
  No tail: 0.121–0.129 % closed, ≥ 10 min after the last close. Menu use never lit the flag
  (idle max 0.191 %).
- **Decided (owner):** ~3 % of a core while the menu is in active use is accepted ("worth it if
  it helps with memory"). The 5 s cadence stays; the 10 s fallback is not taken.
- **Seen:** right after launch the idle figure read 0.209 % (startup cost in the first
  window), so the footer may show `over budget` for a few minutes after launch. Not menu use
  and not new in this slice.

**Readings the spec left open (the run's calls):**
- `menuHasKeyEquivalent`: the SDK header says "set target and action on return", so returning
  `true` without them would leave ⌘Q with no action. Group submenus return `false`. Other menus
  look up their enabled item with the matching key and modifiers, set its target and action,
  and return `true`, or return `false` when none matches.
- `SelfMeter` merges consecutive open intervals into one. Idle skips them either way, and the
  merge keeps memory bounded however long the menu stays open. Trimming keeps the intervals
  back to the one that crosses 600 s of closed time.
- `NSMenuItem.update` clears target, action and represented object whenever a row has no
  action and the item had one. v1-core cleared them only for rows without children; the cases
  differ only for a row that switches from an action to a submenu, which no slot does today.
- A day is `running` when it has a counted row (dry runs don't count) or a `system_samples` row;
  today always is.
- The new Swift Testing suite is `SelfMeterIdleTests` in `SelfMeterTests.swift`: a suite named
  `SelfMeterTests` already exists in `MeasurementTests.swift`.
- The P3 rig run (`--only 3,4`) saw the installed app's seeded wallpaper guard restart the
  wallpaper during check 2's scenario; check 3 attributes it to the installed app's logged
  action. That is the owner's seeded rule, not a mandatory trigger.

## 2026-11-05 · v1-core ships with a false "over budget" on CPU after the menu is used

**Trigger:** "a shipped build exceeded its own overhead budget". Its own footer says so after
the menu has been used, although the budget check passes.

**Measured (owner's acceptance, installed self-signed release, pid 74768):**
- The menu was closed from launch at 21:35 until 21:40: CPU 0.178 % (10-min average), 19.7 MiB.
  The done-gate's quiet window measured 0.105 % over 600 s (limit 0.2 %).
- 98 s of menu use (21:40–21:50): ~6 % of a core while it was open, because the display
  sweeps read every process every 2 s. The 10-min average rose to 0.954 % and 1.043 %, so the
  footer read "Swapless 0.94 % CPU · 33 MB · measuring: full · over budget". The footprint was
  32.3–33.6 MiB, inside the 40 MiB after-use limit.
- So the flag lights up because the owner is looking at the menu, and stays on for up to
  10 min. The CPU budget is defined on the quiet window; the footer averages in the
  menu-open time. This isn't new in this PR; the footer has always worked this way.

**Decided (owner, 2026-11-05):** ship v1-core as it is, and fix this in a small separate task.
The proposed fix is that the footer's CPU flag counts only time with the menu closed. The CPU
budget itself is unchanged. Acceptance otherwise passed: the self-signed signature, Open at
login, the submenu mouse check (no submenu closed), the after-use footprint (≤ 40 MiB), and
the icon and dot. The screenshots are in `docs/proof/v1-core/`.

## 2026-11-05 · Tests never show Swapless UI on the owner's screen

**Decided (owner, 2026-11-05; it replaces anything earlier about menu tests):** "Tests never
show a Swapless menu or window on my screen in the background, inside an unattended run, or
inside done-gate. An on-screen UI test is allowed only in a dedicated, announced test session:
when the UI itself is changing, you propose it, say what will open and for how long, and wait
for my go while I'm present."

**Why (the owner):** "Your experiments opened the menu ~150 times while I worked. It looked
like a bug and it took my keystrokes." An open menu takes the whole Mac's keyboard. The
experiment runs had also put a second Swapless icon in the menu bar each time they ran the app
in its normal mode.

**Overridden once after it was set (trigger: a settled rule overridden in practice):** at 19:03
on 2026-11-05 an agent experiment ran the app in its normal mode for a footprint baseline.
A second Swapless icon sat in the menu bar for about a minute, until the agent stopped
that instance with SIGTERM. The experiment script now refuses any mode with a status item.
The same evening an offscreen run hung ~70 min with no deadline (see the last bullet below).

**What changes:**
- **Check 5 no longer opens the menu.** Measured first: offscreen drawing doesn't faithfully
  reproduce the framework memory. AppKit's menu-item cell, in a bitmap or in a window never
  ordered on screen, leaves +3–5 MiB, against +10–14 MiB on screen; only rows rebuilt as text
  fields come close (+9–11 MiB), and that is a construction, not the menu. Numbers in
  `docs/research/2026-11-05-menu-footprint.md`. So, as the owner set out for that case:
  check 5 keeps its 30 MiB "never shown" window, and the 40 MiB "after use" limit is the
  owner's acceptance check, read from the footprint Swapless shows in its menu footer (PR
  checklist). The footer's "over budget" uses the same split (30 MiB until the menu is first
  shown, 40 MiB after).
- **Check 5's offscreen menu draw test** stays as a functional test: with no status item, the
  release app draws its real menu 50 times into a window never ordered on screen. All draws
  must complete, none may be visible, and the peak must stay ≤ 45 MiB. It found a real bug: a
  reused row still sitting in a stale submenu made `NSMenu` raise, and the fill stopped
  half-way.
- **The on-screen walk** (`SWAPLESS_RIG_MENU_SHOWS`) stays in the rig only behind
  `leak-rig.sh --on-screen-menu`. It is never part of `--budget` or the done-gate, and it runs
  only in an announced session the owner approves. The entry below describes the earlier,
  on-screen version of the menu test; this entry replaces that part.
- **Experiments and rig modes that run the app** use modes without a status item, or nothing
  runs.
- **The submenu fix is checked by hand with the mouse at acceptance** (PR checklist). Unit
  tests cover its reconcile logic: the pure plan (`MenuReconcileTests`) and the `NSMenu` side
  on real, never-shown menus (`SwaplessAppTests`).
- **Every wait in the rig and the experiment scripts has a deadline that fails loudly**
  (owner, 2026-11-05, after an experiment hung for 70 min). A rig wait that runs out
  records a TIMEOUT, which fails the check it happened in.

## 2026-11-05 · The footprint budget splits: before and after the menu has been shown

**Decided (owner, 2026-11-05, before shipping slice 1):** the footprint budget is now three
limits, all in MiB (the rig's unit):
- **≤ 30 MiB idle before the menu has ever been shown** (since launch);
- **≤ 40 MiB idle after the menu has been used;**
- **peak ≤ 45 MiB.**

The CPU budget is unchanged: ≤ 0.2 % of one core over 10 min, ≤ 0.6 % in `top` fallback mode.
This replaces "footprint ≤ 30 MB steady, ≤ 40 MB peak" in the v1-core entry and in
`specs/v1-core.md`.

**Why:** the 16 MB floor behind the original 30 MB was measured on an app whose menu was never
drawn. Drawing it leaves ~10–14 MiB of framework memory that no public API releases
(`docs/research/2026-11-05-menu-footprint.md`). The pieces: CoreGraphics' ColorSync transform
cache (4.8 MiB, fixed), Objective-C and Swift runtime caches, and fragmentation from drawing.
`malloc_zone_pressure_relief` released 0 bytes. With Swapless's refresh off, it still idles at
28.3–28.6 MiB at fresh uptime. The installed app reached 35.5 MiB (peak 39.0 MiB) after real
use. The first rig menu test measured 34.4 MiB (peak 37.5 MiB).

**How the rig holds it (check 5, `--budget`):**
- **Installed app's 10-min window:** idle within 30 MiB, or within 40 MiB once its menu has
  been used since launch (`menuOpenSeconds` > 0). Peak ≤ 45 MiB.
- **Peak test:** fills the menu 20 times without showing it; peak ≤ 45 MiB.
- **Menu test (new):** the release app clicks its own status-item button 10 times and opens 3
  group submenus each time, with arrow keys posted to its own event queue. All 30 must open,
  and none may close unasked. After 60 s with the menu closed: ≤ 40 MiB, peak ≤ 45 MiB.

**Also fixed with it:** the 2 s refresh no longer closes an open submenu. While a submenu is
open, only the open submenus' rows update, in place, and the top level waits. Rows that stay
are never removed. In the first runs, the walk opened 11/30 and 24/30 submenus.

## 2026-11-05 · The wallpaper guard's seed: maxPerDay 24, because the leak regrows at ~1 GB/h

**Decided (owner, 2026-11-05, after accepting slice 1's Portal check):** the seeded
`wallpaper-leak-guard` rule gets `maxPerDay` 24 (it was 8). `footprintAboveMB` 1024 and
`cooldownMinutes` 30 stay. The seed is written only on the app's first launch, so the installed
`rules.json` keeps 8 until the owner edits it by hand. Agents never touch that folder.

**Measured (owner, Portal playing, installed slice-1 build):**
- The guard fired on its own at 15:36:57. The extension went from 1,258 to 133 MB, and
  WindowServer from 1,524 to 1,139 MB. The owner noticed nothing in Portal, then or at the
  14:29 live check.
- The extension regrows at **~1 GB/h**: 138 → 1,258 MB in 66 min. It also jumped 717 → 903 MB
  within 60 s at 16:10.
- The guard fired again at 16:13:27, **36.5 min** after the first restart. The extension went
  from 1,075.2 to 148.1 MB (`ok`), and WindowServer from 1,495.5 to 1,081.5 MB (installed
  app's log). That is 133 MB → over 1,024 MB in ~35 min, so **~1.5 GB/h**: the growth comes
  in bursts, and the rate varies from cycle to cycle.
- The v1-core entry below assumed ~150 MB/h ("about one restart per 6 h of Portal use").

**Why:** at 1–1.5 GB/h the extension climbs from ~135 MB back over 1,024 MB in 36–53 min. So
the guard restarts about once an hour or more often while Portal plays; the 30-min cooldown
didn't bind in either cycle. With 8, the cap ran out after ~5–7 h. The `max-per-day` pause
then held until the owner clicked "Resume", and the leak came back for the rest of the day.
24 covers ~21 h of continuous Portal play at the first cycle's pace, and **~15 h at the
second's**. The owner keeps 24 (2026-11-05): if the cap is ever reached, the menu's
`Paused: max-per-day` shows it, and the number gets revisited with that data.

**Supersedes:** the seed's `maxPerDay` 8 in `specs/v1-core.md` § I, and "about one restart
per 6 h" in the v1-core entry. The spec stays as written, since it is the contract the run
implemented. This entry wins (CLAUDE.md § 2).

**Open:** should a `max-per-day` pause clear on its own the next day? The owner asked, and it
is not decided. Today it clears only through "Resume" (§ I), and step 7 counts a rolling 24 h.

## 2026-11-05 · MagicQuit uninstalled before its replacement

**Decided (owner, 2026-11-05):** MagicQuit 2.0 is uninstalled (moved to the Trash, its
Accessibility grant reset) before Swapless replaces it.

**Why (the owner's measurements):**
- 0 messages from its `com.MagicQuit` log subsystem in 3 days;
- ~2 % of a core (8:07 min of CPU in 6.5 h);
- its idle quit didn't exclude Claude.app.

**What it changes:** "MagicQuit after slices 3 and 4" in the v1-core entry's slice plan no
longer holds, because it is already gone. Until Swapless ships an idle-quit rule, this Mac has
no 4 h idle quit. The mac-memory-guard plan is unchanged (it goes after slice 2).

## 2026-11-05 · v1-core implementation: how the run read the spec where it left room

**Decided (implementation run, from `specs/v1-core.md` only; the owner accepts or reverses at the
PR):** none of these change a contract; they are readings of wording the spec left open.
- **Footer when `top` fails too:** `Swapless … · not measuring system processes`, without the
  `measuring:` prefix (S5 says "the status reads …"; `measuring: not measuring …` read badly).
- **`+ N system processes: X MB`** (§ G) has a submenu listing those processes by name: the
  spec's "the other members appear by name under one row".
- **Member rows in `top` mode** show every member that has a number, `top`-filled ones included;
  the `+ N system processes` row covers only members with no number at all.
- **A Claude Code session whose cwd can't be read** is labelled `Claude Code` alone.
- **Flag labels** (Growing rows, `flag` lines): the group label for a one-process group, else
  `<group label> · <member name>`.
- **rigHelper readiness order** puts `max-per-day` between `fire` and `cooldown`; the spec's list
  (fire > cooldown > consecutive-pending > below-threshold) didn't place it.
- **The § I property test's generator** forces a matching valid rule into the cases where it
  plants an above-threshold allowlisted process. The first generator reached the spec's 30 % floor
  only by chance. The assertions were not touched (0 calls outside the allowlist in 1,000 cases).

**Why:** written down so slice 2 starts from what was built, not from a guess.

## 2026-11-05 · v1-core (slice 1): what the owner decided, and what the first spec settles

**Decided (owner, 2026-11-05, in the `/wingman` session for `specs/v1-core.md`):**
- **The wallpaper guard is on from first launch.** The "What v1 is" entry below is the owner's
  rule. It is seeded into `rules.json` with this date as its source and shown in the menu with
  a toggle.
- **It restarts WallpaperAgent + WallpaperImageExtension once the extension passes 1 GB.**
  That's about one restart per 6 h of Portal use. The owner can change it in `rules.json`.
- **Attribution is display-only in slice 1:** Safari Web Content per process, each Claude Code
  session with its MCP children, and booted simulators get named lines. Swapless never acts on
  them.
- **Acting on a Claude session or a Safari tab "deserves some thought"** (the owner). Deferred
  to slice 2; until then it is never done and never offered as a fix.
- **The menu-bar item is an icon only, plus a dot.** The dot shows when something actionable
  is growing or Swapless just acted, and clears when the menu is opened.
- **The unattended implementation run may run each live check once without asking:**
  - `--sim` boots `iPhone 18 Pro` only if no simulator is booted, and shuts it down
    afterwards;
  - `--live-wallpaper` does one real restart, only with Portal running and the extension
    ≥ 400 MB.

  If either one SKIPs, the PR lists it as pending. The owner still confirms Portal kept
  playing, at acceptance. That restart, and SIGTERMs to the rig's own `swapless-leak-helper`,
  are owner-approved test actions. They don't count toward the "acted on a process with no
  owner rule" trigger above.

**Settled by the spec (argued there; measured in `docs/research/2026-11-05-v1-core-probes.md`):**
- **Private APIs: yes.**
  - `coalition_info_resource_usage` (1 KiB buffer, `phys_footprint` at offset 320) and
    `responsibility_get_pid_responsible_for_pid` (`pid_t f(pid_t)`, labels only), via `dlsym`.
  - A launch self-check against `proc_pid_rusage` gates them (byte-exact on 290 of 290
    coalitions).
  - Fallback: `top -l 1` for the unreadable pids only.
- **Sampling:**
  - every 30 s with 3 s leeway, and every 2 s while the menu is open (display-only);
  - a sweep costs 1.7–5 ms of CPU.
- **Overhead budget:**
  - average CPU ≤ 0.2 % of one core, measured over 10 min;
  - footprint ≤ 30 MB steady, ≤ 40 MB peak;
  - CPU ≤ 0.6 % in `top` fallback mode.
  - The measured floor is 16 MB for an AppKit menu-bar app; MagicQuit uses 27 MB and 1.12 %.
- **Storage:** under `~/Library/Application Support/Swapless/`:
  - `rules.json`, owner-editable, strict decoding;
  - `history.sqlite`: system samples kept 30 days, 5-min buckets 7 days, actions forever.
- **Deployment target:** macOS 27, Swift tools 6.4, Swift 6 language mode, AppKit
  `NSStatusItem` + `NSMenu`.
- **Process identity:** pid + `kinfo_proc.p_starttime`. `ri_proc_start_abstime` can't be read
  for root processes and stops during sleep.

**Why:** "measure what Activity Monitor measures" can't be met unprivileged any other way. 239
of ~680 processes refuse `proc_pid_rusage`, and polling `top` costs ~250× more CPU. The
budget sits ~6× above the measured floor and below the app Swapless replaces. Rules stay a
visible file until slice 3 brings an editor.

**Proposed v1 slice order** (the owner did not object; only slice 1 is a contract):
1. v1-core;
2. alerts, the "what grows" map, and the Claude/Safari question;
3. the rules editor, with `quit` and idle quit;
4. quit on last window close.

mac-memory-guard can go after slice 2, and MagicQuit after slices 3 and 4.

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

**Open (deliberately undecided, for the first specs):** items marked *→ v1-core* were settled
on 2026-11-05 (entry above).
- **Rules model.** What a rule looks like: an app or process match, a condition (footprint above
  X, growth slope, idle for N, last window closed), an action (tell / restart / quit), a
  cooldown, exceptions. Settled: an unknown app defaults to tell only. *→ v1-core: the rules
  live in `rules.json` (a JSON file the owner can edit). Slice 1's flat `restart` schema is
  only for code-allowlisted targets. The per-app model stays open for slice 3.*
- **The "map of what grows".** Which views (top growers today, per-app history). *→ v1-core:
  storage is SQLite, with 7 days of 5-min buckets recorded from slice 1; the views stay open
  for slice 2.*
- **Sampling interval and overhead budget.** *→ v1-core: 30 s; ≤ 0.2 % CPU, ≤ 30 MB steady,
  ≤ 40 MB peak.*
- **Acting on Claude Code sessions and Safari tabs** (added 2026-11-05). May an alert ever offer
  to end a session or reload a tab? The owner: "deserves some thought". Default until slice 2
  decides: never.
- **Quit-on-last-window detection.** MagicQuit's AX-observer approach failed here; see
  `docs/research/2026-11-05-quit-on-last-window.md`: the installed v2.0 counted helper windows, and
  Slack hides its window instead of closing it. Candidate: an AX event plus a captured red-X click,
  a per-window ledger, decide-then-confirm. Run the probe on Notes and Slack first.
- **Alert channel.** Notification Center with actions, a menu-bar badge, or both. Which signals
  fire one. Candidate from research: "warning" measures compressor headroom, not slowness. Alert on
  "critical", on the **swap-in rate**, and on a confirmed leak slope.
- **Safari attribution depth.** *→ v1-core: per Web Content process. Per-site labels need a
  private LaunchServices entitlement and are out of reach.*
- **Private APIs.** *→ v1-core: yes, via `dlsym`, gated by a launch self-check, with a `top`
  fallback.*
- **Deployment target.** *→ v1-core: macOS 27.*
- **Replacing MagicQuit's idle quit** (4 h): as one more rule type, off by default.

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

## 2026-11-17 · Idle CPU: AppKit kept Swapless subscribed to every mouse move after the menu closed

**Trigger:** "a shipped build exceeded its own overhead budget". The menu read `1.89–1.97 % CPU
idle · 50–51 MB · over budget` (v1-quit-on-close build, 11 days up), against 0.2 %.

**Measured (2026-11-17, installed release, menu closed):**
- The old process: 112 min of CPU in 11 days. AppKit's event thread alone used 216 s/day, more
  than Finder (99) or the Dock (69); another menu-bar app on the same Mac used 6.5. Its
  5-min `self` lines read 0.12–0.15 % in quiet stretches and 1–3.7 % while the owner worked.
- Swapless owns no WindowServer window (macOS 27 hosts the status item elsewhere), yet its
  event thread pulled a steady stream of mouse events.
- Not the cause: the workspace KVO and notifications, the display callback, the SkyLight
  calls, hidden status items. A no-UI probe with each of them received 0 events.
- A new `events` line (`EventCounter`, every 5 min in the `self` category) showed it. A fresh
  launch: 0–2 events per 5 min, 0.12–0.19 %, for an hour. After one menu open by the owner
  (45 s, 21:07): **7,000–10,000 `mouseMoved` per 5 min, every one with no window**, and
  1.8–2.3 %. The subscription outlives the menu.
- An announced on-screen probe (the owner present, 4 throwaway status items, one open each),
  mouse moves in the 150 s after the close: plain menu **5019**; flipping
  `acceptsMouseMovedEvents` on close 26; re-attaching the menu on close 24; popping the menu up
  by hand 47.

**Fix:** `MenuController.dropMouseMovedSubscription()` runs when the top-level menu closes. It
flips every window's `acceptsMouseMovedEvents` and back (each keeps its own value), which makes
AppKit drop the app-wide subscription. Verified on the installed app: after the owner opened
the menu with a submenu (29.6 s, 21:36), the next windows read **0 events**.

**`EventCounter` stays** as the sensor for this regression: with the menu closed its line
should read ~0, and a steady `mouseMoved` count means it's back.

**Why it looked fine before:** every earlier budget number (the rig's 597–600 s windows, the
0.123 % after install) was taken on a process whose menu hadn't been opened, or in a quiet
stretch. The cost needs both a menu open and the owner moving the mouse. It also explains
2026-11-08's A/B (1.94 % with quit-on-close off): the observers weren't the cause.

## 2026-11-17 · Before going public: the tagline, the Safari claim, and what "freed" counts

**Tagline (owner, 2026-11-17):** "The menu-bar app that names what pushes a 16 GB Mac into swap —
and fixes it on your rules." It replaces "keeps a 16 GB Mac out of swap". The menu's `Swap` field
is swap *used*, which piles up over uptime and rarely shrinks, so a hero showing `Swap 4.1 GB`
contradicted the old promise. The live signal is `Swap-in`. The README, the GitHub repo
description and the profile use the same sentence.

**Safari (owner, 2026-11-17):** the claim reads "Safari's web-content processes", not "Safari
tabs". The Safari submenu lists `Web Content (pid N)` rows, and one WebKit content process can
host several tabs of a site. Showing tab titles in the submenu is a future roadmap item, not v1.

**"Freed", as the code computes it** (`ActivitySummary.freedMB`, the Today row and its 7-day
total): the signed sum of
- each wallpaper restart whose outcome is `ok` or `no-improvement`: the extension's footprint at
  the sample that fired the rule, minus the respawned extension's footprint 60 s after it came
  back, plus WindowServer's before − after when both were read;
- each quit whose outcome is `ok`: the app's group footprint (the app plus its helper processes,
  as the menu groups them), read by a fresh sweep just before Swapless sends the app's own Quit.

Dry runs, refused quits and restarts that failed (`agent-missing`, `extension-missing`) add
nothing. A quit is gross: an app reopened later isn't subtracted. A restart is already net of
the extension that comes back. The menu floors the total at 0.

## 2026-11-06 · v1-quit-on-close: the slice order changes, and how it fires where MagicQuit didn't

**Slice order (owner, 2026-11-05, revised 2026-11-06):** quit on last window close (the old slice
4) comes **next**, built during the week slice 2 (alerts, the "what grows" map, the
Claude/Safari question) waits for recorded data. It replaces the order in the v1-core entry
below:
1. v1-core (shipped, PR #1);
2. v1-menu-today (shipped, PR #2);
3. **v1-quit-on-close**;
4. alerts and "what grows";
5. the rules editor, with idle quit.

**Decided (owner, in the `/wingman` session for `specs/v1-quit-on-close.md`):**
- **Off by default;** an on/off option in the menu.
- **A Never-quit list edited from the menu.** Seed: Portal, Music, WhatsApp, Messages, Mail,
  Tailscale, ZeroTier, MausBot (installed as `OpenMausBot.app`), iTerm2, Warp, Claude.app.
  Finder is always protected. Spotify, Teams, Zoom and Xcode were offered and **not** added
  ("de momento").
- **Grace delay 5 s** after the last window closes, confirmed again 0.5 s later.
- **Quits add their footprint at quit time to the same "freed" total** as restarts:
  `Today: 1 restart · 3 quits · 4.1 GB freed`.
- **Feedback in the menu only:** `Last quit 14:02: Notes · 312 MB` with a one-click `Never quit
  Notes`. No dot, no notification.
- **Quitting goes through the app's own Quit.** An app that refuses or asks is left alone. A
  minimized window, or one on another Space, counts as a window. Idle quit waits.
- **Accessibility is the owner's step at acceptance**, after the self-signed re-sign, so the
  grant survives rebuilds.

**Settled by the spec (argued there; measured in `docs/research/2026-11-06-quit-on-close-probes.md`):**
- **Why MagicQuit never fired on Notes:** Notes keeps 14–15 layer-0 windows in the window
  server even with no window open (helpers, and its own closed window, ordered out). MagicQuit
  2.0 counted those. Swapless counts:
  - every AX window except a floating panel, and minimized windows always (a minimized window
    reports `AXDialog`, which the first draft would have quit);
  - plus windows SkyLight places only on Spaces that aren't visible.
- **Slack fires `AXUIElementDestroyed`** on the red X and ⌘W (macOS 27.2). The 2026-11-05
  research said it wouldn't. So there's no click capture. Slack keeps its hidden window on its
  Space, so the window is marked closed at the moment of the close.
- **Edge-triggered only:** it acts on a close it sees, never on an app that is already
  windowless.
- **Settings in `rules.json` version 2:** `quitOnLastWindow` plus an `apps` table that slice 3
  extends. `neverQuit` blocks every kind of Swapless quit, later ones included. A v1 file still
  reads, and any menu write produces v2. Matching is by bundle id.
- **No `history.sqlite` schema change:** a quit is an `actions` row, rule id
  `quit-on-last-window`.
- **During rig runs** a prefix seam limits quits to the rig's own off-screen `LSUIElement` test
  apps.

**Open:** Stage Manager isn't supported; the feature pauses while it's on. Supporting it is a
later call.

**Implementation run (2026-11-06), stopped at check 9 by a spec brake:**
- **Mandatory trigger: a settled rule was overridden in practice. A test window was on the
  owner's screen.**
  - During `./scripts/leak-rig.sh --only 9` (started 12:02:44 local), the `panel-left` test
    app's floating `NSPanel` was on a display at (640, 1216), 300×224 pt, for about 10 s. That
    ran from its launch until the rig's cleanup ended it (the app's own `exit` first, then
    SIGTERM).
  - Check 9's visibility gate caught it and stopped the check before any scenario was driven.
    No app was quit, and nothing of the owner's was touched.
  - The P3 probe had launched the same panel once, on its own, and it stayed off-screen. Why it
    didn't this time is **not established**. The hypothesis is that AppKit or the window server
    moves a floating utility panel that sits entirely off every display back onto one. Testing
    that means putting it on screen again, so it wasn't tested.
  - Per the brakes, the run stopped there: no further rig runs, and nothing launched.
- **P3 feasibility** (a scratch probe, not committed):
  - (a) the test window intersected no display;
  - (b) AX listed it as `AXStandardWindow` with a readable id;
  - (c) it sat on the visible Space 6;
  - (d) an AX press on the close button fired `AXUIElementDestroyed` for an app that was never
    active;
  - (f) `terminate()` quit it in 0.08 s with no consent prompt;
  - (e) **failed as written**, so the spec named the wrong API:
    - NSWorkspace never posts `didLaunch`/`didTerminate` for `LSUIElement` apps (none arrived,
      with or without AppKit initialized);
    - KVO on `NSWorkspace.runningApplications` delivers both events in a bare `CFRunLoopRun()`
      process;
    - the watcher uses that KVO for real apps and test apps alike, which is a reading of the
      spec's intent.
- **Measured once, by hand** (a headless release engine, `"rules": []`, the rig prefix, one
  `close-ax` test app):
  - a `performClose` → the quit decision 5.69 s later, through `applicationShouldTerminate`;
  - `before_mb` 83.5 (64 MiB ballast), outcome `ok`, `cpuMs` 26.6.
- **A rig defect, not fixed yet:** in the rig process, `NSRunningApplication.isTerminated`
  apparently never updated. The rig registers no NSWorkspace observer, which is the likely
  cause. So every test app looked as if it ignored `exit` and got SIGTERM at cleanup (they were
  all the rig's own apps).
- **Where the branch stands:**
  - P1 and P2 are done.
  - P4's watcher, engine wiring, test app and check 9 are written.
  - P5's Activity and menu rows are written.
  - `swift build` passes, and `swift test` passes: 207 core tests and 8 app tests.
  - Not done:
    - check 9 passing;
    - P5's new menu tests;
    - check 5c;
    - the whole-slice gate;
    - the proofs.
- **Decided (owner, 2026-11-06, after the stop): drop the panels and add a self-guard.**
  - The unattended rig no longer launches any `NSPanel`. `panel-left` and `dialog-left` leave
    check 9 and the test app.
  - What they covered (a floating panel doesn't keep an app alive; a visible dialog does) stays
    covered by `WindowVerdictTests` and the owner's acceptance. P3 measured the subroles once:
    `AXFloatingWindow` and `AXDialog`.
  - Only ordinary off-screen `NSWindow`s remain; none touched a display in any run.
  - **The self-guard:** the test app checks its own windows (AppKit frame and window-server
    bounds) right after every show and every 200 ms. If one touches a display, it orders every
    window out at once and writes a `guard` status line, which check 9 treats as the visibility
    gate's FAIL and stop.
  - This limits a repeat to a flash under ~200 ms, not zero. The rig's gate stays as it was.

**Implementation run, continued (2026-11-06): stopped a second time by a spec brake.** This
is a mandatory trigger, because a check FAILs in the final report. The proofs are in
`docs/proof/v1-quit-on-close/`.
- **Check 9 passed 13/13 twice** without panels (`rig-only-9-pass.txt`, and inside
  `--budget`).
  - Every ok quit landed 5.6–5.8 s after the close, with `before_mb` within 3 % of the app's
    own footprint.
  - `swap` was cancelled (`cancelled-window`). `never-quit`, `young`, `option-off` and
    `windowless` didn't quit.
  - `refuse` was refused at 30 s, left alone for 15 s, then quit again after a new window.
  - Dry run: no terminate, and one dry-run row.
  - Today counted 6 quits, with freed equal to the sum of `before_mb`, and a relaunch read
    them back.
  - `cpuMs` max was 15.6 and 23.2 (the limit is 150).
  - The self-guard never tripped.
  - One earlier run missed `close-menu` once (no decision, cause unknown); it passed in every
    run since.
- **Check 5 and 5c:**
  - The first `--budget` measured the installed app's window at **0.277 %**, over the limit.
    Its own `self` lines show the cost only while that stretch of the rig ran: 0.25, 0.23 and
    0.33 % per 5 min, then 0.10 % and 0.12 % right after. The previous build idles at
    0.09–0.18 % all day.
  - With the one focused attempt the brakes allow (a fix to 5c's footprint read, then
    `--budget` again), **check 5 passed at 0.107 %** (21.0 MiB, the same as the last slice).
  - **5c passed:** option on, 13 apps tracked, **0.110 %** CPU, 7.2 MiB, peak 9.3 MiB.
  - The 0.277 % stays unexplained. The installed app runs with the option off, so it has no
    observers.
- **What stopped it:** in that `--budget` run, check 2 hit its memory floor (free 36–41 %,
  the helper refused by design; it passed later at 49 %). Check 9 then failed its
  visibility-gate AX read twice, on `close-ax` and then `option-off`. That app's AX window
  list stayed a single element with id 0 and no subrole for more than 10 s. It hit 1 app in
  13, in the two runs made under memory load; it hit none in the three runs before.
  - The product is safe on such an app: the gate returns `no-window-id` and never quits it.
  - The rig's gate can't tell that from a broken test, so it fails, as written.
  - The focused attempt was spent, so the brake applied: report, no more reruns.
- **Not done:**
  - one clean `--budget` run, including check 9's AX condition;
  - the PR's acceptance checklist on the real screen (the owner's).
- **Decided (owner, 2026-11-06): relaunch that app once.** If a test app's AX list stays
  unreadable for 10 s, check 9 ends that instance (its own `exit`, SIGTERM after 5 s), launches
  a fresh one and checks again for 10 s. A second failure still FAILs. Then one clean
  `--budget` run.

**That `--budget` run (13:54 local): stopped a third time. A mandatory trigger: test windows
were seen on the owner's screen.** Report: `docs/proof/v1-quit-on-close/rig-budget-mission-control.txt`.
- **Everything else passed:**
  - `swift test` 217 + 8;
  - checks 1–4;
  - check 5: idle **0.093 %**, 21.0 MiB, peak 22.1 MiB;
  - 5c: option on, 14 apps, **0.100 %**, 7.5 MiB, peak 10.0 MiB.
- **Check 9's gate fired after its first pass.** Four test apps' own windows were on a
  display: `two-windows`, `swap`, `option-off`, `tabs`. Each showed at about 46 % scale (800×632
  shown as 371×294) at x ≈ 2,600–2,940. The visible Spaces had changed from [6, 1379, 1382] to
  [6, 1382, 1478].
- **Most likely Mission Control or App Exposé** (inferred, not measured): it draws every window
  of the Space as a thumbnail on screen, and windows parked 20,000 pt off the edge too.
- The self-guard ordered them out within ~200 ms, and the gate stopped the check. No app was
  quit.
- **So off-screen placement can't hide a window from Mission Control.** That is a limit of
  the design, so the run stopped there.
- **Decided (owner, 2026-11-06): check 9 runs only with the owner present.**
  - It leaves the unattended done-gate: the bare run is checks 1–4 again, and `--budget` is
    1–5 with 5c.
  - It runs through its own flag, `./scripts/leak-rig.sh --quit-on-close`, in an announced
    ~4-min session.
  - `--only` no longer accepts 9.
  - Check 9 had already passed 13/13 twice: the 12:23 `--only 9` run and the 12:27
    `--budget` run.

**The whole-slice gate without check 9 (15:15 local): stopped by the budget brake.** This is
a mandatory trigger, because a check FAILs in the final report. Report:
`docs/proof/v1-quit-on-close/rig-budget-final.txt`.
- **Passed:**
  - `swift test` 217 + 8;
  - checks 1–4;
  - 5c: option on, 13 apps, **0.168 %**, 7.5 MiB, peak 10.2 MiB;
  - the peak, offscreen-draw and menu-open tests: menu-open 0.444 %, tail 0.064 %.
- **Failed:** check 5's installed-app window, **0.231 % > 0.2 %** (the new build, option off,
  no observers).
- **Four `--budget` windows today:** 0.277, 0.107, 0.093, 0.231 %.
  - In this run the installed app's own `self` lines read 0.21, 0.25, 0.29, 0.17 and 0.21 %
    per 5 min while the rig ran (727 processes).
  - After the first failing run the same build settled at 0.10–0.12 % once the rig stopped.
  - The previous build read 0.09–0.18 % all day, and 0.224 % (`cpuPct10m`) once at 10:32.
- **Open, and not decided by the run:** whether this slice raised idle cost, or the rig's own
  load (and the Mac's) pushes the window over. The focused attempt was spent, and the limit
  wasn't loosened.
- **Suggested way to tell:** the owner's day of use with the self-signed build (acceptance
  item 10), compared with the previous build's 0.09–0.18 %.

**Check 9 with the owner present (18:23 local): PASS 13/13**, 6 ok quits, each 5.66–5.70 s
after the close. Activity counted 6 quits and 523.3 MB freed (the sum of `before_mb`). Decision
CPU: p50 5.3 ms, max 22.7 ms. Proof: `docs/proof/v1-quit-on-close/rig-quit-on-close-owner-present.txt`.

**Decided (owner, 2026-11-06): the 0.231 % reading was rig load, not this slice.**
- **The evidence:** the owner measured the installed build (this slice, ad hoc signature) from
  outside, with the option off: **0.123 % of a core over 600 s**. That window included ~3 min of
  the check 9 run at its end. It is in line with the earlier builds' 0.09–0.18 %.
- **The limit stays at 0.2 %.** Nothing is loosened.
- **Confirmation:** acceptance item 10, a day of use on the re-signed build.
- **No investigation** of the idle cost.

**Acceptance, Accessibility grant (2026-11-06, found while the owner ran item 3):** the switch
was on but `AXIsProcessTrusted()` stayed false, and removing the entry with − and adding it back
with + didn't help. tccd's log read "Failed to match existing code requirement … status -67050".
The stored requirement was `cdhash H"d20f0797…"`, from an earlier ad hoc build, while the
installed self-signed build is `990265f3…`. An entry first created by an ad hoc build is pinned
to that one binary's cdhash. **Fix:** `tccutil reset Accessibility com.michaelv.swapless` (no
admin prompt), then grant it again. The new entry follows the certificate, so it survives
rebuilds. At 20:54:14 the watcher logged `trusted=true` and tracked 12 apps.

**Acceptance (owner, 2026-11-07/08):**
- **Passed:** items 1–6, 8 and 9. Notes and Slack quit about 5 s after their last window
  closed, a minimized window didn't quit, and Today showed `3 quits · 1.2 GB freed`.
- **Item 7 (two Spaces):** not run by hand. It's covered by the unit tests, and the live log
  counted `elsewhere=1`.
- **Item 10 failed the CPU limit.** Over the day (10:19–18:09), menu closed: **0.365 %**. Quiet
  stretches read 0.11–0.12 %, with bursts of 1–2.2 % during heavy use. Peak footprint 51.9 MB.
- **A 30 s profile under load:** 1.2 s CPU. WindowServer events (NSEventThread) took ~37 %, the
  v1 sampler ~16 %, the main thread ~17 %, and the quit watcher ~7 %.
- **A/B with the option off (18:41–19:49): 1.94 %**, with bursts of 3–3.8 %.
  - The quit watcher thread used 0.5 s; the main thread +56 s, the NSEventThread +33 s.
  - For comparison, TypeFlow's NSEventThread used 34 s in 6.6 days, Swapless's 222 s in 2 days.
- **Conclusion:** the quit logic isn't the cost. Something in the app (v1, or this slice's
  always-on observers: Space and display callbacks, KVO on `runningApplications`, SkyLight calls)
  draws heavy WindowServer event traffic under load.

**Decided (owner, 2026-11-08): ship `v1-quit-on-close` with that cost as a known issue.**
- **Why:** the owner feels the Mac better since heavy work moved to the Linux host, and doesn't
  feel Swapless. Holding back quit-on-close wouldn't fix a cost that is the same with the option
  off.
- **The 0.2 % budget stays the goal.**
- **Follow-up task:** find why Swapless's NSEventThread and main thread wake under load, and fix
  it. Start with a deadline-bound, read-only auto-capture (`sample` when the app exceeds 1 %),
  and an A/B against the v1 observers.
- `self-report.sh` now filters by pid. On macOS 27, logd records the build product's path, so
  the old path filter matched nothing.

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

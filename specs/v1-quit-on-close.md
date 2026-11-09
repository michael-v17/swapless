# v1-quit-on-close: quit an app when its last window closes, opt-in, with a Never-quit list

Branch `v1-quit-on-close` · written 2026-11-06 in a `/wingman` session, from the owner's input
dated 2026-11-05 and revised 2026-11-06 · the old slice 4, built now while slice 2 waits for a
week of recorded data · this file is the **only input** for the implementation run.

Conventions are those of `specs/v1-core.md` and `specs/v1-menu-today.md`:
- MB / GB mean MiB / GiB.
- "This Mac" is the M1 Pro, 16 GB, macOS 27.2, with three displays and Stage Manager off.
- "Probe" marks a number or behaviour measured here. This slice's probes are in
  `docs/research/2026-11-05-quit-on-last-window.md` (prior art) and
  `docs/research/2026-11-06-quit-on-close-probes.md` (the Notes and Slack probes); the probe
  tool is `docs/research/probes/winprobe.swift`.
- Section names follow `specs/README.md` in English.

---

## Objective

**When the owner closes the last window of an app, Swapless asks that app to quit, 5 s later,
through the app's own Quit.** Off by default, on and off from the menu. A **Never-quit** list
the owner edits from the menu protects apps from every Swapless quit, now and in later slices.
Finder is always protected. Each quit is recorded in `history.sqlite` and feeds the Today row
shipped in v1-menu-today: `Today: 1 restart · 3 quits · 4.1 GB freed`.

Why it will fire where MagicQuit 2.0 never did (probe):
- MagicQuit counted every layer-0 window in the window server, and Notes always has 14 or 15,
  even with no window open. Swapless counts windows the way the owner sees them:
  - every AX window except a floating panel, minimized ones included;
  - plus windows that SkyLight places on a Space that isn't visible right now.
- Notes and Slack both fire `AXUIElementDestroyed` on the red X and on ⌘W. Slack only hides
  its window, and it stays attached to its Space. Swapless marks it closed at the moment of the
  close, so a Space switch during the 5 s wait doesn't save it.

It never quits:
- an app with a window minimized or on another Space;
- an app it didn't see lose its last window;
- an app on the Never-quit list;
- an app that asked to stay. That app is left alone until it opens a new window.

The unattended run is **done** when this passes on the branch:
```
swift build && swift test && ./scripts/make-app.sh release --adhoc && ./scripts/leak-rig.sh --budget
```
That covers:
- v1-core checks 1–5 and v1-menu-today's additions, unchanged;
- this slice's **check 9** (quit on close, with test apps the rig launches itself, whose windows
  sit off every display);
- **check 5c** (the budget with the option on).

The proofs must be in `docs/proof/v1-quit-on-close/` and a **draft** PR must be open. The
owner grants Accessibility, tries it on the real screen and ships (Brakes).

---

## Out of scope

- **Idle quit** ("quit when idle for N h", MagicQuit's old 4 h). Later, as a rule type, off by
  default.
- **The per-app rules editor** (slice 3). This slice only shapes `apps` in `rules.json` so slice 3
  adds fields to it (T1).
- **Alerts and the "what grows" map** (slice 2).
- **Notifications, the menu-bar dot, sounds** for quits (owner, Q3). No UNUserNotification code.
- **Capturing clicks or keys.** No `NSEvent` global monitors and no `CGEventTap`. The probe
  showed `AXUIElementDestroyed` fires for the red X and ⌘W on both Notes and Slack.
- **Stage Manager.** When it's on, the feature pauses (T7). Supporting it is a later slice.
- **Acting on anything but a Dock app** (`activationPolicy == .regular`). Never on menu-bar
  agents, background processes, Safari tabs, Claude Code sessions or simulator devices. Simulator.app
  itself is a Dock app and is treated like any other.
- **Quitting apps that already have no window** when the option turns on or Swapless launches
  (T4).
- **Force quit, SIGTERM or SIGKILL on a user app, ever.** No `forceTerminate()`, no `kill(2)`
  on anything this slice touches.
- **Reopening a quit app**, undo, or "quit later" queues.
- **A per-app grace delay**, or a grace delay setting in `rules.json`. It's a constant (T5).
- **Showing app icons** in the menu.
- **A `history.sqlite` schema change.** Quits are rows in the existing `actions` table (T9).
- **Seeding more apps** than the owner's list. Spotify, Teams, Zoom and Xcode were offered and
  not added. The owner adds any app with one click (S5).
- The open `max-per-day` question, mac-memory-guard's uninstall, Open at login, the wallpaper
  rule's behaviour.

---

## Decisions and why

### Owner calls (this session)

- **Q1 · Grace delay 5 s.** Decide 5.0 s after the close, confirm 0.5 s later. It covers apps
  that close one window and open another (a login window becoming the main window, Xcode's
  welcome window) and a quick ⌘N. It costs no memory.
- **Q2 · One "freed" total.** A quit adds the app's footprint at quit time to the same "freed"
  figure restarts use: `Today: 1 restart · 3 quits · 4.1 GB freed`. The 7-day submenu and its
  total do the same.
- **Q3 · Feedback in the menu only.** No dot, no notification. The menu shows
  `Last quit 14:02: Notes · 312 MB` for 30 min, with `Never quit Notes` under it, one click.
- **Q4 · The seed is the owner's list only:** Portal, Music, WhatsApp, Messages, Mail,
  Tailscale, ZeroTier, MausBot (installed as `OpenMausBot.app`), iTerm2, Warp, Claude.app.
  Finder is always protected. Spotify, Teams, Zoom and Xcode were offered and not added.
- **From the owner's input:**
  - the option is off by default;
  - quitting goes through the app's own Quit, and an app that refuses or asks is left alone;
  - a minimized window, or one on another Space, still counts;
  - granting Accessibility is the owner's step at acceptance, after the self-signed re-sign;
  - idle quit waits;
  - the Never-quit list is shaped for slice 3;
  - quits feed the Today row;
  - nothing goes on the owner's screen during the work;
  - nothing touches the owner's state dir;
  - no sudo;
  - tests never quit the owner's apps.

### Technical calls (argued here; the probe numbers are in the research doc)

**T1 · Settings live in `rules.json` version 2.** The file already holds the owner's rules, is
owner-editable, strictly decoded, and written back atomically with an mtime and size guard. The
v2 file:
```json
{
  "version": 2,
  "rules": [ … the v1 restart rules, unchanged … ],
  "quitOnLastWindow": { "enabled": false },
  "apps": [
    { "bundleId": "app.portal.ios.v1", "name": "Portal", "neverQuit": true,
      "note": "Owner's seed 2026-11-06 (DECISIONS.md)" }
  ]
}
```
- **`apps` is the per-app table slice 3 extends** with more fields per entry (idle quit,
  restart threshold, a per-app last-window override). `neverQuit: true` means **no Swapless
  quit of any kind**, now or later. That is the owner's word "Never quit", and it is why it
  sits on the app, not on the quit-on-close switch.
- **Matching is by bundle id**, never by name. MausBot is installed as `OpenMausBot.app`
  (`com.openmausbot.app`).
- **Finder (`com.apple.finder`) is protected in code** (`QuitGate`), not in the file, so no edit
  can remove it.
- **Version 1 stays readable.** A v1 file loads with its rules unchanged, the switch off, and
  the seed list in memory (`quit.status = default`). Swapless writes the file only when the
  owner changes something from the menu, and **any menu write produces version 2**, the toggle
  of the wallpaper rule included. The installed app's file is v1 today, and agents never touch
  it.
- **Validity is fail-closed and per section.** File-level errors are unchanged: bad JSON, an
  unknown top-level key, a version other than 1 or 2, `rules` not an array. Any of them makes
  the whole file invalid, so there are no rules and quit-on-close is off. An error inside
  `quitOnLastWindow` or `apps` (a missing key, a wrong type, an unknown key, a duplicate
  `bundleId`, an empty string, more than 500 entries) makes **only the quit section** invalid.
  The feature is off and its menu rows are disabled, and the restart rules keep working. A broken
  entry never drops silently, because it might be the one protecting an app.
- **Seed v2 bundle ids** (sorted by name with `localizedCaseInsensitiveCompare`, the order used
  everywhere: in the file, the submenu and the tests):
  - `com.anthropic.claudefordesktop` Claude;
  - `com.googlecode.iterm2` iTerm2;
  - `com.apple.mail` Mail;
  - `com.apple.MobileSMS` Messages;
  - `com.apple.Music` Music;
  - `com.openmausbot.app` OpenMausBot;
  - `app.portal.ios.v1` Portal;
  - `io.tailscale.ipn.macsys` Tailscale;
  - `dev.warp.Warp-Stable` Warp;
  - `net.whatsapp.WhatsApp` WhatsApp;
  - `com.zerotier.ZeroTier-UI` ZeroTier.

  These were read from the installed apps' `Info.plist`. Tailscale and ZeroTier are menu-bar
  agents and never candidates, but they are seeded as the owner asked.

**T2 · Windows are counted the way the owner sees them, not the way the window server stores
them (probe).** For one app, at one moment, a **reading** holds three things:
- AX windows: `kAXWindowsAttribute`, each with its window id (`_AXUIElementGetWindow`),
  subrole and `AXMinimized`;
- CG windows: `CGWindowListCopyWindowInfo(.optionAll)` filtered to the pid, each with layer
  and id;
- each layer-0 window's Spaces (`CGSCopySpacesForWindows(conn, 7, [id])`), and the visible
  Spaces (each display's "Current Space" from `CGSCopyManagedDisplaySpaces`).

`alive` = the count of distinct window ids in **(A) ∪ (B)**:
- **(A)** AX elements with **role `AXWindow`**, not marked closed (T3), that are either:
  - minimized, **whatever their subrole** (probe: a minimized Notes window reports
    `AXDialog`); or
  - not minimized, with any subrole **except `AXFloatingWindow` and
    `AXSystemFloatingWindow`**. That covers `AXStandardWindow`, `AXDialog`, `AXSystemDialog`,
    `AXUnknown`, a missing subrole, and anything else. An unknown kind of window on screen keeps
    the app alive.

  Only floating panels (inspectors, palettes) don't keep an app alive. Elements whose role isn't
  `AXWindow` never count (probe: Finder's `AXScrollArea/AXDesktop`, Portal's
  `AXGroup/AXHostingView`).
- **(B)** layer-0 CG windows that have at least one Space, where **none** of their Spaces is
  visible, and that are not marked closed: "alive elsewhere", such as another Space or a
  full-screen Space.

Windows with no Space never count (probe: Notes' 14 helpers, and the closed Notes window
itself). Windows on a visible Space count only through AX (probe: Chrome's and Safari's
off-screen windows on the visible Space).

**T3 · Closed marks.** On every trigger (T4), 0.3 s later (settle), Swapless reads the app and
**marks closed** every layer-0 window id that is absent from AX and has either no Space or a
visible Space. A closed window never counts as (B). The mark clears when that id is listed in AX
again: Notes and Slack reuse the same id on reopen. Why (probe): Slack keeps its hidden window
on Space 6. Without the mark, a Space switch within 5 s would make it "alive elsewhere" and the
quit would be missed. A window on an invisible Space at the moment of the close is never marked,
so a window genuinely waiting on another Space is never mistaken for a closed one.

**T4 · Edge-triggered only.** An app becomes **armed** when a reading shows ≥ 1 window in (A).
Only an armed app can produce a decision, and only through a trigger:
- **`AXUIElementDestroyed`** on a window element. It is registered on every AX window found
  when an app is tracked, on every `AXWindowCreated`, on every `AXWindowDeminiaturized`, and on
  the re-enumeration after a Space change.
- **`AXApplicationDeactivated`**, a backstop for a missed destroy event, used only when the app
  is armed and not already pending.

Turning the option on, launching Swapless, waking, or an app running windowless never
produces a decision. Owner: "nothing is quit without the option on"; and the probe found
WhatsApp and two Safari web apps running windowless right now.

**T5 · Timing (constants in `QuitTiming`, not in the file):**

| Constant | Value | Purpose |
|---|---|---|
| settle | 0.3 s | after a trigger: closed marks plus the first verdict |
| grace | 5.0 s | after the trigger: the decision read |
| confirm | 0.5 s | after the decision read: the second read; both must give 0 |
| young | 10 s | since `launchDate`, and `isFinishedLaunching` must be true |
| outcome | 30 s | after `terminate()`: if not terminated, `refused` |
| rateLimit | 3 per bundle id per rolling 10 min | runaway guard: an app relaunched by something else |
| trust re-check | every 10 s, while enabled and untrusted | also on menu open, and on any `kAXErrorAPIDisabled` |
| display change | 10 s of suppression | after any `CGDisplayRegisterReconfigurationCallback` event |
| AX timeout | 0.3 s | `AXUIElementSetMessagingTimeout` on every app element |
| last-quit row | 30 min | same as the wallpaper status row |

**T6 · The only path to a quit.**
1. A pure `QuitGate.evaluate` returns `.quit` at **both** the 5.0 s read and the 0.5 s
   confirm.
2. Only then does `WindowWatcher` call `QuitSender.terminate(pid:)`.
3. The live sender is the **only** `NSRunningApplication.terminate()` call in `Sources/`, the
   normal ⌘Q path, so the app may ask to save.

There is no `forceTerminate()` anywhere in `Sources/`. The gate's checks, in order; the first
failure is the reason logged:
1. `option-off`: the quit section's status is not `ok`, or `enabled` is false.
2. `rules-invalid`: the file or the quit section is invalid. It is reported in place of
   `option-off` when that is the cause.
3. `observe-only`: another Swapless holds the state-dir lock.
3b. `history-off`: history is off. Like restarts (the actuator writes its row before it acts),
   a quit happens only when its row can be written first.
4. `untrusted`: Accessibility not granted.
5. `unavailable`: a private symbol is missing or failed its launch check (T8).
6. `stage-manager`: `com.apple.WindowManager` `GloballyEnabled` is true. It is read with
   `CFPreferencesCopyAppValue` at decision time.
7. `asleep`, `locked` or `display-change`.
8. `rig-scope`: the rig seam is set and the bundle id lacks its prefix (S6).
9. `no-bundle-id`.
10. `finder`.
11. `never-quit`.
12. `self`: Swapless's own bundle id or pid.
13. `not-regular`: the policy is not `.regular`, unless the rig seam admits the bundle id.
14. `hidden`.
15. `young`.
16. `disarmed`: Swapless already asked this pid to quit and it hasn't opened a new (A) window
    since.
17. `rate-limit`.
18. `dry-run`: `SWAPLESS_DRY_RUN=1`. It records a dry-run row and does not terminate.

The decision reads run before the gate: `alive` (T2), `ax-error` (the app's AX read timed out
or failed: never quit on an unreadable app), `no-window-id` (an AX window whose id can't be
read: never quit), `gone` (the app exited during the grace) and `cancelled-window` (a window
reappeared during the grace).

**T7 · Pauses.**
- Stage Manager on, sleep (`NSWorkspace.willSleep` → `didWake`), screen lock (the distributed
  `com.apple.screenIsLocked` / `…Unlocked` notifications) and display reconfiguration all cancel
  pending decisions. Their reason is logged. After wake and unlock, every tracked app is
  re-enumerated. Nothing is queued across a pause.
- **Option off, or untrusted:** no AX observers exist at all, so the cost is zero. Turning the
  option on (trusted) registers observers on every running Dock app. Turning it off removes them
  all.

**T8 · Private APIs, looked up with `dlsym` and checked at watcher start.** Same policy as v1-core
(DECISIONS.md: "Private APIs: yes, via `dlsym`, gated by a launch self-check").
- `_AXUIElementGetWindow` comes from HIServices, through `RTLD_DEFAULT`.
- `CGSMainConnectionID`, `CGSCopySpacesForWindows` and `CGSCopyManagedDisplaySpaces` come from
  `/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight`.
- **Check:** all four resolve, and `CGSCopyManagedDisplaySpaces` returns ≥ 1 display with a
  `Current Space` → `ManagedSpaceID`.
- **Failure:** the status is `unavailable (<symbol or check>)`, the feature never acts, and the
  menu shows `Paused: unavailable on this macOS`.
- **Never `@_silgen_name`:** a missing symbol must not stop the app from loading.

**T9 · History: no schema change.**
- **A quit is an `actions` row:**
  - `rule_id` = `quit-on-last-window`;
  - `target` = the bundle id;
  - `pids_json` = `[pid]`;
  - `before_mb` = the footprint of **the app's group** (the coalition group containing the pid,
    the same number the menu's group row shows), from a fresh sweep at decision time;
  - `after_mb`, `ws_before_mb` and `ws_after_mb` stay NULL.
- **Outcome detection:** `NSWorkspace.didTerminateApplicationNotification` for that same
  `NSRunningApplication` (pid plus `launchDate`, so a reused pid can't match), with
  `isTerminated` checked at the 30 s mark. Never `kill(pid, 0)` and never polling `ps`.
- **Outcomes:**
  - `pending` at `terminate()`;
  - then `ok` (terminated within 30 s);
  - or `refused` (still running at 30 s);
  - `not-sent` when `terminate()` returns false;
  - `dry-run` when `dry_run` = 1;
  - and the existing launch path turns a leftover `pending` into `interrupted`.
- `schema_version` stays `1`. The 2026-11-06 in-place migration constraint is respected by not
  needing one.
- **If the fresh sweep fails:** take the last snapshot's group value. If there is none, write
  `before_mb` 0, which yields no freed amount.

**T10 · Activity.**
- `ActivityKind` gains `.quit`. `ActivitySummary.kind(of:)` checks `ruleId ==
  "quit-on-last-window"` first, then the existing target mapping.
- **Counting:** a quit counts **only when its outcome is `ok`** and it is not a dry run. A
  `refused` app wasn't quit and isn't a failure (the app said no, as the owner wants).
  `failedOutcomes` doesn't change.
- **Freed:** a quit's freed amount is `before_mb` when the outcome is `ok` and `before_mb` > 0.
  It is added to the same `freedMB` sum (owner, Q2).

**T11 · Threads.**
- `WindowWatcher` owns one dedicated `Thread` with its own `CFRunLoop`, which carries every
  `AXObserver` source in `.commonModes`. It does every AX, CG and SkyLight call and runs the
  tracker. **The main thread never calls AX.**
- NSWorkspace notifications arrive on the main thread and are forwarded to the watcher thread.
- `terminate()` runs on the main thread.
- History writes and the footprint sweep run on the engine queue, which the watcher reaches with
  `engine.queue.sync` from its own thread. The engine never calls the watcher synchronously.
- **The headless mode runs `CFRunLoopRun()` on the main thread** instead of `dispatchMain()`,
  so NSWorkspace notifications are delivered; the main queue is still serviced. Checks 1–4 must
  stay green with it.

**T11b · Engine exit.** Under `--duration`, the engine already waits for in-flight restart
verifies. It now also waits for open quit outcomes (≤ 35 s more), so a rig run leaves no quit
`pending`. SIGTERM and SIGINT still exit at once (a leftover `pending` becomes `interrupted` at
the next launch, as today).

**T12 · Cost.**
- Off (the default): nothing new runs.
- On: purely event-driven, with no polling. A decision costs:
  - two to four AX reads;
  - one `CGWindowListCopyWindowInfo` per read;
  - SkyLight Space lookups for that pid's layer-0 windows;
  - one footprint sweep (~25 ms, the v1-menu-today number) per actual quit.
- Each decision logs its CPU time.
- The budget doesn't change: ≤ 0.2 % of a core idle over 10 min; ≤ 30 MiB before the menu is
  first shown, ≤ 40 after, peak ≤ 45. Check 5c measures it with the option on.

**T13 · Accessibility.**
- The installed app needs it (AX window lists and observers). It's the owner's step, at
  acceptance, **after** `./scripts/make-app.sh release` re-signs with `Swapless Self-Signed`,
  so the grant follows the stable designated requirement and survives rebuilds. An ad hoc
  build's grant would not.
- Until it is granted, an enabled option shows `Paused: needs Accessibility`, plus a row that
  opens the Accessibility pane. That row works only on the owner's click; nothing prompts on its
  own. **`kAXTrustedCheckOptionPrompt` is never passed**: trust is read with
  `AXIsProcessTrusted()` only.
- **Rig runs** launch the engine as a child process of the terminal, so they inherit the
  terminal's grant. The probe confirmed `AXIsProcessTrusted=true` from this terminal. If a rig
  engine reports `trusted: false`, check 9 FAILs with "the terminal lacks Accessibility", and
  the run stops (Brakes).

---

## Surfaces and files

### S1 · `rules.json` v2 (`Sources/SwaplessCore/Rules/RulesFile.swift`, new `Sources/SwaplessCore/Rules/QuitSettings.swift`)

- `QuitSettings`:
  - `status` (`ok` | `default` | `invalid` | `missing`), `error: String?`, `enabled: Bool`;
  - `apps: [AppEntry]` (`bundleId`, `name`, `neverQuit`, `note?`);
  - `neverQuitIds: Set<String>`, the entries with `neverQuit` true. Finder is **not** added
    here; the gate adds it.
- `RulesLoad` gains `quit: QuitSettings`. `allValid` also requires the quit status to be `ok`
  or `default`. **This is intended:** every write re-encodes the whole model. So while the quit
  section is invalid, the wallpaper toggle is disabled too (the restart rule itself keeps
  running), and `Open rules file…` is the way out.
- `decode`:
  - version 1: top-level keys `version` and `rules` only, as today, with `quit = .default`
    (the seed list, `enabled` false);
  - version 2: top-level keys `version`, `rules`, `quitOnLastWindow` and `apps`. Any other key
    makes the file invalid, as today;
  - v2 without `quitOnLastWindow` or `apps` is a **section** error (`missing key 'apps'`),
    not a file error;
  - inside the quit keys, apply T1's section rules:
    - `quitOnLastWindow`: `enabled` is required and a boolean; no other key;
    - `apps` entries: `bundleId` (1–255 chars, no whitespace), `name` (1–255 chars) and
      `neverQuit` (boolean) are required; `note` is an optional string; no other key;
    - a duplicate `bundleId` or more than 500 entries makes the section invalid;
    - the first error found is `quit.error`, worded like the existing rule errors (`apps[3]:
      missing key 'neverQuit'`).
  - A missing file gives `quit.status = missing`.
- `encode(rules:quit:)` always writes version 2, pretty-printed with sorted keys, `apps` sorted
  by `name` (`localizedCaseInsensitiveCompare`), then `bundleId`.
- **Writes**, each guarded like `writeEnabled`: `allValid`, then the mtime/size check, then an
  atomic write. They return `WriteResult`:
  - `writeEnabled` (existing) now encodes v2;
  - `writeQuitEnabled(url:load:enabled:)`;
  - `addNeverQuit(url:load:bundleId:name:now:timeZone:)`: adds `{bundleId, name, neverQuit:
    true, note: "Added from the menu <yyyy-MM-dd>"}`, with the local date from the injected
    `now` and time zone; if the id exists, sets `neverQuit` true and keeps its
    name and note;
  - `removeNeverQuit(url:load:bundleId:)`: deletes the entry.
- **The seed** (`seedIfFirstLaunch`, `restoreDefault`) writes v2: `[seedRule]`, `enabled`
  false, and T1's 11 entries, each with the note `Owner's seed 2026-11-06 (DECISIONS.md)`.
- The `rules` JSON line and the `.default` log line gain `quit`: `{"status","enabled",
  "neverQuit":[ids sorted],"error"}`.

### S2 · The decision core, pure (new `Sources/SwaplessCore/Quit/`)

- **`WindowReading.swift`:** `AXWin {id: UInt32, subrole: String, minimized: Bool}`, `CGWin {id:
  UInt32, layer: Int, spaces: [UInt64]}`, `WindowReading {ax: [AXWin]?, cg: [CGWin],
  visibleSpaces: Set<UInt64>}`. `ax` is nil when AX failed or timed out. An AX window whose id
  can't be read has id 0.
- **`WindowVerdict.swift`**, two pure functions:
  - `evaluate(_ r: WindowReading, closed: Set<UInt32>) -> Verdict {alive, ax, elsewhere,
    error: String?}`. The error is `ax-error` when `ax` is nil, and `no-window-id` when any
    counted AX window has id 0;
  - `closedMarks(_ r:) -> Set<UInt32>` (T3).
- **`QuitGate.swift`:** `evaluate(GateInput) -> GateResult` (`.quit` | `.dryRun` |
  `.skip(reason)`), in T6's order. `GateInput` carries:
  - the settings, `observeOnly`, `trusted`, `available`, `stageManager`, the pause state;
  - the rig prefix;
  - the app's `bundleId?`, `pid`, policy, `isHidden`, `launchDate`, `isFinishedLaunching`;
  - Swapless's own bundle id and pid;
  - `disarmed`, the recent quit times for the bundle id, `dryRun`, `now`.
- **`QuitTracker.swift`:** the per-pid state machine. Time is injected and nothing is read from
  the system. Per pid it holds `armed`, `pending(trigger, triggerAt)?`, `closed: Set<UInt32>`,
  `disarmed`, and the bundle id's quit times.
  - **Inputs:** `track(app)`, `untrack(pid)`, `reading(pid, r, at)`, `trigger(pid, kind, at)`,
    `windowCreated(pid, at)`, `pause(reason)`, `resume`, `tick(at)`.
  - **Outputs:** `readAt(pid, time, purpose: settle|decide|confirm)`, `decision(pid, verdict,
    reason, trigger)`, and `terminate(pid)`.
  - **The sequence:**
    1. A trigger on an armed app (deactivate: armed and not pending) → `readAt +0.3`.
    2. The settle reading adds `closedMarks`. If `alive` > 0, nothing more happens; if it is
       0, the app goes `pending` with a decide read at trigger +5.0.
    3. `windowCreated`, or any reading with `alive` > 0 while pending → cancel, reason
       `cancelled-window`. **Every `windowCreated` and `deminiaturized` also asks for a
       reading at +0.3 s,** which is how an app becomes armed when its first window appears
       after tracking started.
    4. At the decide read: if `alive` > 0, cancel with `alive`; otherwise gate. On `.quit`,
       read again at +0.5; if `alive` is still 0 and the gate is still `.quit` → `terminate`,
       then `disarmed`.
    5. `.dryRun` → `decision` with `dry-run`, no terminate, and the app is disarmed the same
       way.
    6. A trigger while pending only adds closed marks at its own +0.3 s read. The original
       deadline stays.
  - A reading whose AX list shows ≥ 1 (A) window re-arms the app and clears `disarmed`. An id
    listed in AX leaves `closed`.

### S3 · The watcher and the engine wiring

New files:
- `Sources/Swapless/WindowWatcher.swift`: the thread, AX observers, NSWorkspace forwarding,
  readings, the tracker, trust re-checks.
- `Sources/Swapless/PrivateWindowAPI.swift`: the `dlsym` lookups and the T8 check.
- `Sources/Swapless/QuitSender.swift`: the `LiveQuitSender` (the only `terminate()`) and the
  `DryRunQuitSender`.
- `Sources/SwaplessCore/Quit/QuitSender.swift`: the protocol `QuitSending { func terminate(pid:
  Int32) -> Bool }`.

**Tracked apps:** every running app with `activationPolicy == .regular` and a bundle id,
**plus**, only when the rig seam is set, any app whose bundle id has the seam's prefix
(whatever its policy). Tracking starts at launch, on enable and on `didLaunchApplication`; it
stops at `didTerminateApplication`.

On track, Swapless:
1. creates an `AXObserver`;
2. registers `AXWindowCreated`, `AXWindowMiniaturized`, `AXWindowDeminiaturized`,
   `AXApplicationDeactivated`, `AXApplicationHidden` and `AXApplicationShown` on the app element;
3. enumerates the AX windows and registers `AXUIElementDestroyed` on each;
4. feeds one reading.

On `NSWorkspace.activeSpaceDidChangeNotification`, every tracked app is re-enumerated, and
destroyed is registered on windows not yet registered. An "already registered" error (−25209)
is ignored.

Engine additions (`Sources/SwaplessCore/Engine/Engine.swift`; keep the file's style):
- `groupFootprintMB(pid:) -> Double?` (T9).
- `recordQuit(…) -> Int64?` and `updateQuitOutcome(id:outcome:)`, through `insertAction` /
  `updateOutcome`; `after_mb` stays nil.
- `currentQuitSettings() -> (QuitSettings, RulesStatus)`: re-stats `rules.json` and reloads
  when the mtime or size changed, so a menu or hand edit applies to the very next decision.
- **How the watcher learns of setting changes:** it subscribes to the engine's state publish,
  next to the existing `onState`, and on every publish it compares `rules.quit` and
  `observeOnly`. When the option goes on and Swapless is trusted, it registers observers; when
  the option goes off, it drops them all (T7). It also calls `currentQuitSettings()` at every
  decide and confirm read.
- **How the engine learns of the watcher's state:**
  `setWatcherStatus(trusted:available:unavailableReason:stageManager:tracked:armed:)`, called by
  the watcher whenever any of those change. The engine stores the values, folds them into
  `EngineState.quit` (`paused`, `watching`), and emits the `quitStatus` JSON line.
- `recordQuit` and `updateQuitOutcome` also insert and update the row in the engine's in-memory
  recent actions, the same list restarts update, so the Today row and `lastQuit` change at
  once, not at the next history read.
- `EngineState.quit: QuitDisplay`, published with every state. It holds:
  - `settings` (`QuitSettings`);
  - `paused: String?` (`needs Accessibility`, `unavailable on this macOS`, `Stage Manager is
    on`, `another Swapless is acting`, `history off`, `rules.json invalid`, `not watched by
    --print-menu`);
  - `watching: Int` (armed apps);
  - `lastQuit: QuitActionDisplay?` (ts, bundle id, name, beforeMB, outcome, dryRun): the
    newest non-dry quit row ≤ 30 min old.
- **The wallpaper rows ignore quit rows.** The wallpaper `RuleDisplay.lastAction` keeps
  selecting by its own rule id (add a test).
- **Names:** a new core protocol `AppNameByBundleId`. The app target implements it with
  `NSWorkspace.urlForApplication(withBundleIdentifier:)` and the bundle's
  `CFBundleDisplayName` / `CFBundleName`, falling back to the bundle id. It gives the
  `Last quit` row's name, preferring the `apps` entry's `name` when there is one.
- **Logging:** `EventSink` gains the category `quit` and an `info(_:_:)` method (it has
  `log`, at `.default`, and `debug` today).
  - Every `decision` is logged at `.info`:
    `quit decision pid=<p> app=<bundleId> trigger=<destroyed|deactivated> verdict=<quit|dry-run|skip|cancel> reason=<code> ax=<n> elsewhere=<n> closed=<n> cpuMs=<x.x>`.
  - Every `terminate()` and every outcome is logged at `.default` in the existing `actions`
    category, with `rule=quit-on-last-window`.
- **Headless JSON lines:**
  - `{"type":"quitDecision","t","pid","bundleId","trigger","verdict","reason","alive","ax","elsewhere","closed","cpuMs"}`;
  - quits reuse the existing `action` and `actionOutcome` lines with `ruleId`
    `quit-on-last-window` and `target` = the bundle id, plus a field `"app"` (the name) on
    `action`;
  - the `start` line gains `"quit": {"enabled","rigPrefix"}`, the only quit facts known
    before the watcher starts;
  - `{"type":"quitStatus","t","enabled","trusted","available","paused","tracked","armed"}` is
    emitted by the engine (from `setWatcherStatus`) once the watcher has finished its first
    enumeration, and again whenever any of those fields changes. The rig reads this line, not `start`, for trust, availability and
    tracked counts.

The watcher runs in **menu-app mode and headless mode** (created in `AppDelegate` and in
`runHeadless`). `--print-menu` and `--dump-snapshot` never create it.

### S4 · Activity and the Today row (`Sources/SwaplessCore/History/Activity.swift`, `MenuModel.swift`)

T10, plus:
- **`activityBody` order:** restarts, then quits, then freed. The `(N failed)` suffix attaches to
  the restarts part:
  - `2 restarts (1 failed) · 3 quits · 4.1 GB freed`
  - `3 quits · 912 MB freed`
  - `1 restart · 2.8 GB freed`
  - `no restarts or quits` (it was `no restarts`)
- **Rows:** the day rows and the `7 days:` total use the same body. `Today: …` is unchanged
  otherwise.
- **The `activity` JSON line** gains `"quits"` in each day and in the total.

### S5 · Menu (`Sources/SwaplessCore/Menu/MenuModel.swift`, `Sources/Swapless/MenuController.swift`, `AppDelegate.swift`)

New rows go in `rulesSection`, after the wallpaper rows and before the `rules.json` error rows.
They start with a separator `sep.quit`:

| Slot | Title | State |
|---|---|---|
| `quit.toggle` | `Quit apps when their last window closes` | checkbox = `settings.enabled`; enabled iff `allValid && !observeOnly`; action `.toggleQuitOnClose` |
| `quit.status` | at most one; see below | disabled |
| `quit.never.offer` | `Never quit <Name>` | only under a `Last quit` / `didn't quit` status, when the bundle id isn't already protected; action `.addNeverQuit(bundleId, name)` |
| `quit.accessibility` | `Open Accessibility settings…` | only with `Paused: needs Accessibility`; action `.openAccessibilitySettings` |
| `quit.error` | `rules.json: <quit.error>` | only when the quit section is invalid; disabled |
| `quit.never` | `Never quit` | submenu, below |

`quit.status`, the first that applies (shown when `enabled`, **or** when the file or the quit
section is invalid):
1. `Paused: <paused>`.
2. pending → `Quitting <Name>…`.
3. `ok` → `Last quit 14:02: <Name> · 312 MB` (`valueMB`).
4. `refused` → `14:02: <Name> didn't quit · left open`.
5. `not-sent` → `14:02: <Name> couldn't be asked to quit`.
6. → `Watching <n> apps` (`Watching 1 app`).

The `Never quit` submenu:
- `Finder (always)` (checked, disabled);
- then one row per `neverQuit` entry, sorted by name: title `<name>`, checked, enabled iff
  `allValid && !observeOnly`, action `.removeNeverQuit(bundleId)`;
- a separator;
- `Add running app` with its own submenu: the running Dock apps (bundle id, not Finder, not
  Swapless, not already protected), sorted by name, each action `.addNeverQuit(bundleId,
  name)`. With none, a single disabled row `No other apps running`.

When the quit section is invalid, every row in the submenu is disabled and the existing
`Open rules file…` row shows.

- `MenuAction` gains `.toggleQuitOnClose`, `.addNeverQuit(String, String)`,
  `.removeNeverQuit(String)` and `.openAccessibilitySettings`.
- `MenuInput` gains `runningApps: [RunningApp]` (bundleId, name). `name` is the app's
  `localizedName`, falling back to `AppNameByBundleId`, then to the bundle id; that `name` is
  what `addNeverQuit` writes. `MenuController` fills it from
  `NSWorkspace.shared.runningApplications` when the menu opens; `--print-menu` fills it the same
  way. **`--print-menu`** never creates the watcher, so its status row reads
  `Paused: not watched by --print-menu` whenever the option is on.
- **Handlers** call the S1 writes on the engine queue. Then they reload and publish, as the
  wallpaper toggle does. On `skippedChanged` they reload and do nothing more.
- `.openAccessibilitySettings` opens
  `x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility`. The handler
  is the only one that opens it, so it never opens without the owner's click.
- **Quits never touch the dot** (`dotGeneration` unchanged, owner Q3).

### S6 · The rig: test app, check 9, check 5c (`Package.swift`, new `Sources/swapless-window-app/`, `Sources/swapless-rig/Check9.swift`, `Check5.swift`, `main.swift`, `scripts/leak-rig.sh`, `Config.swift`)

**Seam `SWAPLESS_RIG_QUIT_BUNDLE_PREFIX`** (`Config`, release and debug alike, as
`SWAPLESS_DRY_RUN` is):
- The value must start with `com.michaelv.swapless.rig.`, or it's a config error.
- While it's set, the gate's `rig-scope` blocks every bundle id without the prefix, and admits
  ids with it even when they are not `.regular`.
- It's logged at `.default` at launch and appears in the `start` line.
- **The rig sets it on every engine it runs with the option on.** So, during the rig, nothing of
  the owner's can be quit, even if the owner closes a window.

**Test app `swapless-window-app`** (executable target, AppKit, no dependencies):
- **Bundles:** the rig wraps it into one bundle per scenario,
  `.build/rig/window-apps/<scenario>.app`:
  - `Info.plist`: `CFBundleIdentifier` `com.michaelv.swapless.rig.window.live.<scenario>`
    (`…window.dry.<scenario>` for the dry-run engine's app), `LSUIElement` true,
    `CFBundleExecutable`. The two prefixes are disjoint, so neither engine can act on the
    other's apps;
  - ad hoc signed (`codesign -s - --force`).
- **Launch:** `NSWorkspace.openApplication(at:configuration:)` with `activates = false`,
  `createsNewApplicationInstance = true`, `addsToRecentItems = false`, `arguments = ["--mode",
  <scenario>, "--ctl", <fifo>, "--status", <jsonl>]`.
- **Cleanup:** after check 9, every bundle is unregistered
  (`/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -u <path>`)
  and deleted.
- **Never visible.** `LSUIElement` means no Dock icon and no menu bar of its own, and it never
  calls `activate`. Every window **and panel** it creates, including those created by `open`,
  is a subclass whose `constrainFrameRect(_:to:)` returns the rect unchanged. It is placed at x = (max X of all `NSScreen` frames) + 20,000, y =
  0, size 800×600, and shown with `orderFrontRegardless()`.
- It allocates and touches **64 MiB** at launch, so its footprint is measurable.
- **Status file:** it writes JSON lines with `ready` (its window ids), `windowClosed`,
  `windowOpened`, `shouldTerminate` (its answer) and `willTerminate`.
- **Commands** (FIFO lines):
  - `close <n>` (`performClose:`, the ⌘W path);
  - `open` (new standard window);
  - `exit` (`exit(0)` directly, bypassing `applicationShouldTerminate`, so `refuse` can be
    cleaned up too).

**Modes (scenarios)** and their expected results. Unless a scenario says otherwise, the rig
drives the close with an **AX press** on the window's `kAXCloseButtonAttribute`, the red-X
path. It does this only after checking that the element's pid is that scenario's test-app
pid:

| Scenario | Setup → action | Expected |
|---|---|---|
| `close-ax` | 1 window → AX press close | `terminate` 5.0–7.5 s after the close; outcome `ok`; history row with `before_mb` within ±15 % of the app's own `proc_pid_rusage` footprint read by the rig just before the close, and ≥ 60 |
| `close-menu` | 1 window → `close 0` | quit, `ok` |
| `hide-on-close` | `windowShouldClose` orders out and returns false (Slack-like; it keeps its Space) | quit, `ok` |
| `helpers` | 1 window + 14 ordered-out layer-0 windows (one 500×500, the rest 1920×30) | quit, `ok` |
| `two-windows` | 2 windows → close one, wait 8 s → close the other | after the first: no terminate, and a decision with reason `alive` or none; after the second: quit |
| `swap` | on close, it opens a new window 2 s later | no terminate; reason `cancelled-window` or `alive` |
| `panel-left` | 1 window + a floating `NSPanel` (rig reads its subrole; `AXFloatingWindow` expected) → close the window | quit (panels don't count) |
| `dialog-left` | 1 window + a non-floating titled `NSPanel`; if AX doesn't report it as `AXDialog`, an `NSAlert`'s `window` shown with `orderFrontRegardless()` (never `runModal`) → close the window | no terminate; reason `alive` |
| `tabs` | 2 native tabs in one tab group → close the selected tab, wait 8 s → close the last | none after the first; quit after the last |
| `refuse` | `applicationShouldTerminate` → `.terminateCancel` | one `terminate`; outcome `refused` at 30 s; still running; for 15 s more, no second `terminate`; after `open` + AX close of that new window: a second `terminate` (re-armed) |
| `never-quit` | its bundle id is in the rig's `apps` with `neverQuit` | no terminate; reason `never-quit` |
| `young` | closes its own window 3 s after launch | no terminate; reason `young` |
| `windowless` | launches with no window and stays | no decision at all within 20 s |
| `option-off` | the rig rewrites its own `rules.json` with `enabled` false, waits for a `quitStatus` line with `enabled` false (deadline 10 s), then AX-closes | no terminate within 15 s, and either no decision for it or reason `option-off` (with the option off, observers may already be gone) |
| `dry-run` | its app is `…window.dry.close-ax`, run by a **second** engine with `SWAPLESS_DRY_RUN=1`, its own state dir and `rules.json`, and prefix `com.michaelv.swapless.rig.window.dry.` | no terminate; reason `dry-run`; history row `dry_run` 1; that engine's Today `quits` 0 |

If neither construction yields the subrole a scenario needs (`AXFloatingWindow` for
`panel-left`, `AXDialog` for `dialog-left`), that row reads `n/a (subrole <x>)` in the report.
That isn't a FAIL or a SKIP of check 9; the PR and the DECISIONS.md amendment name it, and unit
fixtures cover the subrole logic.

**Check 9:**
- **Preflight walls** (in `Check9.swift`, before anything is launched): it reads every
  `.swift` file under `Sources/`, drops comment text (`//` to end of line, and `/* … */`), and
  then requires:
  - no `forceTerminate` anywhere;
  - exactly one `.terminate()` (empty parentheses) across `Sources/Swapless` and
    `Sources/SwaplessCore`, in `Sources/Swapless/QuitSender.swift`.

  Either one failing makes check 9 FAIL.
- **Run:**
  1. Write the rig's `rules.json` v2 into its temp state dir: **`"rules": []`** (no restart
     rule: a release engine with the wallpaper seed could restart the owner's real
     WallpaperAgent), `enabled` true, and one `apps` entry for `…window.live.never-quit` with
     `neverQuit` true.
  2. Launch the release engine headless with the prefix `com.michaelv.swapless.rig.window.live.`
     and `SWAPLESS_SAMPLE_INTERVAL=2`, and the dry-run engine with the `…window.dry.` prefix.
  3. Launch every scenario at once, **except `option-off`, which runs alone after all the
     others have reached their outcome**, because it rewrites the engine's `rules.json`.
  4. **Visibility gate (FAIL):** wait (deadline 20 s) for every `ready`, then:
     - (a) every test window's CG bounds intersect **no** active display's bounds;
     - (b) every scenario window expected to count is in that app's AX list and on a visible
       Space;
     - (c) the engine's latest `quitStatus` line shows `trusted: true` and `available: true`.

     On a failure, it terminates the test apps (`exit`, then SIGTERM after 5 s) and stops check
     9. **(a) is re-checked on every `windowOpened` status line** (`open`, `swap`, `tabs`, the
     panels) for the whole check. Any window intersecting a display is the same FAIL and stop.
  5. Wait until each app's age is ≥ 11 s (except `young`), drive the scenarios, and wait for
     their outcomes. The deadline is 60 s per scenario (`refuse`: 120 s), and `TIMEOUT` fails
     it.
- **Afterwards:**
  - the engine's `activity` line has today's `quits` equal to the number of `ok` scenarios,
    and `freedMB` ≥ the sum of their `before_mb`;
  - **relaunch** on the same state dir: the same `quits` are read back (like 4b);
  - **every** `quitDecision` with verdict `quit` names a bundle id with the rig prefix, and the
    run's `actions` rows only ever name rig bundle ids. Any other id FAILs check 9, **is a
    mandatory DECISIONS.md trigger, and stops the run** (Brakes);
  - `cpuMs` per decision: report the p50, p95 and max; **FAIL if the max is > 150 ms** (a
    decision with a footprint sweep is expected to be ~30–60 ms). `cpuMs` is defined as the
    `CLOCK_THREAD_CPUTIME_ID` time the watcher thread spends on that decision's reads, from
    trigger to verdict, **plus** the thread CPU of the footprint sweep, measured inside the
    `engine.queue.sync` block.
- **Order and numbering:** the new check is **9**. **Number 8 already belongs to the on-screen
  menu walk** (`--on-screen-menu` sets `checks = [8]`, `main.swift`), and that mode is not
  touched. Check 9 runs in the bare run and in `--budget` (`checks = [1,2,3,4,9]` and
  `[1,2,3,4,5,9]`). `--only` accepts 1–4 and 9; 8 is never accepted by `--only`. Update the
  usage text and the header comment of both `leak-rig.sh` and `main.swift`.

**Check 5c (`--budget`):**
- **Run:** a release headless engine with the option on (its own temp state dir and v2 rules
  with `"rules": []`, the live prefix set, no test apps, `SWAPLESS_SAMPLE_INTERVAL` unset), for
  600 s, **concurrently**
  with check 5's existing installed-app window, so `--budget` grows by ≤ 1 min.
- **Window:** the CPU is the engine's `ps` cumulative CPU time from 60 s after launch to
  660 s. The first 60 s (self-check, first enumeration, observer registration) are reported
  but not judged. 5c runs and passes or fails on its own, whatever check 5's own window does.
  If 5c's engine reports `source` `top`, the limit is 0.6 %, as in check 5.
- **Pass:**
  - the `ps` CPU over the window ≤ 0.2 % of a core;
  - its footprint ≤ 30 MiB at the end, peak ≤ 45 MiB;
  - within 30 s, a `quitStatus` line shows `tracked` ≥ 1 (the owner's real Dock apps,
    read-only).

---

## Edge cases

- **A minimized window**, on this Space or another, is alive (T2 (A); probe).
- **A window on another Space or in full screen** is alive (T2 (B)), unless it was marked closed
  at the moment of the close (T3).
- **A Space switch, or Mission Control, during the 5 s:**
  - closed marks were taken at +0.3 s;
  - windows of other Spaces count;
  - a hidden-on-close window marked closed doesn't.
- **Native tabs:** closing the selected tab leaves the next tab ordered in, so AX lists it at the
  decision. The rig's `tabs` scenario proves it. A wrongful quit there stops the run.
- **Swapping windows** (a login window becoming the main window, Xcode's welcome window, a quick
  ⌘N) cancels the decision.
- **An app hidden with ⌘H** is never quit, because its windows are ordered out and would look
  closed.
- **Still launching, or younger than 10 s:** never quit.
- **A visible standalone dialog** keeps the app alive. **Floating panels and inspectors** don't.
- **The app refuses or asks to save:** one `terminate()`, outcome `refused` at 30 s, then the app
  is left alone until it opens a new (A) window. If the owner answers a save prompt after 30 s,
  the row stays `refused` and the quit isn't counted; it's documented and accepted.
- **The app exits by itself during the grace:** `gone`, no row.
- **Rapid relaunch loops:** at most 3 `terminate()` per bundle id per 10 min, then
  `rate-limit`.
- **An AX read times out or fails** (a hung app): `ax-error`, never quit. The 0.3 s messaging
  timeout bounds the stall, and it happens on the watcher thread, never the main thread.
- **Two instances of one bundle id:** they are tracked per pid. The rate limit is per bundle id.
- **Option turned off, an entry added to Never quit, or the file edited during the grace:** the
  decision re-reads the settings (`currentQuitSettings`) and skips.
- **Sleep, screen lock, display change:** pending decisions are cancelled; nothing is queued.
- **Accessibility revoked while on:** AX returns `kAXErrorAPIDisabled` → `untrusted`, observers
  are dropped, and the menu shows `Paused: needs Accessibility`. A re-check every 10 s
  re-registers once it's granted again.
- **Stage Manager turned on:** `Paused: Stage Manager is on`, re-read at every decision and at
  menu open.
- **Empty states:**
  - nothing protected but Finder: the submenu shows `Finder (always)`, a separator and `Add
    running app`;
  - no running Dock apps to add: `No other apps running`;
  - no quits in 30 min: `Watching <n> apps`;
  - `rules.json` missing: the toggle is disabled, and the existing `Restore default rules` row
    restores the v2 seed;
  - `rules.json` invalid: the toggle and list are disabled, with `Open rules file…`.
- **History off:** no quit, reason `history-off`; the status row reads `Paused: history off`.
  This matches restarts: no row, no action. If the row insert itself fails at decision time:
  no terminate, reason `history-off`.
- **The owner's real apps during a rig run** are watched read-only and blocked by `rig-scope`.
  The installed app never considers the rig's test apps: they are `LSUIElement`, so not
  `.regular`, and the installed app has no prefix seam set.

---

## Verification plan

Tests use Swift Testing, temp state dirs (`makeTempDir()`), injected clocks, time zones and
fixed `now` values. They never use the real state dir, the system time zone, AX or the window
server; the AX and window-server side is the rig's job.

| Surface | Check type | Gate |
|---|---|---|
| S1 rules v2 | functional | `swift test` `RulesFileTests`: v1 file → rules as before, `quit.status` `default`, `enabled` false, 11 seed ids; v2 round-trip (encode → decode equal, `apps` sorted); v2 with an unknown top-level key → file invalid; version 3 → file invalid; v1 with `apps` → file invalid; each section error from S1 → `quit.status` invalid with the exact error text **and the restart rule still valid**; duplicate `bundleId`; 501 entries; `writeQuitEnabled` from a v1 file writes v2 keeping the rule byte-equal in the model; `writeEnabled` (wallpaper) on a v1 file writes v2 with the seed list; add (new, existing with `neverQuit` false), remove; every write refuses when invalid (`notAllowed`) and when mtime or size changed (`skippedChanged`); the seed file decodes to `[seedRule]` + 11 entries + `enabled` false; Finder is never in `neverQuitIds` unless listed. |
| S2 core | functional | `swift test` `WindowVerdictTests`: the probe readings transcribed as fixtures (`Tests/SwaplessCoreTests/Fixtures/quit-*.json`, from `docs/research/2026-11-06-quit-on-close-probes.md`): Notes closed (14 helpers, no Space) → 0; Notes minimized as `AXDialog` on a visible Space → 1; Notes minimized while on Space 5 → 1; Notes window on another Space, AX empty → 1 elsewhere; Slack hidden on Space 6 visible → 0; the same with the owner moved to Space 5 **and** the mark from the settle read → 0, **without** the mark → 1; Chrome's off-screen windows on the visible Space → not counted; visible `AXDialog` → 1; visible `AXUnknown` and a missing subrole → 1 each; `AXFloatingWindow` or `AXSystemFloatingWindow` only → 0; role `AXGroup` → 0; `ax` nil → `ax-error`; id 0 → `no-window-id`. `QuitGateTests`: one case per reason in T6's order, with an input failing two checks reporting the earlier one; Finder blocked even with an empty list; the rig prefix admits an `.accessory` app only with the prefix. `QuitTrackerTests` (injected time): every S2 sequence, plus the four `QuitTimingTests` boundaries (4.99 s no decision, 5.0 s decision; confirm at 5.5 s; young at 9.99 / 10.0 s; rate limit at the 4th within 600 s and allowed at 600.01 s); the trigger on an unarmed app does nothing; enabling with windowless apps produces no decision; `windowCreated` during pending cancels; `refused` disarms until an (A) reading; pause cancels pending. **Property test** (1,000 random event sequences with random readings and settings): `terminate` is never emitted for a never-quit or Finder bundle, with the option off, when untrusted, unavailable, observe-only, history off, hidden, young, out of rig scope, or for a pid whose last decide or confirm reading had `alive` > 0 or an error. |
| S3 watcher + engine | functional | `swift test`: `ConfigTests` for the seam (missing prefix → error, valid → set, logged); `EngineQuitTests` with a fake `QuitSending` and synthetic readings fed through the engine API: `recordQuit` + `updateQuitOutcome` rows read back; the wallpaper `lastAction` ignores quit rows; `currentQuitSettings` picks up an edit by mtime. **Rig:** check 9 (all scenarios, walls, visibility gate, relaunch read-back, the scope assertion, `cpuMs`). |
| S4 activity | functional | `swift test` `ActivityTests`: `quit-on-last-window` → `.quit` whatever the target; only `ok` quits counted; `refused`, `not-sent`, `pending`, `interrupted` and dry runs not counted and not failed; freed = `before_mb` for `ok`, nothing for `before_mb` 0; a day with 1 restart (2,851.1 MB freed) + 2 quits (300 + 612 MB) → `1 restart · 2 quits · 3.7 GB freed`; every S4 example string; `no restarts or quits`; the `activity` JSON with `quits`. Existing expected strings that change (`no restarts`) are updated, not loosened. |
| S5 menu | functional + user-decides | `swift test` `MenuModelTests`: every row and title in S5 for each status (paused × 5, pending, ok, refused, not-sent, watching 1 / n); `Never quit <Name>` present only when not protected; the submenu (Finder first, sorted entries, `Add running app` excluding protected, Finder and Swapless; the empty row); disabled states when invalid and observe-only; row order (`sep.quit` after the wallpaper rows, before the error rows). **Rig:** check 5's offscreen menu draw test still passes with the new rows (no AppKit raise). **User-decides at acceptance:** the menu screenshots. |
| S6 rig | functional | `./scripts/leak-rig.sh --only 9` exits 0. Then the whole-slice gate. |
| Budget | functional | `--budget` check 5c passes and check 5 is unchanged. |
| Whole slice | functional | `swift build && swift test && ./scripts/make-app.sh release --adhoc && ./scripts/leak-rig.sh --budget` exits 0. `docs/proof/v1-quit-on-close/` holds: the `--budget` report; a `--print-menu` text from a temp state dir with a v2 seed and `enabled` true; the check 9 scenario table with `cpuMs` p50/p95/max. |
| On the real Mac | user-decides, at acceptance | The PR's owner checklist (Brakes). |

---

## Brakes (for the unattended run)

**One surface per pass, in this order. Each pass ends green on its gate before the next
starts:**
- **P1** · S1 (`rules.json` v2) → `swift test`.
- **P2** · S2 (the pure core and its fixtures, the property test) → `swift test`.
- **P3** · **Feasibility first, before building the watcher.** A throwaway rig scenario (or a
  scratch target that is not committed) launches one `close-ax` test app, off-screen as S6
  says. It confirms:
  - (a) no display intersects its window;
  - (b) its AX list shows the window as `AXStandardWindow` with a readable id;
  - (c) SkyLight puts the window on a visible Space;
  - (d) an AX press on its close button produces `AXUIElementDestroyed` for an app that is
    never active;
  - (e) a `CFRunLoopRun()` headless process receives `didLaunchApplication` and
    `didTerminateApplication` for it;
  - (f) one `NSRunningApplication.terminate()` sent from a headless process launched from the
    terminal quits it within 5 s. A longer wait may mean an Automation (TCC) consent prompt is
    on the owner's screen. **Stop and report** if it hasn't terminated after 10 s, saying a
    prompt may be showing, and don't send another.

  Write the results in the PR body.
- **P4** · S3 + S6 (the watcher, engine wiring, test app, check 9 and its walls) → `swift test`
  + `./scripts/leak-rig.sh --only 9`, then `--only 1,2,3,4` (the headless run-loop change).
- **P5** · S4 + S5 (Activity, Today strings, menu rows and actions) → `swift test` +
  `./scripts/leak-rig.sh --only 3,4,9` + a `--print-menu` proof.
- **P6** · Check 5c, the whole-slice gate, the proofs, the DECISIONS.md amendment below, then
  **`/save-task` (a draft PR)**.
  - The PR body opens with **the owner's acceptance checklist**, in this order:
    1. `./scripts/make-app.sh release` (re-sign); `codesign -dv /Applications/Swapless.app` shows
       `Authority=Swapless Self-Signed`; `Open at login` still checked.
    2. The menu shows the new rows with the option off. Turning it on reads `Paused: needs
       Accessibility` and offers `Open Accessibility settings…`.
    3. **Grant Accessibility to Swapless** (System Settings → Privacy & Security →
       Accessibility). Within 10 s the status reads `Watching <n> apps`. WhatsApp and the Safari
       web apps (windowless) are **not** quit.
    4. **Notes:** open a window, close it with the red X → Notes leaves the Dock in about 5 s,
       and the menu shows `Last quit HH:MM: Notes · N MB` with `Never quit Notes`. Reopen Notes
       and close with ⌘W → it quits again.
    5. **Slack:** close with the red X → it quits. Reopen, ⌘W, and switch Space right away →
       it still quits.
    6. **Minimized:** minimize a Notes window and wait 10 s → still running. With it minimized,
       switch Space → still running.
    7. **Another Space:** one Notes window on Space A, one on Space B; close the one on B →
       Notes stays.
    8. **Never quit:** close Music's window → Music keeps running. Click `Never quit Notes`,
       close Notes' window → it stays. Remove Notes from `Never quit` with one click.
    9. **Today:** the Today row and its submenu show the quits and the freed total. A screenshot
       of the menu with `Last quit` and the open `Never quit` submenu.
    10. **A day with it on:** the footer stays ≤ 0.2 % CPU idle and ≤ 40 MB after menu use;
        `./scripts/self-report.sh` after that day.
  - **Never run `/ship-task`, `gh pr ready` or `gh pr merge`.**
- **Existing tests this slice is expected to update** (this is not loosening a gate):
  - the `RulesFileTests` encode and seed expectations (version 2 now);
  - `ActivityTests` and `MenuModelTests` strings with `no restarts`;
  - the `activity` JSON shape (it gains `quits`);
  - check 9's absence from the usage text.

  Their new values come from S1 and S4.
- `leak-rig.sh` always runs with `run_in_background`, never under a foreground timeout. Every
  wait the run adds has a deadline that fails loudly (`TIMEOUT`). One rig at a time
  (`rig.lock`), and no `swift build` while a rig runs.

**Stop and report, without working around it, if:**
- **Swapless asks any app outside the rig's own test apps to quit**, in any run, for any
  reason. Stop at once, write the mandatory DECISIONS.md entry, and report.
- **The `tabs`, `two-windows`, `swap` or `dialog-left` scenario quits its app** (a wrongful
  quit). Report the readings; never adjust the expected result.
- The P3 feasibility check fails, or check 9's visibility gate fails. **Never put a test window on
  a display** to make it pass.
- The terminal lacks Accessibility (`trusted: false`). Granting it is the owner's step.
- `--budget` (5c included) fails after **one** focused attempt on the failing part. Report the
  numbers; don't loosen a limit.
- Any change would need a `history.sqlite` schema change, a new column, `schema_version` ≠ `1`,
  or the reset path.
- Any change would need to touch the wallpaper rule's evaluation, the actuator, `RestartTarget`,
  `SignalGuard`, `LiveSignalSender` or the restart verify loop.
- The implementation would need a global event monitor, an event tap, `forceTerminate`,
  `kill(2)` on a user app, or AX calls on the main thread.
- Anything would read, copy or open `~/Library/Application Support/Swapless`, other than the
  installed app itself. That includes `sqlite3`, `cat` and `ls` of its contents.
- Anything would put UI on the owner's screen:
  - a Swapless status item in a test mode, a window ordered front, `--on-screen-menu`, opening
    the installed app's menu;
  - a test-app window intersecting a display, or a test app activating;
  - opening System Settings.

  Likewise anything that needs a keychain prompt, `make-cert.sh`, signing with the self-signed
  identity, sudo, a TCC grant, a LaunchAgent or a login item.
- v1-core checks 1–4 or v1-menu-today's additions regress.

**Never touch:**
- the owner's state dir (above);
- any window or app the rig didn't launch. AX **reads** of the owner's apps by the engine under
  test are expected. AX **actions** (`AXPress`, attribute writes) are only ever performed on a
  test-app pid, checked before each one;
- any process other than the rig's own engines, helpers and test apps, and the installed app
  through `make-app.sh`'s exact-path stop. Test apps get `exit` first and SIGTERM after 5 s.
  Never SIGKILL;
- the wallpaper pair (`--live-wallpaper` is not run) and the simulators (`--sim` is not run);
- `main` (PR only);
- `.claude/`, `specs/README.md`, `specs/v1-core.md`, `specs/v1-menu-today.md`;
- secrets, args or env of other processes, in any output, log, fixture or proof. Bundle ids and
  app names are fine; window titles are never read or written.

**DECISIONS.md in P6:** the 2026-11-06 entry `v1-quit-on-close: …` already exists, written in the
`/wingman` session. **Amend that entry** with:
- the P3 feasibility results;
- check 9's table, its `cpuMs` and check 5c's numbers;
- any reading the spec left open.

Don't add a second entry, except for a mandatory trigger.

**Committing:** the `/wingman` session commits this spec, the probe research, the probe tool,
`DECISIONS.md` and `CLAUDE.md` first. **Never stage anything under `.claude/`** (for example the
untracked `.claude/routing-log.jsonl`).
- **Mandatory triggers** (DECISIONS.md header):
  - a check SKIPs or FAILs in the final report;
  - Swapless quit or signalled a process outside an owner-approved rule (the rig's own test apps
    and helpers are approved);
  - a user app was affected;
  - the build exceeded its budget.

**Final acceptance and shipping are the owner's** (the PR checklist).

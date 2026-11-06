# v1-menu-today: an open menu inside the budget, and a "Today" row of what Swapless did

Branch `v1-menu-today` · written 2026-11-06 in a `/wingman` session, from the owner's input dated
2026-11-05 · a small slice between v1-core and `v1-quit-on-close` · this file is the **only input**
for the implementation run.

Conventions are those of `specs/v1-core.md`: MB / GB mean MiB / GiB, "this Mac" is the M1 Pro,
16 GB, macOS 27.2, and "probe" marks a number measured here. This slice's probes are in
`docs/research/2026-11-05-menu-cost-probes.md`. Section names follow `specs/README.md` in
English: Objective = Objetivo, Out of scope = Fuera de alcance, Decisions and why = Decisiones y
porqués, Surfaces and files = Superficies y archivos, Edge cases, Verification plan = Plan de
verificación, Brakes = Frenos.

---

## Objective

Two changes to the shipped v1-core app, and nothing else.

1. **Normal menu use never trips the footer's "over budget".** The footer's CPU figure and its
   flag become the **menu-closed 10-minute average**, labelled `idle`. That is the quantity the
   CPU budget has always been defined on (v1-core § B) and the quantity rig check 5 measures.
   The open menu also gets ~4× cheaper:
   - one display sweep when the menu opens, then one every **5 s** (it was every 2 s);
   - **one** menu refresh per sweep (it was two per 2 s);
   - no menu item is rewritten unless its value changed;
   - group submenus that aren't open are not refilled;
   - compressed memory is read only when a submenu opens.

   The installed app's `self` log line gains the menu-closed average and the CPU spent while
   the menu was open, so the cost of looking is measured on the real screen, without anyone
   asking.
2. **A "Today" row: what Swapless did for the owner, read from its own `history.sqlite`.**
   `Today: 2 restarts · 2.8 GB freed`, with a submenu: one row per day for the last 7 local
   days, then a 7-day total. "Freed" is before − after for the wallpaper extension plus before −
   after for WindowServer, exactly as the `actions` table records them. The summary is a pure
   SwaplessCore function over action rows, shaped so `v1-quit-on-close` can add quits as a
   second kind.

The unattended run is **done** when this passes on the branch:
```
swift build && swift test && ./scripts/make-app.sh release --adhoc && ./scripts/leak-rig.sh --budget
```
That covers the v1-core checks 1–5 unchanged, plus this slice's additions:
- check 4's persistence step (4b);
- check 5's idle-figure agreement;
- check 5's offscreen menu-open test.

The proofs must be in `docs/proof/v1-menu-today/` and a **draft** PR must be open. The owner
accepts on the real screen and ships (Brakes).

---

## Out of scope

- **Any change to what Swapless acts on.** The rule evaluator, the actuator, `RestartTarget`,
  `SignalGuard`, `LiveSignalSender`, the verify loop and the § I property test are **not
  touched**. This slice reads action rows; it never writes or creates one.
  - **One allowed exception:** a read-only `recomputeActivity()` call added in
    `Engine.verifyTick` (right before its `onState?(state)`), in `record()` inside `Engine.act`,
    and in `markInterrupted`. It only reads `recentActions` and writes `state.activity`. It
    doesn't count as touching the verify loop or the actuator.
- **Making the sweep itself cheaper.** The probe measured ~20–25 ms of CPU per sweep in the app,
  not the 1.7–5.1 ms v1-core § B assumed. The profile is in the research doc. Deferred: see
  decision T5.
- **Quits, `quit` rules, quit on last window close.** That's `v1-quit-on-close`. This slice only
  leaves the seam (decision T8).
- **Any change to `history.sqlite`'s schema or `schema_version`** (it stays `1`), or to the
  reset-on-unknown-schema path.
- Notifications or alerts of any kind; the Today row is display-only and lights no dot.
- Clicking the Today row or a day row does nothing (no detail windows, no export, no charts).
- The footprint budget (30 / 40 / 45 MiB) and the CPU budget's limits (0.2 %, and 0.6 % in
  `top` mode) are unchanged; only what the footer compares against them changes.
- `--print-menu` reading history (decision T9).
- Running `--sim`, `--live-wallpaper` or `--on-screen-menu`. None is needed in this slice and
  none may run.
- `make-cert.sh`, signing with the self-signed identity, and the `Open at login` toggle. The
  owner re-signs at acceptance (owner call 3).
- The open question of whether a `max-per-day` pause clears the next day (DECISIONS.md,
  2026-11-05). Not decided here.
- Editing `specs/README.md`, `.claude/`, `specs/v1-core.md`.

---

## Decisions and why

### Owner calls (this session)

1. **The footer's CPU number is the menu-closed 10-minute average, labelled `idle`**, and
   "over budget" compares that same number:
   `Swapless 0.11 % CPU idle · 33 MB · measuring: full`.
   *Why:* the number and the flag are then one quantity, the same one check 5 measures, and
   opening the menu never moves it. This was the owner's proposed fix in DECISIONS.md
   (2026-11-05, "v1-core ships with a false over budget").
2. **The 7-day submenu ends with a total row** after a separator: `7 days: 7 restarts · 8.9 GB
   freed`. *Why:* it is the most direct "what did it buy me this week" number.
3. **The run signs ad hoc; the owner re-signs at acceptance.** `make-app.sh release --adhoc`, as
   in v1-core: no keychain prompt can appear. The installed app is self-signed today
   (`designated => identifier "com.michaelv.swapless" and certificate leaf = H"3699…"`), and an
   ad hoc build may not match the `Open at login` registration until the owner runs
   `./scripts/make-app.sh release` and checks the menu's `Open at login` checkmark.
4. **From the owner's input, taken as given:**
   - "freed = before → after for the extension plus WindowServer, as the action log records
     them";
   - a 7-day submenu, one row per day;
   - only the installed app reads its folder; tests use `SWAPLESS_STATE_DIR`;
   - measure headless or offscreen, never on the owner's screen.
5. **Freshness is the run's call to make, backed by a measurement.** The owner asked for it,
   and decision T2 makes it.

### Technical calls (argued; numbers from the research doc)

**T1 · The CPU flag measures menu-closed time, by construction.**
- The budget (v1-core § B; DECISIONS.md, footprint-split entry) is "≤ 0.2 % of one core over
  10 min" for the **installed app, menu closed**. Rig check 5 re-measures whenever
  `menuOpenSeconds` moved during its window. The footer instead averaged all time, so 98 s of
  menu use lifted it to 0.95–1.04 % and lit the flag for up to 10 min.
- Counting only menu-closed time makes "normal menu use never trips the flag" true by
  definition, not by tuning.
- The open-menu cost is not hidden. It gets its own measured number: the `self` line's
  `menuOpenCpuSeconds` (S1), the offscreen limit in check 5 (S5), and the owner's on-screen
  target (T4).
- *Measured:* with the menu closed, the installed app's 5-min intervals had a median of
  **0.118 %** and a p90 of 0.178 % (54 intervals on 2026-11-05). Every 10-min pair stayed
  ≤ 0.17 %, except the two intervals right after the owner's menu use while PR #1 was being
  merged (0.855 % and 0.377 %). The offscreen run showed **no** tail after close. So that tail
  is unexplained: either on-screen AppKit or the concurrent build. The owner's acceptance check
  watches for it (Verification plan).

**T2 · Freshness: sweep when the menu opens, then every 5 s.**
- *Measured* (p2: top-10 rows, sweeps 2 s apart). The share of rows whose displayed text
  changes, and the p95 size of the change:

  | Gap | Text changed | p95 change |
  |---|---|---|
  | ~2 s | 24 % | 32 MB |
  | ~7 s | 33 % | 48 MB |
  | ~11 s | 38.5 % | 73 MB |
  | ~33 s | 53 % | 106 MB |

  The median change is < 1 MB at every gap. The large moves are steps, not drifts: WindowServer
  moved 217 MB within one 2 s gap. A faster cadence shows a step a few seconds sooner; it
  doesn't reveal anything new.
- The staleness that matters is **at open**: the menu opens with the last base tick, up to 30 s
  old, and the ~33 s row above shows what that means. So the display sweep stays **immediate
  when the menu opens**, as today: ~25 ms later the open menu shows a fresh sweep.
- After that, **5 s**. A row then lags at most 5 s plus a sweep: p95 ≈ 45 MB, against 32 MB at
  2 s. That costs 2.5× fewer sweeps and redraws, and 5 s is also Activity Monitor's default
  update frequency ("Normally").
- 10 s would halve the cost again, at a p95 of ~73 MB. It is the fallback if the on-screen
  target (T4) is missed. Only the owner may switch to it.

**T3 · One refresh per sweep, and no rewrites of unchanged items.**
- *Measured:* the on-screen open menu cost **~6 % of a core**: 6.1 % and 6.7 % from the
  installed app's own `self` lines, ~120 ms of CPU per 2 s. Of that, the display sweep is
  ~25 ms. The in-process model build and the submenu fill are ~5 ms (offscreen probe: 29 ms per
  2 s cycle). The remaining **~90 ms per 2 s is the on-screen menu redrawing**.
- It redraws **twice** per 2 s: `MenuController` has its own 2 s `Timer` on top of the refresh
  that each engine publish triggers. Each refresh also:
  - re-reads `SMAppService.mainApp.status`;
  - re-sets `isEnabled`, `state`, `keyEquivalent`, `target`, `action` and a **new**
    `representedObject` on every item, changed or not;
  - refills every group submenu visited since the menu opened, compressed reads included.

  Each of those writes can make the open menu lay out and redraw again. v1-core S1 already says
  compressed memory is read "only for the member rows of a submenu **as it opens**, never per
  sweep".
- So the menu refreshes once per engine publish, and an item's property is written only when
  it changed.

**T4 · Menu-open cost limits.**
- **Projection:** per 5 s, one ~25 ms sweep plus one on-screen refresh of ≤ ~45 ms (half of
  today's ~90 ms for two). That is ≤ 70 ms / 5 s ≈ **≤ 1.4 % of a core**, before the
  no-rewrite savings.
- **On screen (owner's acceptance, user-decides): ≤ 2 % of a core while the menu is open.**
  It is computed from the installed app's `self` lines as Δ`menuOpenCpuSeconds` ÷
  Δ`menuOpenSeconds` over ≥ 60 s of real use. If it is missed, the owner decides between
  accepting the number and the 10 s fallback (T2).
- **Offscreen (rig check 5, functional): ≤ 1.0 % of a core, in-process**, over a 60 s
  simulated open with three group submenus opened in turn. The projection is ~0.6 %. This is a
  regression gate for the cadence and the single refresh. It can't see on-screen drawing.

**T5 · Not this slice: a cheaper sweep.**
- *Measured* (`/usr/bin/sample`, release headless):
  - `source.sweep()` 40 % of the engine's time, mostly `coalition_info` syscalls;
  - grouping 24 %;
  - JSON output 31 % (headless only);
  - detector 5 %.
- *Why defer:* with T2 and T3 the open cost falls from ~6 % to a projected ≤ 1.4 %. The idle
  cost sits at a 0.118 % median, under the 0.2 % budget. A sweep rewrite touches the
  measurement core that check 1 guards, right before the owner's trial days.
- The run records the measured sweep cost in DECISIONS.md, superseding v1-core § B's
  "1.7–5.1 ms".

**T6 · How the idle figure is computed (pure, testable).**
- The self-meter takes a reading at every base tick, **and at every menu open and close
  transition** on the engine queue. So each interval between two consecutive readings is
  either entirely open or entirely closed.
- The idle figure walks the intervals newest to oldest. It skips open ones and sums the
  closed ones' Δuptime and ΔCPU (`cpuSeconds + childCpuSeconds`) until the summed Δuptime
  reaches ≥ 600 s. The interval that crosses 600 s is included whole.
  - With < 60 s of closed time summed, the idle figure is `nil`: the footer prints `—` and
    the CPU part of the flag is off.
  - Otherwise it is ΣΔCPU ÷ ΣΔuptime × 100.
- Readings older than the oldest interval the window needs are dropped (memory stays bounded).
- `menuOpenCpuSeconds` = cumulative ΣΔCPU over open intervals since launch.
- A base tick that runs while the menu is open is counted as open time. That undercounts idle
  by ≤ 25 ms per 30 s of open time, which is negligible and accepted.

**T7 · "Today" reads from the engine's action rows, which mirror `history.sqlite`.**
- At history open, the engine loads the action rows of the last **9 days** (it loaded 2):
  enough for 7 local days plus a time-zone or DST margin. It appends each row it records.
- A row exists in memory only after its insert succeeded (v1-core § J step 2 writes the row
  before any signal; `history-off` means no row and no signal). So the in-memory list is
  always a subset of the file, and the Today row shows only what is durably recorded.
- Rows older than 9 days are dropped from memory at each base tick. Cooldown and maxPerDay
  already filter on 24 h, so their behaviour doesn't change.

**T8 · The summary's shape, for quits later.**
- `ActivityKind` has one case today, `restart`. `ActivitySummary.kind(of: ActionRow)` maps
  `target` `"wallpaper"` and `"rig-helper"` (the rig's DEBUG stand-in) to `.restart`, and any
  other target to `nil` (not counted, no crash).
- Day and total bodies list the kinds in `ActivityKind` declaration order, joined with ` · `.
  A kind with count 0 is omitted.
- **Decision for later (`v1-quit-on-close`; default stated):** that slice adds `.quit` and its
  row mapping, defines a quit's freed amount (default: the app's footprint at quit as
  `before_mb`, with `after_mb` 0), and words the all-zero body (default `nothing needed`).
- **Constraint written now:** any schema change from here on must migrate `actions` **in
  place**. The current "unknown version → move aside and start fresh" path would silently empty
  the record this row shows. The run writes this into DECISIONS.md.

**T9 · `--print-menu` does not read history.** v1-core § K says `--print-menu` never creates
or writes the state dir and takes no lock. Opening a WAL database can create `-shm` / `-wal`
files. So its Today row reads `Today: not recorded (not read by --print-menu)`. The row's real
proofs are the unit tests (real SQLite in a temp dir, reopened), the headless `activity` line
across a relaunch (rig check 4b), and the owner's screenshot.

**T10 · "Freed" and the counts, exactly.**
- **Rows:** `dry_run = 1` rows are ignored. Every other row whose kind is non-nil counts as one
  action of its kind, whatever its outcome (`pending`, `ok`, `no-improvement`, `agent-missing`,
  `extension-missing`, `interrupted`, `signalled`).
- **Failed:** outcome `agent-missing`, `extension-missing` or `no-improvement`. These already
  pause the rule (v1-core § J); the count keeps them visible later.
- **A row's freed amount:**
  - only when its outcome is `ok` or `no-improvement`, `after_mb` is non-null and `before_mb`
    > 0;
  - the amount is `(before_mb − after_mb)`, plus `(ws_before_mb − ws_after_mb)` when both are
    non-null (else + 0);
  - **signed**: a WindowServer that grew reduces it.
- **Per day:** freed = the sum of its rows' amounts, or `nil` when no row contributed. It is
  shown floored at 0.
- **Total:** the sum of the non-nil day amounts (`nil` if all are nil).
- **Days:** the local calendar day of `ts`, in `TimeZone.autoupdatingCurrent` (tests inject a
  zone).
- *Why:* this is the owner's definition, applied to the columns the actuator writes. Rows with
  no measured "after" (verify in flight, interrupted, extension never came back) still count as
  restarts, but they add nothing to "freed", because nothing was measured. Signed values are
  the honest reading of the log.
- *Check against the owner's two known restarts* (DECISIONS.md, 2026-11-05):
  - 15:36: (1,258 − 133) + (1,524 − 1,139) = 1,510 MB;
  - 16:13: (1,075.2 − 148.1) + (1,495.5 − 1,081.5) = 1,341.1 MB;
  - that day: `2 restarts · 2.8 GB freed`, plus any later restarts.

**T11 · "Not running" days.** A past day with no counted row and **no `system_samples` row**
reads `not running`. That covers days before the install and days the app wasn't running.
- *Why:* `no restarts` would claim Swapless was watching.
- `system_samples` is kept 30 days and indexed on `t`. Seven `LIMIT 1` range probes cost
  microseconds.
- Today is always "running": this engine is running, and its unflushed samples aren't in the
  file yet.

---

## Surfaces and files

```
Sources/SwaplessCore/Engine/SelfMeter.swift     S1: readings with open/closed intervals, idle %, open CPU,
                                                over-budget on idle %, the self line's new fields
Sources/SwaplessCore/Engine/Engine.swift        S1 readings at open/close · S2 5 s display cadence, displaySweeps
                                                counter · S3 9-day actions, coverage, activity state, `activity`
                                                JSON line, notRecorded reasons
Sources/SwaplessCore/History/Activity.swift     S3 (new): ActivityKind, DayActivity, ActivitySummary, ActivityState,
                                                kind(of:), summarize(...)
Sources/SwaplessCore/History/HistoryStore.swift S3: daysWithSamples(_:)
Sources/SwaplessCore/Menu/MenuModel.swift       S1 footer · S4 the Today row and its submenu
Sources/SwaplessCore/Engine/Config.swift        S5: SWAPLESS_RIG_MENU_OPEN
Sources/Swapless/MenuController.swift           S2: no own timer, login cached, no-rewrite apply, closed submenus not
                                                refilled, compressed cache per open submenu · S5 simulateOpen + counters
Sources/Swapless/NSMenuItem+Update.swift        S2 (new): the per-item "write only what changed" update, testable
Sources/Swapless/AppDelegate.swift              S5: the SWAPLESS_RIG_MENU_OPEN mode (no status item); the rig's
                                                jsonTypes set gains `menuOpen`, `menuOpenTail`
Sources/swapless-rig/Check34.swift              S5: check 4b (persistence across a relaunch)
Sources/swapless-rig/Check5.swift               S5: idle-figure agreement · the offscreen menu-open test
scripts/self-report.sh                          S5 (new): the installed app's self lines as a cost table
Tests/SwaplessCoreTests/SelfMeterTests.swift    new
Tests/SwaplessCoreTests/ActivityTests.swift     new
Tests/SwaplessCoreTests/HistoryStoreTests.swift + daysWithSamples, 9-day reload across a reopen
Tests/SwaplessCoreTests/MenuModelTests.swift    + footer idle, the Today row and submenu
Tests/SwaplessCoreTests/ConfigTests.swift       + SWAPLESS_RIG_MENU_OPEN validation
Tests/SwaplessAppTests/NSMenuItemUpdateTests.swift  new
docs/proof/v1-menu-today/                       the reports and outputs the PR cites (committed)
```

### S1 · Idle CPU and the open cost

- **`SelfMeter`:**
  - `read(uptime:menuOpenDuringInterval:)` records `(uptime, cpuTotal)` and labels the
    interval ending at this reading. The engine passes its `menuOpen` value **before** it
    toggles it at a transition, and its current value at a base tick.
  - **Seam for tests:** `read` gets the CPU from `sw_pid_rusage` and calls an internal
    `record(uptime: Double, cpuTotal: Double, footprint: UInt64, peak: UInt64,
    menuOpenDuringInterval: Bool) -> SelfReading`, which does everything else (intervals,
    trimming, idle %, open CPU). Tests drive `record` with synthetic values.
  - **Pure function:** `static func idlePercent(_ intervals: [(dt: Double, dcpu: Double, open:
    Bool)], window: Double = 600, minClosed: Double = 60) -> Double?`, newest last, per T6.
- **`SelfReading`** gains:
  - `cpuPercentIdle: Double?`;
  - `menuOpenCpuSeconds: Double`.

  `cpuPercent` (all-time, rolling 10 min) stays as it is.
- **Engine `setMenuOpen`:** on a real transition, take a reading with the old state, then
  toggle the state. `menuOpenSeconds` keeps its current meaning.
- **`overBudget(_:topMode:menuShown:)`:** CPU over = `cpuPercentIdle` > limit (0.2, or 0.6 in
  `top` mode); `nil` is not over. The footprint part is unchanged (30 / 40 MiB split).
- **Footer (`MenuModel.footer`):**
  - `Swapless <idle %.2f> % CPU idle · <MB> MB · measuring: full`, then the existing suffixes,
    unchanged;
  - with `cpuPercentIdle == nil`: `Swapless — % CPU idle · <MB> MB · …`;
  - no reading yet: as today (no CPU and MB part).
- **`self` line:** `SelfMeter.logLine(_ r: SelfReading, menuOpenSeconds: Double, displaySweeps:
  Int)` prints the v1-core § B line, unchanged, with these fields **appended in this order**:
  - ` cpuPct10mIdle=<3 decimals, or none>`;
  - ` menuOpenCpuSeconds=<3 decimals>`;
  - ` displaySweeps=<cumulative int>`.

  All are `.public`. The rig parses fields by key, so the existing parse keeps working.
- **`sample` JSON `self` object:** add `"cpuPercentIdle": number|null` and
  `"menuOpenCpuSeconds": number` after the existing keys.

### S2 · The open-menu refresh

- **Engine display sweeps:**
  - `static let displayInterval = 5.0`. The display timer is scheduled `deadline: .now()`
    (the first sweep runs right when the menu opens), repeating every `displayInterval`, with
    a leeway of 500 ms.
  - The v1-core rule "a display sweep within 1.0 s of a due base tick counts as that tick"
    is unchanged.
  - `public private(set) var displaySweeps: Int` counts every display-timer firing that
    sweeps, through either branch. `public private(set) var publishes: Int` counts every
    `onState` call. The app reads both with `engine.sync { (engine.displaySweeps,
    engine.publishes) }`.
- **`MenuController`:**
  - **No timer of its own.** Delete `refreshTimer`. The menu refreshes once in `menuWillOpen`
    (with the last published state), then once per `update(_:)` while open, which is once per
    engine publish.
  - **Login status:** `LoginItem.isEnabled` is read in `menuWillOpen` and after the
    `.toggleLogin` action, and cached. `refresh()` uses the cache.
  - **`apply`** updates existing items through `NSMenuItem.update(from:target:action:)` (new
    file). It writes `title`, `isEnabled`, `state` and `keyEquivalent` only when each differs.
    It writes `target`, `action` and `representedObject` only when the item's `MenuAction`
    differs from the current `ActionBox`'s action, or one of them is absent and the other
    isn't. It returns whether anything was written.

    The group-submenu logic (by identifier), removal and `NSMenu.reconcile` are unchanged.
    **One change in the `children` branch:** assign `ni.submenu`, `sub.delegate` and
    `sub.autoenablesItems` only when the submenu is created (`ni.submenu == nil`). An existing
    one is reused untouched, and only its rows are applied. This covers the Today row and the
    `+ N system processes` row.
  - **Closed group submenus are not refilled on refresh.** Delete the `else if let sub =
    ni.submenu, isOpen, sub.numberOfItems > 0 { fillGroupSubmenu(…) }` branch;
    `menuNeedsUpdate` fills a group submenu every time it is about to open.
  - **Compressed reads only as a group submenu opens.** `menuNeedsUpdate` reads them for that
    submenu's top-15 readable members and caches them per submenu (keyed by
    `ObjectIdentifier`). Refreshes of an open submenu reuse the cache; a member new since the
    open shows no compressed suffix. The cache entry is cleared in that submenu's
    `menuDidClose`, and all entries in the top menu's `menuDidClose`.

    `drawOffscreen` and `fillEverything` (rig paths) keep reading compressed values on every
    call, as today: they stand in for opens.
  - **Counters, for the rig:** `refreshCount` (each `refresh()` that ran) and
    `compressedReadBatches`. The latter is **+1 for each `menuNeedsUpdate` on a group submenu
    whose group exists in the current state**, even when none of its members is readable
    (WindowServer's group has none). The rig paths `drawOffscreen` and `fillEverything` don't
    count.
  - **`menuHasKeyEquivalent(_:for:target:action:)`** is implemented. It returns `false` for
    group submenus (identifier set), so AppKit's key-equivalent search never triggers
    `menuNeedsUpdate` and its compressed reads. For every other menu it returns `true`, the
    default behaviour, so ⌘Q keeps working.
  - **The on-screen walk's hold** (`AppDelegate.showSubmenuHold`, used only by
    `--on-screen-menu`) goes from 2.5 s to **6 s**, so a hold still spans a 5 s refresh. This
    is a code change only; the walk is never run in this slice.
- **Unchanged:** the v1-core open-submenu rule. While a submenu is open, only open group
  submenus are refreshed and the top level waits.

### S3 · Activity data

- **`Activity.swift`** (SwaplessCore, AppKit-free, all `Sendable` / `Equatable`):
  ```swift
  public enum ActivityKind: String, CaseIterable, Sendable { case restart }
  public struct ActivityCounts: Sendable, Equatable {
      public var byKind: [ActivityKind: Int]   // only kinds with a count > 0 are stored
      public var failed: Int; public var freedMB: Double?
  }
  public struct DayActivity: Sendable, Equatable {
      public var dayStart: Double          // unix time of the local midnight
      public var year: Int, month: Int, day: Int, weekday: Int   // in the summary's time zone
      public var running: Bool
      public var counts: ActivityCounts
  }
  public struct ActivitySummary: Sendable, Equatable {
      public var days: [DayActivity]       // 7 entries, today first
      public var total: ActivityCounts
      public static func kind(of row: ActionRow) -> ActivityKind?
      public static func summarize(actions: [ActionRow], sampleDays: Set<String>,
                                   now: Double, timeZone: TimeZone) -> ActivitySummary
  }
  public enum ActivityState: Sendable, Equatable {
      case notRecorded(reason: String)     // "history off" · "another Swapless is acting" ·
                                           // "not read by --print-menu"
      case summary(ActivitySummary)
  }
  ```
  `summarize` implements T10 and T11, with a gregorian calendar in `timeZone`. Day `i` (0 =
  today) is `startOfDay(now) − i days` via `Calendar.date(byAdding:)`, so DST days are 23 or
  25 h. A row whose `ts` falls outside the 7 days, future days included, is ignored.
- **`HistoryStore.daysWithSamples(_ ranges: [(start: Double, end: Double)]) -> Set<Double>?`.**
  For each range it runs `SELECT 1 FROM system_samples WHERE t >= ? AND t < ? LIMIT 1` and
  returns the `start` of each range with a row. It returns `nil` on an SQLite error, and never
  turns history off.
- **The engine keeps coverage keyed by local date strings** (`yyyy-MM-dd` in the zone used for
  the probe), not by `start` values. `summarize` takes `sampleDays: Set<String>` (its parameter
  is named that way, replacing `sampleDayStarts`) and matches each day by its own `yyyy-MM-dd`.
  So coverage probed before midnight, or before a time-zone change, still marks the right days
  when no new probe could run (for example, history off).
- **`EngineState.activity: ActivityState`**, initially `.notRecorded(reason: "history off")`.
- **The engine:**
  - **Loading:** `openHistory` loads `h.actions(since: now − 9 × 86400)`. Each base tick
    drops `recentActions` rows with `ts < now − 9 × 86400`.
  - **Coverage:** the 6 past local days' ranges are probed:
    - in `openHistory`;
    - after every successful flush;
    - at a publish whose local `startOfDay(now)` differs from the last probe's.

    On `nil` (error), the previous coverage is kept and one `.default` line is logged
    (category `history`). It is logged again only after a successful probe.
  - **Recomputing the state:** `recomputeActivity()` runs at the end of `openHistory` (after
    the 9-day load and the coverage probe), after `retryLock` takes over, at the three
    read-only call sites allowed in Out of scope (a recorded action, a verify outcome,
    `markInterrupted`), **right before the `activity` line is built**, and at every publish:
    - `observeOnly` → `.notRecorded("another Swapless is acting")`;
    - else, history never opened successfully in this run → `.notRecorded("history off")`;
    - else `.summary(ActivitySummary.summarize(actions: recentActions, sampleDays: coverage,
      now: Clock.wall(), timeZone: .autoupdatingCurrent))`.

    A history that turns off after opening keeps summarizing the in-memory rows (T7).
  - `oneShot` (`--print-menu`, `--dump-snapshot`) sets `.notRecorded("not read by
    --print-menu")`.
- **Headless `activity` line**, emitted right after a base tick's `sample` line, on the first
  base tick and whenever its content (everything but `t`) differs from the last one emitted:
  ```
  {"type":"activity","t":…,"recorded":true|false,"reason":null|"…",
   "days":[{"day":"2026-11-06","running":true,"restarts":2,"failed":0,"freedMB":2851.1|null}, …7, today first],
   "total":{"restarts":…,"failed":…,"freedMB":…|null}}
  ```
  - `day` is the local date as `yyyy-MM-dd`. `freedMB` is the **unfloored** sum, so tests see
    the sign.
  - `restarts` is `byKind[.restart] ?? 0`; `v1-quit-on-close` adds `quits`.
  - When `recorded` is false, `days` is `[]` and `total` is `null`.
  - Headless mode already emits every type (`EventSink(jsonTypes: nil)` in `Headless.swift`),
    so no change is needed there. The app's `EventSink` doesn't print `activity` (app mode prints
    only rig lines).

### S4 · The Today row in the menu

- **Position:** right after the rules section's separator (`sep.rules`): the row `today`, then
  a separator `sep.today`, then the footer. Everything else stays where it is.
- **`.notRecorded(reason)`:** `Today: not recorded (<reason>)`, disabled, no submenu.
- **`.summary(s)`:** title `Today: <body(s.days[0].counts)>`. It is **enabled** (so its
  submenu opens), has no action, and has `children`:
  - `today.day.0` … `today.day.6`: `<label>: <dayBody>`. The labels are:
    - 0: `Today`;
    - 1: `Yesterday`;
    - 2–6: `<weekday> <day> <month>` from the `DayActivity`'s components, with fixed English
      tables (`Sun`…`Sat` for weekday 1…7, `Jan`…`Dec`), e.g. `Tue 3 Nov`. No `DateFormatter`,
      so the label is always in the summary's own time zone;
  - `today.sep` (separator);
  - `today.total`: `7 days: <body(s.total)>`.
- **`dayBody`** = `not running` when `running` is false (only possible for days 1–6), else
  `body(counts)`.
- **`body(counts)`:**
  - no kind has a count > 0 → `no restarts`;
  - else the kinds in `ActivityKind` order, each with a count > 0, as `<n> restart` /
    `<n> restarts`. When `failed > 0`, append ` (<failed> failed)`. Then
    ` · <freed> freed` when `freedMB != nil`.
  - **`freed`:** `m = max(0, freedMB)`. When m ≥ 1024: `String(format: "%.1f GB", m / 1024)`;
    else `"\(Int(m.rounded())) MB"`.
- **Examples (exact):**
  - `Today: 2 restarts · 2.8 GB freed`
  - `Today: 1 restart`
  - `Today: 3 restarts (1 failed) · 2.1 GB freed`
  - `Today: no restarts`
  - `Tue 3 Nov: not running`
  - `7 days: 7 restarts · 8.9 GB freed`
  - `Today: not recorded (history off)`
- **In the app:** the row goes through the existing `children` submenu path in `apply` (no
  group identifier). So it is tracked as an open submenu and is not refreshed while open,
  which is fine for daily data. The day rows are disabled and informational.

### S5 · Rig, rig mode and the cost script

- **`SWAPLESS_RIG_MENU_OPEN=<S>`** (`Config`):
  - an integer 50…600, read in app mode only and ignored by every other mode (as
    `SWAPLESS_RIG_MENU_DRAWS` is), in both builds;
  - it can't be combined with `SWAPLESS_RIG_MENU_CYCLES`, `_SHOWS` or `_DRAWS`. Invalid → an
    `error` line and exit 2, like its siblings.
  - The app creates **no status item** in this mode, and the `start`, `rules`, `menuOpen`,
    `menuOpenTail` and `error` lines print to stdout.
- **The mode** (`AppDelegate` + `MenuController.simulateOpen`), on never-shown menus. Every
  delay is a `.common`-mode `Timer`.
  1. After the first sample, settle **32.5 s**, which puts the open off the 30 s base-tick grid.
     Read own CPU: `sw_pid_rusage` user+system+children,
     in ticks × timebase via `SelfMeter.ticksToSeconds`. Read `displaySweeps` and `publishes`.
  2. Call `menuWillOpen(menu)`. This sets `isOpen`, calls `engine.setMenuOpen(true)` and
     refreshes.
  3. At +5 s, +20 s and +35 s, "open" group submenu 0, 1, 2: the submenu of the 1st, 2nd and
     3rd group row, **looked up at that moment** from the menu's current items (a reorder may
     have replaced it). Call `menuNeedsUpdate(sub)`, then `menuWillOpen(sub)`. "Close" the same
     submenu object 10 s later with `menuDidClose(sub)`.
  4. At +S, call `menuDidClose(menu)`. Read CPU, `displaySweeps` and `publishes` again, and emit:
     `{"type":"menuOpen","seconds":S,"refreshes":…,"displaySweeps":<Δ>,"publishes":<Δ>,"compressedReadBatches":…,
     "submenusOpened":<count actually opened>,"cpuSecondsOpen":<Δ>,"cpuPercentOpen":<Δ/S×100>,"windows":<NSApp.windows.count>}`.
  5. 120 s later, read CPU again and emit
     `{"type":"menuOpenTail","seconds":120,"cpuSeconds":<Δ>,"cpuPercent":…}`. Keep running
     until `--duration`.
- **Check 5 additions** (they run in `--budget`, after the existing draw test):
  - **Idle agreement:** self line 3 must carry a numeric `cpuPct10mIdle`, with
    |`cpuPct10mIdle` − `cpuPct`| ≤ **0.02 percentage points**. `cpuPct` is the window's
    existing figure: Δps ÷ Δarrival, Check5.swift `window`. T6's "crossing interval included
    whole" may add the interval ending at line 1 (one sweep plus a flush). That is accepted:
    it would need ≥ ~0.17 s of CPU to break the tolerance. The window's menu was closed throughout:
    the disturbance rule re-measures otherwise. A missing field or `none` is FAIL `self-report`.
  - **Menu-open test:**
    - **Setup:** run `./Swapless.app/Contents/MacOS/Swapless` (release, app mode) with a temp
      state dir, empty rules, `SWAPLESS_DRY_RUN=1`, `SWAPLESS_RIG_MENU_OPEN=60` and
      `--duration 360`. It goes through the same start-line guard as the draw test: `dryRun`
      true, `stateDir` equal to the temp dir, rules status `ok`. Otherwise SIGTERM and FAIL.
    - **Deadlines:** `menuOpen` within 180 s of start, `menuOpenTail` within 330 s; otherwise
      FAIL `TIMEOUT` with the `/usr/bin/log show --predicate 'processID == <pid>'` hint, as
      the draw test does. If the app exits before a line arrives, FAIL `exited early (status
      N)` instead. The rig stops the process (SIGTERM) on every exit path.
    - **Pass:**
      - `displaySweeps` ∈ [12, 13] (5 s cadence over 60 s; it was 30–31 at 2 s);
      - `publishes` ≤ `displaySweeps` + 2 (up to two base-tick publishes not absorbed by a
        display sweep);
      - `refreshes` ≤ `publishes` + 1 (the open refresh; no timer-driven refreshes);
      - `compressedReadBatches` == 3;
      - `cpuPercentOpen` ≤ **1.0**;
      - `menuOpenTail.cpuPercent` ≤ **0.3** (a tail sentinel; expected ~0.1 %);
      - `windows` == 0.
    - The report line carries every number plus `(offscreen: the on-screen cost is the
      owner's acceptance)`.
- **Check 4b, persistence across a relaunch** (inside check 4, after its main engine has
  exited: the rig stops it with `engine.child.stop()` once B exits, and the engine flushes
  history on SIGTERM, v1-core § K; the rig waits for that exit, with a deadline, before 4b):
  - **Setup:** start a **debug** headless engine on **check 4's state dir**, with the same
    `rules.json` and the same environment as check 4's main engine (`SWAPLESS_RIG_HELPER_PATH`
    and `SWAPLESS_SAMPLE_INTERVAL=1` included), plus `--duration 4`. No helper is running, so
    its rule reports `target-absent`.
  - **Pass:**
    - its first `activity` line arrives within 10 s (else FAIL `TIMEOUT`);
    - `recorded` is true;
    - `total.restarts` == 1, `total.failed` == 0, `total.freedMB` == null;
    - `days` has 7 entries, and `days[0].running` is true.
  - The check-4 engine's own last `activity` line before exit must also show `total.restarts`
    == 1. Totals are used, not "today", so a run that crosses midnight still passes.
  - Check 4's existing assertions are unchanged.
- **`scripts/self-report.sh [--since 'YYYY-MM-DD HH:MM:SS']`:**
  - **Input:** it reads the **installed app's** `self` lines with `/usr/bin/log show --start
    <since> --predicate '<check 5's self predicate>' --info --style compact`. The default
    `--since` is the running installed app's start time (`ps -o lstart=`), else today 00:00.
  - **Output:** for each pair of consecutive lines **from the same pid**, one row: end time,
    Δwall, ΔCPU (cpu + child), Δ`menuOpenSeconds`, Δ`menuOpenCpuSeconds`, then:
    - closed CPU % = (ΔCPU − Δopen CPU) ÷ (Δwall − Δopen s);
    - open CPU % = Δopen CPU ÷ Δopen s, only when Δopen s ≥ 1;
    - the line's `cpuPct10mIdle`.

    When Δwall − Δopen s == 0, closed % is `n/a`. Lines without the new fields (old builds) show closed % only when Δopen s == 0, and `n/a`
    otherwise. A last row sums all pairs: total open s, open CPU % and closed CPU %.
  - Exit 0, or 1 when no lines match.
  - It never reads the state dir and never signals anything. All waits are `log show` (finite).

---

## Edge cases

- **Launch:** the idle figure is `—` until 60 s of closed time is measured (two base ticks
  after launch, if the menu stays closed). The flag can't light from CPU until then.
- **The menu open for > 10 min:** the idle figure uses the closed time before the open
  session. With < 60 s of it, `—`.
- **`top` fallback mode:** the idle limit is 0.6 %, as before.
- **Sleep:** uptime stops (`DispatchTime`), so no interval spans the sleep. The first display
  sweep after wake is just a sweep.
- **A verify in flight while the menu is open:** `verifyTick` publishes only once, when the
  outcome lands, so the menu refreshes once more then. No rules act in the rig mode, so its
  counters never see it.
- **The menu open across midnight:** the next publish recomputes Today: yesterday's numbers
  move to `Yesterday`, and the new day's coverage is probed then.
- **A time-zone change:** `TimeZone.autoupdatingCurrent` at each recompute. Rows re-bucket
  into the new zone's days.
- **The clock set backwards or forwards:** rows land on the local day of their `ts`. Rows
  beyond today or before day 6 are ignored.
- **A restart still verifying:** it counts as a restart, with no freed amount until the outcome
  lands. `Today: 1 restart` until then.
- **`interrupted`, `agent-missing`, `extension-missing`:** counted. The last two count as
  failed. No freed amount.
- **`no-improvement` with after ≥ before, or WindowServer grew more than the extension
  shrank:** a negative amount. The day shows `0 MB freed` when its sum is ≤ 0; the `activity`
  line keeps the sign.
- **`ws_before_mb` or `ws_after_mb` null:** the extension part alone.
- **`before_mb` null in the file** (never written by the actuator): it decodes as 0, so no
  freed amount.
- **Only dry-run rows on a day:** `no restarts` (or `not running` if there are no samples).
- **History off from launch** (unwritable dir, SQLite error): `Today: not recorded (history
  off)`. The footer already shows `history off: <error>`.
- **History turns off later:** Today keeps showing the in-memory rows (all written before).
  Coverage keeps its last value.
- **Observe-only (a second engine on the same dir):** `Today: not recorded (another Swapless
  is acting)`, until it takes over the lock and opens history.
- **The history file was reset** (`.bak-<unix>`, v1-core § C): earlier days read `not
  running`. The `.bak` file is not read.
- **The first launch of this build on the owner's Mac:** the existing v1 file is read as is
  (schema unchanged). The owner's 2026-11-05 restarts appear under their local day.
- **A day with samples but no actions:** `no restarts`.
- **No group submenu was ever opened:** no compressed reads at all while the menu is open.
- **A group's submenu open while the groups reorder:** v1-core's rule holds: the top level
  waits, and the open submenu refreshes in place with its cached compressed values.

---

## Verification plan

Every surface has a gate, and gates are run, not assumed. Tests use Swift Testing, temp state
dirs (`makeTempDir()`), injected time zones and fixed `now` values. They never use the real
state dir or the system time zone.

| Surface | Check type | Gate |
|---|---|---|
| S1 idle CPU | functional | `swift test` `SelfMeterTests`: `idlePercent` over synthetic intervals: all closed (exact %); an open interval in the middle excluded; the 600 s window crossing an interval (included whole); < 60 s closed → nil; only open intervals → nil; closed time before a 15-min open session counts. `menuOpenCpuSeconds` sums open intervals only. `overBudget` (in `SelfMeterTests`; the flag stays computed in `Engine.publish`): idle 0.25 → over; `cpuPercent` 0.5 with idle 0.1 → **not** over; idle nil → not over (CPU); idle 0.5 in top mode → not over; footprint split unchanged. Intervals, trimming and `menuOpenCpuSeconds` are driven through `record(…)`. The `self` line's exact text with the three appended fields (`none` for nil). `MenuModelTests`: the footer with idle 0.11 → `Swapless 0.11 % CPU idle · 33 MB · measuring: full`; nil → `Swapless — % CPU idle · …`; `· over budget` printed when `overBudget` is true (rendering only). **Rig `--budget`:** check 5's idle agreement. |
| S2 refresh | functional | `swift test` `NSMenuItemUpdateTests` (SwaplessAppTests, never-shown `NSMenu`). The item is a test subclass of `NSMenuItem` that counts calls to the `title`, `isEnabled`, `state`, `keyEquivalent`, `target`, `action`, `representedObject` and `submenu` setters, a deterministic check that doesn't depend on AppKit notifications. A second `update(from:)` with an identical `MenuItem` returns false with **0** setter calls; a changed title returns true with exactly 1 call (`title`); an unchanged action keeps the same `ActionBox` instance. Re-applying a row with `children` through `MenuController`'s apply path makes 0 `submenu` setter calls. **Rig `--budget`:** check 5's menu-open test (displaySweeps, refreshes, compressedReadBatches, ≤ 1.0 %, tail ≤ 0.3 %, 0 windows). |
| S3 activity | functional | `swift test` `ActivityTests`: kind mapping (`wallpaper`, `rig-helper` → restart; `foo` → nil); dry runs ignored; every outcome counted; failed = the three outcomes; freed signed with WindowServer; WindowServer nil → extension only; `pending`/`interrupted` → no freed; the owner's two 2026-11-05 rows → 2851.1 MB on that day (compared within 1e-6); a negative day sum kept unfloored in the struct; 7 days today first; a row at 23:59:59 and one at 00:00:00 on different days in `America/Mexico_City`; the **DST day** 2026-11-01 in `America/Chicago` (25 h; rows at 00:30 and 23:30 local both on Nov 1); future and > 6-days-old rows ignored; `running` from coverage and from rows, and today always running; total = sum. `HistoryStoreTests`: `daysWithSamples` with rows in 2 of 3 ranges; actions written by one store and read back after a close and reopen over 9 days. **Rig `--budget`** runs check 4b. |
| S4 menu rows | functional + user-decides | `swift test` `MenuModelTests`: every example string in S4; the day labels `Today`, `Yesterday`, `Tue 3 Nov` (fixed zone and `now`); `7 days:` after the separator; `not recorded (…)` for each reason, disabled, with no children; the row's position (after `sep.rules`, then `sep.today`, then the footer); `MenuModel.text` indents the 9 children. **User-decides at acceptance:** the menu screenshot with the Today row and its open submenu. |
| S5 rig + script | functional | `./scripts/leak-rig.sh --budget` exits 0 with checks 1–5, 4b and the new check 5 lines in the report. `./scripts/self-report.sh` run by the agent against the installed app **after** the `--budget` run, when ≥ 3 self lines exist (it reads the unified log, not the folder); output in `docs/proof/v1-menu-today/`. `ConfigTests`: `SWAPLESS_RIG_MENU_OPEN` 49 / 601 / `x` / combined with `_CYCLES`, `_SHOWS` or `_DRAWS` → error; 60 in app mode → ok; any value is ignored (no error, `nil`) by `--headless`, as `_DRAWS` is. |
| On-screen cost | user-decides, at acceptance | After re-signing: the owner uses the menu normally (≥ 5 opens, ≥ 60 s open in total, 3 group submenus hovered), then leaves it closed ≥ 10 min, then opens it once. **Pass:** the footer never showed `over budget`. `./scripts/self-report.sh` shows open CPU ≤ **2 %** over the session, and closed CPU ≤ 0.2 % on the line ≥ 10 min after the last close (no tail). Miss either → the owner decides (T2's 10 s fallback, or a follow-up for the tail). |
| Today numbers | user-decides, at acceptance | The Today row and its submenu match the owner's own read-only query (the agent never runs it): `sqlite3 -readonly "$HOME/Library/Application Support/Swapless/history.sqlite" "SELECT datetime(ts,'unixepoch','localtime'), outcome, before_mb, after_mb, ws_before_mb, ws_after_mb FROM actions WHERE dry_run=0 AND ts >= strftime('%s','now','-8 days') ORDER BY ts"` (in the PR checklist). |
| Whole slice | functional | `swift build && swift test && ./scripts/make-app.sh release --adhoc && ./scripts/leak-rig.sh --budget` exits 0. `docs/proof/v1-menu-today/` holds the `--budget` report, the `self-report.sh` output, and a `--print-menu` text from a temp state dir with the v1-core seed (it shows `Today: not recorded (not read by --print-menu)`). |

---

## Brakes (for the unattended run)

**One surface per pass, in this order. Each pass ends green on its gate before the next
starts:**
- **P1** · S1 (SelfMeter, engine readings at transitions, footer, over budget, `self` line,
  `sample` fields) → `swift test`.
- **P2** · S2 (engine 5 s cadence and counter; MenuController; `NSMenuItem+Update.swift`) →
  `swift test` + `swift build -c release`.
- **P3** · S3 + S4 (Activity, HistoryStore probe, engine wiring, `activity` line, menu rows)
  **and check 4b** in `Check34.swift` (though S5 describes it) → `swift test` +
  `./scripts/leak-rig.sh --only 3,4`.
- **P4** · S5 (Config, rig mode, check 5 additions, `self-report.sh`), then the whole-slice
  gate, the proofs, the DECISIONS.md entries below, then **`/save-task` (a draft PR)**.
  - The PR body opens with the owner's acceptance checklist:
    1. `./scripts/make-app.sh release` (re-sign), `codesign -dv /Applications/Swapless.app`
       shows `Authority=Swapless Self-Signed`, and the menu's `Open at login` is still
       checked;
    2. the menu screenshot with Today and its open submenu;
    3. the on-screen cost session and the `self-report.sh` numbers;
    4. the `sqlite3` cross-check.
  - **Never run `/ship-task`, `gh pr ready` or `gh pr merge`.**
- **Existing tests this slice is expected to update** (this is not loosening a gate):
  `MeasurementTests` `overBudget` (cpu 0.25 → over now depends on idle) and the exact
  `selfLineFormat` string; the `MenuModelTests` footer strings; the `SelfReading(...)` memberwise
  calls. Their new expected values come from S1.
- `leak-rig.sh` always runs with `run_in_background`, never under a foreground timeout
  (`--budget` takes ~20 min now). Every wait the run adds to the rig or the scripts has a
  deadline that fails loudly (`TIMEOUT`). One rig at a time (`rig.lock`), and no `swift build`
  while a rig runs.

**Stop and report, without working around it, if:**
- `--budget` fails after **one** focused attempt on the failing part. Report the numbers.
  Don't loosen a limit in this spec, and don't change the 5 s cadence.
- Any change would need to touch the rule evaluator, the actuator, `RestartTarget`,
  `SignalGuard`, `LiveSignalSender`, the verify loop or the § I property test.
- Any change would need `schema_version` ≠ `1`, a new column, or the reset path.
- Anything would read, copy or open `~/Library/Application Support/Swapless` other than the
  installed app itself. That includes `sqlite3` and `ls` of its contents. The cross-check query
  is the owner's.
- Anything would put Swapless UI on the owner's screen: a status item in a test mode, a window
  ordered front, `--on-screen-menu`, or opening the installed app's menu. Likewise anything that
  needs a keychain prompt, `make-cert.sh`, signing with the self-signed identity, sudo, a TCC
  grant, a LaunchAgent or a login item.
- v1-core checks 1–4 regress.
- The self-check fails on this Mac, or a final run's `source` is `top` (other than check 1's
  forced run).

**Never touch:**
- the owner's state dir (above);
- any process other than the rig's own engines and helpers and the installed app via
  `make-app.sh`'s exact-path stop. Never SIGKILL;
- the wallpaper pair (`--live-wallpaper` is not run in this slice) and the simulators (`--sim`
  is not run);
- `main` (PR only);
- `.claude/`, `specs/README.md`, `specs/v1-core.md`;
- secrets, args or env of other processes, in any output, log, fixture or proof.

**DECISIONS.md in P4:** the 2026-11-06 entry `v1-menu-today: …` already exists, written in the
`/wingman` session. It records the owner's calls, the sweep cost, the 5 s cadence, the limits,
T8's constraint and the open tail question. **Amend that entry** with the run's measured
results (check 5's `cpuPercentOpen`, the tail, the idle agreement) and any reading the spec
left open. Don't add a second entry, except for a mandatory trigger below.

**Committing:** the first `/save-task` stages these files explicitly, together with the code:
`specs/v1-menu-today.md`, `docs/research/2026-11-05-menu-cost-probes.md`, `DECISIONS.md` and
`CLAUDE.md` (all from the `/wingman` session, if not committed yet). **Never stage anything
under `.claude/`** (for example the untracked `.claude/routing-log.jsonl`).
- **Mandatory triggers** (DECISIONS.md header): a check SKIPs or FAILs in the final report; a
  final run's `source` was `top`; Swapless signalled a process outside an owner-approved rule
  (the only ones here are check 4's own rig helper and the installed app's seeded guard); a
  user app was affected; the build exceeded its budget.

**Final acceptance and shipping are the owner's** (the PR checklist). After shipping, the owner
runs `/init-task v1-quit-on-close`. T8 is that slice's starting point for the Today row.

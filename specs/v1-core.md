# v1-core: the sampler, the real culprits in the menu, and the wallpaper guard

Branch `v1-core` · written 2026-11-05 in a `/wingman` session · **slice 1 of v1** · this file
is the only input for the implementation run. Revision 5: it folds in four readiness-gate
rounds, adversarially verified. Findings went 59 → 36 → 13 → 4; the last two rounds had no
blockers.

Conventions used throughout:
- **MB / GB mean MiB / GiB** (1,048,576 / 1,073,741,824 bytes). Activity Monitor, `top` and
  `footprint` print the same units (measured: `top` "305M" = 319,538,448 B).
- **"This Mac"** is the MacBook Pro M1 Pro, 16 GB, macOS 27.2 (26B123), Xcode 27.1, Swift 6.4,
  `mach_timebase_info` = 125/3.
- **"Probe"** marks a number measured on this Mac on 2026-11-05. The numbers are copied into
  `docs/research/2026-11-05-v1-core-probes.md`.

Section names follow the `specs/README.md` skeleton, in English as DECISIONS.md requires:
Objective = Objetivo, Out of scope = Fuera de alcance, Decisions and why = Decisiones y
porqués, Surfaces and files = Superficies y archivos, Edge cases, Verification plan = Plan de
verificación, Brakes = Frenos.

---

## Objective

Ship the first runnable Swapless: a native AppKit menu-bar app that samples **every** process
every 30 s with the number Activity Monitor shows (physical footprint, root and `/System`
processes included), groups the processes into what the owner calls apps, and lists the
biggest groups in its menu. **Safari Web Content processes, each Claude Code session and each
booted simulator get their own named lines, for display only.** From day one it records the
system memory signals (free %, pressure, compressed, swap, swap-in rate) and 5-minute
footprint history, and it flags processes that grow like a leak. It also quietly restarts
macOS's leaking wallpaper extension once it passes 1 GB, which is the only rule in this slice.
Nothing else is ever quit, restarted or signalled.

The unattended run is **done** when this passes on the branch:
```
swift build && swift test && ./scripts/make-app.sh release --adhoc && ./scripts/leak-rig.sh --budget
```
That means:
- footprints match `top`;
- a growing helper is flagged, and flat or sawtooth helpers are not;
- nothing is acted on without a rule;
- the ruled action happens exactly once and respects its cooldown;
- Swapless stays inside its own overhead budget.

The run also needs `--sim` and `--live-wallpaper` attempted once each, with their output in the
PR (PASS, SKIP, or a `--sim` FAIL handled as check 6 says), and a **draft** PR open. The owner
accepts and ships (Brakes).

### Where this slice sits in v1 (context, not a contract)

| Slice | Content | Lets the owner retire |
|---|---|---|
| **1 · v1-core** (this spec) | Sampler, culprits in the menu, growth flags, recording, the wallpaper guard | — |
| 2 · alerts | Notifications for swap-in rate (thresholds calibrated on slice 1's recorded data), a confirmed leak slope and "critical"; one-click fixes; the "what grows" map and history views; **whether a Claude session or a Safari tab may ever be offered as a fix** | mac-memory-guard |
| 3 · rules editor | Per-app rules UI (tell / restart / quit / quit when idle), thresholds, exceptions; graceful `quit` | MagicQuit's idle quit |
| 4 · quit on last window | The Notes and Slack probe first, then the test app and the AX ledger | MagicQuit |

---

## Out of scope

- **Any notification or alert.** No Notification Center and no dialogs; the menu-bar dot is the
  only signal (slice 2).
- **Any action on anything but the wallpaper pair.** Claude Code sessions, Safari Web Content,
  simulators and every user app are **displayed only**. The actuator cannot even express
  another target (§ J). Whether they may ever be offered as a fix is decided in slice 2, and
  **the default is never**.
- Rule types other than `restart` on the code allowlist: no `tell`, `quit`, `quit when idle`
  or per-app exceptions. No rules editor UI (slice 3).
- Quit on last window close, Accessibility, AX observers (slice 4).
- The "what grows" map, per-app history charts, group-level growth detection (slice 2). The
  data for them **is** recorded here.
- Calibrating alert thresholds (slice 2 does it from the data recorded here).
- Per-site Safari labels. They need a private LaunchServices entitlement and are out of reach.
- Per-process numbers for other users' processes inside a multi-member coalition. Only the
  coalition total is readable without privileges.
- Per-app CPU attribution (Portal's 50 % CPU, for example). Only Swapless's own CPU is
  measured.
- macOS < 27, Intel, notarization, auto-update, distribution.
- **Running `make-cert.sh`**, which raises a keychain prompt and is human-only (CLAUDE.md §5).
  The script is written; the owner runs it.
- **Turning on Open at login.** The app ships the toggle; only the owner flips it. Agents never
  install LaunchAgents or login items.
- **Shipping the PR** (`/ship-task`, `gh pr ready`, `gh pr merge`). The owner ships.
- Uninstalling MagicQuit or mac-memory-guard. That's a human step, after slices 2–4.
- Editing `specs/README.md` or `.claude/commands/wingman.md`, which still carry Spanish section
  names. That harness drift goes to the owner.

---

## Decisions and why

### Owner calls (2026-11-05, this session)

1. **The wallpaper guard is ON from first launch.** The owner decided on 2026-11-05 that v1
   restarts the leaking wallpaper quietly (DECISIONS.md, "What v1 is"), and that decision **is**
   the owner's rule. On the installed app's first launch it is written into `rules.json` with
   that date as its source, and shown in the menu with a toggle. *Why:* it must work without
   the owner having to remember a click.
2. **Restart threshold: 1 GB** of WallpaperImageExtension footprint. It idles at ~110 MB and
   leaked ~145 MB/h while Portal played (3.3 GB after ~22 h). That works out to about one
   restart per 6 h of Portal use, ~4 a day. The leak also inflates WindowServer by ~1 GB
   (2.3 → 1.2 GB after a restart), so 1 GB caps the combined cost near 2 GB. The owner can edit
   it in `rules.json`.
3. **Attribution is display-only, all three in slice 1:** Safari Web Content per process, each
   Claude Code session with its MCP children, and each booted simulator. The owner was worried
   about Claude sessions being closed without warning. In this slice they are only named.
4. **Acting on Claude sessions or Safari tabs is deferred to slice 2, default never.** In the
   owner's words, it "deserves some thought" (killing a Web Content process reloads a tab the
   owner may be reading). Until slice 2 decides, they are named only: never acted on, never
   offered as a fix.
5. **The menu-bar item is the icon only, plus a dot when needed.** Normal: a template
   memory-chip icon. The dot appears when a flagged series is **not** covered by an enabled
   rule, when Swapless acted, or when a rule got paused. It clears when the owner opens the
   menu. A leak the guard is already handling is not actionable, so it doesn't light the dot
   (wall: "quiet unless actionable").
6. **v1 slice order** as in the table above: proposed in this session, and the owner did not
   object. Only slice 1 is a contract; the rest stays in DECISIONS.md's Open list.
7. **The unattended run may execute `--sim` and `--live-wallpaper` once each without asking**
   (the owner answered "yes, both" in this session):
   - `--sim` boots and shuts down a simulator;
   - `--live-wallpaper` does one real restart of the wallpaper pair, under a rig-written
     copy of call 1's rule with `footprintAboveMB` = ⌊C⌋ − 100 (Portal running, extension
     ≥ 400 MB).

   Each runs under its preconditions in S6. If either SKIPs, it goes on the PR's pending
   list. *Why:* the installed app will do the same restart on its own anyway, and a live
   proof beats a compile-only one.

### Technical calls: the Open items this slice settles (argued)

**A · Private APIs: yes, behind a self-check, with a `top` fallback.**
- *Why:* "Measure what Activity Monitor measures … including root-owned and `/System` ones"
  can't be met unprivileged any other way. 239 of ~680 processes (root plus other uids,
  WindowServer among them) refuse `proc_pid_rusage` with EPERM. The only alternative is
  setuid `top` at ~260 ms of CPU per run, ~250× the native sweep. Swapless is a private app
  for one Mac, so private symbols carry no App Store risk.
- *What this Mac showed (probe):*
  - **Byte-exact on 290 of 290 single-member coalitions.** `coalition_info_resource_usage` was
    compared with `ri_phys_footprint` for every same-user coalition with one live task.
  - **Within `top`'s rounding on 220 of 220 all-system coalitions** (max diff 0.48 MB).
    WindowServer's coalition reads 1186.2 MB against `top`'s 1173 + 13 MB for WindowServer +
    MTLCompilerService.
- **The private symbols, touched only in the C shim (`CSwaplessProc`, `dlsym` under
  `pthread_once`):**
  - `coalition_info_resource_usage(uint64_t cid, void *buf, size_t size)`. The kernel struct
    is **400 bytes** on 27.2, and a buffer that is too small is **silently truncated with
    rc=0**. So: pass a **zero-filled 1024-byte buffer**, then decode it with a pure function
    `sw_decode_usage(buf, len, &footprint, &started, &exited)` that reads `phys_footprint` at
    **byte offset 320** (uint64 index 40), `tasks_started` at index 0 and `tasks_exited` at
    index 1. It reports **layout drift** when `cpu_time_eqos_len` (index 23) ≠ 7.
  - `responsibility_get_pid_responsible_for_pid`, signature **`pid_t f(pid_t)`**; it returns
    −1 for unknown or other-uid pids. `docs/research/probes/probe.c` misreads it with a
    4-argument prototype, so don't copy that one. It is used **only for labels**.
- **Shim return codes:** 0 ok · `-ESRCH` the coalition is gone (skip it) · **−1000** symbol
  missing · **−1001** layout drift · any other `-errno`.
- **Public calls used next to them:**
  - `proc_pidinfo(pid, 20 /* PROC_PIDCOALITIONINFO */)`. It works for every pid;
    `coalition_id[0]` is the resource coalition and `[1]` the jetsam coalition.
  - `proc_pid_rusage(RUSAGE_INFO_V4)`, for same-user pids.
  - One `sysctl {CTL_KERN, KERN_PROC, KERN_PROC_ALL}` per sweep. It gives pid, ppid, euid
    (`e_ucred.cr_uid`) and `p_starttime` for **every** pid in ~0.08 ms.
- **Self-check:**
  - **When:** at launch, every hour, and after wake.
  - **Test (a):** pick up to 10 same-user coalitions whose `tasks_started − tasks_exited == 1`
    and whose single observed member is readable, largest footprint first. For each, read
    rusage, then coalition, then rusage again. A coalition **passes** if its value lies within
    [min, max] of the two rusage readings.
  - **Test (b):** the shim must return 0 on **WindowServer's** coalition (`coalition_id[0]` of
    the pid whose path ends in `/WindowServer`), with a footprint ≥ 50 MB. When the self-check
    is skipped or the symbol is missing, the `start` line reports `windowServer` with the same
    value as `coalition`, and `checked` / `passed` as 0.
  - **Pass:** (a) has ≥ 5 checked and ≥ 90 % passing, **and** (b) passes. Then the source is
    `coalition`.
  - **Fail, symbol missing or drift:** the source is `top` (degraded). The menu says so, and a
    `.default` log line says why. So does any negative return other than `-ESRCH` on an
    all-system coalition in 2 consecutive sweeps.
  - **Responsibility check:** `sw_responsible_pid(getpid())` must be > 0. Otherwise labels fall
    back to the path heuristics (§ G), and nothing else changes.
- **`top` fallback:**
  - **Command:** `/usr/bin/top -l 1 -stats pid,mem`. `-pid` filtering costs the same, so don't
    bother.
  - **When:** synchronously before the first sample is published, then every max(60 s, base
    interval).
  - **Parsing:** find the line starting with `PID` and split rows on whitespace. **Never** skip
    a fixed number of header lines: the header is 9–12 lines depending on flags. MEM is an
    integer plus `B`/`K`/`M`/`G` in powers of 1024; accept and ignore a trailing `+`/`-`.
    `G` appears only at ≥ 10000 MB and is accurate to 1 GB.
  - **Use:**
    - `top` fills in **only** the unreadable pids; same-user pids keep `proc_pid_rusage`.
    - Between runs, an unreadable pid keeps its last `top` value. A pid absent from the last
      run has footprint `null`.
    - `top`-filled members are `readable: false` with a number.
    - Group totals in `top` mode: § G.
  - **Flags and failures:**
    - `SWAPLESS_FORCE_TOP=1` skips the self-check (`selfCheck.coalition: "skipped"`).
    - If `top` itself fails (non-zero exit or no `PID` header), `source` is `"none"`, an
      `error` line is emitted, and unreadable footprints are `null`.

**B · Sampling interval and overhead budget.**
- **Base interval: 30 s.** `SWAPLESS_SAMPLE_INTERVAL` overrides it (seconds, float, ≥ 0.25).
  The timer is a `DispatchSourceTimer` with leeway min(3 s, 10 % of the interval).
  - *Why 30 s:* it is the research's leak-detection grain (5-minute min-buckets) and the
    swap-in sampling interval.
  - A sweep costs **1.7–5.1 ms CPU** (probe), ~0.02 % of a core at 30 s, so going faster
    buys nothing for leaks that take hours.
- **While the menu is open: a sweep every 2 s, for display only.** Only base ticks feed
  `system_samples` rows, detector buckets and the rules' consecutive-sample counts. A 2 s
  sweep that lands on a due base tick counts as that tick.
- **Budget**, enforced by the rig (`--budget`, check 5):
  - **installed app, menu closed, base interval 30 s, measured over 10 min:**
    - average CPU **≤ 0.2 % of one core** (≤ 1.2 s of CPU in 10 min);
    - footprint **≤ 30 MB** at the end of the window;
    - its `phys_footprint_peak` **≤ 40 MB**;
  - **peak test:** a release app-mode run that builds the real `NSMenu` 20 times
    (`SWAPLESS_RIG_MENU_CYCLES=20`) must keep `ri_lifetime_max_phys_footprint` **≤ 40 MB**.
  - **in `top` fallback mode:** CPU ≤ 0.6 % (one `top` per 60 s ≈ 0.45 %), counting reaped
    children. The footprint budget is unchanged.
  - *Why these numbers (probe):* a minimal AppKit `NSStatusItem` + `NSMenu` app settles at
    **16 MB**. Adding SQLite and 3 MB of history: **20 MB**. The incumbents: MagicQuit 27 MB and
    **1.12 %** of a core, TypeFlow 61 MB and 1.37 %, Tailscale/ZeroTier ~0.1 %. Swapless must
    cost less than the app it replaces. CPU has ~10× headroom over a measured sweep. Footprint
    has 10–14 MB over a floor that was measured with the menu never opened, which is what
    the peak test covers.
- **Self-meter.**
  - **Values:** `cpuSeconds` is cumulative own user+system CPU (`ri_user_time` +
    `ri_system_time`); `childCpuSeconds` is cumulative reaped children (`ri_child_user_time` +
    `ri_child_system_time`), which is where `top` runs land.
  - **CPU time is in mach ticks:** multiply by `mach_timebase_info` numer/denom (125/3 here).
    Read as ns, the values undercount 41×, and a unit test pins this down.
  - **Menu footer:** the CPU % is Δ(cpuSeconds + childCpuSeconds) over a rolling 10 min, next
    to `ri_phys_footprint`. It adds "over budget" when either exceeds its limit.
  - **Log line:** on every base tick whose `seq` is a multiple of 10, tick 0 included (every
    300 s at the default interval). It is never driven by comparing elapsed time. It goes at
    `.default`, category `self`, all values public, exactly:
    `self cpuSeconds=<3 decimals> childCpuSeconds=<3 decimals> cpuPct10m=<3 decimals> footprint=<bytes> peak=<bytes> menuOpenSeconds=<cumulative, 1 decimal>`.

**C · Where samples and rules live.** Everything lives under the **state dir**: by default
`~/Library/Application Support/Swapless/`. `SWAPLESS_STATE_DIR` overrides it.
- **Only the release menu app may use the default state dir.** These exit 2 with an `error`
  line when `SWAPLESS_STATE_DIR` is unset, or when it resolves (standardized, symlinks
  resolved) to the default path:
  - `--headless`, `--print-menu` and `--dump-snapshot`, in any build;
  - every mode of a DEBUG build.

  So nothing but the installed app ever creates or touches the owner's real state, and owner
  call 1's seed is guaranteed to happen on that app's first launch.
- **Testability seam.** `Config`, the state-dir refusal and the seeder never compute the
  default path or the build flavour themselves. They take two parameters:
  - `defaultStateDir: URL`;
  - `flavour: (isRelease: Bool, mode: menuApp | headless | printMenu | dumpSnapshot)`.

  Only `main.swift` passes the real `~/Library/Application Support/Swapless` and the
  compile-time `#if DEBUG` value. Unit tests pass `<fresh temp dir>/Application
  Support/Swapless` as the default and exercise every flavour, release + menu app included.
  The refusal is decided **before** any `mkdir`, `flock`, file open or SQLite open. No test,
  fixture or binary invocation is ever given, or touches, the real path, except the installed
  app as `make-app.sh` launches it.
- **Paths:** the `start` line prints `stateDir` exactly as received in the env. The rig's
  start-line guard compares `realpath()` of both sides, because `/var` is a symlink to
  `/private/var` on this Mac.
- **`rules.json`: the owner's rules, a JSON file the owner can edit.** *Why JSON over
  UserDefaults:* it is visible, diffable and editable without a UI until slice 3 brings one,
  and it can't silently fork between the debug and release builds.
  - **Seeding (the only time a rule appears without the owner writing it):** only the release
    **menu app**, only with `SWAPLESS_STATE_DIR` unset, and only when its own `mkdir` of the
    default state dir succeeded (the dir didn't exist). In every other case a missing
    `rules.json` means **no rules** (status `missing`). That covers an existing dir, `--headless`,
    `--print-menu`, `--dump-snapshot`, and any temp dir.
  - **Strict decoding.** An unknown key, wrong type or out-of-range value inside a rule object
    invalidates **that rule** only. An unknown top-level key, a wrong `version`, or JSON that
    won't parse invalidates **the whole file**: no rules.
  - **The `rules` line's status:** `invalid` only for a file-level error. A file that parses
    with some invalid rules is `ok`, with those rules `valid: false` and their `error`.
  - **Reload:** when its mtime or size changes, checked on each base tick and when the menu
    opens.
  - **Toggle write-back:** the menu toggle is enabled only when the file parsed and every rule
    is valid. It rewrites `enabled` through the model, pretty-printed with sorted keys, as an
    atomic write (temp file + rename).
    - **Right before writing** (the toggle or `Restore default rules`), stat the file. If its
      mtime or size differs from the last load, or the file now exists (for Restore), reload
      instead of writing. Log `rules.json changed on disk; write skipped` at `.default`. A hand
      edit is never clobbered.
- **`history.sqlite`: samples, buckets, actions and rule state.** System SQLite (`import
  SQLite3`, no dependency), WAL mode. *Why SQLite over JSON:* it is append-only time series
  that slice 2 will query ("top growers today", per-app history). Rewriting a JSON file every
  5 minutes would grow with history; memory is not the deciding factor (+4 MB measured).
  - **Writes:** batched, one transaction every 5 minutes, plus one at quit (menu Quit or
    SIGTERM, § K).
  - **Written immediately instead, each in its own transaction:**
    - every `actions` row, **before any signal** (§ J);
    - every outcome update;
    - every `rule_state` insert or delete (a pause, or a Resume).

    If one of these fails, history is off. A pause already in memory still holds for this
    run.
  - **Retention:** system samples 30 days, buckets 7 days, actions forever (tiny), pruned once
    a day.
  - **Schema** `meta(key, value)` with `schema_version = 1`. On a version it can't migrate:
    1. rename the file to `history.sqlite.bak-<unix>`;
    2. start fresh;
    3. in the fresh `rule_state`, write a pause with reason `history-reset` for every rule id
       in the current `rules.json`.

    History is disposable; the circuit breaker is not.
- **`engine.lock`:** an `flock` on the state dir. A second engine on the same dir runs
  **observe-only**: it never acts, never writes `history.sqlite` or `rules.json`, and its menu
  says "another Swapless is acting". It retries the lock on every base tick, and takes over
  (with a `.default` log line) once it gets it. This stops a second instance from
  double-restarting the wallpaper.

**D · Deployment target and toolchain: macOS 27.**
- **Settings:** `// swift-tools-version: 6.4`, `platforms: [.macOS(.v27)]`, Swift 6 language
  mode, and `LSMinimumSystemVersion` 27.0.
- *Why:* it's the only Mac. The private symbols and the struct layout were validated on 27.2
  only. Supporting 26 would add an untested surface and buy nothing.
- **Swift 6 concurrency rule (probe-tested):** the sampler runs off-main and publishes
  **Sendable value snapshots** to a `@MainActor` model. Timer handlers capture the model, never
  a non-Sendable `self`, and shared singletons are `@MainActor`.
- **Testing:** Swift Testing (`import Testing`); it works with no package dependency.
- **SQLite:** copy the shim `let SQLITE_TRANSIENT = unsafeBitCast(-1, to:
  sqlite3_destructor_type.self)`, because the macro is not imported into Swift.
- **Build output:** SwiftPM 6.4 builds into `.build/out/Products/{Debug,Release}`, so scripts
  use `swift build -c <cfg> --show-bin-path` rather than hard-coded paths.

**E · Menu technology: AppKit `NSStatusItem` + `NSMenu`**, not SwiftUI `MenuBarExtra`.
- *Why:* it is ~5 MB lighter (16 vs 21 MB, probe), the menu is a list with no charts, and it's
  TypeFlow's proven pattern.
- Rows are fixed slots updated in place while the menu is open. The refresh timer runs in
  `.common` run-loop mode, so it keeps firing during menu tracking. Submenus are built in
  `menuNeedsUpdate`.
- `SwaplessCore` stays **AppKit-free**. App names come through an injected
  `AppNameProvider` (pid → name). The core's default reads the enclosing `.app`'s Info.plist
  via Foundation, and the app injects one backed by `NSRunningApplication`. The wake signal
  is injected the same way (`NSWorkspace.didWakeNotification` lives in `Sources/Swapless`).

**F · Process identity = (pid, `p_starttime`)** from `kinfo_proc`.
- *Why:* pids get reused. The research proposed `ri_proc_start_abstime`, but it can't be read
  for root or other-uid pids, and it stops during sleep (34,284 s of drift measured here).
  `p_starttime` is public and works for every pid.
- **Formats:**
  - process series key: `proc:<pid>:<sec>.<usec %06d>`;
  - all-system coalition series key: `coal:<kern.bootsessionuuid>:<cid>`. Coalition ids
    restart at boot, and the boot-session UUID stays fixed for the whole boot, unlike
    `kern.boottime`.
  - JSON `startTime`: Unix seconds as a float.
- **Group `key`:** a coalition group's key is its `coal:` key (even when the group has
  same-user members). A Claude session or simulator group's key is its root process's
  `proc:` key.

**G · Grouping and labels** (precedence top to bottom; each process lands in exactly one group).
P1 implements **step 3 only** with the earliest-member label; P2 adds the rest.
1. **Simulator.** A process whose executable name is `launchd_sim` and whose path contains
   `/RuntimeRoot/` roots a group, together with every ppid-descendant.
   - **Device:** read the UDID from that launchd_sim's `KERN_PROCARGS2` (same-user is
     allowed). Extract **only** a UUID that matches `Devices/<UUID>/` or `SIMULATOR_UDID=<UUID>`,
     and discard the buffer immediately. Never log, store or emit args or env.
   - **Name:** from `~/Library/Developer/CoreSimulator/Devices/<UDID>/device.plist`, key
     `name`. The label is `Simulator · <name>`, or `Simulator (unknown device)`.
   - *Unverified:* no simulator was booted during the probes. P2 verifies it with `--sim`; see
     Brakes.
2. **Claude Code session.** The **outermost** process whose executable path starts with
   `$HOME/.local/share/claude/versions/`, or whose basename is `claude`, roots a group with
   every ppid-descendant. A nested `claude` belongs to the outer session (probe: a transient
   nested one appeared).
   - **Label:** `Claude Code · <basename of cwd>`, cwd via `PROC_PIDVNODEPATHINFO`. Copy
     TypeFlow's `executablePath` / `isClaudeBinary` / `workingDirectory`
     (TypeFlow's `Sources/TypeFlow/ProcessWatcher.swift`).
   - Neither coalition nor responsible pid can split sessions; all of them sit in Warp's
     coalition (probe: 6 sessions, 362–501 MB each).
3. **Coalition** (`coalition_id[0]`): everything else.
   - **Label:**
     - the responsible pid's app name (`AppNameProvider`) when it is > 0;
     - else the outermost enclosing `.app` bundle name of a member's path;
     - else the executable name of the **earliest-started** member.
   - A group whose members all run under another euid is kind `system` and gets the suffix
     ` · system`.
   - Safari's Web Content processes are member rows in Safari's group, labelled
     `Web Content (pid N)`. Match WebKit processes by **executable name**
     (`com.apple.WebKit.WebContent`), never by path prefix: they run from three different
     cryptex prefixes. Grouping is by coalition, so another app's WebKit helpers stay with that
     app (probe: a WebKit.GPU belonged to WebThumbnailExtension).
- **Sweep order:** read each coalition's footprint **before** the members' rusage. A member
  that exits in between is then simply not subtracted.
- **Totals, `coalition` source:**
  - A coalition group's total is its **coalition footprint**, which covers unreadable and
    transient setuid members such as `top`, `ps` or `sudo`.
  - A session or simulator group's total is the sum of its members' per-process footprints;
    those members are same-user and readable.
  - A coalition that lost members to a session or simulator group shows
    **max(0, coalition footprint − Σ moved members' footprints)**. Only readable processes are
    ever moved.
  - A coalition group with no remaining members is not shown.
- **Totals, `top` source:** a coalition group's total = Σ members: rusage for same-user
  members, the latest `top` value for the rest. Members without a value are left out.
- **Member rows:**
  - readable members show their own footprint;
  - for a coalition group, the other members appear by name under one row:
    `+ N system processes: X MB` (X = total − readable sum, floored at 0).
- WallpaperImageExtension has its **own** coalition, separate from WallpaperAgent's (probe).
  It shows as its own group, which is correct, and the guard matches it by exact path (§ J).

**H · Leak detector** (pure function; the research's § 5 proposal, adapted).

All numbers live in `DetectorConfig` (Codable, strict). Defaults:

| Field | Default | Field | Default |
|---|---|---|---|
| `bucketSeconds` | 300 | `slopeWindowSeconds` | 7200 |
| `trackFloorMB` | 50 | `minBucketsInWindow` | 12 |
| `baselineShortSeconds` | 3600 | `minSlopeMBPerHour` | 100 |
| `baselineLongSeconds` | 21600 | `risingFraction` | 0.7 |
| `baselineLookbackSeconds` | 86400 | `confirmations` | 2 |
| `floorMB` | 500 | `unflagSlopeMBPerHour` | 50 |
| `baselineMultiplier` | 3 | `fastPathFractionOfRAM` | 0.10 |
| | | `fastPathWindowSeconds` | 300 |

`SWAPLESS_DETECTOR_CONFIG` is a **file path**. The file must contain **all 15 keys**; a
missing or unknown key prints an `error` line and exits 2.

- **Series:**
  - one per readable process, and one per all-system coalition (its coalition footprint);
  - created at the first base tick with footprint ≥ `trackFloorMB`;
  - dropped from memory when the process or coalition is gone.
- **Buckets** are wall-aligned: `bucket_start = floor(unix_t / bucketSeconds) × bucketSeconds`.
  Each stores the **min** (sawtooth-proof) and the **max** of its base-tick samples. When
  `ri_lifetime_max_phys_footprint` rose during a bucket, it raises that bucket's max.
- **Series age** = the number of **closed** buckets holding ≥ 1 base-tick sample ×
  `bucketSeconds`; the open bucket never counts. Only the baselines use it.
  - `first_seen` = the wall time of the series' first base-tick sample, kept in `series`.
  - Time windows (slope, lookback, fast path) use wall time, and so do the rules' cooldown
    and maxPerDay, so they survive a relaunch. The sampling timer and § J's verify deadlines
    use uptime.
- **Baseline:**
  - age ≥ `baselineLongSeconds`: the lowest bucket min in the last `baselineLookbackSeconds`;
  - age ≥ `baselineShortSeconds`: the **median of the mins of the buckets whose start <
    first_seen + baselineShortSeconds**;
  - younger: no baseline, so no slope flag.
- **Candidate** at each bucket close, when all three hold:
  - latest bucket min ≥ **max(floorMB, baselineMultiplier × baseline)**;
  - Theil–Sen slope over the buckets in the last `slopeWindowSeconds` (at least
    `minBucketsInWindow` of them) ≥ `minSlopeMBPerHour`;
  - ≥ `risingFraction` of the consecutive present-bucket steps in that window rising.
- **Flagged:** a candidate on `confirmations` consecutive closes.
- **Unflagging a `slope` flag:** the series is gone; or the slope (with ≥
  `minBucketsInWindow` buckets) is < `unflagSlopeMBPerHour` on `confirmations` consecutive
  closes; or the latest bucket min is < `floorMB`.
- **Fast path.** It never fires during a series' first `fastPathWindowSeconds` of wall time,
  so a launch ramp is not a leak.
  - Let `gateStart = first_seen + fastPathWindowSeconds`. At each base tick with
    `now ≥ gateStart`, take the series' base-tick samples with
    `t ≥ max(now − fastPathWindowSeconds, gateStart)`, the latest included.
  - If there are ≥ 2, and the latest minus their min is ≥ `fastPathFractionOfRAM ×
    hw.memsize` (1.6 GB here), flag immediately with reason `fast`.
  - **Clearing a `fast` flag:** record `fastMin` (that min) at the flag tick; it is frozen,
    never recomputed. The flag clears (an `unflag` line) when the latest sample is < `fastMin`
    + 0.5 × the fast-path threshold, or when the series is gone, whatever its bucket count.
    The slope-unflag rules apply only to `slope` flags.
- **One flag at a time:** a series holds at most one flag, and while it is flagged it is not
  re-flagged.
- **Expected:** a wallpaper-like series flags at **~2.9–3.1 h**. Its first-hour median
  baseline is ~160 MB, so 3× ≈ 480 MB and the 500 MB floor dominates; the trend reaches it at
  ~2.8 h, and bucket closes plus 2 confirmations add ~10 min. That is still ~3 h before the
  1 GB guard (~6.3 h).

**I · Rules: the slice 1 schema** (`rules.json`, version 1). Flat on purpose. Slice 3 owns the
per-app model and will migrate the file to version 2. The seed:
```json
{
  "version": 1,
  "rules": [
    {
      "id": "wallpaper-leak-guard",
      "note": "Owner decision 2026-11-05 (DECISIONS.md): restart macOS's leaking wallpaper quietly.",
      "enabled": true,
      "target": "wallpaper",
      "action": "restart",
      "footprintAboveMB": 1024,
      "consecutiveSamples": 2,
      "cooldownMinutes": 30,
      "maxPerDay": 8
    }
  ]
}
```
- **Required fields:** `id` (non-empty, unique), `enabled`, `target`, `action`,
  `footprintAboveMB`, `cooldownMinutes`, `maxPerDay`.
- **Optional fields:** `note`, and `consecutiveSamples` (default 2).
- **Allowed values:**
  - `target` must be an id on the **code allowlist**. Release builds know only `wallpaper`.
    `rig-helper` exists only in DEBUG builds, and only when `SWAPLESS_RIG_HELPER_PATH` is set.
  - `action` must be `restart`.
  - Ranges: `footprintAboveMB` 1…65536, `consecutiveSamples` 1…20, `cooldownMinutes`
    1…1440, `maxPerDay` 1…48.
  - **At most one valid rule per `target`.** A later rule with the same target is invalid,
    with error `duplicate target`.
- **Evaluation:** on each base tick, per rule, the first match is the reason:
  1. invalid or `enabled: false` → `disabled`;
  2. paused → `paused`;
  3. no same-euid trigger process → `target-absent`;
  4. trigger footprint ≤ threshold → `below-threshold`;
  5. fewer than `consecutiveSamples` consecutive base ticks above, **same identity** →
     `consecutive-pending`;
  6. a verify for this rule is still in flight, or its previous action (dry runs and
     `interrupted` included) was less than `cooldownMinutes` ago → `cooldown`;
  7. this rule's actions in the last 24 h (dry runs and `interrupted` included) ≥
     `maxPerDay` → `max-per-day`;
  8. otherwise **fire**.
- **"Same identity" in step 5:**
  - For `wallpaper`, the identity is the **set** of same-euid extension identities. The count
    continues only while that set is unchanged from the previous base tick; any change
    (added, gone or replaced) restarts it at 1.
  - For `rigHelper`, each identity keeps its own count. The rule's reason is that of the
    identity furthest along the order (fire > cooldown > consecutive-pending >
    below-threshold), or `target-absent` when there is none.
- **Decision lines:** a `decision` line (and a `.default` log line) is emitted whenever the
  reason differs from the last one emitted for that rule, and a fire resets the last reason.
  Reasons that come from § J: `identity-changed`, `history-off`.
- **maxPerDay:** the action that reaches it also writes a `max-per-day` pause. Later ticks
  report `paused`. Step 7 still guards, even if that pause row was lost.
- **Pauses** (the circuit breaker) are engine state in the `rule_state` table, never edits to
  `rules.json`. They survive a relaunch and clear only through the menu's "Resume".

**J · The restart mechanics.** Only code can name a target.
- `enum RestartTarget { case wallpaper; #if DEBUG case rigHelper #endif }` is the **only**
  input the actuator accepts. **No API takes a pid or a path from a rule.** The evaluator and
  the actuator both resolve processes from the current snapshot by **exact executable path +
  euid == getuid()**.
  - `wallpaper` trigger: any process at
    `/System/Library/ExtensionKit/Extensions/WallpaperImageExtension.appex/Contents/MacOS/WallpaperImageExtension`.
    With several instances, the trigger footprint is their **sum**.
  - `wallpaper` restart set: every same-euid process at that path, plus every same-euid
    process at `/System/Library/CoreServices/WallpaperAgent.app/Contents/MacOS/WallpaperAgent`.
    This is the measured fix (`killall WallpaperAgent WallpaperImageExtension`, twice:
    1.66 GB → 111 MB, and 3.3 GB → 118 MB with Portal still playing).
  - `rigHelper`: evaluated **per identity**; each process whose path equals
    `SWAPLESS_RIG_HELPER_PATH` exactly and whose basename is `swapless-leak-helper` is its own
    trigger. Its restart set is **only the triggering identity**, never other helpers at the
    same path.
    - The rig sets that variable to `realpath(<debug-bin>/swapless-leak-helper)` and spawns
      the helper by that same string, so it equals `proc_pidpath`. `.build/debug` is a
      symlink.
- **Sequence:**
  1. **Right before signalling,** re-read each target's `kinfo_proc`: same `p_starttime`, same
     path (`proc_pidpath`), same euid. On any mismatch, emit decision `identity-changed` and
     stop: no actions row, no outcome, no cooldown.
  2. **Write the `actions` row** (outcome `pending`) and log it at `.default`. If the row
     can't be written (history off or an insert error), **don't signal**: emit decision
     `history-off`.
  3. SIGTERM every extension instance, then the agent(s). ESRCH counts as already gone.
     **Never SIGKILL.**
  4. **Verify** on a 2 s cadence (uptime):
     - a WallpaperAgent whose identity is not in the pre-action set within **30 s**: launchd
       relaunches it, `KeepAlive {SuccessfulExit: false}`;
     - a WallpaperImageExtension whose identity is not in the pre-action set within
       **120 s**: WallpaperAgent spawns it on demand.
     - Record `afterMB` (the sum of the new extension instances) 60 s after the first new one
       appears, and the WindowServer coalition footprint before and after.
  5. **Outcomes:**
     - `ok`: both are back, and afterMB < 50 % of beforeMB;
     - `agent-missing`, `extension-missing` or `no-improvement`: the rule is **paused** with
       that reason, and the menu shows it;
     - `rigHelper`: SIGTERM only, no verification. The `actionOutcome` comes right after the
       signal: outcome `signalled`, with `afterMB`, `wsBeforeMB` and `wsAfterMB` null.
- **At engine start,** every `actions` row still `pending` (a crash or SIGTERM mid-verify)
  gets outcome `interrupted`, with an `actionOutcome` line and a `.default` log line. It
  counts for cooldown and maxPerDay, and it doesn't pause the rule.
- **Dry run** (`SWAPLESS_DRY_RUN=1`): steps 1–2 run, the row is `dry-run` from the start,
  nothing is signalled, and no `actionOutcome` is emitted. The menu footer says "dry run".
- **Seams.** The Actuator takes two injected protocols:
  - `ProcessInspector`: `identity(pid) -> (startTime, path, euid)?` for step 1, and `list()`
    for the verify loop;
  - `SignalSender`: `sigterm(pid, target:) -> result`.
- **Where the senders live:**
  - SwaplessCore ships `LiveProcessInspector`, `FixtureProcessInspector` and
    `DryRunSignalSender`.
  - **`LiveSignalSender` lives only in `Sources/Swapless/LiveSignalSender.swift`**, and
    `main.swift` injects it. SwaplessCore, the tests and `swapless-rig` can't construct it.
- **The refusals live in one pure SwaplessCore function:** `SignalGuard.refusal(pid:target:ownPid:refuseWallpaper:) -> String?`. It returns:
  - `pid-out-of-range` for pid ≤ 1 (0 and −1 included);
  - `own-pid` for pid == ownPid;
  - `debug-build-refuses-wallpaper` for `.wallpaper` when `refuseWallpaper` is true;
  - otherwise nil.
- **Both senders call it as their first statement, before any `kill`:**
  - `LiveSignalSender` passes `getpid()`, and `refuseWallpaper: true` under `#if DEBUG`
    (false otherwise). So only a release build (check 7, the installed app) can ever signal
    the real wallpaper.
  - `DryRunSignalSender` passes `refuseWallpaper: false`.
  - On a non-nil result the sender emits an `error` line with that message and sends
    nothing.
- **No test ever constructs `LiveSignalSender`.**

**K · Engine shape and seams.**
- **One binary.** `Swapless` runs the menu app by default.
  - **`--headless`** runs the same engine with no AppKit and prints **JSON lines** to stdout
    (S6). It is the rig's contract, so the rig exercises the code that ships.
  - **`--duration <s>`** (both modes): exit cleanly after N seconds.
    - If a § J verify is in flight then, the engine first finishes it and emits its
      `actionOutcome` (at most 180 s more). It never exits leaving an action `pending`.
    - The first base tick runs right after start.
  - **`--print-menu`**: one sample, then print the `MenuModel` as text and exit.
  - **`--dump-snapshot <file>`**: write one sanitized snapshot for test fixtures:
    `{bootSessionUUID, hwMemsize, t, entries:[{pid, ppid, euid, startSec, startUsec, coalition,
    jetsamCoalition, name, path ($HOME → "~"), footprint|null, lifetimeMax|null,
    responsiblePid, cwdBasename|null (Claude roots only), simulatorUDID|null}],
    coalitions:[{cid, footprint, started, exited}], system:{…}}`. `FixtureSource` reads this
    format. It never writes args, env or a full cwd.
  - `--print-menu` and `--dump-snapshot` **never evaluate rules or act**, take no lock, and
    never create or write the state dir; they read `rules.json` only if it is present.
- **SIGTERM / SIGINT** (a `DispatchSource` signal handler, both modes): flush history, then
  exit 0. The app's `pkill` install path and the rig rely on this.
- **Environment seams**, validated at start (invalid → an `error` line, exit 2 before the
  first sample):
  - `SWAPLESS_SAMPLE_INTERVAL` (float ≥ 0.25);
  - `SWAPLESS_DRY_RUN`: exactly `0` or `1`;
  - `SWAPLESS_STATE_DIR`: required in `--headless`, `--print-menu`, `--dump-snapshot` and
    every DEBUG mode, and must not be the default path (§ C);
  - `SWAPLESS_DETECTOR_CONFIG` (file path, § H);
  - `SWAPLESS_FORCE_TOP`: `0` or `1`;
  - `SWAPLESS_RIG_MENU_CYCLES`: N ≥ 1, app mode only, ignored by `--headless`;
  - `SWAPLESS_RIG_HELPER_PATH`: honoured in DEBUG builds only. A release build ignores it,
    with one `.default` log line and no exit.
- **Logging:** `os_log` / `Logger`, subsystem `com.michaelv.swapless`, categories `sampler`,
  `grouping`, `detector`, `rules`, `actions`, `self`, `history`.
  - At `.default` (persisted): the self-check result, every rules load and reload, every
    decision transition, the `self` lines, every action and outcome, and every error.
    Per-sweep detail goes at `.debug` at most.
  - **Every interpolated value is `privacy: .public`**, with `$HOME` replaced by `~` in paths.
    Without that, `log show` would print `<private>`.

---

## Surfaces and files

```
Package.swift                         tools 6.4 · .macOS(.v27) · Swift 6 · products: Swapless,
                                      swapless-leak-helper, swapless-rig · test target
Sources/CSwaplessProc/                C shim (the only place private symbols are touched)
  include/CSwaplessProc.h             sw_symbols_available() bitmask · sw_coalition_ids(pid,&res,&jet)
                                      sw_coalition_usage(cid,&footprint,&started,&exited) · sw_decode_usage(buf,len,…)
                                      sw_responsible_pid(pid) · return codes per § A
  CSwaplessProc.c                     1024-byte zero-filled buffer; indexes 0/1/23/40; dlsym under pthread_once
Sources/SwaplessCore/                 library, no AppKit
  Snapshot/ProcessTable.swift         KERN_PROC_ALL → [ProcessEntry(pid, ppid, euid, startTime)]
  Snapshot/FootprintSource.swift      protocol; LiveSource (coalition then rusage) · TopFallbackSource · FixtureSource
  Snapshot/TopParser.swift            header-agnostic; B/K/M/G ×1024; trailing +/−
  Snapshot/SelfCheck.swift            § A self-check (a) + (b); result feeds the menu and the `start` line
  Snapshot/SystemMemory.swift         free % · pressure · swap · swap-in · compressed (S1)
  Snapshot/Snapshot.swift             Sendable value: entries, footprints, coalitions, system, uptime and wall time
  Grouping/Grouper.swift              § G; pure over Snapshot
  Grouping/Labeler.swift              AppNameProvider (injected) · .app bundle · earliest member · WebContent naming
  Grouping/SimulatorResolver.swift    launchd_sim → UDID (UUID only) → device.plist name
  History/HistoryStore.swift          SQLite (WAL), 5-min batched writes, immediate action rows, retention,
                                      schema_version, rule_state
  History/Buckets.swift               open buckets in memory; loads the last 24 h at launch
  Detect/LeakDetector.swift           pure; DetectorConfig (§ H)
  Rules/RulesFile.swift               strict model, validation, seed, atomic toggle write-back
  Rules/RuleEvaluator.swift           pure: (snapshot, rules, action history, rule_state) → [Intent] + [Decision]
  Act/RestartTarget.swift             the code allowlist (§ J)
  Act/Actuator.swift                  ProcessInspector + SignalSender protocols · LiveProcessInspector ·
                                      FixtureProcessInspector · DryRunSignalSender · identity re-check · verify loop ·
                                      outcomes · interrupted-at-start (NO LiveSignalSender here: § J)
  Engine/Engine.swift                 base timer + menu-open display sweeps · self-check schedule · injected wake
                                      signal · publishes EngineState (Sendable) · engine.lock · SIGTERM flush
  Engine/Config.swift                 env seams (§ K), validated
  Engine/SelfMeter.swift              cpuSeconds, childCpuSeconds, footprint, peak; budget flags; `self` line
  Engine/EventSink.swift              os_log + JSONL emitter
  Menu/MenuModel.swift                pure text model of the menu (used by the app and by --print-menu)
Sources/Swapless/                     executable: AppKit app + --headless/--print-menu/--dump-snapshot
  main.swift · AppDelegate.swift · StatusItemController.swift (icon + dot) · MenuController.swift
  (fixed slots, in-place refresh, submenus, compressed reads, RIG_MENU_CYCLES) · LoginItem.swift
  (SMAppService.mainApp toggle) · AppKitProviders.swift (NSRunningApplication names, wake notification) ·
  LiveSignalSender.swift (the only kill(SIGTERM); refuses pid ≤ 1, own pid, and .wallpaper in DEBUG)
Sources/swapless-leak-helper/main.swift   rig helper (S6)
Sources/swapless-rig/                 the rig's checks in Swift (S6)
Tests/SwaplessCoreTests/              Swift Testing + Fixtures/ (sanitized snapshots, top outputs, coalition buffers)
scripts/make-cert.sh                  copy of TypeFlow's, identity "Swapless Self-Signed" (the owner runs it)
scripts/make-app.sh                   copy of TypeFlow's (S5 changes)
scripts/leak-rig.sh                   builds debug + release, runs swapless-rig (S6)
scripts/rig/detector-rig.json         DetectorConfig for the rig (all 15 keys, S6 check 2)
docs/proof/v1-core/                   the rig reports, logs and outputs the PR cites (committed)
```

### S1 · Measurement core
- **Each sweep (P1 order):**
  1. `KERN_PROC_ALL`;
  2. flavor 20 for each pid;
  3. `coalition_info_resource_usage` once per distinct coalition (with the `coalition`
     source);
  4. `proc_pid_rusage` V4 for euid == getuid() (footprint, lifetime max);
  5. `SystemMemory`.
- Executable paths are cached by identity. ESRCH or exits mid-sweep are skipped silently.
- **SystemMemory:**
  - **free %** = `kern.memorystatus_level`;
  - **pressure** = `kern.memorystatus_vm_pressure_level` (1/2/4 → normal / warning /
    critical);
  - **swap used** = `vm.swapusage` (`xsw_usage.xsu_used`);
  - **compressed** = `HOST_VM_INFO64.compressor_page_count` × page size, which is Activity
    Monitor's "Compressed" (not `vm.compressor_bytes_used`);
  - **swap-in rate:**
    `swapinBytesPerSec = Δ HOST_VM_INFO64.swapins × 16384 ÷ Δ uptime seconds`. The global
    counter counts 16 KiB compressed-swap units, while per-task and coalition swap-ins are
    **bytes**, so never mix them. It is `null` for the first sample and the first sample
    after wake.
- **Per-process compressed memory** (same-user, `task_name_for_pid` + `TASK_VM_INFO.compressed`)
  is read **only for the member rows of a submenu as it opens**, never per sweep.

### S2 · Grouping and the menu content
- Implement § G exactly (P1 coalition-only, P2 complete).
- **The menu shows:**
  - the **top 10 groups** by footprint;
  - `Everything else: X GB in N groups`;
  - for each group, a submenu of member rows, sorted descending, with the top 15 and then
    `+ N smaller processes: X MB`.
- **Group rows:** `<label>: 1.42 GB`. A group with a flagged series gets the prefix `↑ ` and a
  slope suffix: `↑ WallpaperImageExtension: 1.10 GB (+150 MB/h)`.
- **Member rows:** `<name>: 305 MB`, with ` (302 MB compressed)` appended for same-user rows
  whose compressed is ≥ 10 MB. Web Content rows read `Web Content (pid N): 1.20 GB`. Then the
  `+ N system processes: X MB` row (§ G).
- **Number formats:** group and member values ≥ 1 GB get two decimals (`1.42 GB`), smaller
  ones whole MB (`305 MB`). The header values use one decimal (`2.7 GB`). Rule thresholds
  print as `1 GB` when divisible by 1024, otherwise in MB.

### S3 · History and detector
- Implement § C (store) and § H (detector).
- **Each base tick:** one `system_samples` row, buffered and flushed every 5 minutes. Columns:
  `t` (Unix s) · `freePct` · `pressure` · `swapUsedBytes` · `swapinBytesPerSec REAL|NULL` ·
  `swapinsTotal INTEGER` (the raw cumulative counter, 16 KiB units) · `compressedBytes` ·
  `intervalSeconds`.
- **Each bucket close:**
  - `series_buckets(series_key, bucket_start, min_fp, max_fp)` for live series;
  - `series(series_key, kind, label, path, group_label, first_seen, last_seen)` upserts.
- **At launch:** load the last 24 h of buckets, so a relaunch keeps the detector's memory.

### S4 · Rules, actuator and the wallpaper guard
- Implement § I and § J.
- **Seed** per § C.
- **Tables:** `actions(id, ts, rule_id, target, pids_json, before_mb, after_mb, outcome,
  dry_run, ws_before_mb, ws_after_mb)` and `rule_state(rule_id, paused_reason, paused_at)`.
- **The menu's rules section:**
  - `Wallpaper guard: restarts above 1 GB`, with a checkmark that writes `enabled` (§ C);
  - one status line, first match wins:
    1. paused → `Paused: <reason>`, plus a `Resume` item;
    2. a non-dry-run action in the last 30 min, keyed on its **outcome**:
       - `pending` → `Last restart HH:mm: 1.21 GB → verifying…`;
       - `ok` → `Last restart HH:mm: 1.21 GB → 110 MB`;
       - `interrupted` → `Last restart HH:mm: 1.21 GB → interrupted`;
       - `agent-missing`, `extension-missing` or `no-improvement` (seen once the owner has
         clicked Resume) → `Last restart HH:mm: 1.21 GB → <outcome>`.

       Dry-run rows never show here; the footer already says "dry run".
    3. trigger running → `Watching: WallpaperImageExtension 412 MB`;
    4. otherwise → `Not running`.
  - When no **valid** rule has `target: "wallpaper"`, the section reads `No wallpaper rule`.
    It adds `Restore default rules` only if `rules.json` is missing, and `Open rules file…`
    if it exists. **Restore is never offered for an existing file.**
  - `rules.json: <error>` lines when validation fails, then `Open rules file…` (it opens in
    the default editor).
  - When the file is missing: `Restore default rules`, which atomically writes the seed from
    § I. Per § C, it reloads instead if the file has appeared meanwhile.

### S5 · The app and packaging
- **Status item:** an SF Symbol `memorychip` template image. The dot variant is a 4 pt circle
  drawn top-right, still a template image. Dot logic as in owner call 5.
- **Menu, top to bottom:**
  1. Header (disabled): `Free 62 % · Pressure normal`.
  2. Header (disabled): `Compressed 2.7 GB · Swap 1.0 GB · Swap-in 0.0 MB/s`.
  3. Before the first sample, `Measuring…` replaces the groups.
  4. Separator, the groups (S2), separator.
  5. `Growing` (only if anything is flagged): up to 5 rows, then `and N more`. Rows covered by
     an enabled rule add `(guard restarts at 1 GB)`.
  6. Separator, the rules section (S4), separator.
  7. Footer (disabled): `Swapless 0.02 % CPU · 21 MB · measuring: full`.
     - The status reads `degraded (top)` in fallback mode, or `not measuring system
       processes` when `top` fails too.
     - It appends ` · dry run`, ` · over budget`, ` · history off: <error>` and
       ` · another Swapless is acting` as they apply.
  8. `Open at login` (checkmark, `SMAppService.mainApp`; only the owner turns it on), then
     `Quit Swapless` ⌘Q.
- **`make-cert.sh`:** TypeFlow's, with `NAME="Swapless Self-Signed"` (and the CN to match) and
  a different p12 passphrase. **Written and committed, never run by the agent.**
- **`make-app.sh`:** TypeFlow's, with these changes:
  - `BIN="$(swift build -c "$CONFIG" --show-bin-path)/Swapless"`;
  - bundle id `com.michaelv.swapless`, `CFBundleShortVersionString` 0.1.0,
    `CFBundleVersion` = `git rev-list --count HEAD`;
  - `LSMinimumSystemVersion` 27.0, `LSUIElement` true;
  - no usage descriptions, no Services, no `pbs`;
  - **`--adhoc`** skips the identity lookup and signs with `-`. The unattended run always
    passes it;
  - **stopping the installed app:** exact argv[0] only, `pkill -U "$(id -u)" -f
    '^/Applications/Swapless\.app/Contents/MacOS/Swapless( |$)' || true`, then wait up to
    5 s for it to exit. It flushes on SIGTERM (§ K). If it is still alive after 5 s, print
    `old Swapless still running (pid N); not replacing` and exit 1 without touching the bundle.
    **Never SIGKILL.**
- No TCC grant is needed in this slice: no Accessibility, no Notifications.

### S6 · Headless mode, helper and rig

**JSON lines** (stdout, one object per line). `t` is Unix seconds as a float, and footprints
are bytes:
```
{"type":"start","pid":…,"version":"<CFBundleShortVersionString or dev>","stateDir":"…",
 "intervalSeconds":…,"dryRun":false,"observeOnly":false,"source":"coalition|top|none",
 "selfCheck":{"coalition":"pass|fail|missing|skipped","checked":10,"passed":10,
 "windowServer":"pass|fail|missing|skipped","responsibility":"pass|fail|missing"}}
{"type":"rules","status":"ok|invalid|missing","rules":[{"id":"…","valid":true,"error":null}]}
{"type":"sample","t":<wall time read right before KERN_PROC_ALL>,"seq":…,"system":{"freePct":…,
 "pressure":1,"swapUsedBytes":…,"swapinBytesPerSec":…|null,"compressedBytes":…},
 "groups":[{"key":"…","label":"…","kind":"app|system|claude|simulator","footprint":…|null,
 "members":[{"pid":…,"ppid":…,"startTime":…,"name":"…","path":"~/…","footprint":…|null,
 "readable":true,"coalition":…}]}],
 "self":{"cpuSeconds":…,"childCpuSeconds":…,"cpuPercent":…,"footprint":…,"peakFootprint":…}}
{"type":"flag","t":…,"seriesKey":"…","pid":…|null,"label":"…","footprint":…,
 "slopeMBPerHour":…|null,"baselineMB":…|null,"reason":"slope|fast"}   (also "type":"unflag", same keys)
{"type":"decision","t":…,"ruleId":"…","reason":"disabled|paused|target-absent|below-threshold|
 consecutive-pending|cooldown|max-per-day|identity-changed|history-off"}   (transitions only)
{"type":"action","t":…,"actionId":…,"ruleId":"…","target":"wallpaper|rig-helper","pids":[…],
 "beforeMB":…,"dryRun":false,"outcome":"pending|dry-run"}
{"type":"actionOutcome","t":…,"actionId":…,"outcome":"ok|agent-missing|extension-missing|
 no-improvement|signalled|interrupted","afterMB":…|null,"wsBeforeMB":…|null,"wsAfterMB":…|null}
{"type":"menuCycles","n":20,"peakFootprint":…}        (app mode with SWAPLESS_RIG_MENU_CYCLES only)
{"type":"error","where":"…","message":"…"}
```
`members` lists **every** pid, so the rig can check coverage and compare with `top`. Only
base ticks emit `sample` lines.
- **A group footprint is `null`** when neither a coalition value nor any member value exists.
  Null groups sort after every numbered group and print `not readable` in the menu.

**`SWAPLESS_RIG_MENU_CYCLES=N`** (app mode only):
- The app first prints the `start` and `rules` lines to stdout, so the rig's start-line guard
  applies. It prints no `sample` lines.
- After the first sample, `MenuController` builds and fills the real `NSMenu` N times, 2 s
  apart, without an `NSStatusItem` and without showing it. That covers every slot, every
  group submenu through `menuNeedsUpdate`, the icons and the compressed reads.
- Then the app prints a `menuCycles` line with `ri_lifetime_max_phys_footprint` and exits 0.

**`swapless-leak-helper`** (our own process; the rig owns its whole lifecycle):
- **Memory:** `mmap` anonymous 8 MB chunks, touching every page with a non-zero pattern;
  `munmap` to shrink.
- **Phases:**
  1. allocate `--start-mb`;
  2. hold `--hold-start` (default 0);
  3. if `--grow-mb-per-s` > 0, grow to `--max-mb`;
  4. hold `--hold-end` (default 120);
  5. exit 0.
- **`--sawtooth LOW:HIGH:PERIOD`** replaces phases 3 **and** 4: a linear triangle LOW → HIGH
  → LOW each PERIOD seconds, in 8 MB steps, for `--hold-end` seconds, then exit 0.
- **"Exits on its own"** (as the checks use it) means exit status 0: not 143, and not a death
  by signal.
- **Other flags:** `--marker <file>` (on SIGTERM: write it, exit 143) and `--max-lifetime S`
  (default 300, always enforced). It also exits as soon as `getppid()` changes.
- **Output:** one JSON line per second, `{"t":…,"allocatedMB":…,"phase":"…"}`.
- **Low memory:** if `kern.memorystatus_level` < 30 before a chunk, it stops allocating, prints
  `{"t":…,"allocatedMB":…,"refused":true}`, and keeps holding until `--hold-end`.

**`scripts/leak-rig.sh`** runs `swift build -c debug && swift build -c release`, then
`swapless-rig --debug-bin <dir> --release-bin <dir> "$@"`, with both dirs from
`--show-bin-path`.
- **Modes:**
  - a bare run = preflight + checks 1–4, in order;
  - `--only N[,N…]` = preflight + just those checks (the pass gates). It accepts **only**
    1–4. Any other value exits 2 with `usage: check 5 runs via --budget, 6 via --sim, 7 via
    --live-wallpaper`, before preflight and before any engine starts;
  - `--budget` = preflight + checks 1–5;
  - `--sim` = preflight + check 6;
  - `--live-wallpaper` = preflight + check 7.
  - `--sim` and `--live-wallpaper` don't combine with anything.
- **Output:** each check prints `PASS` / `FAIL <why>` / `SKIP <missing precondition>` with
  its numbers. The full report goes to stdout and to
  `.build/rig/rig-<yyyymmdd-hhmmss>-<mode>.txt`. Only the reports the PR cites are copied to
  `docs/proof/v1-core/`, with `$HOME` → `~`.
- **Exit code:** 0 iff there is no FAIL. A SKIP is allowed only where a check names its
  precondition.
- **The agent runs `leak-rig.sh` with `run_in_background`**, never under a foreground timeout:
  `--budget` takes ~15 min.
- **One rig at a time:** `swapless-rig` first takes an exclusive non-blocking `flock` on
  `.build/rig/rig.lock`. If that is held, it prints FAIL `rig-busy` and exits 1. The agent
  never starts a rig invocation, or a `swift build` of this worktree, while another rig
  invocation is running.
- **Every `--only` that includes 3 also works without 2:** check 3 then runs check 2's
  scenario itself (below).

**Preflight** (every mode):
- **Memory:** free % ≥ 40. If lower, poll every 30 s for up to 10 min, then FAIL
  `mac-too-busy`. Never free memory by touching other processes.
- **State dirs and rules:** for **every** engine run, the rig creates a temp state dir
  (`mktemp -d`) and writes `rules.json` into it first. The file is `{"version":1,"rules":[]}`
  unless the check names other rules.
- **Dry run:** every engine whose rules name `target: "wallpaper"` runs with
  `SWAPLESS_DRY_RUN=1`, except check 7.
- **Start-line guard:** the rig reads each engine's `start` and `rules` lines first. If
  `dryRun`, `stateDir` or the rules status differ from what it set up, it stops that engine
  (SIGTERM) before its second sample and FAILs.
- **Cleanup:** every engine gets `--duration` (the check's length + 30 s). Every child the rig
  spawns (engines, helpers, `log stream`) is stopped on every exit path. The rig never signals
  a helper whose "no marker" it is about to assert: it waits for that helper to exit on its
  own.
- **Baseline:** record the identities of the real WallpaperAgent and WallpaperImageExtension.

**Checks**
1. **footprint-matches-top** (debug engine, interval 2 s; the flat helper `--start-mb 256
   --hold-end 60`).
   - **Timing:**
     - the rig runs `top -l 1 -stats pid,mem` once, recording the wall time before (T0) and
       after (T1) it;
     - "before" is the last `sample` with `t` < T0; "after" is the first with `t` > T1;
     - the engine runs until the "after" sample exists.
   - **Comparisons** (each passes when `top`'s value lies within [min − tol, max + tol] of the
     engine's two values):
     - **the helper:** tol 1 MB. Also its `phys_footprint:` line from `footprint -p <pid> -f
       bytes --noCategories` vs the "after" sample, within 1 MB;
     - **WallpaperImageExtension** (if running): tol 2 MB;
     - **WindowServer's group** vs Σ `top` MEM over its members: tol members × 1 MB + 1 %;
     - **broad:** for ≥ 95 % of same-user processes ≥ 50 MB in both, tol max(2 MB, 2 %).
   - **Coverage:** every pid `top` listed is in the "after" sample's `members`, or at check
     time is gone or carries a different `p_starttime` (via `KERN_PROC_ALL`). `top` itself and
     the rig's own children are excluded.
   - **Again with `SWAPLESS_FORCE_TOP=1`:** the same assertions, plus `source == "top"` and
     `selfCheck.coalition == "skipped"`.
     - In this run the rig starts its `top` as soon as the engine's first `sample` line
       arrives, so "before" is that first sample.
     - Its unreadable values come from the engine's synchronous pre-first-sample `top`, a few
       seconds older than T0. The engine's next `top` (60 s later) never falls between
       "before" and "after".
2. **growth-flagged** (debug engine, `SWAPLESS_SAMPLE_INTERVAL=1`,
   `SWAPLESS_DETECTOR_CONFIG=scripts/rig/detector-rig.json`).
   - **The config file:**
     ```
     bucketSeconds 2, trackFloorMB 16, baselineShortSeconds 6, baselineLongSeconds 3600,
     baselineLookbackSeconds 3600, floorMB 200, baselineMultiplier 1, slopeWindowSeconds 20,
     minBucketsInWindow 6, minSlopeMBPerHour 3600, risingFraction 0.7, confirmations 2,
     unflagSlopeMBPerHour 1800, fastPathFractionOfRAM 0.10, fastPathWindowSeconds 10
     ```
     *Why multiplier 1:* flat and sawtooth then pass the floor condition, so they must be
     rejected by the slope and the rising fraction, which makes the check meaningful. The
     grower's threshold stays 200 MB.
   - **Helpers,** all started right after the engine's first `sample` line:
     - **grower:** `--start-mb 32 --hold-start 10 --grow-mb-per-s 8 --max-mb 480 --hold-end 60
       --marker <tmp>/c2-grower.marker`;
     - **flat:** `--start-mb 260 --hold-end 130 --marker <tmp>/c2-flat.marker`;
     - **sawtooth:** `--start-mb 220 --sawtooth 220:320:3 --hold-end 130 --marker
       <tmp>/c2-sawtooth.marker`.
   - **Pass:**
     - the grower is flagged **within 20 s** of crossing 200 MB (from its own `allocatedMB`
       lines);
     - its `slopeMBPerHour` is within ±25 % of 28,800;
     - flat and sawtooth are **never** flagged.
   - A helper `refused` line FAILs the check as `memory-floor` (the environment, not the
     detector).
   - Peak extra memory is ~1.06 GB, for ~2 minutes.
3. **no-action-without-rule** (debug engines, interval 1 s, unless a run names release).
   - **The check-2 run itself** uses the empty rules file.
     - If check 2 ran earlier in this invocation, check 3 asserts on that run. Otherwise it
       first runs check 2's scenario itself (same engine env, config file and helpers), and
       check 2's own pass criteria are not evaluated.
     - It must show zero `action` events, none of the three `c2-*.marker` files, every helper
       exiting on its own, and the wallpaper identities unchanged.
   - **Then 8 s runs, each with a helper `--start-mb 480 --hold-end 20 --marker
     <tmp>/c3-<run>.marker` above every threshold:**
     - (a) `target: "WindowServer"` → rules status `ok`, that rule `valid: false`;
     - (b) `action: "quit"` → status `ok`, that rule `valid: false`;
     - (c) a file that won't parse → status `invalid`;
     - (d) the wallpaper rule with `enabled: false`, `footprintAboveMB: 1`, in dry run →
       decision `disabled`;
     - (e) the **release** engine, with `SWAPLESS_RIG_HELPER_PATH` **set** to the helper's path
       and a `target: "rig-helper"` rule → status `ok`, that rule `valid: false` with error
       `unknown target`.
     - Each run: zero `action` events, the helper exits on its own with no marker, and the
       wallpaper identities are unchanged.
   - **"Unchanged" exception:** a wallpaper identity change passes only if the **installed**
     Swapless logged a matching action in that window (`/usr/bin/log show --start <run start>
     --predicate 'subsystem == "com.michaelv.swapless" AND category == "actions" AND
     processImagePath == "/Applications/Swapless.app/Contents/MacOS/Swapless"'`).
4. **ruled-action-once** (debug engine, interval 1 s, `SWAPLESS_RIG_HELPER_PATH` set).
   - **Rule:** `rig-helper`, threshold 200, consecutiveSamples 2, cooldownMinutes 5,
     maxPerDay 2.
   - **Grower A:** `--start-mb 32 --hold-start 2 --grow-mb-per-s 16 --max-mb 300 --hold-end 60
     --marker <tmp>/a.marker`.
   - **Grower B** starts only once A has exited and `a.marker` exists, with the same flags
     except `--hold-end 20 --marker <tmp>/b.marker`. It crosses 200 MB ~13 s after it starts
     and exits on its own ~39 s after, inside the cooldown. The rig stops the engine after B
     exits.
   - **Pass:**
     - exactly one `action` line (outcome `pending`) whose pids are A's, then one
       `actionOutcome` with that `actionId`: outcome `signalled`, and `afterMB`, `wsBeforeMB`
       and `wsAfterMB` null;
     - `a.marker` appears within 3 s of the action;
     - a `decision` `cooldown`, with `t` ≥ B's second sample above 200 MB;
     - no `b.marker`, and B exits 0.
   - **Then the dry run against the real wallpaper** (SKIP if it isn't running): a separate
     8 s run, `SWAPLESS_DRY_RUN=1`, the wallpaper rule with `footprintAboveMB: 1`.
     - exactly one `action` with `dryRun: true` and outcome `dry-run`, and no
       `actionOutcome`;
     - its pids equal the real restart set (every extension instance plus the agent);
     - both identities unchanged 5 s later.
5. **budget** (`--budget`, ~11 min).
   - **Precondition:** `/Applications/Swapless.app` is running with ppid 1 (launched by
     LaunchServices), and the process's `p_starttime` is later than the installed
     executable's mtime. That executable is `cmp`-identical to
     `./Swapless.app/Contents/MacOS/Swapless` (make-app.sh's repo-root bundle), and that file
     is newer than `Package.swift` and every file under `Sources/`. Otherwise FAIL
     `installed app is stale: run ./scripts/make-app.sh release --adhoc`.
   - **Log predicate** for the `self` lines below:
     `subsystem == "com.michaelv.swapless" AND category == "self" AND processImagePath ==
     "/Applications/Swapless.app/Contents/MacOS/Swapless"`. The rig starts `/usr/bin/log
     stream --level info --predicate '<that>'` before the window.
   - **Window:** from the installed app's first `self` line after check 5 starts to the second
     line after that (≈ 10 min). At those two lines the rig reads `ps -o time= -p <pid>`.
     - CPU % = Δ ps time ÷ Δ wall, which must be within § B.
     - At the end, `top` MEM ≤ 30 MB, and the `phys_footprint_peak:` line of `footprint -p
       <pid> -f bytes --noCategories` ≤ 40 MB.
     - **Disturbance:** when the window closes, the rig runs `/usr/bin/log show --start
       '<window start − 180 s>' --end '<window end>' --predicate 'subsystem ==
       "com.michaelv.swapless" AND category == "actions" AND processImagePath ==
       "/Applications/Swapless.app/Contents/MacOS/Swapless"'`. If that shows any action, or
       `menuOpenSeconds` changed during the window, the rig measures once more. A second
       disturbance is SKIP `disturbed`.
     - **No lines:** FAIL `self-report` if no installed-app `self` line arrives within 360 s
       of check 5 starting (or of the re-measure starting), or if there are fewer than 3 lines
       by window start + 11 min. The rig then stops its `log stream` child, and check 5 still
       runs the peak test. That is not a budget overrun, so the optimization brake doesn't
       apply; fix the emission.
   - **Self-report:** at each of those lines, within 2 s, the rig also reads the
     `phys_footprint:` line. It requires |cpuSeconds − ps time| ≤ max(0.05 s, 10 %) and
     |footprint − phys_footprint| ≤ 2 MB.
   - **Peak test, after the window closes:** run `./Swapless.app/Contents/MacOS/Swapless`
     (release, app mode) directly, with a temp state dir, empty rules, `SWAPLESS_DRY_RUN=1` and
     `SWAPLESS_RIG_MENU_CYCLES=20`. Its `menuCycles` line must have `peakFootprint` ≤ 40 MB.
6. **simulator** (`--sim`; **one boot per implementation run**, owner call 7).
   - **Engine:** debug headless, `SWAPLESS_SAMPLE_INTERVAL=2`, empty rules, `--duration 450`,
     started **before** the boot.
   - **Booting:**
     - If a device is already booted, use it and expect `Simulator · <its device.plist
       name>`. With several, take the lowest UDID (string sort); other simulator groups are
       ignored.
     - Otherwise announce it, look up `iPhone 18 Pro`'s UDID in `xcrun simctl list devices
       -j` (SKIP if it doesn't exist), and boot it **by UDID** (never `simctl create`).
       Before booting, write `.build/rig/booted-sim` as `<UDID> <parent-pid>` (see Shutdown).
       Wait with `xcrun simctl
       bootstatus <UDID> -b`; not booted within 300 s is a FAIL.
   - **Shutdown:** only if the rig booted it, on **every** exit path.
     - `swapless-rig` has SIGINT/SIGTERM/SIGHUP handlers that shut it down.
     - **Only in `--sim` mode,** `leak-rig.sh` sets `trap … EXIT INT TERM HUP` and passes
       `--parent-pid $$` to `swapless-rig`. After taking `rig.lock` and before booting,
       `swapless-rig` writes `.build/rig/booted-sim` as `<UDID> <parent-pid>`. The trap shuts
       down that UDID and deletes the file **only if the recorded pid equals `$$`**;
       otherwise it touches neither.
     - If `--sim` finds `.build/rig/booted-sim` already present after taking `rig.lock`, it
       FAILs `stale-booted-sim` with the file's contents and the device's state. It boots
       nothing, shuts nothing down, and leaves the file.
     - After the check, the rig confirms with `xcrun simctl list devices booted` that the
       UDID is no longer booted.
   - **"Booted"** is the moment `bootstatus -b` returns, or, for an already-booted device, the
     engine's first sample. **"Steady"** is 6 consecutive samples (10 s) whose group footprint
     lies within ±5 % of their mean. Not steady within 120 s of Booted is FAIL `not-steady`,
     with the series.
   - **Fixture:** while the device is booted, the rig also runs the debug `Swapless
     --dump-snapshot Tests/SwaplessCoreTests/Fixtures/sim-booted.json` (temp state dir),
     whatever the outcome.
   - **Pass,** on the sample that completes "steady", judged from **that sample alone** (its
     `members`' pid and ppid), never from a process table read at another moment:
     - one `simulator` group with the expected label and a footprint ≥ 300 MB;
     - its members are exactly launchd_sim plus the ppid-closure of launchd_sim over that
       sample's members;
     - no pid in any other group of that sample has a simulator-group pid in its ppid chain.
   - **A FAIL is never re-run by booting again.**
     - **Three FAILs are Brakes stops, not fix-and-continue:** the simulator's processes don't
       descend from launchd_sim by ppid; `stale-booted-sim`; the rig-booted UDID is still
       booted after the check. For those, save the report to `docs/proof/v1-core/`, then stop
       and report.
     - **For any other FAIL:**
       1. save the report to `docs/proof/v1-core/`;
       2. fix the code against `sim-booted.json` with a unit test that would have caught it,
          and continue;
       3. the PR lists `--sim` as pending an owner re-run, and it triggers the DECISIONS.md
          entry like a SKIP.
7. **live-wallpaper** (`--live-wallpaper`; approved by owner call 7; **one invocation per
   implementation run**, and a precondition SKIP counts as that invocation).
   - **Precondition:** Portal (`/Applications/Portal.app/Contents/MacOS/Portal`) is running,
     and WallpaperImageExtension exists with a footprint **≥ 400 MB**. Otherwise SKIP with the
     current numbers. *Why 400:* the extension comes back at ~110 MB, so `ok` (after < 50 % of
     before) needs before ≥ ~250 MB, and 400 MB leaves margin.
   - **Setup:**
     - the **release** headless engine, a temp state dir, `SWAPLESS_SAMPLE_INTERVAL=2`,
       `--duration 300`;
     - the wallpaper rule with `footprintAboveMB` = ⌊C⌋ − 100 and consecutiveSamples 2, where
       C (MB) is the sum of the extension instances' `ri_phys_footprint`, read by the rig
       with `proc_pid_rusage` right before it starts the engine. C ≥ 400, so the threshold is
       ≥ 300 MB, well above the ~110 MB respawn;
     - not a dry run.
     - The rig never stops this engine before its `actionOutcome` line, except on its own
       abort.
   - **Pass:**
     - exactly one action;
     - WallpaperAgent is back with a new identity in ≤ 30 s, and the extension in ≤ 120 s;
     - the outcome is `ok`, with after < before;
     - Portal's pid is unchanged and still running;
     - `wsBeforeMB` and `wsAfterMB` are reported.
   - An engine exit that leaves an `action` with no matching `actionOutcome` is FAIL
     `verify-cut`.
   - **Right after the run,** save `/usr/bin/log show --start '<run start>' --predicate
     'subsystem == "com.michaelv.swapless"'` to `docs/proof/v1-core/`.

---

## Edge cases

- **Pid reuse:** everything is keyed by (pid, `p_starttime`). Identity is re-checked right
  before every signal, and a mismatch means no action.
- **Exits mid-sweep:** ESRCH from rusage, flavor 20 or the coalition call is skipped silently.
  Coalitions are read before rusage, so a member that just exited is never subtracted.
- **Transient setuid children** (`top`, `ps`, `sudo`) inside a user app's coalition: the group
  total comes from the coalition footprint, so they're covered. Their row is `+ N system
  processes`.
- **Several WallpaperImageExtension instances** (an external display, a respawn in progress):
  the trigger is their sum, all of them are restarted, and verify waits for new identities
  (§ J).
- **Another user's wallpaper processes** (fast user switching): never a trigger, never
  restarted. The euid filter sits in both the evaluator and the actuator.
- **Sleep and wake:**
  - timers pause;
  - the first swap-in delta after wake is `null`;
  - buckets have gaps, which Theil–Sen and the rising-steps ratio tolerate (they use the
    buckets present);
  - the self-check re-runs on wake.
- **Clock changes:** sampling and verify deadlines use uptime. Buckets, windows, cooldown and
  maxPerDay use wall time (§ H). Coalition series keys use the boot-session UUID, so an NTP
  step doesn't restart them.
- **Swapless launches with the wallpaper already above 1 GB:** it acts after 2 consecutive
  base ticks (~30–60 s). That's intended.
- **Wallpaper processes absent** (Portal closed, a non-image wallpaper): the rule reports
  `target-absent` and the menu says `Not running`. That is not an error.
- **WallpaperAgent not back within 30 s, or the extension within 120 s:** the rule is paused
  with the reason, the dot lights, and the menu shows `Paused: …` with `Resume`. **No
  retry.** The pause survives a relaunch.
- **The wallpaper restarts on its own, or the owner kills it:** the new identity starts a new
  series with no action. Cooldown counts only Swapless's own actions.
- **The owner edits `rules.json` while it runs:** the next base tick (or opening the menu)
  reloads it. An invalid rule is disabled on its own, with its error shown; a file-level error
  means no rules. The toggle is disabled while anything is invalid, and every write-back
  re-checks mtime and size first (§ C), so it never clobbers a hand edit.
- **Two rules with `target: "wallpaper"`:** the later one is invalid (`duplicate target`), so
  two restart sequences can never overlap.
- **A tick that lands during a verify can never fire** (§ I step 6). It reports the first
  match in § I's order: usually `target-absent` or `below-threshold`, since the respawned
  extension sits near 110 MB. It reports `cooldown` only if the trigger is again above
  threshold for `consecutiveSamples` same-identity ticks. § I's order is the contract.
- **Swapless crashes or is killed mid-verify:** at the next start the `pending` row becomes
  `interrupted`, which counts for cooldown and maxPerDay.
- **`rules.json` deleted:** no rules, and the menu offers `Restore default rules`. Seeding
  happens only on the release app's first launch (§ C).
- **State dir not writable, disk full, or a SQLite error:** history is off, the detector runs
  in memory only, and the footer shows `history off: <error>`. **The guard cannot act while
  history is off**, because the `actions` row must be written first (decision `history-off`).
  So cooldown, maxPerDay and pauses can never be bypassed.
- **Two engines on one state dir:** the second one is observe-only (§ C `engine.lock`). A
  rig engine on a temp dir is independent of the installed app. The two can't double-act on
  the wallpaper: the installed app only acts above 1 GB, and a rig engine only acts on the
  real wallpaper in check 7, once.
- **Coalition self-check fails, or the symbol is gone:** fallback `top` (degraded). If `top`
  fails too, groups made only of system processes show `not readable` with no number, and the
  footer reads `not measuring system processes`. Same-user numbers are unaffected.
- **Responsibility symbol missing:** labels use the path heuristics. Nothing else changes.
- **Nested Claude Code processes:** they belong to the outermost session. A Claude process
  outside any terminal still gets its own session group; the coalition it leaves empty is
  hidden.
- **A Claude binary at an unknown path:** the basename `claude` rule catches npm and Homebrew
  installs. Any other path stays in its coalition group, uncounted as a session (acceptable).
- **A simulator with no `device.plist`, or no UUID in its args:** `Simulator (unknown device)`.
- **WebKit helpers of other apps:** they stay with their own coalition (§ G).
- **A launch ramp** (Xcode indexing, a VM, a heavy tab reaching GBs within minutes): it is not
  fast-flagged during a series' first 5 min, and samples from those 5 min never enter the
  fast-path window (§ H).
- **A non-UTF-8 path:** decoded with replacement characters; never crashes.
- **First launch, before the first sample:** `Measuring…`. Growing section: hidden when empty.
- **The menu opens during a sweep:** it shows the last published `EngineState`. The refresh
  never blocks the main thread.
- **SIGTERM** (`make-app.sh` reinstall, the rig, logout): history is flushed, then exit 0.
- **Fixtures, logs and proofs:** they carry no args, no env and no full cwd (basename only),
  and `$HOME` becomes `~` (wall: no secrets in the repo).

---

## Verification plan

Every surface has a gate. Gates are run, not assumed. Unit tests use Swift Testing, with
fixtures recorded by `--dump-snapshot` (with `SWAPLESS_STATE_DIR` set to a temp dir) plus
synthetic ones. Random inputs use a seeded deterministic generator (SplitMix64), never the
system RNG.

| Surface | Check type | Gate |
|---|---|---|
| S1 measurement | functional | `swift test`: `TopParser` on real output fixtures (K/M/B, header variants, `+`/`-`, a synthetic `10G`). `sw_decode_usage`: offset 320, drift on `eqos_len ≠ 7`, short buffers. **Ticks × 125/3** (raw `47,941,393` ticks ≈ 1.998 s). Self-check pass and fail on fixtures, including a failing WindowServer (b). `top`-mode totals. **Rig `--only 1`.** |
| S2 grouping + menu content | functional + judgment | `swift test` on fixtures: Safari with Web Content rows; Warp with 3 Claude sessions, one nested; WindowServer as a system coalition; WallpaperImageExtension in its own group; a mixed coalition with a transient setuid child; a moved member that exits mid-sweep; a synthetic simulator subtree, plus the real `sim-booted.json` once `--sim` has captured it; residual totals (max(0, coalition − moved)); an emptied coalition hidden; a null-footprint group sorted last as `not readable`. `MenuModel` strings per S2/S4/S5. **Rig `--only 1`** (coverage with full grouping). **Rig `--sim`** once. `--print-menu` output in `docs/proof/v1-core/`. |
| S3 history + detector | functional | `swift test`: **wallpaper series** (110 MB + 145 MB/h, 30 s base ticks, noise uniform in [−20, +20] MB, start on a bucket boundary) flags in **[2.75, 3.25] h for each of 50 seeds**. **Plateau** (noise-free, 110 MB for 1 h, then 600 MB held 8 h): no flag. **Sawtooth** (noise-free, 110 MB for 1 h, then a 550 → 1000 → 550 MB triangle with a 20-min period for 8 h): no flag. These two keep bucket mins ≥ 500 MB, so slope or rising fraction must reject them. **One-off spike**, +1 GB for one sample on a 600 MB plateau: no flag. **Fast path**, +2 GB held ≥ 2 samples on a series older than 5 min: flags `fast`. **Launch ramp** (hw.memsize 16 GiB; first seen 290 s into a bucket at 50 MB, linear to 2 GB over 270 s, then held 15 min): no flag on any tick. **Fast-flag clearing** (16 GiB): on a 600 MB plateau series aged 2 h, a +2 GB step held 30 min stays flagged `fast` on every tick, and a drop to 1316 MB emits `unflag` on that tick; the same on a series aged 20 min. **Pid reuse** starts a new series. **Store:** round-trip, retention prune, schema mismatch → backup + fresh + every current rule paused `history-reset`. `DetectorConfig` rejects missing or unknown keys. **Rig `--only 2`.** |
| S4 rules + actuator | functional | `swift test`: strict decoding (an unknown key in a rule invalidates that rule; at top level, the file; status semantics); `duplicate target`; the seed only on the release app's own mkdir, and not for an existing empty dir, a temp dir, headless or DEBUG; the default-path refusal for `--headless`, `--print-menu`, `--dump-snapshot` (any build) and every DEBUG mode; atomic toggle round-trip, disabled while invalid, skipped when the file changed on disk; the 8-step evaluation order and decision transitions; consecutive same-identity samples (wallpaper set change restarts the count; rigHelper per identity); cooldown and maxPerDay counting dry runs and `interrupted`; in-flight verify with the trigger above threshold for `consecutiveSamples` same-identity ticks → `cooldown` and no second fire, and with the trigger absent or below → `target-absent` / `below-threshold`; the S4 status-line strings per outcome (`pending`, `ok`, `interrupted`; dry runs hidden); Restore offered only when the file is missing; the max-per-day pause; `pending` → `interrupted` at start; `identity-changed` (no row); `history-off` (no signal); multi-instance wallpaper (sum, all restarted); rigHelper only the triggering identity; `SignalGuard.refusal` refuses pid 0, −1, 1 and the own pid, refuses `.wallpaper` with `refuseWallpaper` true and allows it with false (`.rigHelper` allowed for any pid > 1 other than `ownPid`); `DryRunSignalSender` applies the same pid refusals (no test constructs `LiveSignalSender`); seeding and refusal tests run against an injected temp `defaultStateDir`, never the real one; DRY_RUN parsing (`0`/`1` only). **Property test:** 1,000 seeded random snapshots × random rule files, with a `FixtureProcessInspector` that agrees with each snapshot. Same-euid allowlisted processes are above threshold in ≥ 30 % of cases. The `SignalSender` mock is called **only** with pids whose path is on the allowlist and whose euid == uid, **and** is called in ≥ 100 cases. **Rig `--only 3,4`**, then **`--live-wallpaper` once** (PASS or a SKIP with numbers). |
| S4 Portal | user-decides, at acceptance | The owner confirms that Portal kept playing and the desktop didn't go black. Either the owner runs `./scripts/leak-rig.sh --live-wallpaper` while watching, once the menu shows the extension ≥ 400 MB, or watches the installed app's first real restart (`Last restart …` in the menu). |
| S5 app + packaging | functional + user-decides | `./scripts/make-app.sh release --adhoc` builds, installs and launches. `codesign --verify --strict /Applications/Swapless.app` exits 0, and `codesign -dv` shows `Signature=adhoc`. `--print-menu` text in the PR. **User-decides at acceptance:** the owner runs `./scripts/make-cert.sh`, then `./scripts/make-app.sh release`, clicks Always Allow, and `codesign -dv` shows `Authority=Swapless Self-Signed`; takes the menu screenshot; accepts the icon and dot look. |
| Overhead | functional | **Rig `--budget`** passes on the installed release app. |
| Whole slice | functional | `swift build && swift test && ./scripts/make-app.sh release --adhoc && ./scripts/leak-rig.sh --budget` exits 0. `docs/proof/v1-core/` holds the `--budget` report, the `--sim` and `--live-wallpaper` reports, the `--print-menu` text, the log excerpt saved right after check 7, and a log excerpt from the installed app's launch (`/usr/bin/log show --start '<launch>' --predicate 'subsystem == "com.michaelv.swapless"'`) that shows the self-check and the rules load. |

---

## Brakes (for the unattended run)

**One surface per pass, in this order. Each pass ends green on its gate before the next
starts:**
- **P1** · S1 measurement, coalition-only grouping (§ G step 3), minimal `--headless`, the
  helper, the rig skeleton → `swift test` + `leak-rig.sh --only 1`.
  - P1 also lands `Engine/Config.swift` (every § K seam, validated, including the state-dir
    refusal) and `RulesFile` loading with strict validation and the `rules` line, so the
    rig's start-line guard works from P1.
  - No seeding, evaluator or actuator yet; P4 adds those.
- **P2** · S2 grouping complete, `MenuModel`, `--print-menu`, `--dump-snapshot` fixtures →
  `swift test` + `--only 1` + `--sim` once (PASS, SKIP, or a FAIL handled as check 6 says).
- **P3** · S3 history and detector → `swift test` + `--only 2`.
- **P4** · S4 rules and actuator → `swift test` + `--only 3,4`, then `--live-wallpaper` once.
- **P5** · S5 app and packaging → `make-app.sh release --adhoc` + codesign checks + the seed
  check:
  1. Before the first `make-app.sh`, record that `~/Library/Application Support/Swapless`
     does **not** exist (it didn't on 2026-11-05).
  2. After that first launch, `/usr/bin/log show --start '<launch>' --predicate 'subsystem ==
     "com.michaelv.swapless" AND category == "rules"'` must show status `ok` with
     `wallpaper-leak-guard` valid and enabled. The rules log line carries the `rules` line's
     fields plus each rule's `enabled`.
  3. Save that excerpt to `docs/proof/v1-core/`.
- **P6** · the whole-slice gate (`--budget`), the proofs, the DECISIONS.md entry if one is
  required, then **`/save-task` (a draft PR)**.
  - The PR body opens with the owner's acceptance checklist: the Portal check (or the pending
    live check with its SKIP reason), `make-cert.sh` + Always Allow + a rebuild, the menu
    screenshot, the icon and dot look, and turning on Open at login.
  - **Never run `/ship-task`, `gh pr ready` or `gh pr merge`.** The owner ships.

**A SKIP is not a stop.** If `--sim` or `--live-wallpaper` SKIPs (no simulator, Portal not
running, extension < 400 MB), save the SKIP line to `docs/proof/v1-core/`, continue, and list
it in the PR checklist as pending. The run never waits for the owner and never launches,
focuses or quits Portal or any other user app.

**Stop and report, without working around it, if:**
- the coalition self-check fails on this Mac. The probes said byte-exact on 290 of 290, so a
  failure means the OS moved;
- any code path could signal a process that wasn't resolved through `RestartTarget`, or the
  property test needs weakening to pass;
- a rig check passes only with a tolerance looser than this spec's, or a timing that differs
  from it;
- `--budget` fails after **one** focused optimization attempt. Report the numbers; don't raise
  the budget;
- the preflight FAILs `mac-too-busy`, or a check FAILs `memory-floor`;
- the booted simulator's processes do **not** descend from launchd_sim by ppid, or don't sit
  where § G assumes. Report what you found, and don't invent another grouping;
- the rig-booted simulator is still booted after `--sim`, or `--sim` FAILs
  `stale-booted-sim` (the owner decides about that simulator and the file);
- the default state dir already exists before P5's first install, or the installed app's
  first launch did not seed `wallpaper-leak-guard`. **Never delete or edit that dir;**
- `--live-wallpaper` ends with anything other than PASS or a precondition SKIP. **Stop
  immediately:** no retry, and no second run. Report the outcome, the processes' state, and
  the recovery for the owner. If the desktop looks wrong, the owner can run `killall
  WallpaperAgent` or log out and back in;
- anything would require Accessibility, Notifications, Screen Recording, sudo, `make-cert.sh`,
  a keychain prompt, a LaunchAgent or a login item.

**Never touch:**
- the owner's real state dir (`~/Library/Application Support/Swapless`) from tests, dev builds
  or the rig. No Swapless binary runs without `SWAPLESS_STATE_DIR` set to a temp dir, except
  the installed app as `make-app.sh` launches it. For the `--print-menu` proof, put a copy of
  the § I seed in that temp dir;
- any process other than the rig's own helpers and engines, the installed app via
  `make-app.sh`'s exact-path stop, and, only inside `--live-wallpaper`, the wallpaper pair.
  Never SIGKILL anything;
- the `Open at login` toggle;
- MagicQuit, mac-memory-guard (`~/Library/LaunchAgents/com.memoryguard.agent.plist`), and the
  simulators beyond `--sim`'s boot/shutdown etiquette;
- `main` (PR only);
- `.claude/`, `specs/README.md`, and other specs;
- secrets, args or env of other processes, in any output, log, fixture or proof.

**A DECISIONS.md entry is mandatory** (written in P6, before the PR) if:
- any check in the final reports is SKIP;
- a final run's `source` was `top` (other than check 1's forced `SWAPLESS_FORCE_TOP=1` run),
  or a self-check failed;
- Swapless signalled any process outside an owner-approved rule, even in a test. The
  owner-approved ones are the installed app's seeded `wallpaper-leak-guard`, check 4's own rig
  helper, and check 7's restart;
- a user app was affected;
- the build exceeded its budget.

**Final acceptance and shipping are the owner's** (the PR checklist).

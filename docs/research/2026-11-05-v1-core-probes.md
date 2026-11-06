# v1-core probes: what the first spec's API claims measured (2026-11-05)

Context, not authority (CLAUDE.md §2). Four read-only probe agents measured these facts for
`specs/v1-core.md`. The Mac: M1 Pro, 16 GB, macOS 27.2 (26B123, xnu-13432.41.4), Xcode 27.1, Swift
6.4. Rules for the probes:
- no signals to any process the probes did not start;
- no simulator booted;
- no sudo;
- scratch work outside the repo.

Several results correct `2026-11-05-memory-measurement.md`; each correction is marked **Correction**.

## Coalition footprint (`coalition_info_resource_usage`, private, `dlsym`)

- **Exact for single-member coalitions.** Of the 290 single-member same-user coalitions, every
  coalition `phys_footprint` equalled `ri_phys_footprint` to the byte (3 reps each). The range
  was 1.5–304.7 MB; examples: MauiAUSP 319,538,448 B, WallpaperImageExtension 112,673,176 B.
- **Within `top`'s rounding for system coalitions.** Across the 220 all-system coalitions,
  the coalition value vs the sum of `top` MEM over the members gave max |diff| 0.48 MB and a
  median of 0.
  - WindowServer coalition 381: 1186.2 MB vs `top` 1173 (WindowServer, uid 88) + 13
    (MTLCompilerService, root).
  - That 13 MB is the whole gap the earlier doc saw (1177 vs 1164).
- **Correction: the kernel struct is 400 bytes,** not the 360 the named fields cover. Five
  unnamed uint64 words follow `swapins`.
  - `phys_footprint` is still at byte offset 320 (word 40).
  - A buffer that is too small is **silently truncated with rc=0, errno=0**, so the return
    code can't reveal a layout mismatch.
  - Errors: NULL buffer → EFAULT; unknown cid → ESRCH.
  - `cpu_time_eqos_len` (word 23) == 7 in all 543 coalitions.
- **`tasks_started − tasks_exited` equals the live members observed:** 543 of 543 coalitions,
  6 runs, including the 50-member churny Warp coalition.
- **Cost per sweep** (678 pids, 540 coalitions):
  - flavor 20 for every pid: 0.30 ms CPU;
  - one coalition call per coalition: 0.75 ms;
  - a full sweep with rusage, path and grouping: ~5.1 ms;
  - `top -l 1`: ~260 ms CPU (0.27 s real).
- **Mixed coalitions** occur transiently when a setuid child runs (`top`, `ps`, `sudo`).
  The coalition total covers them.
- **The coalition `swapins` field is in bytes.** It is not a page count.

## Identity, labels, units

- **Correction: `responsibility_get_pid_responsible_for_pid` is `pid_t f(pid_t)`.** It
  returns −1 with EPERM for root and other-uid pids.
  - `probes/probe.c`'s 4-argument cast misreads it: its `rc` is the pid.
  - Results: Safari's WebContent, GPU and Networking → Safari. Everything in a Warp session →
    Warp (1171), so it **can't split Claude sessions**. WallpaperAgent → itself.
  - A sibling, `responsibility_get_responsible_for_pid(pid, pid_t*, uint64_t*, size_t*, char*)`,
    exists.
- **`sysctl KERN_PROC_ALL`** returns all 677 pids, root included, with ppid, euid (`cr_uid`)
  and `p_starttime`, in ~0.075 ms CPU.
  - `p_starttime` equals `pbi_start` wherever both work.
  - euid ≠ ruid on WindowServer (88/0) and loginwindow (501/0). The kernel's EPERM check uses
    the euid.
- **Per-pid flavors that refuse other-uid pids:** `PROC_PIDTBSDINFO` (EPERM on 239/677) and
  `PROC_PIDVNODEPATHINFO`.
- **Per-pid flavors that work on every pid:** `PROC_PIDT_SHORTBSDINFO` and flavor 17
  (`p_uniqueid`).
- **Correction: `ri_proc_start_abstime` can't key root processes.** `proc_pid_rusage` gives
  EPERM on them, and that clock stops during sleep (34,284 s of drift measured). Key
  processes by pid + `kinfo_proc.p_starttime` instead.
- **`ri_user_time` / `ri_system_time` are mach ticks.** Multiply by 125/3 to get ns on M1.
  - Read as ns, they undercount 41×.
  - Checked against `ps`: Warp 7645.97 s both ways; Finder 2184.96 s vs 36:24.96.

## Claude Code, Safari, simulators, wallpaper

- **Claude Code** runs as `~/.local/share/claude/versions/<ver>` (the file itself; several
  versions run at once).
  - cwd is readable via `PROC_PIDVNODEPATHINFO`.
  - MCP children are `node` ppid-descendants, each 34.5–66.1 MB.
  - All sessions sit in Warp's coalition, and a transient nested `claude` appears under a
    session's tool shell.
  - 6 sessions: 362–501 MB each, ~2.7 GB in total. Warp's coalition: 46 processes, 3387.6 MB
    (equal to the per-process sum).
- **Safari** runs from `/System/Volumes/Preboot/Cryptexes/App/…`; its WebKit helpers run from
  `…/Cryptexes/Incoming/OS/…` and `…/Cryptexes/OS/…`.
  - Its WebContent processes are in Safari's coalition, and their responsible pid is Safari.
  - Safari's coalition also holds GPU, Networking, the open/save panel and others.
  - Other apps' WebKit helpers sit in those apps' coalitions.
- **Simulators:** none was booted, so the launchd_sim path, coalitions and subtree are
  unmeasured.
  - `device.plist` keys: `deviceType`, `isDeleted`, `isEphemeral`, `name`, `runtime`,
    `runtimePolicy`, `state` (1 = Shutdown), `UDID`.
  - 4 device dirs exist, while `simctl` lists 3.
  - The idle CoreSimulator services stay up (~55 MB).
- **Wallpaper:**
  - **WallpaperAgent** (uid 501) is the launchd agent `com.apple.wallpaper.agent`, with
    `KeepAlive {AfterInitialDemand: true, SuccessfulExit: false}`, `ThrottleInterval 1`, and a
    soft jetsam limit of 30 MB.
  - **WallpaperImageExtension** (uid 501, ppid 1) is an ExtensionKit service in
    WallpaperAgent's domain, managed by RunningBoard, with no KeepAlive and a soft jetsam limit
    of 1000 MB. The kernel won't cap the leak.
  - It is in its **own** resource coalition (29980) and shares only the jetsam coalition (664)
    with the agent. Its responsible pid is itself.
  - Observed: 107 MB, 58 min after a restart at 09:57.

## `top`, `footprint`, system counters

- **`top -l 1 -stats pid,mem,cmprs`** lists every process (687 of 687), root included.
  - The header is 9–12 lines depending on flags, and rows are sorted by pid, descending.
  - MEM uses B/K/M/G in powers of 1024 (MauiAUSP `305M` = 319,538,448 B), and switches to G
    at ≥ 10000 M.
  - From the second sample on, it appends `+` or `-`.
  - `-pid` filtering costs the same 0.27 s.
- **`footprint -p`** is not setuid, so it fails on root pids (exit 66). Only its
  `phys_footprint:` line equals `ri_phys_footprint`; the `Footprint:` header is a sum of
  categories (302 vs 305 MB).
- **Readable unprivileged:** `kern.memorystatus_level` (= `memory_pressure`'s free %),
  `kern.memorystatus_vm_pressure_level` (1/2/4), `vm.swapusage` (`xsw_usage`), `hw.memsize`.
- **The compressed figure:** "Compressed" as Activity Monitor and `top` show it =
  `HOST_VM_INFO64.compressor_page_count` × 16 KiB (2785 MB). `vm.compressor_bytes_used` is the
  payload and smaller (2466 MB).
- **The swap-in counter:** `HOST_VM_INFO64.swapins` counts 16 KiB compressed-swap units
  (xnu `vm_swap_get`). It ran at 0–1.2/s at pressure level 1.

## Toolchain and menu-bar cost

- **Package:** `swift-tools-version: 6.4` with `.macOS(.v27)`. `.macOS("27.0")` parses from
  6.0. Swift 6 mode is the default.
- **A scratch package** builds and tests green: a C `dlsym` target, a Swift 6 library with
  libproc and SQLite3, Swift Testing.
  - It needed the fixes: `@MainActor` singletons; capture the `@MainActor` model in timer
    handlers, never a non-Sendable `self`.
  - Clean build 8 s, `swift test` 4 s.
- **Build output:** SwiftPM 6.4 builds into `.build/out/Products/{Debug,Release}`, with
  `.build/debug` and `.build/release` as symlinks.
- **Footprint after 20 s, release, menu never opened:**
  - AppKit `NSStatusItem` + `NSMenu`: 16 MB;
  - SwiftUI `MenuBarExtra(.menu)`: 21 MB;
  - AppKit + SQLite + 3 MB of history: 20 MB.
- **Incumbents:** TypeFlow 61 MB and 1.37 % of a core on average; MagicQuit 27 MB and 1.12 %;
  Tailscale 40 MB and 0.10 %; ZeroTier UI 26 MB and 0.08 %.
- **Not measured:** footprint after the menu has been opened, and growth over hours.

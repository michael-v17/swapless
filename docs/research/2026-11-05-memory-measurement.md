# Measuring and attributing memory without privileges (2026-11-05)

Context, not authority (CLAUDE.md §2). Measured on the target Mac (M1 Pro, 16 GB, macOS 27.2) by a
read-only research agent with small C probes, kept in `probes/` (our own code). Claims marked ✓
were re-run by hand.

## 1 · Footprint per process: what Activity Monitor shows

- Activity Monitor's "Memory", `top`'s MEM and Xcode's gauge all read the **`phys_footprint`
  ledger** (`man footprint`). It includes compressed memory; RSS doesn't.
- **Same-user processes:** `proc_pid_rusage(pid, RUSAGE_INFO_V4)` → `ri_phys_footprint`. Or use
  `task_name_for_pid` + `TASK_VM_INFO`, which also gives `compressed` and matched top's CMPRS.
- **Other users' processes** (root, `_windowserver`): `proc_pid_rusage` fails with EPERM
  (xnu `bsd/kern/proc_info.c` ~3181–3199). `PROC_PIDT_SHORTBSDINFO` (ppid), `PROC_PIDPATHINFO`
  and `PROC_PIDCOALITIONINFO` still work for every pid.
- **The unprivileged path to WindowServer:** `coalition_info_resource_usage(cid, &cru, size)`,
  private and loaded with `dlsym`, then read `cru.phys_footprint`. ✓ Measured: WindowServer's
  coalition gives 1177.2 MB, `top` gives 1164 MB, and its own `proc_pid_rusage` returns -1. The
  kernel does no privilege check there (`sys_coalition.c:380`, `/* TODO: priv check? */`).
- Why `top` sees everything: `/usr/bin/top` is **setuid root** ✓. `/bin/ps` is setuid too but gives
  only RSS (WindowServer 278 MB RSS vs 1164 MB footprint).
- **Cost:** a native sweep of 669 pids takes ~4 ms of CPU, and one `top -l 1` ~0.27 s. Polling `top`
  or `ps` costs ~70× more, which is where Stats and RAMBar spend their CPU.

**Recommendation:** use `proc_pid_rusage` for same-user processes and coalition usage for the rest,
with a `top -l 1 -stats pid,mem` fallback if the private symbol goes away.

## 2 · Grouping into "apps"

- **Coalition = responsible process = what the user calls "the app".** Grouping by coalition and
  by responsible pid gave the same top-12 list here. Key groups on `coalition_id[0]` from
  `proc_pidinfo(pid, 20 /* PROC_PIDCOALITIONINFO */)`, which works for all pids.
- **Label each group** with `responsibility_get_pid_responsible_for_pid`. It is private, has the
  signature `pid_t (pid_t)` and needs `dlsym`; it covers same-user processes only and returns -1
  otherwise. Then use `proc_pidpath` → the enclosing `.app` → `NSRunningApplication`. Stats groups
  the same way (`Modules/RAM/readers.swift` ~210–227).
- **Terminals lump every CLI session together.** Warp's coalition held 47 processes and 3 GB. Split
  it by the ppid subtree rooted at each Claude Code process (`~/.local/share/claude/versions/*`);
  its MCP children are `node`, at 35–66 MB each.
- **Safari:** WebContent processes sit in Safari's coalition, and their responsible pid is Safari.
  **Per-site labels are out of reach:** Activity Monitor reads them under a private LaunchServices
  entitlement (`com.apple.private.launchservices.allowedtoget.LSActivePageUserVisibleOriginsKey`).
  The best we can show is "Safari Web Content pid N: X GB". Killing one reloads that tab.
- **Simulators** (not verified on a booted one): find each `…/RuntimeRoot/sbin/launchd_sim`, then
  read its `KERN_PROCARGS2` (allowed for same-user processes) and match `Devices/<UDID>/` or
  `SIMULATOR_UDID=`. Attach the descendants by ppid. The name and state are in
  `~/Library/Developer/CoreSimulator/Devices/<UDID>/device.plist`; no `xcrun` spawn needed.

## 3 · Which pressure signal to alert on

- **"Warning" measures compressor headroom, not slowness.** It fires when available
  non-compressed memory falls below the compressor's compact threshold (xnu `vm_pageout.c`
  ~10300–10360). That is why the old tool alerted at 42–47 % free.
- `kern.memorystatus_level` = the "free percentage" of `memory_pressure`.
  `DispatchSource.makeMemoryPressureSource` pushes the same levels (1/2/4). `vm.swapusage` is a stock
  that rarely shrinks, so it makes a poor alarm.
- **The signal that means real stalls is the swap-in rate:** `host_statistics64(HOST_VM_INFO64)`
  sampled every 30 s. `coalition_resource_usage.swapins` and `TASK_VM_INFO.ledger_swapins` say
  *which app* is being swapped back in.
- **Starting thresholds** (heuristics, to calibrate against a week of logs): soft at ≥ 500 pages/s
  (~8 MB/s) for 60 s; hard at ≥ 2,000 pages/s, or "critical". Compressor size
  (`vm.compressor_bytes_used` / `hw.memsize`) is context only.

## 4 · Prior art (licenses checked)

| Project | License | Take | Avoid |
|---|---|---|---|
| MaxGhenis/rambar | Unlicense | Uses `ri_phys_footprint`; Claude session trees; least-squares slope (≥ 6 points, ≥ 1 MB/min); a "runaway guard" (+10 % of RAM in 30 s) | Shells out to `ps` every 5 s; misses other users' processes; matches Chrome tabs to renderers by sorted index |
| exelban/stats | MIT | Groups by responsible pid; reads pressure level and swap | Spawns `top -l 1` every refresh; no trend or leak detection |
| alfishe/scenekit-watchdog | MIT | Kills one leaking extension: the same pattern as our wallpaper guard | — |
| WonderBox, current/wisp | MIT | Footprint + memorystatus; per-app grouping | Not read in depth |

## 5 · Leak detection (proposal)

- **Key** each process by pid plus its start time (`ri_proc_start_abstime`), because pids get reused.
- **Sample** the footprint every 30 s and **store the minimum of each 5-minute bucket**, which
  removes garbage-collection sawtooth. Keep 24 h (288 points per process).
- **Baseline:** the lowest bucket of the last 6–24 h, or the median of the first hour.
- **Flag** when all three hold, confirmed on 2 consecutive evaluations:
  - footprint ≥ max(500 MB, 3× baseline);
  - Theil–Sen slope over the last 2 h ≥ 100 MB/h;
  - ≥ 70 % of bucket-to-bucket steps rising.
- **Fast path:** a gain of more than 10 % of RAM within 5 min.
- Use `ri_lifetime_max_phys_footprint` to catch spikes between samples.
- At ~150 MB/h from a 110 MB baseline, this flags the wallpaper leak in ~2.5 h, long before it
  reaches 3 GB.

## Pitfalls

- **Footprint and RSS diverge both ways.** WebContent: 9 MB footprint vs 50 MB RSS. MauiAUSP: 305 MB
  footprint, 302 MB of it compressed, 16 MB resident. Show footprint and compressed side by side.
- **Private symbols can change between releases** (`responsibility_*`,
  `coalition_info_resource_usage`, flavor 20). Load them with `dlsym`, check them at launch against
  `proc_pid_rusage` on a same-user single-member coalition, and fall back to `top`.
- **A coalition's footprint is a sum** (WindowServer's had 2 live tasks).
- **WindowServer can't be acted on.** It is a symptom of other apps' windows.
- **Killing a WebContent process reloads a tab** the owner may be looking at.

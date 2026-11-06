# Menu-open cost and freshness: probes for `v1-menu-today` (2026-11-05)

Measured on this Mac (MacBook Pro M1 Pro, 16 GB, macOS 27.2) on 2026-11-05, 22:30–23:15 local,
during the `/wingman` session for `specs/v1-menu-today.md`. Context, not authority (CLAUDE.md § 2).
Nothing was shown on screen: the probes ran `--headless` or in the app's no-status-item
`SWAPLESS_RIG_MENU_DRAWS` mode, each with a temp state dir, `--duration` and a SIGTERM
watchdog. The installed app was only observed: its own `self` log lines and `ps`, never its
folder.

MB / GB are MiB / GiB, as in the v1-core spec.

## 1 · The installed app's own numbers (`self` lines, category `self`)

Source: `/usr/bin/log show --start '2026-11-05 00:00:00' --predicate 'subsystem ==
"com.michaelv.swapless" AND category == "self" AND processImagePath ==
"/Applications/Swapless.app/Contents/MacOS/Swapless"'`. There is one line every 300 s, with
cumulative `cpuSeconds` and `menuOpenSeconds`. CPU % = Δ(cpuSeconds + childCpuSeconds) / Δwall.

**Menu closed through a 5-min interval** (54 intervals, three app pids, 17:10–22:35):
- median **0.118 %** of a core, p90 0.178 %, third highest 0.208 % (18:45);
- the two highest are **0.855 % (21:55–22:00) and 0.377 % (22:00–22:05)**. They come right after
  the owner's 130 s of menu use, while `/ship-task` merged PR #1 (21:58: builds and tests
  churning processes). The app logged no action and no flag then. The offscreen run (§ 3) shows
  no tail after close, so the cause is **not attributed**: an on-screen AppKit tail or the
  concurrent build load.
- excluding those two, every pair of consecutive closed intervals (a 10-min window) stays
  ≤ 0.17 %.

**Menu open** (the owner's acceptance use):

| App pid | Interval | Menu open | ΔCPU | Open cost (closed time at 0.11 % subtracted) |
|---|---|---|---|---|
| 77090 | 20:10–20:15 | 20.0 s | 1.641 s | ≈ **6.7 %** of a core |
| 74768 | 21:40–21:55 | 129.6 s | 8.707 s | ≈ **6.1 %** of a core |

The second row may be inflated by the same concurrent load as the tail above.

## 2 · Engine sweep cost (headless, release build, empty rules)

| Probe | Interval | Ticks | CPU per tick |
|---|---|---|---|
| p1 | 30 s | 4 (first excluded) | **24 ms** (0.081 % of a core) |
| p2 | 2 s | 74 | **30 ms** (1.51 % of a core) |

Headless output includes a full `sample` JSON line per tick (every pid), which the app doesn't
write. **The v1-core spec's "a sweep costs 1.7–5.1 ms" (§ B) does not hold for the shipped
sweep.**

**Profile** (`/usr/bin/sample` on the release headless engine at a 0.25 s interval, 12 s, ~48
ticks; samples on the engine queue, by `Engine.baseTick` line):

| Part | Samples | Share |
|---|---|---|
| `source.sweep()` (of which `__coalition_info` ~124, `__proc_info` ~34) | 148 | 40 % |
| `emitSample` (JSON, headless only) | 113 | 31 % |
| `grouper.group` | 88 | 24 % |
| detector | 18 | 5 % |

So in the app (no JSON) a sweep plus grouping is **~20–25 ms** of CPU.

## 3 · Offscreen menu cost and post-close tail (app mode, no status item)

The release bundle with `SWAPLESS_RIG_MENU_DRAWS=30`, `--duration 420`: a 30 s settle, then the
menu-open display sweeps (every 2 s) and 30 offscreen draws of the real menu (every group
submenu filled, compressed reads included), then closed. `ps` time every 5 s:

| Phase | Wall | CPU | Rate |
|---|---|---|---|
| draws + display sweeps | 61 s | 0.87 s | **1.43 %** of a core, **29 ms per 2 s cycle** |
| closed, after the draws | 330 s | 0.22 s | **0.067 %**: steps of ~0.03 s per 30 s base tick, **no tail** |

`menuDraws`: 30 draws, 3,151 rows, 0 visible, 0 windows; peak 17.1 MiB.

**What it implies:** of the ~120 ms of CPU per 2 s that the on-screen menu costs (§ 1, ~6 %), ~25 ms
is the display sweep and ~5 ms the in-process model and fill. The remaining ~90 ms is the
on-screen menu redrawing. The menu redraws **twice** per 2 s: `MenuController` has its own
2 s `Timer` on top of the refresh that every engine publish triggers. Each refresh also re-reads
`SMAppService.mainApp.status` and re-sets every item's properties, changed or not.

## 4 · Freshness: how much the top-10 rows move (p2, sweeps 2 s apart, 148 s)

Rows = the 10 biggest groups at the earlier sweep; "text changed" = the menu's formatted value
(`1.42 GB` / `305 MB`) differs.

| Gap | Rows whose text changed | \|Δ\| median | \|Δ\| p95 | \|Δ\| max | Top-10 order changed |
|---|---|---|---|---|---|
| ~2 s | 24.0 % | 0.0 MB | 32.5 MB | 217 MB | 20 of 74 pairs |
| ~4 s | 29.2 % | 0.1 MB | 42.9 MB | 216 MB | 24 of 73 |
| ~7 s | 32.6 % | 0.2 MB | 48.1 MB | 199 MB | 30 of 72 |
| ~11 s | 38.5 % | 0.3 MB | 72.8 MB | 208 MB | 33 of 70 |
| ~33 s | 52.8 % | 0.7 MB | 106 MB | 275 MB | 45 of 60 |

The big moves are **steps, not drifts**: WindowServer jumped 217 MB and the wallpaper extension
132 MB within one 2 s gap. A faster cadence shows a step a few seconds sooner. It doesn't show
anything the owner could act on sooner. The staleness that matters is **at open**: the
menu opens with the last base tick, up to 30 s old (the ~33 s row). The display sweep that
runs right when the menu opens removes that.

Activity Monitor's update frequency choices are 1, 2 and 5 s, with 5 s ("Normally") the
default. This Mac has no `UpdatePeriod` override (`defaults read com.apple.ActivityMonitor
UpdatePeriod`: key not found).

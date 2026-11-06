# What showing the menu costs in footprint (2026-11-05)

**Question (owner, after acceptance):** the installed app sat at 37 MB idle after the owner had
used its menu, above the 30 MB steady budget. Is that Swapless, or AppKit memory that can't be
released?

**Answer:** almost all of it is AppKit and the frameworks under it, held after the menu is
drawn. Swapless's own data is ~0.4 MiB of it. Nothing public releases the rest.

## The installed app (pid 77090, release, up 2.5 h, menu open 197 s in total)

- `self` lines: 21.7–24.4 MB from 14:45 to 16:05 (menu never opened), 34.2 MB at 16:15 (after
  the first 62 s of menu use), then 35.2–37.3 MB, the menu closed for the last 10 min.
  `phys_footprint_peak` 39.0 MiB.
- `footprint -p`: 28 MB of 37 MB is **Malloc Small**. CoreAnimation, CG Image, CoreUI image
  data and fonts total under 1.5 MB.
- `vmmap --summary`, DefaultMallocZone: **17.6 MB allocated** (49,462 blocks), **9.6 MB
  fragmentation** (35 %).
- `heap`: 12.3 MB of "non-object" blocks, of which **32 blocks of 272 KB** (8.7 MB). `leaks`:
  6 KB really leaked, so the 272 KB blocks are referenced.
- `leaks --traceTree` on one block: `ColorSyncTransform` → `CFData` → the block, held in
  CoreGraphics' color caches (`CGCMSConverterColorCache`, `NSCache`).

## Controlled runs (the repo's release bundle, temp state dir, `SWAPLESS_DRY_RUN=1`)

`SWAPLESS_RIG_MENU_SHOWS=N` opens the real status-item menu N times through its button and walks
three group submenus per show with arrow keys posted to the app's own event queue. Measured
with `footprint -p` and `vmmap --summary` from outside.

| Run | Idle footprint | Peak | Malloc allocated | Fragmentation | 272 KB blocks |
|---|---|---|---|---|---|
| never opened, 60–120 s | 18.0–18.6 MiB | 18.6 MiB | 10.1 MB | 2.0–2.5 MB | 18 |
| 20 top-level shows, no submenus | 26.1–27.5 MiB | 30.1 MiB | 17.3–18.8 MB | 1.2–1.8 MB | 36 |
| 10 shows, 11 submenus | 29.1 MiB | 33.1 MiB | 17.6 MB | 4.3 MB | 36 |
| 10 shows, 24 submenus | **31.8 MiB** | 33.6 MiB | — | — | 36 |
| 10 shows, 30 submenus, **no refresh, no display sweeps** (experiment build) | 28.3–28.6 MiB | 30.8 MiB | 17.6 MB | 2.7–3.2 MB | 36 |
| **rig check 5 menu test** (`leak-rig.sh --budget`): 10 shows, 30 submenus, 60 s closed | **34.4 MB** | 37.5 MB | — | — | — |

- **The 272 KB blocks** (allocation stacks, `MallocStackLogging=1`): `calloc` in ColorSync's
  `CMMParaCurveTag::MakeInvertedTRC` / `MakeTRC`, reached from QuartzCore drawing menu glyphs
  (`draw_glyphs` → `CARequiresColorMatching` → `colorspace_has_srgb_gamma` →
  `CGColorSyncTransformCacheGetRetained` → `ColorSyncTransformCreate`). The cache is bounded:
  18 blocks at launch (the status item), 36 after the first shows, no more after 20 shows.
  A fixed ~4.8 MiB the first time the menu is drawn.
- **Live heap, never opened → 10 shows with 24 submenus** (`heap` class diff): +8.1 MiB.
  ColorSync tables 4.8 MiB; other untyped framework buffers ~1.1 MiB; Objective-C method
  caches 0.55 MiB; Swift type metadata 0.48 MiB; **Swapless's own data ~0.4 MiB** (one more
  `ProcessSample` array, groups, strings).
- **The rest of the gap** (~5.5 MiB) is malloc fragmentation and image/animation regions left by
  drawing. `malloc_zone_pressure_relief(nil, 0)` 3 s after the menu closed released **0 bytes**
  in all 5 runs: the freed space sits in pages that still hold live blocks.
- **Swapless's 2 s refresh** adds roughly 0.5–3 MiB on top of a static menu (mostly
  fragmentation), with large run-to-run variance (the rig's run, 34.4 MB, is the highest).
  With it on, keyboard-walked submenus opened 11, 24 and 30 times out of 30 in three runs;
  with it off, 30 of 30. The refresh may sometimes interrupt an open submenu (not checked
  with a mouse).
- **The 17 `NSStatusBarWindow`s** are there at launch too: AppKit's, not a leak.

## Offscreen: what reproduces it without showing anything (2026-11-05, after the owner's rule)

The owner's rule (DECISIONS.md) keeps every Swapless menu and window off the screen during
tests. Does drawing the menu offscreen leave the same framework memory? The release bundle,
`SWAPLESS_RIG_MENU_DRAWS=50` (no status item; 30 s settle, then 50 draws of the real menu and
all its group submenus, 2 s apart, display sweeps on), measured from outside with `footprint`,
`vmmap` and `heap`:

| Offscreen method | Before | +5 s | +60 s | +120 s | Peak | 272 KB blocks |
|---|---|---|---|---|---|---|
| `NSMenuItemCell` into a plain `CGBitmapContext` (screen color space) | 11.2 MiB | 14.9 MiB | 14.6 MiB | — | 15.7 MiB | **0** |
| layer-backed text fields in a borderless window, never ordered on screen, kept alive | 10.9 MiB | 23.1 MiB | 24.5 MiB | — | 26.0 MiB | 18 |
| the same, window released after the draws | 10.7 MiB | 22.7 MiB | 21.8 MiB | 19.8 MiB | 26.8 MiB | **18** |
| AppKit's `NSMenuItemCell` in layer-backed views of a never-ordered window, one window per draw (5,252 rows drawn) | 11.1 MiB | 14.5 MiB | 14.7 MiB | 16.0 MiB | 16.1 MiB | 9 |

- **Offscreen drawing doesn't faithfully reproduce it.** The result depends on how the rows
  are drawn, and nothing offscreen draws the menu's real views (they are private to
  `NSMenu`). AppKit's own menu-item cell leaves +3–5 MiB, in a window or in a bitmap. Only
  rows rebuilt as 5,400 text fields come close (+9–11 MiB, and the same 18 ColorSync tables
  the on-screen menu adds: 36 on screen − 18 from the status item at launch), and that is a
  construction, not the menu. On screen the menu leaves +10–14 MiB.
- Without a status item the app starts at ~11 MiB, not 18: the status item itself costs
  ~7 MiB, including its own 18 ColorSync tables.
- So check 5 keeps its 30 MiB "never shown" window, and the 40 MiB "after use" limit is the
  owner's acceptance check, read from the footprint Swapless shows in its menu footer (owner,
  2026-11-05). Check 5's offscreen menu draw test (the cell method, one window per draw)
  stays as a functional test: all 50 draws complete, nothing visible, peak ≤ 45 MiB.
- **It found a bug the on-screen runs hid.** On the second draw, `-[NSMenu insertItem:atIndex:]`
  raised `NSInternalInconsistencyException` ("Item to be inserted into menu already is in
  another menu"). Group rows are positional, so after the groups reorder a row gets a new
  submenu for its new group, while that group's cached member rows still sit in its previous
  submenu. AppKit logs an exception raised in a timer callback and carries on, so the fill
  just stopped. The committed code (`removeAllItems` + `addItem`) had the same assertion. In
  the real app it fires only if the old submenu is still alive when the new one is filled
  (not observed there). Fixed: a reused row is taken out of the menu that still holds it
  before it is inserted. A unit test on real `NSMenu`s reproduces the exception with the
  fix removed.

## What it means for the budget

- Fresh app, menu never opened: ~18 MiB. After hours of uptime (installed app): 22–24 MB.
- Drawing the menu once adds ~8–10 MiB that stays (frameworks); using submenus adds more
  fragmentation. Realistic idle after menu use, after hours: **~32–37 MiB**. The peak during
  menu use: 33–39 MiB.
- Not verified: whether the CoreGraphics caches are dropped under system memory pressure
  (simulating it needs `sudo memory_pressure`).

**Decision (owner, 2026-11-05):** the budget splits into ≤ 30 MiB idle before the menu has ever
been shown, ≤ 40 MiB idle after it has been used, and peak ≤ 45 MiB. See DECISIONS.md.

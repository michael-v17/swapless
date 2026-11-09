# Quit on last window close: the Notes and Slack probes (2026-11-06)

Context, not authority (CLAUDE.md § 2). Measured in the `/wingman` session for
`specs/v1-quit-on-close.md`, on this Mac (M1 Pro, 16 GB, macOS 27.2), three displays (Spaces
visible at the time: `6,1379,1382`), Stage Manager off (`com.apple.WindowManager
GloballyEnabled = 0`).

Tool: `docs/research/probes/winprobe.swift` (built with `swiftc -O`), run from the owner's
terminal, which already had Accessibility (`AXIsProcessTrusted=true`). It is read-only: it never
presses, closes or quits anything and shows no UI (activation policy `.prohibited`). It reads:
- each app's AX windows: role, subrole, `AXMinimized`, and the window id from the private
  `_AXUIElementGetWindow`;
- its CG windows (`CGWindowListCopyWindowInfo(.optionAll)`): layer, on-screen, alpha, bounds;
- each window's Spaces from SkyLight's private `CGSCopySpacesForWindows(conn, 7, [wid])`;
- the visible Spaces (the "Current Space" of each display, from `CGSCopyManagedDisplaySpaces`).

`watch` mode also logs AX notifications, global left-mouse and ⌘-key events, and prints a
**verdict** on every change under the candidate rule:
alive = (AX windows with subrole `AXStandardWindow`) ∪ (layer-0 windows whose Spaces are all
currently invisible). The owner closed the windows by hand; the probe watched.

## 1 · Passive snapshot, nothing touched

| App | AX windows | CG layer-0 windows | Layer-0 windows on a Space |
|---|---|---|---|
| Notes (window open) | 1 standard | **15** | 1 (the real one, Space 6) |
| Notes (window on Space 6, owner on Space 5) | **0** | 15 | 1 (Space 6) |
| Notes (window closed) | 0 | 15 | **0** |
| Warp, iTerm2 (windows on another Space) | 0 | 13–14 | 1 each (Space 6) |
| WhatsApp, two Safari web apps (running, no window) | 0 | 12–13 | 0 |
| Chrome (window visible) | 1 standard | 17 | 3: the window + two off-screen 1830×458 / 1830×139 on the same Space |
| Safari (window visible) | 1 standard | 15 | 2: the window + one off-screen 792×528 on the same Space |
| Portal | 3 `AXGroup/AXHostingView` (wallpaper, desktop layer) | 13 | 1 off-screen 1400×900 |
| Finder | 1 `AXScrollArea/AXDesktop` | 12 | 0 |

The Notes helpers are layer-0, alpha 1.0, ordered out and on no Space: one 500×500, the rest
1920×30, 3440×30 and 1512×33 (one pair per display).

**What it shows:**
- **Counting CG layer-0 windows can never reach zero for Notes.** That is why MagicQuit 2.0
  never fired on it. Its unreleased 2.0.1 filter (≥ 64×64, alpha > 0) would still count the
  500×500 helper.
- **AX does not list a window that sits on another Space**, but SkyLight still puts it on its
  Space. Deciding on AX alone would quit Warp, iTerm2 or Notes while their window waits on
  another Space.
- **"Has a Space" alone doesn't prove a real window**: Chrome and Safari keep ordered-out
  windows attached to the visible Space.
- **Apps run with no window at all** (WhatsApp, the Safari web apps), so turning the feature on
  must not act on a state; only a close it sees happening.

## 2 · Run A: Notes, watched for 90 s

The owner opened a window, minimized it, switched Space and back, restored it, closed it with
the red X, reopened it and closed it with ⌘W. Timeline, trimmed (unrelated clicks in other apps
dropped):

```
  0.394  WOULD-QUIT AX=[] cg0total=14                         (Notes running, no window)
 19.664  AXFocusedWindowChanged / AXMainWindowChanged / AXWindowCreated wid=43392
 19.684  alive(ax=1) AX=[43392] 43392 on-screen [6]
 25.576  AXWindowMiniaturized wid=43392
 25.576  WOULD-QUIT AX=[43392 minimized, subrole AXDialog] 43392 off-screen [6]   ← rule bug
 31.141  alive(elsewhere=1) visibleSpaces=5,…                  (owner on Space 5)
 33.406  WOULD-QUIT visibleSpaces=6,…                          (back on Space 6, still minimized)
 41.832  AXWindowDeminiaturized / AXWindowCreated wid=43392    (restored from the Dock)
 46.892  mouse down on 43392 (red X)
 47.038  AXUIElementDestroyed wid=0
 47.138  WOULD-QUIT AX=[] (43392 still in CG, ordered out, no Space)
 54.939  AXWindowCreated wid=43392                              (reopened: same id)
 65.544  key cmd+w
 65.672  AXUIElementDestroyed wid=0
 65.682  WOULD-QUIT AX=[]
```

**Findings:**
- **A minimized window reports subrole `AXDialog`**, not `AXStandardWindow`. The candidate rule
  counted it as gone. That would have been a wrongful quit. **Fix: count every AX window with
  `AXMinimized = true`, whatever its subrole.** AX keeps listing the minimized window from
  another Space (31.1 s), and SkyLight keeps it on its Space (6) the whole time.
- **The red X and ⌘W both fire `AXUIElementDestroyed`** on the window element registered for it.
  The callback's element is already dead (`_AXUIElementGetWindow` → 0), so the trigger can't
  name the window. AX reads empty ~100 ms later.
- **Notes reuses the window**: id 43392 stays in the window server, ordered out with no Space,
  and comes back with the same id. So Notes' CG layer-0 count never changes (14 → 14).
- Re-registering `AXUIElementDestroyed` on an element already registered returns `-25209`
  (`kAXErrorNotificationAlreadyRegistered`), which is harmless.

## 3 · Run B: Slack, watched for 60 s

The owner closed Slack's window with the red X, reopened it from the Dock and closed it with ⌘W.

```
  0.364  alive(ax=1) AX=[43438] 43438 on-screen [6]  cg0total=1
  7.568  mouse down on 43438 (red X)
  7.630  AXUIElementDestroyed wid=0
  7.861  WOULD-QUIT AX=[] 43438 OFF-screen but still on Space [6]
 11.898  AXWindowCreated wid=43438 (same id)   cg0total=14 (helpers appear after reopening)
 16.007  key cmd+w
 16.094  AXUIElementDestroyed wid=0
 16.122  WOULD-QUIT AX=[] 43438 off-screen, Space [6]
```

**Findings:**
- **Slack fires `AXUIElementDestroyed` on both the red X and ⌘W** on macOS 27.2 with the current
  Slack. The 2026-11-05 research said hide-on-close apps fire no destroyed event (cause 3);
  that doesn't hold here. **No mouse-click capture is needed.**
- **Slack hides its window and keeps it on its Space** (43438 ordered out, Space 6). With the
  owner on Space 6, the rule reads it as gone, which is correct. If the owner switches Space
  before the decision, the hidden window would look like "a window on another Space" and the
  quit would be missed. **Fix: when a close event fires, mark every window of that app that is
  then absent from AX and on no Space or on a visible Space as closed.** A closed window never
  counts as being elsewhere, and the mark clears if the id shows up in AX again.
- After the first reopen Slack also creates 13 Notes-like layer-0 helpers (on no Space).

## 4 · The rule these probes settle

Spec `v1-quit-on-close` § T3 is the contract; in short:
- **Alive windows**:
  - AX windows (role `AXWindow`) that are minimized (any subrole), or not minimized with any
    subrole except `AXFloatingWindow` / `AXSystemFloatingWindow`. The readiness review
    widened this from "standard or dialog", so an unknown kind of visible window keeps the app
    alive;
  - plus layer-0 windows whose Spaces are all currently invisible and that were not marked
    closed.
- Windows on no Space never count.
- **Trigger:** `AXUIElementDestroyed` registered on every window element, with app
  deactivation as a backstop.
- **Decision:** 5 s after the trigger, confirmed again 0.5 s later.

## 5 · Not measured here (they go to the rig or to the owner's acceptance)

- Native tabs, full-screen, and Mission Control in progress.
- Display reconfiguration.
- An app that refuses to quit.
- A visible standalone dialog.
- Stage Manager on.
- How these signals look for an `LSUIElement` test app whose windows sit off every display (the
  rig's first pass checks this).

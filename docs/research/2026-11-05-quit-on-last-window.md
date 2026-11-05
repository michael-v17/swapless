# Quit on last window close: prior art and a design (2026-11-05)

Context, not authority (CLAUDE.md §2). Research by a read-only agent. The one claim re-checked by
hand is marked ✓. No code was copied; GPL sources were read for ideas only (DECISIONS.md, License).

## Why MagicQuit never fired on this Mac

Measured on 2026-11-05: setting on, Accessibility granted, Notes and Slack not excluded. The last
window of Notes (3 tries) and of Slack (the owner's try) closed, and the app kept running.
`/usr/bin/log stream` showed nothing from the `com.MagicQuit` subsystem.

1. **The installed binary is v2.0 (build 16), the only release.** ✓ `grep -a` on
   `/Applications/MagicQuit.app/Contents/MacOS/MagicQuit` finds `Last window closed` but none of
   the strings 2.0.1 added (`too young`, `CG windows`, `AX windows`, `window-close watcher`). The
   fixes on GitHub HEAD (commits `03231e8`, `463135f`, labelled 2.0.1, 2026-07-21) were never
   released, and the appcast offers only build 16. Its CHANGELOG describes the bug: "invisible
   helper windows blocked the window count check, and a missed close event was never retried."
2. **v2.0's decision gate:**
   - It counts every layer-0 window `CGWindowListCopyWindowInfo(.optionAll)` returns for the app,
     visible or not, at any size or alpha. Closed-but-kept windows and helper windows keep it above
     zero, so it returns early without logging.
   - A missed "destroyed" event is never retried.
   - Its only log line is on the success path, which is why `log stream` was silent.
3. **Slack hides its window on close instead of destroying it** (Electron behaviour, also reported
   for Discord in SwiftQuit #25). No AX "destroyed" event fires at all.
4. **Even HEAD (2.0.1) may still fail on Slack** (inferred). It counts off-screen windows of at
   least 64×64 with alpha > 0, and a hidden Electron window keeps its full size and alpha.

Lesson: read the source **at the installed tag**, not at HEAD.

## How other tools do it

| Tool (license) | Trigger | Quit decision | Known failures |
|---|---|---|---|
| MagicQuit 2.0 (GPL-3; its README says MIT, but the LICENSE file wins) | AX `WindowCreated` / `UIElementDestroyed` | 0 AX windows and 0 CG layer-0 windows after 2 s | Above |
| SwiftQuit 1.5, 2023 (GPL-3) | AX via the Swindler library, "window destroyed" | Known window list empty after a 2 s delay | Quits apps whose windows are on other Spaces, full-screen, minimized or hidden (#7). Closing a tab quits the app (#6). Doesn't work with Discord, Firefox, iTerm2, Arc (#13, #25–#27). Broke on macOS 26/27 for Chrome and VS Code (#59, #63). Exits if not trusted and never retries |
| RedQuits3 (MIT) | Global mouse monitor + AX hit-test of the close button; the release inside it is the trigger | Quits the whole app on the red X, even with other windows open | ⌘W and File > Close aren't covered; apps whose close button AX can't reach are skipped |
| Red X Quit (no license, no source) | Not disclosed | n/a | Can't be audited |
| TrueClose (MIT) | Polls AX every 0.8 s; ScreenCaptureKit sees other Spaces (needs Screen Recording) | 0 AX windows for a set delay | Users report it works on macOS 27 (SwiftQuit #63) |

## Recommended design (to argue in `/wingman`, written from scratch)

Keep the **trigger** ("something was closed") separate from the **decision** ("are any real
windows left").

1. **Triggers.** Any of these starts a check:
   - an AX "window destroyed" event, with the observer added in `.commonModes` so it fires while
     menus are open;
   - a captured click on the red close button, the only reliable signal for hide-on-close apps
     like Slack;
   - the main window changing to none;
   - a 5 s re-check that runs only for apps already marked pending.
2. **Per-window ledger.** Each window's ID as AX reports it (the private `_AXUIElementGetWindow`
   is fine for a private app, behind a probe test so an OS update that breaks it is caught):
   - a trigger that names a window marks it "closed";
   - a window that drops out of AX without a trigger (Space switch, full-screen) counts as
     "alive elsewhere" while the window server still lists its ID.
3. **Decide after ~1.5 s, then confirm again.** Quit when no standard windows are left (minimized
   ones count as alive) and none is alive elsewhere. Cancel if a new window appears. Quit with
   `NSRunningApplication.terminate()`, the normal ⌘Q, never force-quit.
4. **Guards:**
   - Pause during sleep, screen lock and Space transitions.
   - Skip apps that are hidden, still launching, or younger than ~10 s.
   - AX messaging timeout of ~0.3 s, so a hung app can't stall Swapless.
   - Check trust every ~2 s and re-register observers when it changes.
   - Only `.regular` apps. Finder is always excluded.
   - Media and messaging apps are excluded by default.
   - Log every decision with a reason code at `.info`, so `log stream` always explains a non-quit.
5. **Edge cases:**
   - native tabs, where closing a tab can briefly leave zero windows (the re-confirm handles it);
   - floating panels and sheets (count standard windows only);
   - Stage Manager;
   - closing the last window and reopening one right away;
   - an app that refuses to quit (a save prompt cancelled).

## How to prove it (feeds `scripts/leak-rig.sh` and the unit tests)

- **The decision logic is a pure state machine,** unit-tested on recorded sequences of events
  and snapshots.
- **A test app of our own, with one mode per case:**
  - real close;
  - close but keep the window;
  - hide on close (Electron-style);
  - a tiny off-screen helper window;
  - panel only;
  - minimized;
  - on another Space or full-screen;
  - tabs;
  - refuses to quit;
  - stalled.

  Drive it with an AX press on the close button and with posted mouse clicks (the click path
  needs a real click). Assert whether it terminated and the logged reason.
- **Probe on macOS 27.2 first.** Close the last window of Notes and of Slack, and dump the AX and
  CG window lists at 0, 1 and 3 s. That measures causes 3 and 4 above; the research didn't
  measure them.

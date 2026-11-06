#!/bin/bash
# The rig (CLAUDE.md §3 sensor slot; spec S6): builds debug + release, then runs swapless-rig.
#
#   ./scripts/leak-rig.sh                  preflight + checks 1–4
#   ./scripts/leak-rig.sh --only 1[,2…]    preflight + just those checks (1–4 only)
#   ./scripts/leak-rig.sh --budget         preflight + checks 1–5 (needs the installed app)
#   ./scripts/leak-rig.sh --sim            preflight + check 6 (boots and shuts down a simulator)
#   ./scripts/leak-rig.sh --live-wallpaper preflight + check 7 (one real wallpaper restart)
#   ./scripts/leak-rig.sh --on-screen-menu preflight + the on-screen menu walk. It opens the real
#                                          menu on the owner's screen: only in an announced
#                                          session the owner approved (DECISIONS.md 2026-11-05),
#                                          never in the done-gate.
#
# Exits 0 iff no check FAILs. Reports land in .build/rig/rig-<yyyymmdd-hhmmss>-<mode>.txt.
set -euo pipefail
cd "$(dirname "$0")/.."

SIM=0
for arg in "$@"; do
    [ "$arg" = "--sim" ] && SIM=1
done

swift build -c debug
swift build -c release
DEBUG_BIN="$(swift build -c debug --show-bin-path)"
RELEASE_BIN="$(swift build -c release --show-bin-path)"
mkdir -p .build/rig

if [ "$SIM" -eq 1 ]; then
    # Only in --sim mode: shut down the simulator this invocation booted, on every exit path.
    # The record is "<UDID> <parent-pid>"; touch it only when the pid is ours.
    sim_cleanup() {
        local f=".build/rig/booted-sim"
        if [ -f "$f" ]; then
            read -r udid ppid < "$f" || true
            if [ "${ppid:-}" = "$$" ] && [ -n "${udid:-}" ]; then
                xcrun simctl shutdown "$udid" >/dev/null 2>&1 || true
                rm -f "$f"
            fi
        fi
    }
    trap sim_cleanup EXIT INT TERM HUP
    status=0
    "$DEBUG_BIN/swapless-rig" --debug-bin "$DEBUG_BIN" --release-bin "$RELEASE_BIN" --parent-pid $$ "$@" || status=$?
    exit "$status"
fi

exec "$DEBUG_BIN/swapless-rig" --debug-bin "$DEBUG_BIN" --release-bin "$RELEASE_BIN" "$@"

#!/bin/bash
# The installed app's own cost, from its `self` log lines (v1-menu-today S5).
#
#   ./scripts/self-report.sh [--since 'YYYY-MM-DD HH:MM:SS']
#
# Reads the installed app's `self` lines from the unified log (`/usr/bin/log show`, finite) and
# prints one row per pair of consecutive lines from the same pid:
#   end time · Δwall · ΔCPU (cpu + child) · Δ menu-open s · Δ menu-open CPU ·
#   closed CPU % = (ΔCPU − Δopen CPU) ÷ (Δwall − Δopen s) ·
#   open CPU % = Δopen CPU ÷ Δopen s (only when Δopen s ≥ 1) · the line's cpuPct10mIdle
# then a total row. Lines from builds without the new fields show closed % only when the menu
# wasn't open in that pair.
#
# Default --since: the running installed app's start time, else today 00:00.
# Never reads the state dir, never signals anything. Exit 0, or 1 when no lines match.
set -euo pipefail
export LC_ALL=C

INSTALLED="/Applications/Swapless.app/Contents/MacOS/Swapless"
BASE='subsystem == "com.michaelv.swapless" AND category == "self"'

SINCE=""
while [ $# -gt 0 ]; do
    case "$1" in
        --since)
            [ $# -ge 2 ] || { echo "usage: $0 [--since 'YYYY-MM-DD HH:MM:SS']" >&2; exit 2; }
            SINCE="$2"
            shift 2
            ;;
        *)
            echo "usage: $0 [--since 'YYYY-MM-DD HH:MM:SS']" >&2
            exit 2
            ;;
    esac
done

# Only the executable path is compared; no args or env of any process are read.
pid="$(ps -axo pid=,comm= | awk -v p="$INSTALLED" '$2 == p && !f { print $1; f = 1 }')"
# The log can't be filtered by the installed path: logd resolves the image by its UUID and
# records the build product's path (`.build/out/Products/Release/Swapless`, found 2026-11-07).
# So filter by the running installed app's pid; with none running, every `Swapless` process
# (dev and rig runs included) matches.
if [ -n "$pid" ]; then
    PREDICATE="$BASE AND processID == $pid"
else
    PREDICATE="$BASE AND process == \"Swapless\""
    echo "self-report: the installed app isn't running; matching every Swapless process" >&2
fi

if [ -z "$SINCE" ]; then
    if [ -n "$pid" ]; then
        lstart="$(ps -o lstart= -p "$pid" | sed 's/^ *//; s/  */ /g')"
        SINCE="$(date -j -f '%a %b %d %T %Y' "$lstart" '+%Y-%m-%d %H:%M:%S' 2>/dev/null || true)"
    fi
    [ -n "$SINCE" ] || SINCE="$(date '+%Y-%m-%d') 00:00:00"
fi

echo "self-report: installed app self lines since $SINCE"

/usr/bin/log show --start "$SINCE" --predicate "$PREDICATE" --info --style compact |
awk '
function civil(y, m, d,    a, yy, mm) {   # days since 1970-01-01 (proleptic gregorian)
    a = (m <= 2) ? 1 : 0
    yy = y - a
    mm = m + 12 * a - 3
    return 365 * yy + int(yy / 4) - int(yy / 100) + int(yy / 400) + int((153 * mm + 2) / 5) + d - 719469
}
function secs(date, time,    D, T) {
    split(date, D, "-")
    split(time, T, ":")
    return civil(D[1] + 0, D[2] + 0, D[3] + 0) * 86400 + T[1] * 3600 + T[2] * 60 + T[3]
}
function field(k,    i, kv) {
    for (i = 1; i <= NF; i++) {
        if (index($i, k "=") == 1) { return substr($i, length(k) + 2) }
    }
    return ""
}
function pct(a, b) { return (b > 0) ? sprintf("%.3f", a / b * 100) : "n/a" }
BEGIN {
    printf "%-19s %8s %8s %8s %9s %9s %9s %8s\n", "end", "wall_s", "cpu_s", "open_s", "openCpu_s", "closed_%", "open_%", "idle_%"
    n = 0
}
/self cpuSeconds=/ {
    if (match($0, /\[[0-9]+:/) == 0) next
    pid = substr($0, RSTART + 1, RLENGTH - 2)
    t = secs($1, $2)
    cpu = field("cpuSeconds") + field("childCpuSeconds")
    open = field("menuOpenSeconds") + 0
    oc = field("menuOpenCpuSeconds")
    idle = field("cpuPct10mIdle")
    if (idle == "") idle = "-"
    n++
    if (pid in lastT) {
        dw = t - lastT[pid]
        dc = cpu - lastC[pid]
        dopen = open - lastO[pid]
        hasNew = (oc != "" && lastOC[pid] != "")
        doc = hasNew ? (oc - lastOC[pid]) : 0
        if (hasNew) {
            closed = (dw - dopen > 0) ? pct(dc - doc, dw - dopen) : "n/a"
            openp = (dopen >= 1) ? pct(doc, dopen) : "-"
            docs = sprintf("%.3f", doc)
        } else {
            closed = (dopen == 0) ? pct(dc, dw) : "n/a"
            openp = "n/a"
            docs = "n/a"
        }
        printf "%-19s %8.1f %8.3f %8.1f %9s %9s %9s %8s\n", substr($1 " " $2, 1, 19), dw, dc, dopen, docs, closed, openp, idle
        rows++
        if (hasNew) {
            totOpenS += dopen; totOpenC += doc
            totClosedS += dw - dopen; totClosedC += dc - doc
        } else if (dopen == 0) {
            totClosedS += dw; totClosedC += dc
        }
    }
    lastT[pid] = t; lastC[pid] = cpu; lastO[pid] = open; lastOC[pid] = oc
}
END {
    if (n == 0) { print "self-report: no installed-app self lines matched"; exit 1 }
    printf "total: %d pairs · menu open %.1f s, open CPU %s %% · menu closed %.1f s, closed CPU %s %%\n", rows + 0, totOpenS, (totOpenS >= 1 ? pct(totOpenC, totOpenS) : "n/a"), totClosedS, pct(totClosedC, totClosedS)
}
'

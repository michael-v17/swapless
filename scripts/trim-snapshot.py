#!/usr/bin/env python3
"""trim-snapshot.py <raw.json> <fixture.json>: turn a raw `--dump-snapshot` into a fixture safe to commit.

Keeps Apple system processes (SIP-protected paths), kernel_task, the booted simulator's process tree,
Claude Code sessions and Swapless's own dev processes. Drops every other app, agent and extension.
Claude Code session folder names become project-a, project-b, … (the repo's own folder stays).
Coalitions are kept as recorded, only for the coalitions a kept process belongs to.
FixturePrivacyTests fails if a tracked fixture holds anything this script would drop."""
import json, sys
APPLE = ("/System/", "/usr/libexec/", "/usr/sbin/", "/usr/bin/", "/sbin/", "/bin/", "/Library/Apple/",
         "/private/var/run/com.apple.security.cryptexd/", "/Library/Developer/PrivateFrameworks/CoreSimulator.framework/")
src, dst = sys.argv[1], sys.argv[2]
d = json.load(open(src, encoding="utf-8"))
E = d["entries"]
children = {}
for e in E: children.setdefault(e["ppid"], []).append(e["pid"])
sim, stack = set(), [e["pid"] for e in E if e["name"] == "launchd_sim"]
while stack:
    p = stack.pop()
    if p not in sim: sim.add(p); stack += children.get(p, [])
def keep(e):
    p = e["path"] or ""
    return (p.startswith(APPLE) or e["name"] == "kernel_task" or e["pid"] in sim or e.get("simulatorUDID")
            or e.get("cwdBasename") or "/Swapless/.build/" in p)
kept, names = [dict(e) for e in E if keep(e)], {}
for e in kept:
    cwd = e.get("cwdBasename")
    if cwd and cwd != "Swapless":
        e["cwdBasename"] = names.setdefault(cwd, f"project-{chr(ord('a') + len(names))}")
cids = {e["coalition"] for e in kept} | {e["jetsamCoalition"] for e in kept}
d["entries"], d["coalitions"] = kept, [c for c in d["coalitions"] if c["cid"] in cids]
open(dst, "w", encoding="utf-8").write(json.dumps(d, ensure_ascii=False, separators=(",", ":")))
print(f"{len(E)} -> {len(kept)} processes; Claude Code folders renamed: {len(names)}")

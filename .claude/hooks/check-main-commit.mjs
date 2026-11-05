#!/usr/bin/env node
// PreToolUse(Bash) guard: block `git commit` while on the `main` branch.
// `main` is the shared integration branch — every change reaches it via a branch + PR, so
// collaborators never tangle and there's always a review point + a rollback point.
// Reads the hook payload on stdin; exit 2 + stderr = block the tool call.
// Bypass for a deliberate one-off: ALLOW_MAIN_COMMIT=1 git commit ...
// Note: on a repo with zero commits HEAD doesn't resolve — the guard fails open on
// purpose, so the genesis commit can land on main.
import { execSync } from "node:child_process";

const raw = await new Promise((resolve) => {
  let d = "";
  process.stdin.setEncoding("utf8");
  process.stdin.on("data", (c) => (d += c));
  process.stdin.on("end", () => resolve(d));
  // If nothing is piped, don't hang.
  setTimeout(() => resolve(d), 1000).unref?.();
});

let cmd = "";
try { cmd = (JSON.parse(raw || "{}").tool_input || {}).command || ""; } catch {}

// A real commit = a `git` invocation whose subcommand (after global flags) is `commit`.
// Token-based so `git log --grep commit` or paths like docs/commit-style.md don't trigger.
function hasGitCommit(command) {
  if (/--dry-run\b/.test(command)) return false;
  const toks = command.trim().split(/\s+/);
  for (let i = 0; i < toks.length; i++) {
    if (toks[i] !== "git" && !toks[i].endsWith("/git")) continue;
    let j = i + 1;
    while (j < toks.length) {
      const t = toks[j];
      // global flags that take a separate value
      if (t === "-c" || t === "-C" || t === "--git-dir" || t === "--work-tree" || t === "--namespace") { j += 2; continue; }
      if (t.startsWith("-")) { j += 1; continue; }
      break;
    }
    if (toks[j] === "commit") return true;
  }
  return false;
}

if (!hasGitCommit(cmd)) process.exit(0);
// The prefix sets the var on the git process, not on this hook — detect it in the command too.
// Only a truthy value bypasses (ALLOW_MAIN_COMMIT=0 must still block).
if (/^(1|true)$/i.test(process.env.ALLOW_MAIN_COMMIT || "") || /(^|\s)ALLOW_MAIN_COMMIT=(1|true)\b/i.test(cmd)) process.exit(0);

let branch = "";
try { branch = execSync("git rev-parse --abbrev-ref HEAD", { encoding: "utf8" }).trim(); } catch { process.exit(0); }

if (branch === "main") {
  process.stderr.write(
    "✗ Blocked: don't commit directly to `main` — it's the shared integration branch.\n" +
    "Start a branch first:  /init-task <short-name>   (or: git switch -c <name>)\n" +
    "Then /save-task (checkpoint) and /ship-task (PR → squash-merge).\n" +
    "Deliberate one-off? prefix with  ALLOW_MAIN_COMMIT=1\n"
  );
  process.exit(2);
}
process.exit(0);

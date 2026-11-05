#!/usr/bin/env node
// UserPromptSubmit capture: append each user prompt to .claude/observer/log/YYYY-MM-DD.jsonl.
// Personal steering-loop sensor — the raw material /retro mines for corrections, repeated
// procedures, and machine-checkable mistakes, so they graduate into rules/skills/hooks
// instead of being re-typed forever. See .claude/observer/README.md (local, not committed).
//
// Registered per-user in .claude/settings.local.json (opt-in), NOT in the shared settings.json —
// each person's log stays on their machine; .claude/observer/ is gitignored.
//
// Contract: NEVER block or slow the prompt. Always exit 0. No stdout (stdout on this hook
// would inject text into the prompt's context).
import { appendFileSync, mkdirSync } from "node:fs";
import { join } from "node:path";

const raw = await new Promise((resolve) => {
  let d = "";
  process.stdin.setEncoding("utf8");
  process.stdin.on("data", (c) => (d += c));
  process.stdin.on("end", () => resolve(d));
  // If nothing is piped, don't hang.
  setTimeout(() => resolve(d), 1000).unref?.();
});

try {
  const p = JSON.parse(raw || "{}");
  const prompt = (p.prompt || "").toString();
  if (!prompt.trim()) process.exit(0);

  const dir = join(process.env.CLAUDE_PROJECT_DIR || process.cwd(), ".claude", "observer", "log");
  mkdirSync(dir, { recursive: true });

  const now = new Date();
  const entry = {
    ts: now.toISOString(),
    session: p.session_id || null,
    transcript: p.transcript_path || null, // lets /retro pull full context around a correction
    cwd: p.cwd || null,
    kind: prompt.startsWith("/") ? "command" : "prose",
    prompt,
  };
  appendFileSync(join(dir, `${now.toISOString().slice(0, 10)}.jsonl`), JSON.stringify(entry) + "\n");
} catch {
  // Capture must never break a session — swallow everything.
}
process.exit(0);

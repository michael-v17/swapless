---
description: Steering retro — mine the observer's captured prompts for corrections/repetitions and propose harness upgrades (rules, skills, hooks). Proposes only; the user curates.
argument-hint: [days back, default 7]
allowed-tools: Read, Glob, Grep, Bash(git log:*), Bash(ls:*), Write, Edit
---

The steering loop for this repo, per the harness-engineering discipline: **every recurring
mistake should become a rule, a skill, or a hook — never a correction re-typed in chat.**
This command mines the raw capture and turns it into curated proposals. It NEVER applies
anything by itself.

Data source: `.claude/observer/log/*.jsonl` (written by the `capture-prompt.mjs` hook,
registered per-user in `settings.local.json`; the log is local and gitignored). Each line:
`{ts, session, transcript, cwd, kind: command|prose, prompt}`.

Opt-in recipe (for a fresh clone — the observer dir itself is gitignored): create
`.claude/settings.local.json` with a `UserPromptSubmit` hook entry running
`node "$CLAUDE_PROJECT_DIR/.claude/hooks/capture-prompt.mjs"`. Kill switch: delete that entry.

Steps:

1. **Window.** Default: last 7 days of log files; `$ARGUMENTS` (a number) overrides. If the
   log directory is missing or empty, say the observer isn't capturing (check that
   `settings.local.json` registers the `UserPromptSubmit` hook) and stop.

2. **Context.** Skim `git log --oneline --since="<window>"` so proposals can reference what
   was actually being built.

3. **Mine the `prose` prompts** (ignore `kind: command` except for counting) for four signals:
   - **Corrections** — the user telling Claude something came out wrong, redoing an
     instruction, or re-stating a constraint. Each correction that could recur →
     candidate **rule** (CLAUDE.md §, an authority doc, or `.claude/rules/`). The rule text
     must trace to the concrete failure — pilot's checklist, not style guide.
   - **Repeated procedures** — the same multi-step instruction typed ≥2 times across
     sessions → candidate **skill/command** (like /save-task already is).
   - **Machine-checkable mistakes** — anything a script could have caught
     (`swift build` / `swift test` breakage; `scripts/leak-rig.sh` failures: a footprint that
     disagrees with `footprint`/`top`, an action with no owner rule, a missed last-window quit,
     overhead over budget) → candidate **hook/sensor** (PostToolUse or
     a verify script).
   - **Intent debt** — context the user re-explains at session start → candidate pointer
     in CLAUDE.md or the relevant authority doc.
   When a correction needs more context than the prompt shows, follow its `transcript` path
   and read around that timestamp.

4. **Write proposals** to `.claude/observer/proposals.md` (create if missing). Append one
   dated section per retro run:
   - **Metrics line**: `prompts analyzed / prose / corrections found /
     corrections-per-prose-prompt`. Over time this ratio falling = the harness is learning.
   - Per proposal: evidence (short quote + date), proposed artifact (`rule` | `skill` |
     `hook`), a ready-to-paste draft, and `status: proposed`.
   - Never delete old sections; when the user adopts/rejects, flip the status in place.

5. **Report** (≤10 lines): the metrics line, the top 3 proposals by expected recurrence, and
   the reminder that adopting one means that correction can never recur. When the user
   answers "adopta N" / "adopt N", implement that artifact (edit CLAUDE.md / create the
   command / write the hook — hooks go to the shared settings.json only with explicit OK,
   since that file is shared with collaborators) and mark it `adopted`.

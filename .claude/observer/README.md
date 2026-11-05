# Observer — the steering loop's capture layer (local, not committed)

**What:** `capture-prompt.mjs` (a `UserPromptSubmit` hook) appends every prompt you type in
this repo to `log/YYYY-MM-DD.jsonl`. `/retro` mines that log weekly and writes
`proposals.md` — candidate rules/skills/hooks, each traced to a concrete correction you made.
You curate: adopt, reject, or ignore. Adopted = that correction can never recur.

**Why:** the compounding rule that separates system-builders from prompt-by-prompt users —
"every single time Claude makes a mistake, write it to the CLAUDE.md, or make a skill"
(Cherny).

**Privacy / sharing:** this whole directory is gitignored — your prompts stay on your
machine. The hook is registered per-user in `.claude/settings.local.json` (also gitignored),
so collaborators are unaffected unless they opt in with their own settings.local.json entry
(the hook script itself IS committed for that purpose; the opt-in recipe is in the
committed `retro.md`).

**Cadence:** run `/retro` once a week (or after any session where you corrected Claude more
than twice). Watch the metrics line in `proposals.md`: corrections-per-prompt falling means
the harness is absorbing your taste.

**Kill switch:** delete the `UserPromptSubmit` entry from `.claude/settings.local.json`.
Capture stops; nothing else breaks.

**Known limitation:** worktree sessions (`.claude/worktrees/<name>/`) don't inherit
`settings.local.json` (it's gitignored), so prompts typed there aren't captured — /retro
undercounts worktree-heavy weeks. Copy settings.local.json into the worktree if you want
capture there.

---
description: Start a task — sync main and create a fresh short-lived branch off it.
argument-hint: <short-name-for-the-work>
allowed-tools: Bash(git status:*), Bash(git switch:*), Bash(git pull:*), Bash(git branch:*)
---

Start a new unit of work on its own branch. `main` is the shared branch everyone builds off — never edited directly.

Steps:
1. Run `git status --porcelain`. If there are uncommitted changes, **stop** and tell the user:
   they likely belong to current work — finish/`/save-task` or stash them before starting fresh.
2. `git switch main && git pull --ff-only` — get the latest shared state. (No remote
   configured yet? Skip the pull and say "no remote yet — branching off local main".)
3. Derive a branch name from `$ARGUMENTS` (kebab-case — "Fix login crash" → `fix-login-crash`).
   If `$ARGUMENTS` is empty, ask for a short name. Keep it about the *work*, not the person.
4. `git switch -c <name>`.
5. Confirm: "On branch `<name>`, off the latest `main`. Nothing committed yet — go build."

One branch ≈ one shipment. Keep it short-lived (hours, not weeks).

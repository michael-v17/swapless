---
description: Checkpoint — commit touched files, push, and open/refresh a draft PR. Run any time.
argument-hint: [optional commit message]
allowed-tools: Bash(git status:*), Bash(git add:*), Bash(git commit:*), Bash(git push:*), Bash(git branch:*), Bash(git rev-parse:*), Bash(gh pr:*)
---

A checkpoint so the work isn't only on this laptop. Safe to run as often as you like — it never
merges anything. (Think Ctrl+S; `/ship-task` is publish.)

Steps:
1. **Refuse if on `main`** (`git rev-parse --abbrev-ref HEAD`) — tell the user to `/init-task` first.
2. Stage the files changed **for this task** with explicit paths (`git add <paths>`). Avoid
   `git add -A` unless everything pending genuinely belongs to this task.
3. Commit. Use `$ARGUMENTS` as the message if given; otherwise write a short `scope: summary` subject
   (scope prefixes for this repo: `app:` Swift code, `rules:` the rules engine and its defaults, `rig:` the leak rig and fixtures, `harness:`, `docs:`). Footer:
   `Co-Authored-By: Claude <noreply@anthropic.com>`.
4. Push, setting upstream the first time: `git push -u origin HEAD`. If no remote is configured
   yet, say so and stop after the commit — the checkpoint is still local-only.
5. If no PR exists for this branch yet (`gh pr view` fails), open a **draft**:
   `gh pr create --draft --fill --base main`. If one exists, leave it (the push updated it).
6. Report the PR URL and that it's a draft (nobody reviews/merges a draft).

If the work produced something runnable/visual, capture proof (screenshot / the output of the
executable check) before saving so the PR shows what changed.

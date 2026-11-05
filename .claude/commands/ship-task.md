---
description: Done — commit pending work, mark the PR ready, squash-merge to main, clean up.
argument-hint: [optional final commit message]
allowed-tools: Bash(git status:*), Bash(git add:*), Bash(git commit:*), Bash(git push:*), Bash(git switch:*), Bash(git pull:*), Bash(git rev-parse:*), Bash(gh pr:*)
---

The "I'm done, put it on `main`" command. Only run when the change is finished — `main` is the
shared branch everyone builds off (and what releases cut from), so it should always be in
a good state. This lands on `main`.

Steps:
1. **Refuse if on `main`** — there's nothing to ship from `main`.
2. If the change produced something runnable/visual, confirm it was verified this session
   (screenshot / the task's executable check — this repo's exit-gate sensor if it exists
   yet, see CLAUDE.md §3; pre-sensor, build + run + screenshot is the gate). If not, stop
   and verify first.
3. **Rationale log — check the mandatory triggers.** An entry in DECISIONS.md is NOT
   optional when this task: bypassed a hard wall (via its named hatch or otherwise) ·
   overrode a rule this repo had settled · shipped a degraded pass (a fallback fired, a
   check was skipped, something scored "partially done") · or added a trigger this repo
   declared for itself (DECISIONS.md header). Any of those → append the dated entry NOW so
   it lands in this shipment. None → say "no trigger this task" and continue; discretionary
   entries stay welcome, the triggers are a floor.
   *Why this step exists:* without it the rationale migrates to PR bodies — dated and rich,
   but in a channel no session ever reads — and the log dies at its genesis entry while the
   repo keeps deciding. Measured in this family: one wingman shipped 14 commits with 1
   commit to its log, its real reasoning stranded in PR descriptions.
4. Commit anything still pending (stage touched paths; message from `$ARGUMENTS` or a short
   `scope: summary` subject; keep the `Co-Authored-By: Claude <noreply@anthropic.com>` footer),
   then `git push`.
5. Ensure a PR exists (`gh pr view` or `gh pr create --fill --base main`) and mark it ready:
   `gh pr ready`.
6. Ownership: **shared** — anyone may merge any PR. Still give the others a heads-up for
   anything large (they may have context the diff doesn't show). (Solo repo? merge away.)
7. Squash-merge and clean up: `gh pr merge --squash --delete-branch`.
8. `git switch main && git pull --ff-only` so local `main` shows the merged result.
9. Report: merged to `main`, branch deleted — and whether step 3 produced a log entry.

The squashed history on `main` is the team's activity log — one line per shipment, recording
**what** changed. It is not the rationale log: **why** lives in DECISIONS.md (step 3), which is
what a future session actually reads. A PR body is a fine place to explain a shipment to a
reviewer; it is not a place to store a decision, because nothing in this repo's read order
leads there.

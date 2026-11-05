# Team workflow

How we work in this repo without tangling merges. Short branches, PRs.
Solo for now (michael-v17). The flow still pays: history and rollback points.

## The one rule
**Nobody commits to `main` directly.** `main` is the **shared integration branch** — the
state everyone builds off, and the base releases cut from. Every change reaches `main` by
merging a Pull Request. Enforced by the `check-main-commit` hook (deliberate one-off?
prefix the commit with `ALLOW_MAIN_COMMIT=1`).

## The loop
```
1. /init-task short-name        # sync main + create a fresh branch
2. (/wingman if fuzzy/large)    # converge intent → specs/<branch>.md
3. ...do the work...            # build → run → verify with the executable check
4. /save-task   (any time)      # checkpoint → commit + push + draft PR
5. /ship-task   (when done)     # PR ready → squash-merge → main
```
The branch lives hours, not weeks. After `/ship-task` it's deleted — branches are disposable.

## The commands
| Command | What it does |
|---|---|
| `/init-task <name>` | `git pull` on `main`, then `git switch -c <name>`. The everyday "begin work". |
| `/wingman [intro]` | Spec session for fuzzy/large tasks → `specs/<branch>.md`, the only input for the run. |
| `/save-task` | Commit touched files + push + open/refresh a **draft** PR. Run it often. |
| `/ship-task` | Commit pending + push + mark PR ready + **squash-merge** + delete branch + update `main`. |
| `/init-worktree <name>` | Like `/init-task`, but in an isolated worktree — for two Claude sessions in parallel. |
| `/close-worktree [ship]` | Commit + push + PR (draft by default; `ship` = squash-merge), then remove the worktree. |
| `/retro [days]` | Mine the observer log → harness-upgrade proposals (personal, opt-in). |

All of it also works by hand: `git switch -c …`, `gh pr create`, `gh pr merge --squash --delete-branch`.

## Shipping discipline
- Nothing ships without verification by **running it** (CLAUDE.md §3): build → run →
  exercise the change → capture proof (screenshot / check output) in the PR.
- `main` must always build and run. If it doesn't, fixing it is the next PR.

## Ownership
**Shared.** Any PR can self-merge. PRs are for visibility and a clean history, not a hard
review gate. Heads-up for anything large.

## When something breaks
- Merge conflict on pull → resolve **on the branch**, never on `main`.
- A bad merge slipped to `main` → branch a fix and `/ship-task` it. Don't hand-edit `main`.

# Start a worktree session

Spin up a git worktree for this Claude session so it can edit the repo in isolation from any other
parallel session. Same idea everywhere: sync, worktree, go.

Use this at the **start** of a session when one person is running two Claude sessions at once and
wants their working trees isolated (e.g. two tasks in parallel). It is *optional* — a plain branch
(`/init-task`) is enough for solo, single-session work. The worktree is only an isolation
convenience; the change still reaches `main` via a PR, never by a local merge.

## Arguments

- **(optional, but always pass one)** `name` — kebab-case slug describing the *work*, not the person.
  If omitted, `EnterWorktree` generates a random slug that tells no one what the branch is for —
  avoid that. **Do not include a `worktree-` prefix**: the tool namespaces the branch itself.

## What this does

1. **Sync first**, so the worktree branches from an up-to-date base and the eventual PR merges
   cleanly. `EnterWorktree` branches from `origin/main` (the default `worktree.baseRef: fresh`), so
   a fetch is what matters — but pull `main` too if we're on it, so the user's primary checkout
   isn't stale:

   ```bash
   git fetch origin
   ```

2. **Create the worktree.** Call the `EnterWorktree` tool, passing `name` if the user provided one.
   The session switches into `.claude/worktrees/<name>/` on a new branch, based on `origin/main`.

3. **Coordinate shared resources.** Two sessions share one Mac, and Swapless acts on machine-global state.
   Only one Swapless may run at a time, so quit the installed `/Applications/Swapless.app` before
   running a dev build. Run `scripts/leak-rig.sh` in one session at a time: its leaking helper
   and test app are machine-wide. And never let a dev build act for real while another session
   is working: use `SWAPLESS_DRY_RUN=1` unless this task is the one being verified.

   Skip this step entirely for markdown/design-doc work.

4. **Report a one-liner:**

   ```
   Worktree ready: .claude/worktrees/<name>  (branch: <branch>)
   ```

## Notes

- Same rules as any branch: **never merge locally into `main`** — `/save-task` and `/ship-task`
  work normally from inside the worktree (commit → push → PR → squash-merge).
- The `check-main-commit` hook still protects `main`; the worktree is on its own branch, so it
  never triggers.
- To wrap up: `/close-worktree` — it commits/pushes, ensures the PR, and removes the worktree.

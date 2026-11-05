# End a worktree session

Wrap up the worktree this Claude session is running in: commit any pending work, push the branch
and make sure a PR exists, and remove the worktree directory + local branch.

By default this leaves the work as a **draft PR** (like `/save-task`) — merge it later, or pass
`ship` to squash-merge to `main` right here (like `/ship-task`).

## Arguments

- **(optional)** `ship` — mark the PR ready and squash-merge it to `main` before cleaning up.
- **(optional)** `discard` — throw away uncommitted changes and unpushed commits instead of
  committing/pushing. **Ask for explicit confirmation before destroying work.**

## What this does

1. **Check the git state** inside the worktree: `git status --short`, plus
   `git rev-list --count origin/main..HEAD` (commits ahead of `main`). Branch by case:

   - **Clean tree, nothing ahead of `main`** → nothing to ship; jump to step 4.
   - **Clean tree, branch ahead** → step 3 (push + PR), then step 4.
   - **Dirty tree** → ask the user: "commit and open the PR?" / "discard?" (unless an argument
     already answered).

2. **Commit pending changes** (if committing): stage only the files this session touched
   (`git add <paths>`, never `-A` blindly — the usual intentionally-uncommitted local files must
   not ride along). Short `scope: summary` subject + the `Co-Authored-By: Claude` trailer.

3. **Push and ensure the PR:**

   ```bash
   git push -u origin HEAD
   gh pr view || gh pr create --draft --fill --base main
   ```

   (No remote configured yet? Stop after the commit and report local-only, like `/save-task`.)

   - Without `ship`: stop here — report the draft PR URL.
   - With `ship`: `gh pr ready && gh pr merge --squash --delete-branch`. (Ownership is shared —
     self-merge is fine; give collaborators a heads-up if it's large.)

4. **Kill any long-running process this worktree started** (build daemons, local servers) — only
   processes whose cwd is inside this worktree, so closing one parallel session never knocks down
   the other. Check with `lsof -p <pid>` before killing.

5. **Exit and remove the worktree.** Call the `ExitWorktree` tool with `action: "remove"`. If
   `discard` was confirmed, also pass `discard_changes: true`. The session returns to the primary
   checkout.

6. **Back in the primary checkout:** if `ship` was used, `git switch main && git pull --ff-only`
   so local `main` shows the merged result. Then report a one-liner: PR URL (draft or merged),
   worktree removed.

## Notes

- Without `ship`, the work lands on `main` only when the PR is merged — same rule as always.
- `discard` only destroys local, unpushed work; anything already pushed is safe on the remote.
- After this command the session is back in the primary checkout — good moment to close the
  terminal, or `/init-worktree` again for the next parallel task.

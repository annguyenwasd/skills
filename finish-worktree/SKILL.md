---
name: finish-worktree
description: Close out a git worktree session from inside the worktree - merge its branch into the repository's default branch, remove the worktree, delete the branch, then sweep other worktrees whose work already landed. Use when the user invokes /finish-worktree, says the worktree session is done, asks to merge this session's branch back to main without leaving the worktree, or asks to clean up stale worktrees.
argument-hint: "[--dry-run] [--no-prune]"
---

# /finish-worktree - Close Out A Worktree Session

Land this session's branch on the default branch, remove the worktree, delete the branch, then
sweep worktrees whose work already landed.

It runs from inside the worktree. git refuses to check out one branch in two worktrees, so the
merge happens in whichever checkout already holds the default branch - worktrees share refs, so it
is the same merge.

Results: `PASS`, `SKIP`, `BLOCKER`.

## Run This

```bash
ROOT="$(git rev-parse --path-format=absolute --git-common-dir)"
PRIMARY="$(dirname "$ROOT")"
bash "$HOME/workspace/skills/finish-worktree/finish-worktree.sh" "$@"; rc=$?
cd "$PRIMARY" && pwd
exit $rc
```

Run the script and the `cd` in **one** Bash call, and capture `PRIMARY` **before** the run.

The run removes the worktree this session is standing in. Afterwards `git rev-parse` cannot run
from the old directory, and without the `cd` every later Bash call fails with
`getcwd: cannot access parent directories`. This is the only subtle part of invoking it.

## Reading The Output

- `PASS:` something was merged, removed or deleted.
- `SKIP:` deliberately left alone. `refusing to --force` and `has N commits not in '<default>'`
  mean a worktree kept its uncommitted work or its unmerged branch. That is the tool working, not
  failing.
- `BLOCKER:` nothing was removed. Fix what the line names and run again; a failed merge is aborted
  first, so the merge target is never left mid-merge.

Exit 0 means the branch landed and this worktree is gone. Exit 1 means nothing was removed.

Sweep refusals are `SKIP:` and do not affect the exit code - a repository with any dirty worktree
would otherwise be red on every single run.

## Report Back

Say what landed: the branch, the default branch, whether it fast-forwarded or made a merge commit,
which worktrees the sweep removed, and every `SKIP:` or `BLOCKER:` line that needs a human
decision. If the default branch is now ahead of `origin/<default>`, say so - pushing it is
`/commit-push`.

## Rules This Tool Will Not Break

- **Never `--force`.** A worktree with uncommitted or untracked changes is refused, not cleaned.
- **Never `git branch -D`.** A branch is deleted only when it is an ancestor of the default branch.
  `git branch -d` alone is not enough: it is satisfied by the branch's *upstream*, so it would
  happily delete a pushed-but-unmerged branch with unique commits on it.
- **Never a locked worktree.** Unlock it yourself, deliberately, if it really is finished.
- **Never the primary checkout**, and never this worktree before the merge is verified to have
  landed.

If a sweep refuses a worktree you believe is disposable, removing it is a deliberate human act:
`git worktree remove --force <path>`. Do not reach for it on the tool's behalf.

## Arguments

- `--dry-run` - print the whole plan, change nothing. Run this first in an unfamiliar repository.
- `--no-prune` - finish this worktree only; leave the others alone.

## Run From The Primary Checkout

Nothing to merge, so the finish phase reports `SKIP:` and the sweep still runs. That is the
intended way to clear stale worktrees without a session to close out.

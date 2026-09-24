#!/usr/bin/env bash
# Close out a worktree session from inside the worktree.
#
# git refuses to check out one branch in two worktrees, so a session parked in
# .claude/worktrees/<name> cannot land its own branch with a plain `git merge` -- it would have to
# leave the worktree first. Worktrees share refs, so merging from whichever checkout already holds
# the default branch is the same merge: `git -C <that checkout> merge <branch>`. This does that,
# removes the worktree, deletes the branch, then sweeps worktrees whose work already landed.
#
# Safety rules, in order of importance:
#   - never --force: a worktree with uncommitted or untracked changes is refused, not cleaned
#   - never `git branch -D`: a branch is deleted only when it is an ancestor of the default
#     branch, which is strictly stronger than `git branch -d` -- that one is satisfied by the
#     branch's upstream, so every pushed-but-unmerged branch passes it
#   - never a locked worktree
#   - on any block, nothing is removed and the caller gets exit 1
#
#   finish-worktree.sh [--dry-run] [--no-prune]
set -euo pipefail

PROG="finish-worktree"
blocker() { echo "$PROG: BLOCKER: $*" >&2; exit 1; }

usage() {
  cat >&2 <<'EOF'
usage: finish-worktree.sh [--dry-run] [--no-prune]

  --dry-run   print what would happen, change nothing
  --no-prune  finish this worktree only; do not sweep other worktrees
EOF
}

# --- arguments ---------------------------------------------------------------
DRY_RUN=0; PRUNE=1
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run)  DRY_RUN=1 ;;
    --no-prune) PRUNE=0 ;;
    -h|--help)  usage; exit 0 ;;
    *)          usage; exit 2 ;;
  esac
  shift
done

# --- resolve -----------------------------------------------------------------
# WORKTREE must be read before the cd below: it is the directory being removed.
WORKTREE="$(git rev-parse --path-format=absolute --show-toplevel 2>/dev/null)" \
  || blocker "not inside a git worktree"
COMMON_DIR="$(git -C "$WORKTREE" rev-parse --path-format=absolute --git-common-dir)"
PRIMARY="$(dirname "$COMMON_DIR")"

# dirname(git-common-dir) is the primary checkout for an ordinary repository. Verify it, because
# --separate-git-dir, a bare repository and a moved primary all break that shortcut.
PRIMARY_COMMON="$(git -C "$PRIMARY" rev-parse --path-format=absolute --git-common-dir 2>/dev/null || true)"
[ "$PRIMARY_COMMON" = "$COMMON_DIR" ] \
  || blocker "cannot locate the primary checkout (common dir is $COMMON_DIR)"
[ "$(git -C "$PRIMARY" rev-parse --is-bare-repository)" = "false" ] \
  || blocker "bare repository: there is no checkout to merge into"

# Every git call below carries -C, so nothing depends on the working directory. Leaving the
# worktree that is about to be removed avoids forking children from a deleted directory.
cd "$PRIMARY"

# Which branch we land on.
INTO="$(git -C "$PRIMARY" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null || true)"
INTO="${INTO#origin/}"
if [ -z "$INTO" ]; then
  for candidate in main master; do
    if git -C "$PRIMARY" show-ref --verify --quiet "refs/heads/$candidate"; then
      INTO="$candidate"; break
    fi
  done
fi
[ -n "$INTO" ] || blocker "cannot tell which branch is the default one; there is no origin/HEAD,
  no local 'main' and no local 'master'"
git -C "$PRIMARY" show-ref --verify --quiet "refs/heads/$INTO" \
  || blocker "no local branch named '$INTO'"

BRANCH="$(git -C "$WORKTREE" symbolic-ref --quiet --short HEAD 2>/dev/null || true)"

# One line per worktree: <path>\t<branch>\t<locked>\t<prunable>
wt_annotations() {
  git -C "$PRIMARY" worktree list --porcelain | awk '
    /^worktree /{ p = substr($0, 10); b = ""; l = ""; r = "" }
    /^branch /  { b = substr($0, 8); sub(/^refs\/heads\//, "", b) }
    /^locked/   { l = "yes" }
    /^prunable/ { r = "yes" }
    /^$/        { if (p != "") print p "\t" b "\t" l "\t" r; p = "" }
    END         { if (p != "") print p "\t" b "\t" l "\t" r }'
}
wt_status() { git -C "$1" status --porcelain 2>/dev/null || true; }
wt_is_locked() { wt_annotations | awk -F'\t' -v w="$1" '$1 == w && $3 == "yes" { f = 1 } END { exit !f }'; }
wt_is_ancestor() { git -C "$PRIMARY" merge-base --is-ancestor "refs/heads/$1" "refs/heads/$INTO"; }

# The checkout that holds the default branch. Merges happen there, and so does `branch -d`,
# which decides "fully merged" against the HEAD of the repository it runs in.
MERGE_TARGET="$(wt_annotations | awk -F'\t' -v want="$INTO" '$2 == want { print $1; exit }')"
BRANCH_HOME="${MERGE_TARGET:-$PRIMARY}"

# --- phase 1: land this worktree's branch ------------------------------------
FINISHING=1
if [ "$WORKTREE" = "$PRIMARY" ]; then
  echo "SKIP: this is the primary checkout -- it has no branch of its own to land."
  FINISHING=0
elif [ -z "$BRANCH" ]; then
  echo "SKIP: this worktree has a detached HEAD -- there is no branch to land."
  FINISHING=0
elif [ "$BRANCH" = "$INTO" ]; then
  echo "SKIP: this worktree is already on '$INTO'."
  FINISHING=0
fi

if [ "$FINISHING" = 1 ]; then
  if wt_is_locked "$WORKTREE"; then
    blocker "$WORKTREE is locked, and locked worktrees are never touched. Unlock it with
    'git -C $PRIMARY worktree unlock $WORKTREE' once you are sure it is finished."
  fi

  status_out="$(wt_status "$WORKTREE")"
  if [ -n "$status_out" ]; then
    printf '%s\n' "$status_out" >&2
    blocker "$WORKTREE has $(printf '%s\n' "$status_out" | wc -l | tr -d ' ') uncommitted or untracked \
change(s). Refusing to --force. Commit or discard them, then run again."
  fi

  [ -n "$MERGE_TARGET" ] || blocker "no checkout has '$INTO' checked out, so there is nowhere to
    merge into. Check out '$INTO' in the primary ($PRIMARY) and run again."

  tracked="$(git -C "$MERGE_TARGET" status --porcelain --untracked-files=no)"
  if [ -n "$tracked" ]; then
    printf '%s\n' "$tracked" >&2
    blocker "$MERGE_TARGET (which holds '$INTO') has uncommitted changes. Commit or stash them
    first; a merge would write into that working tree."
  fi
  [ -z "$(wt_status "$MERGE_TARGET")" ] || echo "NOTE: $MERGE_TARGET has untracked files; they are left alone, and a merge refuses rather than overwrites them."

  before="$(git -C "$MERGE_TARGET" rev-parse HEAD)"
  if wt_is_ancestor "$BRANCH"; then
    echo "SKIP: branch '$BRANCH' is already an ancestor of '$INTO' -- nothing to merge."
  fi

  if [ "$DRY_RUN" = 1 ]; then
    echo "WOULD: git -C $MERGE_TARGET merge --no-edit $BRANCH"
  elif ! git -C "$MERGE_TARGET" -c core.editor=true merge --no-edit "$BRANCH"; then
    git -C "$MERGE_TARGET" merge --abort >/dev/null 2>&1 || true
    blocker "merge of '$BRANCH' into '$INTO' failed. Nothing was removed. If $MERGE_TARGET is left
    mid-merge, run 'git -C $MERGE_TARGET merge --abort'; otherwise resolve it there and run again."
  fi
  after="$(git -C "$MERGE_TARGET" rev-parse HEAD)"

  # Post-condition: the branch's commits must be reachable from the default branch. This, and not
  # the merge's exit code, is what authorises the removal below.
  wt_is_ancestor "$BRANCH" || blocker "the merge reported success but '$BRANCH' is still not an
    ancestor of '$INTO'. Not removing anything."
  if [ "$before" != "$after" ]; then
    echo "PASS: merged '$BRANCH' into '$INTO' ($(git -C "$MERGE_TARGET" rev-parse --short "$before") -> $(git -C "$MERGE_TARGET" rev-parse --short "$after"))"
  fi

  if [ "$DRY_RUN" = 1 ]; then
    echo "WOULD: git -C $PRIMARY worktree remove $WORKTREE"
    echo "WOULD: git -C $BRANCH_HOME branch -d $BRANCH"
  else
    # Remove before deleting the branch: git refuses to delete a branch that is checked out.
    git -C "$PRIMARY" worktree remove "$WORKTREE" \
      || blocker "'$BRANCH' is merged into '$INTO', but the worktree could not be removed and is
    still there. Nothing else was touched. Finish by hand: git worktree remove '$WORKTREE'"
    echo "PASS: removed worktree $WORKTREE"
    git -C "$BRANCH_HOME" branch -d "$BRANCH" \
      || blocker "'$BRANCH' is merged into '$INTO', but git refused to delete it. Delete it by
    hand from a checkout of '$INTO': git -C $BRANCH_HOME branch -d $BRANCH"
    echo "PASS: deleted branch $BRANCH"
  fi
fi

# --- phase 2: sweep worktrees whose work already landed ----------------------
total_removed=0; total_skipped=0
if [ "$PRUNE" = 1 ]; then
  echo
  echo "Sweep: worktrees whose branch has already landed"
  annotations="$(wt_annotations)"
  while IFS=$'\t' read -r path br locked prunable; do
    [ -n "$path" ] || continue
    rel="${path#"$PRIMARY"/}"

    if [ "$path" = "$PRIMARY" ]; then
      echo "SKIP: $rel -- the primary checkout"; total_skipped=$((total_skipped + 1)); continue
    fi
    [ "$path" = "$WORKTREE" ] && { total_skipped=$((total_skipped + 1)); continue; }
    if [ "$locked" = "yes" ]; then
      echo "SKIP: $rel -- locked"; total_skipped=$((total_skipped + 1)); continue
    fi
    if [ -n "$prunable" ] || [ ! -d "$path" ]; then
      echo "SKIP: $rel -- the directory is gone; run 'git -C $PRIMARY worktree prune --expire now'"
      total_skipped=$((total_skipped + 1)); continue
    fi
    if [ -z "$br" ]; then
      echo "SKIP: $rel -- detached HEAD, no branch to reason about"
      total_skipped=$((total_skipped + 1)); continue
    fi
    if [ "$br" = "$INTO" ]; then
      echo "SKIP: $rel -- holds '$INTO'"; total_skipped=$((total_skipped + 1)); continue
    fi

    out="$(wt_status "$path")"
    if [ -n "$out" ]; then
      echo "SKIP: $rel -- $(printf '%s\n' "$out" | wc -l | tr -d ' ') uncommitted or untracked change(s); refusing to --force"
      total_skipped=$((total_skipped + 1)); continue
    fi
    if ! wt_is_ancestor "$br"; then
      echo "SKIP: $rel -- branch '$br' has $(git -C "$PRIMARY" rev-list --count "refs/heads/$INTO..refs/heads/$br") commit(s) not in '$INTO'"
      total_skipped=$((total_skipped + 1)); continue
    fi

    if [ "$DRY_RUN" = 1 ]; then
      echo "WOULD: remove $rel and delete branch $br"; continue
    fi
    if git -C "$PRIMARY" worktree remove "$path"; then
      echo "PASS: removed $rel"
      total_removed=$((total_removed + 1))
      if [ -n "$MERGE_TARGET" ] && git -C "$BRANCH_HOME" branch -d "$br" 2>/dev/null; then
        echo "PASS: deleted branch $br"
      else
        echo "SKIP: branch $br kept -- could not be deleted from here"
      fi
    else
      echo "SKIP: $rel -- git refused to remove it"; total_skipped=$((total_skipped + 1))
    fi
  done <<<"$annotations"

  if [ "$DRY_RUN" = 1 ]; then
    echo "SWEEP: dry run, nothing changed."
  else
    git -C "$PRIMARY" worktree prune
  fi
fi

echo
echo "SUMMARY: removed $total_removed worktree(s), skipped $total_skipped"
if [ ! -d "$WORKTREE" ]; then
  echo "RESUME: this session's directory is gone. Next command: cd $PRIMARY"
fi

---
name: interactive-qa
description: Interactive QA session where user reports bugs conversationally. By default, fixes bugs one at a time on a feature branch in the current repo and queues additional bugs entered while a fix is in flight; pass `--worktree` to spawn parallel agents in isolated worktrees instead. Every fix must follow strict TDD RED-GREEN-REFACTOR — TDD_SKIPPED is a hard fail with no exceptions. When a bug is fixed, prompts user interactively (root cause + fix summary) to merge or re-fix. After merge, branch is kept for manual testing; user confirms fix or requests re-fix before branch is removed. Failed bugs get GitHub issues. Use when user wants bugs fixed on the spot during QA, mentions "interactive-qa", or wants TDD auto-fix during QA.
model: opus
argument-hint: "(--prd <issue-number>) (--pr) (--worktree)"
---

# Interactive QA Session

Run an interactive QA session. User describes bugs. **By default**, fix bugs one at a time on a feature branch in this repo — additional bugs entered while a fix is in flight are queued and started automatically when the active fix resolves. Pass `--worktree` to instead spawn one explore+fix agent per bug in its own git worktree (parallel, no batching). When the user says "done", stop accepting new bugs but keep handling agent completions, approvals, re-fixes, and queue drains. The session closes automatically once every bug is `approved` or `failed`.

## Arguments

- `--prd <number>` — (optional) GitHub issue number of the parent PRD. When provided, every GitHub issue filed in this session gets labeled `PRD-<number>` and `QA`.
- `--pr` — (optional) Instead of merging directly, create a PR per bug on approval, auto-merge it via `gh pr merge --squash`, then pull to update `BASE_BRANCH`. **Requires `--worktree`.**
- `--worktree` — (optional) Spawn each bug in its own git worktree so multiple agents can work in parallel. **Default is OFF.** Sequential mode (the default) runs one agent at a time on a feature branch in the main repo and queues additional bugs entered while a fix is in flight.

Parse at session start. Store as `PRD_NUMBER` (integer or null), `PR_MODE` (true/false), and `WORKTREE_MODE` (true/false) in context.

**Constraint:** if `PR_MODE=true && WORKTREE_MODE=false`, hard-fail at session start with: *"`--pr` requires `--worktree` (PR-per-bug only makes sense with parallel worktrees). Re-run with `--worktree --pr` or drop `--pr`."*

## Session start prechecks

Run before accepting any bug. Hard-fail with a clear message if any check fails:

```bash
# 1. Inside a git repo with at least one commit
git rev-parse --show-toplevel >/dev/null 2>&1 || abort "Not a git repo."
git rev-parse HEAD             >/dev/null 2>&1 || abort "Repo has no commits."

# 2. On a named branch (not detached HEAD)
BASE_BRANCH=$(git rev-parse --abbrev-ref HEAD)
[ "$BASE_BRANCH" != "HEAD" ] || abort "Detached HEAD — checkout a branch first."

# 3. Clean working tree
#    Default mode: agent commits directly in this repo, so WIP would interleave with the fix.
#    --worktree mode: WIP would be invisible to the worktree agent.
#    Either way, require a clean start.
[ -z "$(git status --porcelain)" ] || abort "Uncommitted changes in $BASE_BRANCH — commit or stash before QA."

# 4. --pr requires --worktree
if [ "$PR_MODE" = true ] && [ "$WORKTREE_MODE" != true ]; then
  abort "--pr requires --worktree (PR-per-bug only makes sense with parallel worktrees). Re-run with --worktree --pr or drop --pr."
fi

# 5. PR mode needs gh auth + a remote tracking branch
if [ "$PR_MODE" = true ]; then
  gh auth status >/dev/null 2>&1 || abort "PR mode needs 'gh auth login'."
  git ls-remote --exit-code origin "$BASE_BRANCH" >/dev/null 2>&1 \
    || abort "PR mode needs $BASE_BRANCH on origin."
fi
```

Store `BASE_BRANCH` in context. All rebases and merges target this branch.

### Detect test runner

Probe for the command agents will use:

1. If `package.json` has script `test:run` → `TEST_CMD="pnpm test:run"`
2. Else if `package.json` has script `test`        → `TEST_CMD="pnpm test"`
3. Else if `pyproject.toml` or `pytest.ini`        → `TEST_CMD="pytest"`
4. Else if `Cargo.toml`                            → `TEST_CMD="cargo test"`
5. Else → ask user: *"What command runs your tests?"* — store their answer.

Store `TEST_CMD` in context. Pass into §agent-prompt.

### Detect test marker syntax

The TDD marker (default `// qa-fix:#<id>`) must be a comment in the project's language:

- JS / TS / Java / Rust / Go / C-family → `// qa-fix:#<id>`
- Python / Ruby / Shell                  → `# qa-fix:#<id>`
- Other → ask user.

Store as `MARKER_PREFIX` in context.

---

## Session tracking (internal)

Track bugs in context only — no files. Each bug:

```
id:            integer (increment from 1)
title:         kebab-style short title
status:        queued | fixing | pending-review 🔍 | approved ✓ | failed ✗
commitHash:    null | 40-char hash
issueNumber:   null | integer
failureReason: null | string
branch:        null | string  (e.g. "fix-off-by-one-split"; set when bug starts fixing)
worktreePath:  null | string  (only set in --worktree mode; null in default sequential mode)
testFilePath:  null | string  (set when agent reports test file used)
rootCause:     null | string  (one sentence parsed from agent SUCCESS line)
fixSummary:    null | string  (one sentence parsed from agent SUCCESS line)
```

---

## Phase A — Bug collection + agent launch (queueing in default mode)

### 1. Listen and clarify

Let the user describe in their own words. Ask **at most 2 short clarifying questions** focused on:
- Expected vs actual behavior
- Steps to reproduce (if not obvious)

If the description is clear, skip questions.

### 2. Generate slug, then either spawn agent or queue

As soon as the bug description is collected — do NOT wait for "done" — immediately:

**a) Generate kebab title** from the user's description.
- 3–6 words, lowercase, hyphen-separated, names the symptom or component.
- Examples: "off by one in date split", "login button no spinner", "cart total ignores tax".
- Store as `title` on the bug record. Used for branch slug and chat messages.

**b) Identify repo root:**
```bash
REPO_ROOT=$(git rev-parse --show-toplevel)
```

**c) Compute branch slug.** Resolve collisions against existing branches in both modes; in `--worktree` mode also against the on-disk worktree directory:

```bash
SLUG="fix-$(echo "<title>" | sed 's/[^a-zA-Z0-9]/-/g' | tr '[:upper:]' '[:lower:]' | tr -s '-' | cut -c1-40)"

i=2
if [ "$WORKTREE_MODE" = true ]; then
  while [ -e "${REPO_ROOT}/../${SLUG}" ] || git -C "$REPO_ROOT" show-ref --quiet "refs/heads/${SLUG}"; do
    SLUG="${SLUG%-[0-9]*}-$i"; i=$((i+1))
  done
else
  while git -C "$REPO_ROOT" show-ref --quiet "refs/heads/${SLUG}"; do
    SLUG="${SLUG%-[0-9]*}-$i"; i=$((i+1))
  done
fi
```

Store `branch=$SLUG`. `worktreePath` stays null until step 2d sets it (only in `--worktree` mode).

**d) Branch on `WORKTREE_MODE`:**

#### `WORKTREE_MODE=true` (parallel)

```bash
WORKTREE_PATH="${REPO_ROOT}/../${SLUG}"
git -C "$REPO_ROOT" worktree add "$WORKTREE_PATH" -b "$SLUG"
```

Store `worktreePath=$WORKTREE_PATH`. Spawn the explore+fix agent (`run_in_background: true`, `subagent_type: general-purpose`) using the §agent-prompt template with `WORK_DIR=$WORKTREE_PATH`. Substitute `TEST_CMD` and `MARKER_PREFIX` from session context. Set `status=fixing`. Print: `#<id> <title> — explore+fix agent started in worktree $WORKTREE_PATH.`

#### `WORKTREE_MODE=false` (default, sequential)

If **no other bug** has `status` in `{fixing, pending-review}`, this bug starts immediately:

```bash
# Refuse if BASE_BRANCH picked up dirt since session start (e.g. a previous
# re-fix or manual edit). Sequential mode requires a clean tree to checkout cleanly.
[ -z "$(git -C "$REPO_ROOT" status --porcelain)" ] || abort "Working tree dirty in $BASE_BRANCH — resolve before starting next fix."

git -C "$REPO_ROOT" checkout -b "$SLUG" "$BASE_BRANCH"
```

`worktreePath` stays null. Spawn the explore+fix agent (`run_in_background: true`, `subagent_type: general-purpose`) using the §agent-prompt template with `WORK_DIR=$REPO_ROOT`. Set `status=fixing`. Print: `#<id> <title> — explore+fix agent started on branch $SLUG.`

Otherwise (an agent is already running or a fix is awaiting review), queue this bug:

- Set `status=queued`.
- Do **not** create the branch yet — creating it now would race the in-flight fix's eventual rebase + merge.
- Print: `#<id> <title> — queued (will start after #<active-id> resolves).`

### 3. Continue accepting bugs

After spawning the agent (or queueing it), print the current bug table:

```
| #  | Description                  | Status         | Branch                  |
|----|------------------------------|----------------|-------------------------|
|  1 | <title>                      | fixing         | fix-<slug>              |
|  2 | <title>                      | queued         | —                       |
```

Then immediately continue: `What's the next bug? (or say "done" to wait for results)`

In `--worktree` mode, all agents run in parallel — N bugs = N concurrent agents. In default mode, exactly one agent runs at a time; additional bugs sit in the `queued` column until the active fix resolves.

---

## Phase B — Wait for completion (fires when user says "done")

In default (sequential) mode there is at most one running agent; the table will show queued bugs that have not started yet. Each time an active bug resolves, §coordinator drains the queue (see §coordinator below).

### Step 1 — Acknowledge

Print the full bug table, then say `Agent(s) running — results will arrive as notifications.`

**Do NOT poll.** Background agents emit a notification on completion; that notification is delivered as the next user turn. Process each as it arrives via §coordinator and reprint the updated table.

If the user does NOT speak and no notification arrives within ~30 minutes of "done", check stuck agents with `TaskList`. For any agent in `running` state past 30 min, mark its bug `failed` with `failureReason="Agent timed out"` and call `TaskStop`. (Queued bugs are not running, so this sweep ignores them — they will be picked up by the queue drain after the timeout failure is recorded.)

### Step 2 — Continue accepting user input

After "done", approval is driven by `AskUserQuestion` in §coordinator — no need to type "approve". Still accept:
- Free-form description targeting a `pending-review` `#<id>` → re-fix flow (fallback if AskUserQuestion is not yet visible).
- New bug description (no `#<id>` reference) → reject: *"Session is closing — new bugs after 'done' are not accepted. Start a new QA session."*

Session ends only once every bug is `approved` or `failed`. Then run Phase D.

---

## §coordinator — processing agent results

> **Invariant.** Every transition to `approved` or `failed` — anywhere in this spec, including all four failure sites in §merge-flow — MUST invoke the queue-drain check below before yielding control. In `--worktree` mode the check is a no-op; in default mode it's the only mechanism that starts queued bugs.

### TDD enforcement check

Before accepting any `SUCCESS`, confirm the marker exists somewhere in the **branch's diff vs `BASE_BRANCH`** (not just HEAD — TDD may produce multiple commits, and HEAD may have moved off the bug branch):

```bash
# WORK_DIR = <worktreePath> in --worktree mode, $REPO_ROOT in default mode.
# Use the branch ref, not HEAD, so the check is correct regardless of current checkout.
git -C <WORK_DIR> diff "$BASE_BRANCH"...<branch> -- '**/*test*' '**/*spec*' '**/__tests__/**' \
  | grep -E "qa-fix:#<id>\b"
```

The `\b` word boundary prevents `qa-fix:#1` from matching `qa-fix:#10`.

If missing → treat as `TDD_SKIPPED: no qa-fix marker in test diff`.

### Parse agent result

- `SUCCESS: <hash> TEST:<testFilePath> ROOT_CAUSE:<rootCause> FIX_SUMMARY:<fixSummary>` (marker confirmed):
  - Set `status=pending-review`, store `commitHash`, `testFilePath`, `rootCause`, `fixSummary`
  - Call `AskUserQuestion`:
    ```
    question: "#<id> `<title>` ready.\n\nRoot cause: <rootCause>\nFix: <fixSummary>\n\nMerge into `<BASE_BRANCH>`?"
    header:   "Merge #<id>"
    options:
      - label: "Merge"   description: "Rebase + fast-forward merge (branch kept until you confirm)"
      - label: "Re-fix"  description: "Describe what's wrong — agent re-fixes on same branch"
    ```
  - If "Merge" → run **§merge-flow**
  - If "Re-fix" / Other (user typed feedback) → run **re-fix flow** (see Phase C)
  - **Tie-breaker.** If the user types a free-form description targeting `#<id>` while this `AskUserQuestion` is still pending, the harness routes it as the `Other` answer (typed feedback). Treat it as Re-fix with that text as the user's feedback. The `pending-review` → `fixing` transition happens once, not twice.
- `FAILED: <reason>` → `status=failed`, failureReason=reason. Then run §coordinator queue-drain.
- `TDD_SKIPPED: <reason>` → `status=failed`, failureReason=`TDD skipped: <reason>` **(hard fail, never retry)**. Then run §coordinator queue-drain.

### Drain the queue (default mode only)

Whenever a bug transitions to `approved` or `failed`, in default mode immediately start the next queued bug:

```
if WORKTREE_MODE=false and no other bug has status in {fixing, pending-review}:
  pick the lowest-id bug with status=queued (FIFO)
  if none → skip
  # Working tree must be clean. HEAD may still be on the just-failed bug branch
  # (rebase --abort restores HEAD there); checkout BASE_BRANCH only succeeds with a clean tree.
  [ -z "$(git -C "$REPO_ROOT" status --porcelain)" ] || abort "Working tree dirty in $REPO_ROOT — resolve before draining queue."
  git -C "$REPO_ROOT" checkout "$BASE_BRANCH"
  git -C "$REPO_ROOT" checkout -b "<branch>" "$BASE_BRANCH"
  spawn explore+fix agent (run_in_background: true) using §agent-prompt with WORK_DIR=$REPO_ROOT
  set its status=fixing
  print: "#<id> <title> — agent started (queue drained)."
```

The re-fix flow (Phase C) does **not** drain the queue: re-fix sets the bug back to `status=fixing`, which keeps the active slot occupied until that re-fix resolves. Do not add a redundant drain on the re-fix path.

---

## §agent-prompt

```
You are an explore+fix agent. Fix exactly one bug using strict TDD.

═══════════════════════════════════════
WORK DIR     : <WORK_DIR>     # = $WORKTREE_PATH in --worktree mode, $REPO_ROOT in default mode
REPO ROOT    : <repoRoot>
BRANCH       : <branch>       # already checked out by the orchestrator
BUG ID       : #<id>
BUG TITLE    : <title>
═══════════════════════════════════════

BUG DESCRIPTION:
<full user description, expected vs actual, reproduction steps>

═══════════════════════════════════════
STEP 0: EXPLORE
═══════════════════════════════════════

Before writing any code, explore the codebase inside <WORK_DIR>:

- Find exact files, functions, and modules involved in the bug
- Understand intended behavior from code and comments
- Find existing test files (*.test.*, *.spec.*, __tests__/)
- Check UBIQUITOUS_LANGUAGE.md if it exists
- Identify related types, interfaces, data models
- Note edge cases and guard conditions already present
- Form a hypothesis about the root cause

Do NOT start writing code until you have a clear picture.

═══════════════════════════════════════
TDD PROTOCOL — ZERO EXCEPTIONS
═══════════════════════════════════════

All work happens inside `<WORK_DIR>` on branch `<branch>`, which has already been checked out for you. In `--worktree` mode the orchestrator did this via `git worktree add -b`; in default sequential mode the orchestrator did `git checkout -b` in the main repo. Either way the branch is your starting point — do not switch branches. Never push to remote.

Read and follow the TDD skill at `~/.claude/skills/tdd/SKILL.md`.
Apply its RED-GREEN-REFACTOR cycle for this bug fix. Test runner: `cd <WORK_DIR> && <TEST_CMD> [<test file>]`

Interactive-QA additions on top of the TDD skill:

▸ MARKER — Add this comment on the line IMMEDIATELY ABOVE the test definition (test()/it()/describe block in JS, def test_xxx() in Python, #[test] in Rust, func TestXxx() in Go, etc.):
    <MARKER_PREFIX>
  Required. Without it the fix is rejected as TDD_SKIPPED.

▸ If you CANNOT write a failing test for any reason, output immediately and stop:
    TDD_SKIPPED: <one-sentence reason>
  NO fallback. No partial fix without a red test first.

▸ If the full suite fails due to your change, revert and output:
    FAILED: regression in full test suite — <file:line>

── STEP 4: COMMIT ───────────────────────────
Stage only the files you changed (NEVER git add . or git add -A):
  cd <WORK_DIR>
  git add <file1> <file2> ...
  git commit -m "fix(<scope>): <descriptive title that names the bug and the fix>

  - <one bullet: what was wrong>
  - <one bullet: what the fix does>
  - <one bullet: test added>

  Co-Authored-By: Claude Sonnet 4.6 <noreply@anthropic.com>"

Commit message rules:
  - Subject line: fix(<scope>): <what-was-broken> — not a generic "fix bug"
  - Body: 2–3 bullets max
  - Test file must be one of the staged files

── STEP 5: FINAL REPORT ─────────────────────
Your LAST message must be EXACTLY one of these three forms:
  SUCCESS: <full 40-character commit hash> TEST:<path/to/test/file> ROOT_CAUSE:<one sentence naming the defective code> FIX_SUMMARY:<one sentence naming the change made>
  FAILED: <one-sentence reason>
  TDD_SKIPPED: <one-sentence reason>

Never push to remote.
```

---

## §merge-flow — merge + post-merge confirmation

Called from §coordinator when user picks "Merge" on a `pending-review` bug.

**Step 1 — Rebase onto `BASE_BRANCH`:**

`WORK_DIR` resolves to `<worktreePath>` in `--worktree` mode and to `$REPO_ROOT` in default mode. In default mode the bug branch is already checked out in the main repo (orchestrator did `git checkout -b` before spawning the agent), so the rebase happens in place.

```bash
cd <WORK_DIR>
if [ "$PR_MODE" = true ]; then
  git fetch origin "$BASE_BRANCH"
  REBASE_TARGET="origin/$BASE_BRANCH"
else
  REBASE_TARGET="$BASE_BRANCH"
fi
git rebase "$REBASE_TARGET"
```

**On any conflict:** abort, do NOT auto-resolve.
```bash
git rebase --abort
```
→ `status=failed`, `failureReason="Rebase conflict — manual resolution required"`. Then run §coordinator queue-drain.

After a successful rebase, run `<TEST_CMD>`. Fail → `status=failed`, `failureReason="Regression after rebase"`. Then run §coordinator queue-drain.

---

**Step 2 — Merge:** branches on `PR_MODE`.

Before any merge, refuse if `BASE_BRANCH` in the main repo has uncommitted changes:
```bash
[ -z "$(git -C "$REPO_ROOT" status --porcelain)" ] || abort "Uncommitted changes in $BASE_BRANCH — resolve before approving."
```

#### Direct merge (`PR_MODE=false`)

```bash
git -C "$REPO_ROOT" checkout "$BASE_BRANCH"
git -C "$REPO_ROOT" merge --ff-only "<branch>" || {
  # Fast-forward merge failed — base branch advanced.
  # Reachable in --worktree mode (parallel bugs racing for ff merge).
  # In default sequential mode this is unreachable: only one bug holds the active slot
  # so BASE_BRANCH cannot advance between rebase and merge — the rebase already covers drift.
  # Mark this bug failed; let the next take over.
  status=failed; failureReason="Fast-forward merge failed — base advanced; rebase #<id> again."
  # Then run §coordinator queue-drain.
}
```

#### `--pr` mode (`PR_MODE=true`)

`--pr` requires `--worktree`, so `<WORK_DIR>` here is always `$WORKTREE_PATH`.

```bash
cd <WORK_DIR>
git push -u origin <branch>
PR_URL=$(gh pr create \
  --title "fix: <title>" \
  --base "$BASE_BRANCH" \
  --head <branch> \
  --body "$(cat <<EOF
## Summary

Fixes #<id>: <title>

## Test

Test marker \`<MARKER_PREFIX>\` in \`<testFilePath>\`.

🤖 Generated with [Claude Code](https://claude.com/claude-code)
EOF
)")

gh pr merge --squash --auto "$PR_URL"
until [ "$(gh pr view "$PR_URL" --json state -q .state)" = "MERGED" ]; do sleep 10; done

git -C "$REPO_ROOT" checkout "$BASE_BRANCH"
git -C "$REPO_ROOT" pull --ff-only origin "$BASE_BRANCH"
```

If merge stays `OPEN` past 30 min → `status=failed`, `failureReason="PR did not auto-merge: $PR_URL"`. Then run §coordinator queue-drain (no-op in `--worktree` mode, but kept for invariant consistency).

---

**Step 3 — Post-merge confirmation (branch/worktree NOT removed yet):**

Call `AskUserQuestion`. The wording differs by mode — in default mode there is no separate worktree path (the merged code is on `BASE_BRANCH` in the main repo):

```
# WORKTREE_MODE=true:
question: "#<id> `<title>` merged into `<BASE_BRANCH>`. Test manually at `<worktreePath>`. Fixed?"

# WORKTREE_MODE=false:
question: "#<id> `<title>` merged into `<BASE_BRANCH>`. Test manually in this repo. Fixed?"

header:   "Confirm #<id>"
options:
  - label: "Confirmed fixed"  description: "Remove branch (and worktree, if any), mark approved"
  - label: "Still broken"     description: "Describe what's wrong — re-fix on same branch, then merge again"
```

- If "Confirmed fixed":
  ```bash
  if [ "$WORKTREE_MODE" = true ]; then
    git -C "$REPO_ROOT" worktree remove <worktreePath> --force
  fi
  git -C "$REPO_ROOT" branch -D <branch> 2>/dev/null || true
  ```
  Set `status=approved`. Print: `#<id> <title> — merged and confirmed ✓`. Then run the queue-drain step from §coordinator.

- If "Still broken" / Other (user typed feedback):
  - `status=fixing`
  - In default mode, re-checkout `<branch>` in the main repo first: `git -C "$REPO_ROOT" checkout <branch>`. (Already on the branch in `--worktree` mode.)
  - Spawn new explore+fix agent (`run_in_background: true`) on the **same worktree/branch** using §agent-prompt with RE-FIX NOTE (see Phase C). `WORK_DIR` matches the original mode.
  - When agent completes → back to §coordinator (same flow: AskUserQuestion merge? → §merge-flow → post-merge confirmation).

---

## Phase C — Re-fix loop (per bug, ongoing)

Handles cases where the user is not satisfied with a fix — either before or after merge. Runs continuously alongside Phase B.

### User describes remaining problem with `#<id>`

User is not satisfied — they describe what's still wrong. Re-fix on the **same branch** (do not create a new branch; in `--worktree` mode, also reuse the same worktree):

1. Set `status=fixing`
2. In default mode, ensure the bug branch is checked out in the main repo: `git -C "$REPO_ROOT" checkout <branch>`. (Already current in `--worktree` mode.)
3. Spawn a new explore+fix agent (`run_in_background: true`) using §agent-prompt with `WORK_DIR=$REPO_ROOT` (default mode) or `WORK_DIR=$WORKTREE_PATH` (`--worktree` mode), plus the additional context:

```
RE-FIX NOTE: A previous fix was committed on this branch but did not satisfy the user.
User feedback: <user's description of remaining problem>

The existing fix and test are already committed; the existing test passes against current code.

TDD invariant for re-fix:
- The user feedback describes a NEW failing scenario the previous fix did not cover.
- Write a NEW failing test for that scenario (must genuinely RED against current code) with its own marker on the line above:
    <MARKER_PREFIX>
- Then GREEN, then REFACTOR. Commit normally. Final report uses the same #<id>.
- If the user feedback merely says "still broken" with no new scenario, ask for a concrete reproduction before writing code.
```

4. Print the updated bug table.

---

## Phase D — Summary

**Trigger:** runs automatically when every bug in the session is `approved` or `failed` (no `fixing` or `pending-review` left). Do NOT wait for any further user input.

Print the session banner:

```
══════════════════════════════════════════════════════════════
  QA SESSION COMPLETE
══════════════════════════════════════════════════════════════
  Bugs reported:  N
  ✓ Fixed (tests pass):  N
  ✗ Failed:              N  (TDD_SKIPPED counts as failed)
══════════════════════════════════════════════════════════════

BUGS APPROVED AND MERGED:
──────────────────────────────────────────────────────────────
| #  | Title                       | Test File                    | Commit    |
|----|-----------------------------|------------------------------|-----------|
|  1 | fix-bug-title               | src/__tests__/foo.test.ts    | abc12345  |
|  3 | another-bug                 | src/__tests__/bar.test.ts    | def67890  |

BUGS THAT DID NOT PASS:
──────────────────────────────────────────────────────────────
| #  | Title                       | Reason                              |
|----|-----------------------------|-------------------------------------|
|  2 | some-bug                    | TDD skipped: no test file found     |
```

### File GitHub issues for failed bugs

For each bug with `status: failed`:

1. Ensure labels exist:
   ```bash
   gh label create HARD --color FF0000 --description "Resisted automated TDD fix" 2>/dev/null || true
   gh label create "QA" --color 22C55E --description "Filed during QA session" 2>/dev/null || true
   # If PRD_NUMBER is set:
   gh label create "PRD-<PRD_NUMBER>" --color 0EA5E9 --description "Slice of PRD #<PRD_NUMBER>" 2>/dev/null || true
   ```

2. Build the label string: `LABELS="HARD,QA"`; if `PRD_NUMBER` set, append `,PRD-$PRD_NUMBER`. Then create the issue and capture its URL:
   ```bash
   ISSUE_URL=$(gh issue create \
     --title "<title>" \
     --label "$LABELS" \
     --body "$(cat <<EOF
   ## What happened
   <actual behavior>

   ## What I expected
   <expected behavior>

   ## Steps to reproduce
   <reproduction steps>

   ## Why automated fix failed
   <failureReason>

   ## Notes
   Reported during interactive QA session. Labeled HARD for further investigation.
   EOF
   )")
   ```

3. Parse the trailing number from `$ISSUE_URL` and store as `issueNumber` on the bug record. Print `$ISSUE_URL`.

### Cleanup branches and worktrees

Approved bugs already had their branch (and worktree, if any) removed in §merge-flow. Here we clean up **failed** bugs (left in place for inspection until summary), but selectively — failures where the fix itself was valid (rebase conflict, regression after rebase, ff-only failure, PR stuck open) keep their branch so the user can investigate or recover the work; failures where no usable fix exists (`TDD skipped`, agent `FAILED`, agent timed out) drop the branch.

Failure reason → keep branch?

| Failure reason                                     | Keep branch? |
|----------------------------------------------------|--------------|
| `TDD skipped: ...`                                 | no           |
| `<agent FAILED reason>` (no valid commit produced) | no           |
| `Agent timed out`                                  | no           |
| `Rebase conflict — manual resolution required`     | **yes**      |
| `Regression after rebase`                          | **yes**      |
| `Fast-forward merge failed — base advanced ...`    | **yes**      |
| `PR did not auto-merge: ...`                       | **yes**      |

```bash
# For each bug with status=failed:
if [ "$WORKTREE_MODE" = true ]; then
  git -C "$REPO_ROOT" worktree remove <worktreePath> --force
fi
if [ "<keepBranch>" = false ]; then
  git -C "$REPO_ROOT" branch -D <branch> 2>/dev/null || true
fi
# else: keep branch for manual recovery; print its name in the summary.

# After all removals:
if [ "$WORKTREE_MODE" = true ]; then
  git -C "$REPO_ROOT" worktree prune
fi

# Make sure we end on the base branch in default mode (HEAD may currently be on a deleted bug branch).
git -C "$REPO_ROOT" checkout "$BASE_BRANCH" 2>/dev/null || true
```

For each preserved branch, print: `#<id> <title> — branch <branch> kept for manual recovery.`

Print: `Branches cleaned up. Session closed.`

---
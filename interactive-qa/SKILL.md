---
name: interactive-qa
description: Interactive QA session where user reports bugs conversationally. For each bug, immediately spawns one explore+fix agent in background (parallel, no batching). Every fix must follow strict TDD RED-GREEN-REFACTOR — TDD_SKIPPED is a hard fail with no exceptions. When a bug is fixed, prompts user interactively (root cause + fix summary) to merge or re-fix. After merge, branch is kept for manual testing; user confirms fix or requests re-fix before branch is removed. Failed bugs get GitHub issues. Use when user wants bugs fixed on the spot during QA, mentions "interactive-qa", or wants TDD auto-fix during QA.
model: opus
argument-hint: "(--prd <issue-number>) (--pr)"
---

# Interactive QA Session

Run an interactive QA session. User describes bugs. For **each bug reported**, immediately spawn one explore+fix agent in the background — no waiting for "done". When user says "done", stop accepting new bugs but keep handling agent completions, approvals, and re-fixes. The session closes automatically once every bug is `approved` or `failed`.

## Arguments

- `--prd <number>` — (optional) GitHub issue number of the parent PRD. When provided, every GitHub issue filed in this session gets labeled `PRD-<number>` and `QA`.
- `--pr` — (optional) Instead of merging directly, create a PR per bug on approval, auto-merge it via `gh pr merge --squash`, then pull to update `BASE_BRANCH`.

Parse at session start. Store as `PRD_NUMBER` (integer or null) and `PR_MODE` (true/false) in context.

## Session start prechecks

Run before accepting any bug. Hard-fail with a clear message if any check fails:

```bash
# 1. Inside a git repo with at least one commit
git rev-parse --show-toplevel >/dev/null 2>&1 || abort "Not a git repo."
git rev-parse HEAD             >/dev/null 2>&1 || abort "Repo has no commits."

# 2. On a named branch (not detached HEAD)
BASE_BRANCH=$(git rev-parse --abbrev-ref HEAD)
[ "$BASE_BRANCH" != "HEAD" ] || abort "Detached HEAD — checkout a branch first."

# 3. Clean working tree (uncommitted WIP would be invisible to worktree agents)
[ -z "$(git status --porcelain)" ] || abort "Uncommitted changes in $BASE_BRANCH — commit or stash before QA."

# 4. PR mode needs gh auth + a remote tracking branch
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
status:        fixing | pending-review 🔍 | approved ✓ | failed ✗
commitHash:    null | 40-char hash
issueNumber:   null | integer
failureReason: null | string
branch:        null | string  (e.g. "fix-off-by-one-split")
worktreePath:  null | string  (e.g. "/path/to/repo/../fix-off-by-one-split")
testFilePath:  null | string  (set when agent reports test file used)
rootCause:     null | string  (one sentence parsed from agent SUCCESS line)
fixSummary:    null | string  (one sentence parsed from agent SUCCESS line)
```

---

## Phase A — Bug collection + immediate agent launch

### 1. Listen and clarify

Let the user describe in their own words. Ask **at most 2 short clarifying questions** focused on:
- Expected vs actual behavior
- Steps to reproduce (if not obvious)

If the description is clear, skip questions.

### 2. Immediately create worktree and spawn explore+fix agent

As soon as the bug description is collected — do NOT wait for "done" — immediately:

**a) Generate kebab title** from the user's description.
- 3–6 words, lowercase, hyphen-separated, names the symptom or component.
- Examples: "off by one in date split", "login button no spinner", "cart total ignores tax".
- Store as `title` on the bug record. Used for branch slug and chat messages.

**b) Identify repo root:**
```bash
REPO_ROOT=$(git rev-parse --show-toplevel)
```

**c) Create worktree:**
```bash
SLUG="fix-$(echo "<title>" | sed 's/[^a-zA-Z0-9]/-/g' | tr '[:upper:]' '[:lower:]' | tr -s '-' | cut -c1-40)"

# Collision: append -2, -3, … if either the directory OR the branch already exists.
i=2
while [ -e "${REPO_ROOT}/../${SLUG}" ] || git -C "$REPO_ROOT" show-ref --quiet "refs/heads/${SLUG}"; do
  SLUG="${SLUG%-[0-9]*}-$i"; i=$((i+1))
done
WORKTREE_PATH="${REPO_ROOT}/../${SLUG}"

git -C "$REPO_ROOT" worktree add "$WORKTREE_PATH" -b "$SLUG"
```

**d) Spawn explore+fix agent** (`run_in_background: true`, `subagent_type: general-purpose`) using the §agent-prompt template. Substitute `TEST_CMD` and `MARKER_PREFIX` from session context.

Set bug status to `fixing`. Print: `#<id> <title> — explore+fix agent started.`

### 3. Continue accepting bugs

After spawning the agent, print the current bug table:

```
| #  | Description                  | Status   | Branch                  |
|----|------------------------------|----------|-------------------------|
|  1 | <title>                      | fixing   | fix-<slug>              |
```

Then immediately continue: `What's the next bug? (or say "done" to wait for results)`

All agents run in parallel — N bugs = N concurrent agents.

---

## Phase B — Wait for completion (fires when user says "done")

### Step 1 — Acknowledge

Print the full bug table, then say `All agents running — results will arrive as notifications.`

**Do NOT poll.** Background agents emit a notification on completion; that notification is delivered as the next user turn. Process each as it arrives via §coordinator and reprint the updated table.

If the user does NOT speak and no notification arrives within ~30 minutes of "done", check stuck agents with `TaskList`. For any agent in `running` state past 30 min, mark its bug `failed` with `failureReason="Agent timed out"` and call `TaskStop`.

### Step 2 — Continue accepting user input

After "done", approval is driven by `AskUserQuestion` in §coordinator — no need to type "approve". Still accept:
- Free-form description targeting a `pending-review` `#<id>` → re-fix flow (fallback if AskUserQuestion is not yet visible).
- New bug description (no `#<id>` reference) → reject: *"Session is closing — new bugs after 'done' are not accepted. Start a new QA session."*

Session ends only once every bug is `approved` or `failed`. Then run Phase D.

---

## §coordinator — processing agent results

### TDD enforcement check

Before accepting any `SUCCESS`, confirm the marker exists somewhere in the **branch's diff vs `BASE_BRANCH`** (not just HEAD — TDD may produce multiple commits):

```bash
git -C <worktreePath> diff "$BASE_BRANCH"...HEAD -- '**/*test*' '**/*spec*' '**/__tests__/**' \
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
- `FAILED: <reason>` → `status=failed`, failureReason=reason
- `TDD_SKIPPED: <reason>` → `status=failed`, failureReason=`TDD skipped: <reason>` **(hard fail, never retry)**

---

## §agent-prompt

```
You are an explore+fix agent running in an isolated git worktree. Fix exactly one bug using strict TDD.

═══════════════════════════════════════
WORKTREE DIR : <worktreePath>
REPO ROOT    : <repoRoot>
BRANCH       : <branch>
BUG ID       : #<id>
BUG TITLE    : <title>
═══════════════════════════════════════

BUG DESCRIPTION:
<full user description, expected vs actual, reproduction steps>

═══════════════════════════════════════
STEP 0: EXPLORE
═══════════════════════════════════════

Before writing any code, explore the codebase inside <worktreePath>:

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

All work happens inside <worktreePath>. Never touch the main repo.

Read and follow the TDD skill at `~/.claude/skills/tdd/SKILL.md`.
Apply its RED-GREEN-REFACTOR cycle for this bug fix. Test runner: `cd <worktreePath> && <TEST_CMD> [<test file>]`

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
  cd <worktreePath>
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
```bash
cd <worktreePath>
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
→ `status=failed`, `failureReason="Rebase conflict — manual resolution required"`.

After a successful rebase, run `<TEST_CMD>`. Fail → `status=failed`, `failureReason="Regression after rebase"`.

---

**Step 2 — Merge (two modes):**

Before any merge, refuse if `BASE_BRANCH` in the main repo has uncommitted changes:
```bash
[ -z "$(git -C "$REPO_ROOT" status --porcelain)" ] || abort "Uncommitted changes in $BASE_BRANCH — resolve before approving."
```

#### Default mode (`PR_MODE=false`)

```bash
git -C "$REPO_ROOT" checkout "$BASE_BRANCH"
git -C "$REPO_ROOT" merge --ff-only "<branch>" || abort "Fast-forward merge failed — base branch advanced; rebase #<id> again."
```

#### `--pr` mode (`PR_MODE=true`)

```bash
cd <worktreePath>
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

If merge stays `OPEN` past 30 min → `status=failed`, `failureReason="PR did not auto-merge: $PR_URL"`.

---

**Step 3 — Post-merge confirmation (branch/worktree NOT removed yet):**

Call `AskUserQuestion`:
```
question: "#<id> `<title>` merged into `<BASE_BRANCH>`. Test manually at `<worktreePath>`. Fixed?"
header:   "Confirm #<id>"
options:
  - label: "Confirmed fixed"  description: "Remove branch + worktree, mark approved"
  - label: "Still broken"     description: "Describe what's wrong — re-fix on same branch, then merge again"
```

- If "Confirmed fixed":
  ```bash
  git -C "$REPO_ROOT" worktree remove <worktreePath> --force
  git -C "$REPO_ROOT" branch -D <branch> 2>/dev/null || true
  ```
  Set `status=approved`. Print: `#<id> <title> — merged and confirmed ✓`

- If "Still broken" / Other (user typed feedback):
  - `status=fixing`
  - Spawn new explore+fix agent (`run_in_background: true`) on the **same worktree/branch** using §agent-prompt with RE-FIX NOTE (see Phase C)
  - When agent completes → back to §coordinator (same flow: AskUserQuestion merge? → §merge-flow → post-merge confirmation)

---

## Phase C — Re-fix loop (per bug, ongoing)

Handles cases where the user is not satisfied with a fix — either before or after merge. Runs continuously alongside Phase B.

### User describes remaining problem with `#<id>`

User is not satisfied — they describe what's still wrong. Re-fix on the **same branch and worktree** (do not create a new one):

1. Set `status=fixing`
2. Spawn a new explore+fix agent (`run_in_background: true`) on the same worktree using §agent-prompt, with the additional context:

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

3. Print the updated bug table.

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

### Cleanup worktrees

Approved bugs already had their worktree removed in §merge-flow. Here we only clean up **failed** bugs (their worktrees were left in place for inspection until summary):

```bash
# For each bug with status=failed:
git -C "$REPO_ROOT" worktree remove <worktreePath> --force
git -C "$REPO_ROOT" branch   -D <branch> 2>/dev/null || true

# After all removals:
git -C "$REPO_ROOT" worktree prune
```

Print: `Worktrees cleaned up. Session closed.`

---
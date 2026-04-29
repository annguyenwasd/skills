---
name: qa
description: Interactive QA session where user reports bugs conversationally. Fixes bugs one at a time on a feature branch in the current repo and queues additional bugs entered while a fix is in flight. Every fix must follow strict TDD RED-GREEN-REFACTOR — TDD_SKIPPED is a hard fail with no exceptions. When a bug is fixed, prompts user interactively (root cause + fix summary) to merge or re-fix. After merge, branch is kept for manual testing; user confirms fix or requests re-fix before branch is removed. Failed bugs get GitHub issues. Use when user wants bugs fixed on the spot during QA, mentions "qa", or wants sequential TDD auto-fix during QA.
model: opus
argument-hint: "(--prd <issue-number>)"
---

# Interactive QA Session

Run an interactive QA session. User describes bugs. Fix bugs one at a time on a feature branch in this repo — additional bugs entered while a fix is in flight are queued and started automatically when the active fix resolves. When the user says "done", stop accepting new bugs but keep handling agent completions, approvals, re-fixes, and queue drains. The session closes automatically once every bug is `approved` or `failed`.

## Arguments

- `--prd <number>` — (optional) GitHub issue number of the parent PRD. When provided, every GitHub issue filed in this session gets labeled `PRD-<number>` and `QA`.

Parse at session start. Store as `PRD_NUMBER` (integer or null) in context.

## Session start prechecks

Run before accepting any bug. Hard-fail with a clear message if any check fails:

```bash
# 1. Inside a git repo with at least one commit
git rev-parse --show-toplevel >/dev/null 2>&1 || abort "Not a git repo."
git rev-parse HEAD             >/dev/null 2>&1 || abort "Repo has no commits."

# 2. On a named branch (not detached HEAD)
BASE_BRANCH=$(git rev-parse --abbrev-ref HEAD)
[ "$BASE_BRANCH" != "HEAD" ] || abort "Detached HEAD — checkout a branch first."

# 3. Clean working tree — agent commits directly in this repo, so WIP would interleave with the fix.
[ -z "$(git status --porcelain)" ] || abort "Uncommitted changes in $BASE_BRANCH — commit or stash before QA."
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
id:                integer (increment from 1)
title:             kebab-style short title
status:            queued | fixing | pending-review 🔍 | approved ✓ | failed ✗
commitHash:        null | 40-char hash
issueNumber:       null | integer
failureReason:     null | string
branch:            null | string  (e.g. "fix-off-by-one-split"; set when bug starts fixing)
testFilePath:      null | string  (set when agent reports test file used)
rootCause:         null | string  (one sentence parsed from agent SUCCESS line)
fixSummary:        null | string  (one sentence parsed from agent SUCCESS line)
expectedBehaviour: string         (set in Phase A — "what user wants", separated from actualBehaviour)
actualBehaviour:   string         (set in Phase A — "what user observes before fix")
uiFlag:            null | boolean (computed in §coordinator from full branch diff vs BASE_BRANCH)
```

---

## Phase A — Bug collection + agent launch

### 1. Listen and clarify

Let the user describe in their own words. Ask **at most 2 short clarifying questions** focused on:
- Expected vs actual behavior
- Steps to reproduce (if not obvious)

After the description (and any clarifications) settles, **always derive and store two short fields** before spawning the agent — they drive the `/verify --qa <id>` checklist later:

- `expectedBehaviour` — one or two sentences describing what the user wants to happen
- `actualBehaviour` — one or two sentences describing what the user observes today

If the user's description already separates them, copy verbatim. Otherwise, infer from context and confirm with one short echo: `"Got it — expected: <X>; actual: <Y>. Right?"`. If the user corrects, update the fields. Skip the echo only when both are unambiguous from the original description.

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

**c) Compute branch slug.** Resolve collisions against existing branches:

```bash
SLUG="fix-$(echo "<title>" | sed 's/[^a-zA-Z0-9]/-/g' | tr '[:upper:]' '[:lower:]' | tr -s '-' | cut -c1-40)"

i=2
while git -C "$REPO_ROOT" show-ref --quiet "refs/heads/${SLUG}"; do
  SLUG="${SLUG%-[0-9]*}-$i"; i=$((i+1))
done
```

Store `branch=$SLUG`.

**d) Spawn agent or queue:**

If **no other bug** has `status` in `{fixing, pending-review}`, this bug starts immediately:

```bash
# Refuse if BASE_BRANCH picked up dirt since session start (e.g. a previous
# re-fix or manual edit). Sequential mode requires a clean tree to checkout cleanly.
[ -z "$(git -C "$REPO_ROOT" status --porcelain)" ] || abort "Working tree dirty in $BASE_BRANCH — resolve before starting next fix."

git -C "$REPO_ROOT" checkout -b "$SLUG" "$BASE_BRANCH"
```

Spawn the explore+fix agent (`run_in_background: true`, `subagent_type: general-purpose`) using the §agent-prompt template with `WORK_DIR=$REPO_ROOT`. Substitute `TEST_CMD` and `MARKER_PREFIX` from session context. Set `status=fixing`. Print: `#<id> <title> — explore+fix agent started on branch $SLUG.`

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

Exactly one agent runs at a time; additional bugs sit in the `queued` column until the active fix resolves.

---

## Phase B — Wait for completion (fires when user says "done")

There is at most one running agent; the table will show queued bugs that have not started yet. Each time an active bug resolves, §coordinator drains the queue (see §coordinator below).

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

> **Invariant.** Every transition to `approved` or `failed` — anywhere in this spec, including all four failure sites in §merge-flow — MUST invoke the queue-drain check below before yielding control. This is the only mechanism that starts queued bugs.

### TDD enforcement check

Before accepting any `SUCCESS`, confirm the marker exists somewhere in the **branch's diff vs `BASE_BRANCH`** (not just HEAD — TDD may produce multiple commits, and HEAD may have moved off the bug branch):

```bash
# WORK_DIR = $REPO_ROOT
# Use the branch ref, not HEAD, so the check is correct regardless of current checkout.
git -C "$REPO_ROOT" diff "$BASE_BRANCH"...<branch> -- '**/*test*' '**/*spec*' '**/__tests__/**' \
  | grep -E "qa-fix:#<id>\b"
```

The `\b` word boundary prevents `qa-fix:#1` from matching `qa-fix:#10`.

If missing → treat as `TDD_SKIPPED: no qa-fix marker in test diff`.

### Parse agent result

- `SUCCESS: <hash> TEST:<testFilePath> ROOT_CAUSE:<rootCause> FIX_SUMMARY:<fixSummary>` (marker confirmed):
  - Set `status=pending-review`, store `commitHash`, `testFilePath`, `rootCause`, `fixSummary`
  - **Compute `uiFlag`** from the *full branch diff* against `BASE_BRANCH` (not just the latest commit — re-fixes layer commits, and the answer must reflect everything the user has to manually verify):
    ```bash
    UI_HIT=$(git -C "$REPO_ROOT" diff --name-only "$BASE_BRANCH...<branch>" \
      | grep -E '\.(tsx|jsx|vue|svelte|html|css|scss|sass|less|astro)$|(^|/)(component|page|view|screen|layout|widget)s?(/|\.|-|_)' \
      | head -1)
    [ -n "$UI_HIT" ] && uiFlag=true || uiFlag=false
    ```
    Store `uiFlag` on the bug record.
  - Write checklist file (overwrite if exists):
    ```bash
    CHECKLIST_DIR="$(git -C "$REPO_ROOT" rev-parse --show-toplevel)/.checklist"
    mkdir -p "$CHECKLIST_DIR"
    ```
    Write `$CHECKLIST_DIR/qa-<id>.md` using stored fields (`expectedBehaviour`, `actualBehaviour` from Phase A; `fixSummary` from agent; `type` from `uiFlag`):
    ```markdown
    ---
    qa-id: <id>
    type: <ui if uiFlag=true, else api>
    ---

    ## Expected behaviour

    <expectedBehaviour>

    ## Actual behaviour (before fix)

    <actualBehaviour>

    ## Fix summary

    <fixSummary>
    ```
    Print: ``Checklist written: .checklist/qa-<id>.md — pick "Verify" below or run `/verify --qa <id>` later.``
  - Call `AskUserQuestion`:
    ```
    question: "#<id> `<title>` ready.\n\nRoot cause: <rootCause>\nFix: <fixSummary>\n\nMerge into `<BASE_BRANCH>`?"
    header:   "Review #<id>"
    options:
      - label: "Merge"   description: "Rebase + fast-forward merge (branch kept until you confirm)"
      - label: "Verify"  description: "Run /verify --qa <id> against bug branch, then re-prompt"
      - label: "Re-fix"  description: "Describe what's wrong — agent re-fixes on same branch"
    ```
  - If "Merge" → run **§merge-flow**
  - If "Verify" → run **§verify-flow**
  - If "Re-fix" / Other (user typed feedback) → run **re-fix flow** (see Phase C)
  - **Tie-breaker** (applies to **every** `AskUserQuestion` in §coordinator, §verify-flow, and §merge-flow). If the user types a free-form description targeting `#<id>` while a prompt is open, the harness routes it as the `Other` answer (typed feedback). Treat `Other` as the closest re-fix-shaped option on the current prompt: **Re-fix** on the post-success and post-verify-pass prompts, **Re-fix** on the post-verify-fail prompt, **Cancel→Re-fix** on the tooling/error prompts (treat the typed text as a re-fix request), **Still broken** on the post-merge prompt. The `pending-review` → `fixing` transition happens once, not twice.
- `FAILED: <reason>` → `status=failed`, failureReason=reason. Then run §coordinator queue-drain.
- `TDD_SKIPPED: <reason>` → `status=failed`, failureReason=`TDD skipped: <reason>` **(hard fail, never retry)**. Then run §coordinator queue-drain.

### Drain the queue

Whenever a bug transitions to `approved` or `failed`, immediately start the next queued bug:

```
if no other bug has status in {fixing, pending-review}:
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
WORK DIR     : <WORK_DIR>     # = $REPO_ROOT
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

All work happens inside `<WORK_DIR>` on branch `<branch>`, which has already been checked out for you via `git checkout -b` in the main repo. Do not switch branches. Never push to remote.

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

## §verify-flow — run /verify and re-prompt for merge

Called from §coordinator when the user picks **Verify** on a `pending-review`
bug. Bug stays in `pending-review` for the entire flow. The bug branch is
already checked out in the main repo.

**Bug-record additions.** Extend the bug record with:

- `verifyStatus` ∈ `{not-run, pass, fail, error}` — default `not-run`.
- `verifyReport` — full text from the most recent /verify run (used to
  compose re-fix feedback in §verify-feedback).

**Step 1 — Print progress and confirm branch checkout.**

```bash
echo "Verifying #<id> — running /verify --qa <id>… (this blocks until done)"
git -C "$REPO_ROOT" checkout "<branch>"
```

**Step 2 — Invoke /verify via a foreground Agent.**

Do **not** use `Skill(skill="verify")` — the harness rejects nested skill
invocations while /qa is running. Spawn a foreground `general-purpose`
Agent that follows verify's SKILL.md instructions with `--qa <id>`. Block
on completion. Capture stdout as `VERIFY_REPORT` and store on the bug
record's `verifyReport`. Use **§verify-invoke-prompt**.

**Step 3 — Classify the run.**

```
if "VERIFY_ERROR" in VERIFY_REPORT or no "## Summary" block:
    classification = error
else:
    parse PASS, FAIL, TIMEOUT, ASSUMED, UNVERIFIABLE counts from Summary
    fails = FAIL + TIMEOUT
    unv   = UNVERIFIABLE
    if "Browser MCP pass skipped" in report or "Browser pass skipped" in report:
        tool_unv = unv
    else:
        tool_unv = 0
    real_fails = fails + (unv - tool_unv)

    if real_fails == 0 and tool_unv == 0:
        classification = pass
    elif real_fails == 0 and tool_unv > 0:
        classification = tooling
    else:
        classification = fail
```

Set `verifyStatus = pass | fail | error` (`tooling` records as `fail` on
the record but takes its own prompt branch below).

If `Total == 0`, classify as `pass` and append the literal string
` (checklist had 0 items)` to the next prompt's question text — the user
needs to know it was a no-op.

**Step 4 — Branch on classification.**

**4a · `classification == pass`** — re-prompt for merge:

```
question: "#<id> `<title>` — verify passed (PASS:<n> ASSUMED:<n>)<empty-note>. Merge into `<BASE_BRANCH>`?"
header:   "Merge #<id>"
options:
  - label: "Merge"   description: "Rebase + fast-forward merge (branch kept until you confirm)"
  - label: "Re-fix"  description: "Describe what's wrong — agent re-fixes on same branch"
```

- "Merge" → §merge-flow.
- "Re-fix" / Other → re-fix flow (Phase C).

**4b · `classification == fail`** — at least one real FAIL/TIMEOUT/non-tooling
UNVERIFIABLE:

```
question: "#<id> `<title>` — verify failed (FAIL:<n> TIMEOUT:<n> UNVERIFIABLE:<n>). Next step?"
header:   "Verify #<id>"
options:
  - label: "Re-fix"        description: "Re-fix on same branch using verify failures + your notes (Recommended)"
  - label: "Merge anyway"  description: "Skip verify and merge — only if failures are checklist artefacts"
  - label: "Verify again"  description: "Re-run /verify --qa <id> (e.g. flaky timeout); each retry restarts the app"
```

- "Re-fix" / Other → re-fix flow (Phase C) with composite feedback (see
  **§verify-feedback**).
- "Merge anyway" → §merge-flow.
- "Verify again" → loop to §verify-flow Step 1. No hard cap; document the
  cost in the option description above.

**4c · `classification == tooling`** — every remaining failure is
UNVERIFIABLE caused by missing browsermcp / Playwright:

```
question: "#<id> `<title>` — verify could not run UI checks (UNVERIFIABLE:<n>); browser tooling missing. Next step?"
header:   "Verify #<id>"
options:
  - label: "Show install hint"  description: "Print the install command from the verify report and re-prompt"
  - label: "Merge anyway"       description: "Tooling gap is unrelated to fix correctness"
  - label: "Cancel"             description: "Stay on `pending-review`; pick Merge/Verify/Re-fix later"
```

- "Show install hint" → echo the lines from `VERIFY_REPORT` between
  `Browser (MCP|pass) skipped:` and the next blank line, then re-prompt
  with the same options.
- "Merge anyway" → §merge-flow.
- "Cancel" → return to the §coordinator post-success prompt
  (Merge / Verify / Re-fix) without re-running verify.
- "Other" (typed feedback) → treat as Cancel + Re-fix: store typed text as
  re-fix feedback and run re-fix flow (Phase C).

**4d · `classification == error`** — /verify itself failed:

```
question: "#<id> `<title>` — /verify errored (autostart or subagent failure). Next step?"
header:   "Verify #<id>"
options:
  - label: "Re-fix"        description: "Treat as re-fix; describe what to address"
  - label: "Merge anyway"  description: "Skip verify and merge"
  - label: "Cancel"        description: "Stay on `pending-review`; pick Merge/Verify/Re-fix later"
```

Routing analogous to 4c.

**Free-form input during /verify run.** The verify-runner Agent is
foreground and the orchestrator is blocked. Any user message typed during
this window is delivered after the Agent returns; route it as `Other` on
whichever post-verify prompt opens next (per the generalised tie-breaker
in §coordinator).

---

## §verify-feedback — composing the re-fix feedback string

When "Re-fix" / Other is picked from a post-verify-fail prompt (4b), build
the §agent-prompt RE-FIX NOTE `User feedback:` line as:

```
Verify reported failures (from /verify --qa <id>):
<the "Items Requiring Attention" block from VERIFY_REPORT verbatim>

User notes: <typed feedback if any, else omit this line>
```

Typed feedback is **appended**, never replaces the verify items. If the
verify report has no "Items Requiring Attention" section (e.g. only
TIMEOUT rows produced one), substitute the failing rows from the verify
result table instead.

---

## §verify-invoke-prompt — prompt for the verify-runner Agent

```
You are running the /verify skill non-interactively for /qa.

Read the skill at /Users/annguyenvanchuc/workspace/skills/verify/SKILL.md
and execute it with arguments:  --qa <id>

Repo root: <REPO_ROOT>
Bug branch (already checked out): <branch>

Constraints:
- Do not modify code, do not switch branches, do not commit anything.
- Do not call /qa or any other skill.
- Print only the final Verification Report (Step 6 of /verify). The
  /qa orchestrator parses it.
- If /verify cannot start the app or the subagent errors, your last
  line must be exactly:  VERIFY_ERROR: <one-sentence reason>
```

---

## §merge-flow — merge + post-merge confirmation

Called from §coordinator when user picks "Merge" on a `pending-review` bug.

**Step 1 — Rebase onto `BASE_BRANCH`:**

`WORK_DIR` = `$REPO_ROOT`. The bug branch is already checked out in the main repo (orchestrator did `git checkout -b` before spawning the agent), so the rebase happens in place.

```bash
cd <WORK_DIR>
REBASE_TARGET="$BASE_BRANCH"
git rebase "$REBASE_TARGET"
```

**On any conflict:** abort, do NOT auto-resolve.
```bash
git rebase --abort
```
→ `status=failed`, `failureReason="Rebase conflict — manual resolution required"`. Then run §coordinator queue-drain.

After a successful rebase, run `<TEST_CMD>`. Fail → `status=failed`, `failureReason="Regression after rebase"`. Then run §coordinator queue-drain.

---

**Step 2 — Merge:**

Before any merge, refuse if `BASE_BRANCH` in the main repo has uncommitted changes:
```bash
[ -z "$(git -C "$REPO_ROOT" status --porcelain)" ] || abort "Uncommitted changes in $BASE_BRANCH — resolve before approving."
```

```bash
git -C "$REPO_ROOT" checkout "$BASE_BRANCH"
git -C "$REPO_ROOT" merge --ff-only "<branch>" || {
  # Fast-forward merge failed — base branch advanced.
  # Mark this bug failed; let the next take over.
  status=failed; failureReason="Fast-forward merge failed — base advanced; rebase #<id> again."
  # Then run §coordinator queue-drain.
}
```

---

**Step 3 — Post-merge confirmation (branch NOT removed yet):**

Call `AskUserQuestion`:

```
question: "#<id> `<title>` merged into `<BASE_BRANCH>`. Test manually in this repo. Fixed?"
header:   "Confirm #<id>"
options:
  - label: "Confirmed fixed"  description: "Remove branch, mark approved"
  - label: "Still broken"     description: "Describe what's wrong — re-fix on same branch, then merge again"
```

- If "Confirmed fixed":
  ```bash
  git -C "$REPO_ROOT" branch -D <branch> 2>/dev/null || true
  ```
  Set `status=approved`. Print: `#<id> <title> — merged and confirmed ✓`. Then run the queue-drain step from §coordinator.

- If "Still broken" / Other (user typed feedback):
  - `status=fixing`
  - Re-checkout `<branch>` in the main repo: `git -C "$REPO_ROOT" checkout <branch>`.
  - Spawn new explore+fix agent (`run_in_background: true`) on the **same branch** using §agent-prompt with RE-FIX NOTE (see Phase C). `WORK_DIR=$REPO_ROOT`.
  - When agent completes → back to §coordinator (same flow: AskUserQuestion merge? → §merge-flow → post-merge confirmation).

---

## Phase C — Re-fix loop (per bug, ongoing)

Handles cases where the user is not satisfied with a fix — either before or after merge. Runs continuously alongside Phase B.

### User describes remaining problem with `#<id>`

User is not satisfied — they describe what's still wrong. Re-fix on the **same branch** (do not create a new branch):

1. Set `status=fixing`
2. Ensure the bug branch is checked out in the main repo: `git -C "$REPO_ROOT" checkout <branch>`.
3. Spawn a new explore+fix agent (`run_in_background: true`) using §agent-prompt with `WORK_DIR=$REPO_ROOT`, plus the additional context:

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
| #  | Title                       | Test File                    | Commit    | Verify   |
|----|-----------------------------|------------------------------|-----------|----------|
|  1 | fix-bug-title               | src/__tests__/foo.test.ts    | abc12345  | pass     |
|  3 | another-bug                 | src/__tests__/bar.test.ts    | def67890  | not-run  |

The `Verify` column echoes the bug record's `verifyStatus`
(`pass | fail | error | not-run`); `not-run` means the user merged without
picking the Verify option in §coordinator or §verify-flow.

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

### Cleanup branches

Approved bugs already had their branch removed in §merge-flow. Here we clean up **failed** bugs (left in place for inspection until summary), but selectively — failures where the fix itself was valid (rebase conflict, regression after rebase, ff-only failure) keep their branch so the user can investigate or recover the work; failures where no usable fix exists (`TDD skipped`, agent `FAILED`, agent timed out) drop the branch.

Failure reason → keep branch?

| Failure reason                                     | Keep branch? |
|----------------------------------------------------|--------------|
| `TDD skipped: ...`                                 | no           |
| `<agent FAILED reason>` (no valid commit produced) | no           |
| `Agent timed out`                                  | no           |
| `Rebase conflict — manual resolution required`     | **yes**      |
| `Regression after rebase`                          | **yes**      |
| `Fast-forward merge failed — base advanced ...`    | **yes**      |

```bash
# For each bug with status=failed:
if [ "<keepBranch>" = false ]; then
  git -C "$REPO_ROOT" branch -D <branch> 2>/dev/null || true
fi
# else: keep branch for manual recovery; print its name in the summary.

# Make sure we end on the base branch (HEAD may currently be on a deleted bug branch).
git -C "$REPO_ROOT" checkout "$BASE_BRANCH" 2>/dev/null || true
```

For each preserved branch, print: `#<id> <title> — branch <branch> kept for manual recovery.`

Print: `Branches cleaned up. Session closed.`

---
name: ship-it
description: End-to-end PRD orchestrator. Takes a PRD file path or GitHub issue URL/number, breaks it into a dependency-ordered task DAG, creates GitHub issues with labels and milestone, then spawns parallel TDD agent swarms in isolated git worktrees — one per ready task. Each agent implements strict RED-GREEN-REFACTOR TDD, opens a PR quoting the PRD section, links to the parent issue. Monitors CI (re-invokes fix agents on failure), polls PR review comments every N minutes and addresses them with follow-up commits. Unlocks dependent tasks as PRs merge. Produces a live markdown dashboard. Supports --dry-run to render the ASCII DAG without executing. Use when user says "ship it", "ship this PRD", "run ship-it", or invokes /ship-it.
model: opus
argument-hint: "--prd <file|url|number> (--dry-run) (--poll <minutes>) (--max-iter <n>)"
---

# Ship-It Orchestrator

Autonomously ship a PRD: DAG decomposition → GitHub issues → parallel TDD swarms → CI monitoring → PR review handling → merged PRs.

---

## Usage

```
/ship-it --prd <file-or-issue-url-or-number> [--dry-run] [--poll <minutes>] [--max-iter <n>]
```

- `--prd` — local Markdown file path, GitHub issue URL, or issue number
- `--dry-run` — render the ASCII DAG and stop; create nothing
- `--poll` — CI/review polling interval in minutes (default: 5)
- `--max-iter` — max TDD iterations per task agent (default: 10)

---

## Session state (JSON sidecar)

All orchestrator state lives in `./ship-it-<PRD_SLUG>.json`. The Markdown dashboard is derived from it. Re-read before each write to handle near-simultaneous agent completions.

Task status values (in order): `pending → in-progress → pr-open → ci-pass → done | failed | skipped`

```json
{
  "version": 1,
  "prdSlug": "invoice-mgmt-v2",
  "prdTitle": "...",
  "prdSource": "#42 or ./docs/prd.md",
  "milestoneNumber": 7,
  "baseBranch": "feat/my-feature",
  "repoRoot": "/abs/path",
  "pollMinutes": 5,
  "maxIter": 10,
  "startedAt": "ISO-8601",
  "coverageMap": { "REQ-1": [1, 3], "REQ-2": [] },
  "tasks": [{
    "id": 1,
    "title": "add-pdf-export",
    "displayTitle": "Add PDF Export",
    "type": "AFK",
    "wave": 0,
    "status": "pending",
    "issueNumber": 101,
    "blockedBy": [],
    "blockedByIssues": [],
    "worktreePath": null,
    "branch": null,
    "prUrl": null,
    "prNumber": null,
    "ciStatus": null,
    "reviewStatus": null,
    "mergedAt": null,
    "failureReason": null,
    "hitlResolution": null,
    "ciFixAttempts": 0,
    "reviewFixAttempts": 0,
    "notes": "",
    "uiInvolved": false,
    "uiMockupUrl": null
  }]
}
```

---

## Phase 0 — Parse arguments and ingest PRD

Extract `--prd`, `--dry-run`, `--poll` (default 5), `--max-iter` (default 10).

Capture the current branch as the base branch for all PRs:
```bash
BASE_BRANCH=$(git branch --show-current)
```
Store as `BASE_BRANCH` in JSON sidecar (`baseBranch` field).

If `--prd` is a GitHub issue URL or number:
```bash
gh issue view <number-or-url> --json title,body,number
```

If `--prd` is a file path, read it.

Store `PRD_TITLE`, `PRD_BODY`, `PRD_SOURCE` (issue number or file path).

Extract `PRD_MOCKUP_URL`: if `PRD_BODY` contains a `## UI Mockup` section, parse the Gist URL from `[View HTML mockup on GitHub Gist](<url>)`. Store in JSON sidecar as `"prdMockupUrl"`. If absent, `prdMockupUrl = null`.

Generate `PRD_SLUG`: lowercase 4–5 word kebab from title. Example: "Invoice Management System v2" → `invoice-mgmt-v2`

**Resume check:** If `./ship-it-<PRD_SLUG>.json` exists and `--prd` is omitted, offer to resume (§resume).

---

## Phase 1 — DAG generation

**Apply prd-to-issues §3 (Draft vertical slices), §3.5 (gap-check), §3.6 (supplemental flows), and §4 (quiz the user)** against `PRD_BODY`. Use the same vertical-slice rules, `uiInvolved` heuristic, and gap-coverage logic — do not restate them here.

Ship-it adds the following per-task fields beyond what prd-to-issues produces:

```
id:                 integer (1-indexed)
title:              kebab slug (for branch/worktree names)
displayTitle:       short human title
prdSection:         verbatim PRD paragraph(s) this task maps to (used in PR body)
uiMockupUrl:        prdMockupUrl when uiInvolved == true AND prdMockupUrl != null, else null
```

After §4 user approval, compute **execution waves**:

- Wave 0: `blockedBy = []`
- Wave N: every blocker is in waves 0..N-1
- Same wave = `parallel` label; alone in wave = `serial` label.

Store `coverageMap` and `supplementalDag` (`null | "screen" | "process"` plus nodes/edges) in the JSON sidecar.

**If `--dry-run`:** render §dry-run-output and STOP.

---

## §dry-run-output

Render the DAG as ASCII inside a fenced plain code block (no ` ```mermaid `). Use box-drawing characters for wave containers and an explicit edge list below for dependencies. Keep it copy-pasteable into a terminal.

Template (fill in real tasks and edges):

```
PRD: <PRD_TITLE>
Source: <PRD_SOURCE>   Tasks: <N>   Waves: <M>

┌─ Wave 0 (parallel — start immediately) ──────────────────────┐
│  [#1] <title> [AFK]                                          │
│  [#2] <title> [HITL]                                         │
└──────────────────────────────────────────────────────────────┘
                       │
                       ▼
┌─ Wave 1 (parallel — after Wave 0) ───────────────────────────┐
│  [#3] <title> [AFK]                                          │
│  [#4] <title> [AFK]                                          │
└──────────────────────────────────────────────────────────────┘
                       │
                       ▼
┌─ Wave 2 (serial — after Wave 1) ─────────────────────────────┐
│  [#5] <title> [AFK]                                          │
└──────────────────────────────────────────────────────────────┘

Edges (blocker → blocked):
  #1 → #3
  #1 → #4
  #2 → #4
  #3 → #5
  #4 → #5

Legend: [AFK] runs unattended   [HITL] requires human gate
```

Rendering rules:
- One box per wave in wave order (top → bottom).
- Inside each box list every task as `[#<id>] <displayTitle> [AFK|HITL]`.
- Between boxes draw a single `│` then `▼` on its own line to show wave progression.
- After the last wave box, print a blank line then an `Edges (blocker → blocked):` section that lists every `blockedBy` edge, one per line, sorted by blocker id then blocked id.
- If a wave contains only one task, keep the same box — label it "(serial)" in the header instead of "(parallel)".
- Box width is cosmetic; 62 chars works well for most titles. Truncate long titles with `…` at 50 chars inside the box.

If `supplementalDag` is set (from §1b.6), render it after the edges section:

Screen-flow format:
```
UI Screen Flow:
  [Login] ──→ [Dashboard] ──→ [Settings]
                   │
                   ▼
              [Reports] ──→ [Export]
```

Process-flow format:
```
<Flow Name>:
  (Step A) ──→ (Step B) ──→ (Step C) ──→ (Done)
                   │
                   ▼
              (Alternate path)
```

Then print: `Dry run complete. N tasks across M waves. Invoke without --dry-run to execute.`

**Stop here.**

---

## Phase 2 — GitHub setup

### 2a. Ensure labels exist

```bash
gh label create "ship-it"          --color 7C3AED --description "Managed by ship-it" 2>/dev/null || true
gh label create "parallel"         --color 0EA5E9 --description "Runs in parallel"   2>/dev/null || true
gh label create "serial"           --color F97316 --description "Runs serially"       2>/dev/null || true
gh label create "HITL"             --color F59E0B --description "Requires human"      2>/dev/null || true
gh label create "status:pending"   --color 94A3B8 --description "Not yet started"    2>/dev/null || true
gh label create "status:in-progress" --color 3B82F6 --description "Agent working"   2>/dev/null || true
gh label create "status:done"      --color 22C55E --description "PR merged"          2>/dev/null || true
gh label create "status:failed"    --color EF4444 --description "Agent failed"        2>/dev/null || true
gh label create "NEEDS-HUMAN"      --color FF0000 --description "Manual intervention" 2>/dev/null || true
```

If `PRD_SOURCE` is a GitHub issue number (not a file path), also create the slice-tracing label:

```bash
gh label create "PRD-<PRD_SOURCE_NUMBER>" --color 0EA5E9 --description "Slice of PRD #<PRD_SOURCE_NUMBER>" 2>/dev/null || true
```

### 2b. Create GitHub milestone

```bash
gh api repos/:owner/:repo/milestones \
  --method POST \
  --field title="<PRD_TITLE>" \
  --field description="ship-it run. Source: <PRD_SOURCE>" \
  --field state="open" \
  --jq '.number'
```

Store as `MILESTONE_NUMBER`.

### 2c. Create GitHub issues in topological order (blockers first)

For each task (sorted: wave 0 first, then wave 1, etc.):

```bash
gh issue create \
  --title "<displayTitle>" \
  --label "ship-it,<parallel|serial>,status:pending<,HITL if type=HITL><,PRD-N if PRD_SOURCE is an issue number>" \
  --milestone "<MILESTONE_NUMBER>" \
  --body "$(cat <<'EOF'
## Parent PRD

#<PRD_SOURCE issue number, or "Local file: PRD_SLUG">

## What to build

<task description — thin vertical slice through all layers>

## Acceptance criteria

- [ ] <criterion>
- [ ] <criterion>

## Blocked by

<"- #<issue-number> (<title>)" for each blocker, or "None — can start immediately">

## User stories addressed

<userStories>

<!-- CONDITIONAL: include only when task.uiMockupUrl != null -->

## UI Mockup

[View HTML mockup on GitHub Gist](<uiMockupUrl>)

> Visual specification from the parent PRD. Implement to match this mockup.

<!-- END CONDITIONAL -->

<!-- CONDITIONAL: include only when task.uiInvolved == true -->

## API errors to cover

| Backend `error` string | i18n key | Friendly EN message | Friendly VI message |
|---|---|---|---|

(Populated from backend route scan during Phase 1, or empty if no API calls.)

<!-- END CONDITIONAL -->

## ship-it metadata

- Type: AFK | HITL
- Wave: <wave>
- Slug: <PRD_SLUG>
EOF
)"
```

Record the real GitHub issue number for each task. Update `blockedByIssues` in the task list with real issue numbers.

---

## Phase 3 — Initialize state and dashboard

### 3a. Write JSON sidecar

Write `./ship-it-<PRD_SLUG>.json` with all task data (see §session-state schema above).

### 3b. Write Markdown dashboard

Write `./ship-it-<PRD_SLUG>.md`:

```markdown
# Ship-It: <PRD_TITLE>

> Source: <PRD_SOURCE> | Milestone: #<MILESTONE_NUMBER> | Started: <timestamp> | Poll: <POLL>min

## Status

| # | Title | Type | Wave | Status | Worktree | PR | CI | Notes |
|---|-------|------|------|--------|----------|----|----|-------|
| 1 | <displayTitle> | AFK | 0 | pending | — | — | — | — |
```

Update this file by re-rendering from JSON at each polling cycle and after every status change.

---

## Phase 4 — HITL gate (runs before each wave)

For every HITL task that is about to become ready, use `AskUserQuestion` before spawning agents:

**Question:** "Task #<issueNumber> (<displayTitle>) is HITL and is now unblocked. How do you want to proceed?"

**Options:**
1. Proceed — run the agent now (I trust it to decide)
2. Provide guidance — I'll describe constraints for the agent
3. Skip — mark as skipped and continue

For option 2: collect guidance, append to the GitHub issue:
```bash
gh issue comment <issueNumber> --body "## HITL guidance from user

<guidance>"
```
Then treat the task as AFK for spawning purposes.

For option 3: update task `status = skipped`, update label, update dashboard. Do not spawn an agent.

---

## Phase 5 — Parallel execution

### 5a. Identify ready tasks

Ready = `status: pending` AND all tasks in `blockedBy` have `status: done`.

On first run this is Wave 0.

### 5b. Run HITL gate for any HITL tasks in ready set (§Phase 4)

### 5c. Create worktrees — SEQUENTIAL (one at a time, no parallelism here)

Identify repo root first:
```bash
REPO_ROOT=$(git rev-parse --show-toplevel)
```

For each ready AFK task:
```bash
SLUG="<PRD_SLUG>-<task-title-kebab>"
WORKTREE_PATH="$HOME/workspace/$SLUG"
git -C "$REPO_ROOT" worktree add "$WORKTREE_PATH" -b "$SLUG"
```

Store `worktreePath` and `branch` in JSON. Skip `git worktree add` if path already exists (resume case).

### 5d. Launch ALL ready AFK task agents in ONE message (true parallel)

**Critical:** Every `Agent` call for the current ready set must appear in a single response. Use multiple Agent tool calls with `run_in_background: true` and `subagent_type: general-purpose`.

Do NOT launch one, wait, then launch another.

Update each launched task: `status = in-progress`, update GitHub label, update JSON, update dashboard.

Use §task-agent-prompt for each agent, filling in the task-specific values.

---

## §task-agent-prompt

```
You are a ship-it task agent. Implement one GitHub issue using strict TDD, then open a PR.

═══════════════════════════════════════════════════════════════
TASK CONTEXT
═══════════════════════════════════════════════════════════════
WORKTREE DIR  : <worktreePath>
REPO ROOT     : <repoRoot>
BRANCH        : <branch>
BASE BRANCH   : <baseBranch>
ISSUE NUMBER  : #<issueNumber>
ISSUE TITLE   : <displayTitle>
MILESTONE     : <milestoneNumber>
MAX ITERATIONS: <maxIter>
═══════════════════════════════════════════════════════════════

── STEP 0: READ THE ISSUE ──────────────────────────────────────
  gh issue view <issueNumber> --json title,body

── STEP 1: EXPLORE ─────────────────────────────────────────────
Explore the codebase in <worktreePath>:
  - Existing tests (*.test.*, *.spec.*, __tests__/)
  - Test runner command (look in package.json, Makefile, Cargo.toml, etc.)
  - Existing modules this slice touches
  - Conventions: naming, file structure, import style
  - Any UBIQUITOUS_LANGUAGE.md
  - If any acceptance criterion involves schema changes (columns, tables, indexes,
    constraints, enum values): apply §migration-tdd instead of standard RED for those criteria.

Note the test runner command. Use it exactly in subsequent steps.

── §api-error-coverage (when issue body contains "## API errors to cover" AND uiInvolved == true) ──

  a) If the issue has a populated ## API errors to cover table: extract every row.
     Each row gives: error string, i18n key, EN message, VI message. Go to step (c).

  b) If the table is absent or empty: scan backend route files for each endpoint this task calls.
     Pattern: grep -rn "res\.status.*\.json.*error" <worktreePath>/backend/src/
     Collect every distinct { statusCode, errorString } pair for touched endpoints.
     Derive i18n key as camelCase from the error string, nested under the feature's existing
     i18n section. Use friendly messages from the PRD's ## Implementation Decisions, or
     compose sensible defaults.

  c) For each (errorString, i18nKey, enMessage, viMessage) tuple:
     - Add key + EN to frontend/src/i18n/en.json under the feature section.
     - Add key + VI to frontend/src/i18n/vi.json under the same section.
     - Both files MUST be in the SAME commit. Never update one without the other.

  d) In every catch handler for these API calls, apply Pattern C:
       const code = e.response?.data?.error;
       const status = e.response?.status;
       if (code === 'some_error') { message.error(t('featureSection.someError')); }
       else if (status === 403)   { message.error(t('common.forbidden')); }
       else                       { message.error(t('common.errorGeneric')); }
     Never use a single generic catch key. Never pass raw server strings to the UI.

═══════════════════════════════════════════════════════════════
TDD LOOP — REPEAT for each acceptance criterion (up to <maxIter> total iterations)
═══════════════════════════════════════════════════════════════

Maintain a counter starting at 1. Increment on each RED→GREEN cycle.
If counter exceeds <maxIter> and tests still fail:
  Output: TASK_FAILED: exhausted <maxIter> iterations — <last failure summary>
  STOP. Do not open a PR.

For EACH acceptance criterion from the issue:

── RED ──────────────────────────────────────────────────────────
Write ONE failing test describing the expected behavior.

  Rules:
  - Test must use public interfaces ONLY — never private methods
  - Test must describe BEHAVIOR, not implementation details
  - Test would survive an internal refactor while behavior is unchanged
  - Add this marker on the line IMMEDIATELY ABOVE the test() / it() / #[test] call:
      // ship-it:#<issueNumber>

  Run the test to confirm it FAILS:
    cd <worktreePath> && <test-runner> <test-file>

  ▶ If the test PASSES before your fix: you wrote the wrong test. Rewrite until it fails.
  ▶ If you CANNOT write a meaningful failing test for this criterion:
      Output: TASK_FAILED: TDD_SKIPPED — <one-sentence reason>
      STOP immediately. Do not attempt a partial fix. Do not open a PR.

── GREEN ─────────────────────────────────────────────────────────
Write MINIMAL code to make the failing test pass.

  Run targeted test:
    cd <worktreePath> && <test-runner> <test-file>
  Confirm new test passes.

  Run full suite to check for regressions:
    cd <worktreePath> && <test-runner>

  ▶ If full suite fails due to your change: revert your code, try a different approach.
  ▶ If you cannot make it pass without regressions after 3 attempts:
      Output: TASK_FAILED: regression introduced by <criterion> — <file:line>
      STOP. Do not open a PR.

── Continue until all acceptance criteria have passing tests ──────

── REFACTOR (after ALL criteria green) ───────────────────────────
One focused refactor pass: remove obvious duplication introduced in the green phase.
Apply SOLID where trivially obvious. Do NOT speculate about future requirements.
Re-run full suite. Must still pass.
If suite fails after refactor: revert the refactor changes.

── §api-error-coverage TDD PASS (only when §api-error-coverage ran above) ──────

After all standard acceptance criteria are green, run one additional RED→GREEN cycle per
error string from §api-error-coverage:

  RED: Mock the API to return { status: N, data: { error: 'errorString' } }.
       Assert the component displays the text resolved by t('i18nKey').
       Mark with // ship-it:#<issueNumber> immediately above the test() call.
       Confirm it FAILS before the catch handler is wired.
       ▶ If it already passes: mapping was accidentally covered — log it and skip.

  GREEN: Ensure the Pattern C handler maps this errorString to the i18nKey.
         Run targeted test (confirm pass), then full suite (confirm no regressions).

Each error-string RED→GREEN cycle counts against the <maxIter> iteration budget.

═══════════════════════════════════════════════════════════════
COMMIT
═══════════════════════════════════════════════════════════════
Stage ONLY the files you changed. NEVER use git add . or git add -A:

  cd <worktreePath>
  git add <file1> <file2> ...
  git commit -m "feat(<scope>): <displayTitle>

  Closes #<issueNumber>

  Co-Authored-By: Claude Sonnet 4.6 <noreply@anthropic.com>"

═══════════════════════════════════════════════════════════════
PUSH AND OPEN PR
═══════════════════════════════════════════════════════════════
  cd <worktreePath>
  git push -u origin <branch>

  gh pr create \
    --title "feat: <displayTitle>" \
    --base <baseBranch> \
    --head <branch> \
    --milestone <milestoneNumber> \
    --body "$(cat <<'PRBODY'
## Parent PRD

> <prdSection — verbatim quote of the PRD paragraph this task maps to>

Closes #<issueNumber>

## What was built

<one paragraph describing what was implemented>

## TDD evidence

All acceptance criteria have tests marked `// ship-it:#<issueNumber>`.
Run: `<test-runner>`

## Checklist

- [x] RED test written before implementation
- [x] GREEN — all tests pass
- [x] REFACTOR — no speculative changes
- [x] Full test suite passes with no regressions
- [x] Linked to milestone #<milestoneNumber>

🤖 Generated with [Claude Code](https://claude.com/claude-code)
PRBODY
)"

═══════════════════════════════════════════════════════════════
FINAL REPORT — your LAST output must be EXACTLY one of these
═══════════════════════════════════════════════════════════════
  TASK_COMPLETE: <full-pr-url>
  TASK_FAILED: <one-sentence reason>
  TASK_FAILED: TDD_SKIPPED — <one-sentence reason>

═══════════════════════════════════════════════════════════════
RULES
═══════════════════════════════════════════════════════════════
- All work happens in <worktreePath>. NEVER touch the main repo working tree.
- RED must fail before GREEN. No exceptions.
- TDD_SKIPPED is a hard failure. Never attempt a partial fix.
- NEVER use git add . or git add -A
- Do not push before all tests are green.
- The // ship-it:#N marker is MANDATORY above every new test.
- Do not open a PR if TASK_FAILED.
- No speculative code, no future-proofing, no abstractions beyond the current criterion.
```

---

## Phase 6 — Process completions and poll CI/reviews

You will be notified when each background agent completes. Process them as they arrive.

### 6a. Parse agent result

Read the last line of the agent's output:

- `TASK_COMPLETE: <pr-url>` → validate marker (§6b), then `status = pr-open`, store `prUrl`
- `TASK_FAILED: TDD_SKIPPED — <reason>` → `status = failed`, `failureReason = reason`. **No retry.** If `worktreePath` is set, remove it:
  ```bash
  git -C "$REPO_ROOT" worktree remove <worktreePath> --force 2>/dev/null || true
  git -C "$REPO_ROOT" worktree prune
  ```
  Set `worktreePath = null` in JSON.
- `TASK_FAILED: <reason>` → `status = failed`, `failureReason = reason`. If `worktreePath` is set, remove it (same commands as above). Set `worktreePath = null` in JSON. Log for final summary.

**After every parse, in this exact order — no skipping:**
1. Re-read JSON sidecar from disk
2. Apply status change to in-memory state
3. Write updated JSON sidecar to disk
4. Update GitHub issue label
5. Re-render and write Markdown dashboard from the updated JSON — **this step is mandatory, never skip it**

### 6b. Validate TDD marker (before accepting TASK_COMPLETE)

```bash
git -C <worktreePath> show HEAD | grep "ship-it:#<issueNumber>"
```

If marker is missing and agent reported `TASK_COMPLETE` → treat as `TASK_FAILED: TDD_SKIPPED — no ship-it marker in commit`.

### 6c. CI polling loop (every POLL minutes, for each `pr-open` task)

```bash
gh pr checks <prUrl> --json name,state,conclusion
```

- All `conclusion = success` → `status = ci-pass`; proceed to §6e (merge + unlock)
- Any `conclusion = failure` → extract logs (§ci-fix), spawn fix agent
- Still pending → wait for next poll

### 6d. PR review polling (every POLL minutes, for each `pr-open` or `ci-pass` task)

```bash
gh pr view <prUrl> --json reviews,comments,reviewDecision
```

- `reviewDecision = APPROVED` and `ciStatus = pass` → merge (§6e)
- `reviewDecision = CHANGES_REQUESTED` or unresolved comments → spawn review-fix agent (§review-fix)
- `reviewDecision = REVIEW_REQUIRED` with no feedback → keep polling

Update dashboard after each poll cycle even if nothing changed (to show current timestamp).

### 6e. Merge + unlock (CI pass, review approved or not required)

```bash
gh pr merge <prUrl> --squash --auto --delete-branch
```

After merge:
1. `status = done`, record `mergedAt` in JSON
2. Update GitHub issue label: `status:done`
3. Explicitly close the slice issue (GitHub only auto-closes on default branch merges):
   ```bash
   gh issue close <issueNumber> --comment "Shipped via <prUrl> → merged into <baseBranch>."
   ```
4. Remove worktree:
   ```bash
   git -C "$REPO_ROOT" worktree remove <worktreePath> --force
   git -C "$REPO_ROOT" worktree prune
   ```
5. Update JSON and dashboard
6. Check for newly unblocked tasks: tasks where `status = pending` AND all `blockedBy` tasks are `done`
7. If newly unblocked tasks exist → run HITL gate if needed → create worktrees → **launch all in ONE message** (§Phase 5)

---

## §ci-fix — CI failure agent

When CI fails on a PR, extract logs:

```bash
RUN_ID=$(gh run list --branch <branch> --json databaseId,conclusion --jq 'map(select(.conclusion=="failure"))[0].databaseId')
gh run view "$RUN_ID" --log-failed
```

Increment `ciFixAttempts` in JSON. If `ciFixAttempts > 3`: mark task `failed`, `failureReason = "CI fix exhausted after 3 attempts"`. Remove worktree:
```bash
git -C "$REPO_ROOT" worktree remove <worktreePath> --force 2>/dev/null || true
git -C "$REPO_ROOT" worktree prune
```
Set `worktreePath = null` in JSON. Skip spawning another fix agent.

Otherwise, spawn a `general-purpose` Agent with `run_in_background: true`:

```
You are a CI fix agent. Fix failing tests/build in this worktree.

WORKTREE : <worktreePath>
BRANCH   : <branch>
PR       : <prUrl>

CI FAILURE LOGS:
<paste full gh run view --log-failed output>

STEPS:
1. Read the failure logs carefully — identify root cause
2. Fix the failing code (minimal change only)
3. Run the full test suite locally to confirm green:
   cd <worktreePath> && <test-runner>
4. Stage specific files and commit:
   cd <worktreePath>
   git add <files>
   git commit -m "fix: resolve CI failure

   Co-Authored-By: Claude Sonnet 4.6 <noreply@anthropic.com>"
5. Push:
   cd <worktreePath> && git push

FINAL REPORT (last line, exactly):
  CI_FIXED: <commit-hash>
  CI_FAILED: <one-sentence reason>
```

After completion:
- `CI_FIXED` → update `notes` in JSON with fix summary, resume CI polling
- `CI_FAILED` → `status = failed`, `failureReason = reason`

---

## §review-fix — PR review comment agent

When PR has unresolved change requests:

```bash
gh pr view <prUrl> --json reviews,comments \
  --jq '[.reviews[] | select(.state == "CHANGES_REQUESTED")] + .comments'
```

Increment `reviewFixAttempts`. If `reviewFixAttempts > 3`: surface to user via `AskUserQuestion`.

Spawn a `general-purpose` Agent with `run_in_background: true`:

```
You are a review-fix agent. Address PR review comments.

WORKTREE : <worktreePath>
BRANCH   : <branch>
PR       : <prUrl>

REVIEW COMMENTS (JSON):
<paste gh pr view --json reviews,comments output>

STEPS:
1. Read each review comment carefully
2. For each actionable comment: make the minimal change requested
3. Run full test suite to confirm still green:
   cd <worktreePath> && <test-runner>
4. Stage specific files and commit:
   cd <worktreePath>
   git add <files>
   git commit -m "review: address PR feedback

   Co-Authored-By: Claude Sonnet 4.6 <noreply@anthropic.com>"
5. Push: cd <worktreePath> && git push

If a comment requires a design decision you cannot make alone:
  Output: REVIEW_BLOCKED: <description of decision needed>
  STOP.

FINAL REPORT (last line, exactly):
  REVIEW_ADDRESSED: <commit-hash>
  REVIEW_BLOCKED: <decision description>
  REVIEW_FAILED: <reason>
```

After completion:
- `REVIEW_ADDRESSED` → update notes, resume review polling
- `REVIEW_BLOCKED` → use `AskUserQuestion` to surface to user, await guidance, re-spawn
- `REVIEW_FAILED` → log warning, keep polling (retry next cycle)

---

## §migration-tdd — TDD for DB schema changes

When a task's acceptance criteria involve a schema change (new column, table, index, constraint, enum value), apply this pattern instead of writing a unit test against non-existent code.

**Detect:** Task mentions migration, schema, column, index, constraint, or acceptance criteria reference DB-level behavior.

**RED:**
Write an integration test that exercises the new schema feature through the public ORM/service layer:
- New column → test saving + reading an entity that uses the field
- New constraint → test that a violation raises the expected error
- New index → test via `information_schema` or `pg_indexes` if no behavior difference
- New table / relation → test creating and querying a record via the new relation

Run the test against the current DB (migration not yet applied). It MUST fail.
Mark with `// ship-it:#<issueNumber>` on the line immediately above.

▶ If the test passes before migration: wrong test — rewrite until it fails.
▶ If no meaningful behavioral test is possible (e.g., pure performance index with no correctness impact): write a schema-inspection test querying `information_schema.columns` / `pg_indexes`. This still counts as RED — it fails because the column/index doesn't exist yet.

**GREEN:**
1. Generate or write the migration file.
2. Run the migration using the project's standard command (check `package.json` scripts, `Makefile`, or repo README — e.g. `npm run migrate`, `bundle exec rails db:migrate`, `alembic upgrade head`, `npx typeorm migration:run`).
3. Re-run the test — it must pass.
4. Run full test suite to check for regressions.

**REFACTOR:** Same rules as standard TDD. Re-run full suite after.

**Commit both** the migration file AND the entity/model change in the same commit.

---

## §resume — Resume from existing JSON

When `./ship-it-<PRD_SLUG>.json` exists:

```
Found existing ship-it session: <prdTitle>
  Done:        N
  In-progress: N
  Pending:     N
  Failed:      N

Resume this session?
```

Use `AskUserQuestion` with options: Resume / Start fresh.

On resume:
- Load JSON state
- **Prune stale worktrees:** For any task with `status` in (`done`, `failed`, `skipped`) that has a non-null `worktreePath`:
  ```bash
  git -C "$REPO_ROOT" worktree remove <worktreePath> --force 2>/dev/null || true
  ```
  After iterating all such tasks, run once:
  ```bash
  git -C "$REPO_ROOT" worktree prune
  ```
  Set `worktreePath = null` in JSON for each cleaned task. Write updated JSON.
- For `in-progress` tasks: check if worktree exists and PR was opened. If neither exists and the previous run started >30 min ago, mark `failed` with `failureReason = "agent did not produce a PR before resume — likely crashed or timed out"`.
- For `pr-open` tasks: detect manually-merged PRs (`gh pr view --json state` returns `MERGED`) → treat as `done`. Detect deleted branches (`git ls-remote origin <branch>` empty AND PR closed unmerged) → treat as `failed` with reason "branch deleted externally".
- For `pr-open` / `ci-pass` tasks: re-poll CI and reviews immediately (§Phase 6)
- For `pending` tasks now unblocked: launch agents (§Phase 5)
- Continue from Phase 6

---

## Phase 7 — Final summary

When all tasks are in a terminal state (`done`, `failed`, `skipped`):

Print the session banner:

```
══════════════════════════════════════════════════════════════
  SHIP-IT COMPLETE — <PRD_TITLE>
══════════════════════════════════════════════════════════════
  Total tasks:  N
  Done:         N  (PRs merged)
  Failed:       N  (TDD skip or CI unresolvable)
  Skipped:      N  (user skipped HITL)
══════════════════════════════════════════════════════════════
```

Print the full dashboard table.

Clean up any remaining worktrees for `failed` or `skipped` tasks (belt-and-suspenders — §6a and §ci-fix should have already cleaned these, but handle crash/resume gaps):
```bash
# For each task with status failed/skipped and non-null worktreePath:
git -C "$REPO_ROOT" worktree remove <worktreePath> --force 2>/dev/null || true
```
After iterating, run once: `git -C "$REPO_ROOT" worktree prune`. Set `worktreePath = null` for each. Write JSON.

For each `failed` task, file a GitHub issue:

```bash
gh issue create \
  --title "[ship-it FAILED] <displayTitle>" \
  --label "ship-it,NEEDS-HUMAN" \
  --body "## Failure reason

<failureReason>

## Original issue

#<issueNumber>

## Worktree (may still exist)

<worktreePath>

## Notes

<notes>"
```

Close the milestone ONLY if all tasks are `done` or `skipped` — never if any are `failed`:

```bash
gh api repos/:owner/:repo/milestones/<MILESTONE_NUMBER> \
  --method PATCH \
  --field state="closed"
```


---

## Orchestrator rules

- **Create worktrees BEFORE spawning agents** — never simultaneously with Agent calls
- **Launch ALL ready agents in ONE response** — multiple Agent tool calls, same message, `run_in_background: true`
- **Validate `// ship-it:#N` marker** before accepting any `TASK_COMPLETE`
- **`TDD_SKIPPED` = hard failure** — no retry, no partial accept
- **Never push commits from the orchestrator** — only from within task/fix/review agents
- **JSON sidecar = ground truth** — re-read before each write; dashboard is derived
- **Dashboard MUST be written after EVERY status change** — never batch, never skip; one transition = one file write
- **Update GitHub issue labels** on every status transition
- **Do not close the milestone** if any task is `failed`
- **Poll interval is a minimum** — process completions immediately as notifications arrive

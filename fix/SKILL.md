---
name: fix
description: Single-shot bug fixer. Fixes one bug inline on the current branch using strict TDD — no queue, no separate branch, no subagent. Writes a per-attempt checklist (`.checklist/fix-<slug>-#<try>.md`), runs /verify against it in the foreground, allows one re-fix on verify failure, prompts the user to confirm, then optionally (AskUserQuestion) creates a GitHub issue, posts the fix commit and links as comments, adds `fix-issue:` next to the `fix:<slug>-#N` marker, commits, and closes the issue. Use when the user wants a single bug fixed end-to-end on the current branch in the current session, mentions "fix this", or invokes /fix.
model: opus
argument-hint: "(--no-verify) (--no-issue) (<bug description>)"
---

# /fix — Single-Shot Bug Fixer

Fix exactly one bug end-to-end in the current session, on the current branch, in the main conversation (no subagent). One TDD cycle, one foreground `/verify --checklist <path>` against the per-attempt checklist this skill writes, optional one re-fix on verify failure, one confirmation prompt, then an optional GitHub issue + marker link when the session ends (see Step 7).

## Arguments

- `--no-verify` — skip the automatic `/verify --checklist <path>` step after the fix. Jump straight to the confirm prompt.
- `--no-issue` — skip Step 7 entirely (no `AskUserQuestion`, no `gh` calls).
- `<bug description>` — free-form description; everything after the flags is treated as the bug. Optional; if omitted, ask once.

Parse at start. Store as:

- `AUTO_VERIFY` — boolean; default `true`. Set `false` when `--no-verify` is present.
- `AUTO_ISSUE` — boolean; default `true`. Set `false` when `--no-issue` is present.
- `BUG_DESC` — string; may be empty.

## Step 1 — Prechecks

Hard-fail with a clear single-line message if any check fails. Make no commits.

```bash
# 1. Inside a git repo with at least one commit
git rev-parse --show-toplevel >/dev/null 2>&1 || abort "Not a git repo."
git rev-parse HEAD             >/dev/null 2>&1 || abort "Repo has no commits."

# 2. On a named branch (not detached HEAD)
CURRENT_BRANCH=$(git rev-parse --abbrev-ref HEAD)
[ "$CURRENT_BRANCH" != "HEAD" ] || abort "Detached HEAD — checkout a branch first."

# 3. Clean working tree — fix commits land on the current branch directly,
#    so any pre-existing WIP would interleave with the fix.
[ -z "$(git status --porcelain)" ] || abort "Uncommitted changes in $CURRENT_BRANCH — commit or stash before /fix."

REPO_ROOT=$(git rev-parse --show-toplevel)
```

Store `CURRENT_BRANCH` and `REPO_ROOT` in context. The fix commit will land on `CURRENT_BRANCH`; no checkout, no new branch.

### Protected-branch warning

If `CURRENT_BRANCH` is `main` or `master`, do not auto-abort — many small repos commit to main. Ask once via `AskUserQuestion`:

```
question: "You are on `<CURRENT_BRANCH>`. Fix commits will land here directly. Continue?"
header:   "Confirm branch"
options:
  - label: "Continue"  description: "Commit the fix on `<CURRENT_BRANCH>`"
  - label: "Cancel"    description: "Abort — checkout a feature branch first"
```

`Cancel` / `Other` → abort with `Cancelled — checkout a feature branch first, then re-run /fix.`

### Detect test runner

Probe in this order; stop at the first match:

1. `package.json` script `test:run` → `TEST_CMD="pnpm test:run"`
2. `package.json` script `test`    → `TEST_CMD="pnpm test"`
3. `pyproject.toml` or `pytest.ini` → `TEST_CMD="pytest"`
4. `Cargo.toml`                    → `TEST_CMD="cargo test"`
5. Else → ask once: *"What command runs your tests?"*. Empty answer → abort.

Store `TEST_CMD`.

### Detect comment prefix

The TDD marker is composed later as `<COMMENT_PREFIX> fix:<slug>-#<try>` (the slug comes from the title in Step 2, the try comes from the attempt index in Step 3 / Step 4b — neither is known yet). Step 1 only resolves the language-appropriate comment prefix:

- JS / TS / Java / Rust / Go / C-family → `COMMENT_PREFIX="//"`
- Python / Ruby / Shell                  → `COMMENT_PREFIX="#"`
- Other → ask user for the line-comment token in this language.

Store as `COMMENT_PREFIX`. The full marker string is built inline at write time; do not store a fixed marker constant.

## Step 2 — Collect bug description

If `BUG_DESC` is empty (no inline argument provided):

> What's the bug?

Wait for one user reply. Empty / whitespace-only second answer → abort: `No bug description provided — re-run /fix with the bug description.`

### Derive expected vs actual

Always derive and store two short fields before writing any code:

- `expectedBehaviour` — one or two sentences: what the user wants to happen.
- `actualBehaviour` — one or two sentences: what the user observes today.

If `BUG_DESC` already separates them, copy verbatim. Otherwise infer and confirm with one short echo:

> Got it — expected: `<expectedBehaviour>`; actual: `<actualBehaviour>`. Right?

If the user corrects, update the fields. Skip the echo only when both are unambiguous from `BUG_DESC`.

### Generate title

Derive a kebab `title` from the bug description: 3–6 words, lowercase, hyphen-separated, naming the symptom or component. Used in the commit subject and the final summary line. Examples: `off-by-one-in-date-split`, `login-button-no-spinner`, `cart-total-ignores-tax`.

## Step 3 — TDD fix (inline, in this conversation)

Read and follow the TDD skill at `~/.claude/skills/tdd/SKILL.md`. Apply RED-GREEN-REFACTOR for this bug. The work happens directly in the main conversation — no `Agent`, no `run_in_background`.

Test runner: `<TEST_CMD>` (or `<TEST_CMD> <test file>` for a single test).

Set `ATTEMPT=1` (initial fix; the re-fix path in Step 4b bumps it to `2`). Compose the TDD marker for this attempt as:

```
MARKER="${COMMENT_PREFIX} fix:${title}-#${ATTEMPT}"
```

Additions on top of the TDD skill:

- **Marker.** Add `${MARKER}` as a comment on the line IMMEDIATELY ABOVE the new test definition (the `test()` / `it()` / `describe(...)` block in JS, `def test_xxx()` in Python, `#[test]` in Rust, `func TestXxx()` in Go, etc.). Required. Without it the fix is rejected as TDD_SKIPPED.
- **No fallback if you cannot write a failing test.** Print exactly one line and stop:
  ```
  TDD_SKIPPED: <one-sentence reason>
  ```
  No partial fix without a red test first. Make no commit. Final status: `FAILED`. Skip Step 4 and Step 5 entirely; jump to Step 6 (summary).
- **Regression in full suite.** If the full suite fails because of your change after refactor, revert your edits and print:
  ```
  FAILED: regression in full test suite — <file:line>
  ```
  Make no commit. Final status: `FAILED`. Jump to Step 6.

### Commit

Stage only the files you changed (NEVER `git add .` or `git add -A`):

```bash
cd $REPO_ROOT
git add <file1> <file2> ...
git commit -m "fix(<scope>): <descriptive subject naming the bug and the fix>

- <one bullet: what was wrong>
- <one bullet: what the fix does>
- <one bullet: test added>

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>"
```

Commit rules:

- Subject line: `fix(<scope>): <what-was-broken>` — not a generic "fix bug".
- Body: 2–3 bullets max.
- The test file containing `${MARKER}` must be one of the staged files.

Store the resulting commit hash as `COMMIT_HASH` (full 40 chars).

### TDD enforcement check

Before continuing, confirm the marker landed in the commit's diff:

```bash
git -C "$REPO_ROOT" show --pretty=format: --name-only "$COMMIT_HASH" \
  | xargs -I{} git -C "$REPO_ROOT" show "$COMMIT_HASH" -- {} 2>/dev/null \
  | grep -E "fix:${title}-#${ATTEMPT}\b"
```

If missing → treat as `TDD_SKIPPED: no fix:${title}-#${ATTEMPT} marker in test diff`. Reset the commit (`git reset --hard HEAD~1` is safe here because the precheck guaranteed a clean tree at start), final status `FAILED`, jump to Step 6.

## Step 4 — Write checklist + run /verify

### Compute uiFlag

```bash
UI_HIT=$(git -C "$REPO_ROOT" diff --name-only "$COMMIT_HASH^...$COMMIT_HASH" \
  | grep -E '\.(tsx|jsx|vue|svelte|html|css|scss|sass|less|astro)$|(^|/)(component|page|view|screen|layout|widget)s?(/|\.|-|_)' \
  | head -1)
[ -n "$UI_HIT" ] && UI_FLAG=true || UI_FLAG=false
```

### Write `.checklist/fix-<slug>-#<try>.md`

```bash
CHECKLIST_DIR="$REPO_ROOT/.checklist"
mkdir -p "$CHECKLIST_DIR"
CHECKLIST_PATH="$CHECKLIST_DIR/fix-${title}-#${ATTEMPT}.md"
```

Write `$CHECKLIST_PATH` (overwrite if a file at the same `<slug>-#<try>` already exists from a stale run), substituting stored fields:

```markdown
---
fix-id: <title>-#<ATTEMPT>
type: <ui if UI_FLAG=true, else api>
---

## Expected behaviour

<expectedBehaviour>

## Actual behaviour (before fix)

<actualBehaviour>

## Fix summary

<one-sentence summary of the change just committed>
```

Ensure `.checklist/` is gitignored:

```bash
if ROOT="$(git -C "$REPO_ROOT" rev-parse --show-toplevel 2>/dev/null)"; then
  grep -qxF '.checklist/' "$ROOT/.gitignore" 2>/dev/null || echo '.checklist/' >> "$ROOT/.gitignore"
fi
```

Print: `Checklist written: .checklist/fix-${title}-#${ATTEMPT}.md`

### Skip verify if --no-verify

If `AUTO_VERIFY == false`: set `VERIFY_STATUS=not-run`, skip the rest of Step 4, jump to Step 5 (confirm prompt).

### Run /verify --checklist <path> (foreground subagent)

The harness rejects nested skill invocations from inside a skill. Spawn a foreground `general-purpose` Agent that runs `/verify --checklist .checklist/fix-${title}-#${ATTEMPT}.md` non-interactively. Block on completion. Store stdout as `VERIFY_REPORT`.

Use this prompt for the subagent (substitute `${title}` and `${ATTEMPT}` into the `--checklist` path):

```
You are running the /verify skill non-interactively for /fix.

Read the skill at /Users/annguyenvanchuc/workspace/skills/verify/SKILL.md
and execute it with arguments:  --checklist .checklist/fix-<title>-#<ATTEMPT>.md

Repo root: <REPO_ROOT>
Branch (already checked out): <CURRENT_BRANCH>

Constraints:
- Do not modify code, do not switch branches, do not commit anything.
- Do not call /fix or any other skill.
- Print only the final Verification Report (Step 6 of /verify). The
  /fix orchestrator parses it.
- If /verify cannot start the app or the subagent errors, your last
  line must be exactly:  VERIFY_ERROR: <one-sentence reason>
```

Print to the user before spawning: `Verifying #${ATTEMPT} — running /verify --checklist .checklist/fix-${title}-#${ATTEMPT}.md… (this blocks until done)`

### Classify the verify result

```
if "VERIFY_ERROR" in VERIFY_REPORT or no "## Summary" block:
    classification = error
else:
    parse PASS, FAIL, TIMEOUT, ASSUMED, UNVERIFIABLE counts from Summary
    fails = FAIL + TIMEOUT
    unv   = UNVERIFIABLE
    if "Browser pass skipped" in VERIFY_REPORT:
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

Set `VERIFY_STATUS = pass | fail | tooling | error`. If `Total == 0`, classify as `pass` and append `(checklist had 0 items)` to the next prompt.

### Branch on classification

**pass** → fall through to Step 5 (confirm prompt).

**tooling** → print the install hint from `VERIFY_REPORT` (lines between `Browser pass skipped:` and the next blank line), then call `AskUserQuestion`:

```
question: "#${ATTEMPT} `<title>` — verify could not run UI checks (UNVERIFIABLE:<n>); browser tooling missing. Next step?"
header:   "Verify #${ATTEMPT}"
options:
  - label: "Continue"  description: "Treat tooling gap as not-our-problem; go to confirm prompt"
  - label: "Cancel"    description: "Abort without confirming — commit stays on branch for manual inspection"
```

`Continue` → fall through to Step 5. `Cancel` / `Other` → final status `FAILED`, jump to Step 6.

**error** → call `AskUserQuestion`:

```
question: "#${ATTEMPT} `<title>` — /verify errored (autostart or subagent failure). Next step?"
header:   "Verify #${ATTEMPT}"
options:
  - label: "Continue"  description: "Skip verify and go to confirm prompt"
  - label: "Cancel"    description: "Abort without confirming — commit stays on branch for manual inspection"
```

`Continue` → fall through to Step 5. `Cancel` / `Other` → final status `FAILED`, jump to Step 6.

**fail** → if no re-fix has been attempted yet, call `AskUserQuestion`:

```
question: "#${ATTEMPT} `<title>` — verify failed (FAIL:<n> TIMEOUT:<n> UNVERIFIABLE:<n>). Next step?"
header:   "Verify #${ATTEMPT}"
options:
  - label: "Re-fix"        description: "Run one more TDD cycle on this branch using verify failures (Recommended)"
  - label: "Continue"      description: "Skip remaining failures and go to confirm prompt"
  - label: "Cancel"        description: "Abort without confirming — commit stays on branch for manual inspection"
```

- `Continue` → fall through to Step 5.
- `Cancel` / `Other-without-feedback` → final status `FAILED`, jump to Step 6.
- `Re-fix` / `Other` (typed feedback) → run **Step 4b — Re-fix** (allowed exactly once).

If a re-fix has **already** been attempted, skip the prompt and fall through to Step 5 directly with `VERIFY_STATUS=fail` — the resolved plan permits exactly one inline re-fix.

## Step 4b — Re-fix (allowed once)

Triggered only by `Re-fix` (or typed feedback) on the post-verify-fail prompt, and only on the first verify failure of this `/fix` invocation.

1. Set the re-fix-attempted flag and bump `ATTEMPT=2`. Recompose the marker for this attempt: `MARKER="${COMMENT_PREFIX} fix:${title}-#2"`.
2. Build the re-fix feedback string:
  ```
   Verify reported failures (from /verify --checklist .checklist/fix-${title}-#1.md):
   <the "Items Requiring Attention" block from VERIFY_REPORT verbatim;
    if absent, substitute the failing rows from the verify result table>

   User notes: <typed feedback if any, else omit this line>
  ```
3. Run another TDD cycle inline (same Step 3 protocol) on the same branch, with one extra constraint:
  - The user feedback describes a **new** failing scenario the previous fix did not cover.
  - Write a **new** failing test for that scenario (must genuinely RED against current code) with its own `${MARKER}` (i.e. `fix:${title}-#2`) on the line above. New test, new marker value. The original `#1` test and its marker stay in place — Step 4b adds a second test, it does not replace the first.
  - Then GREEN, then REFACTOR. Commit normally — this becomes a second commit on `CURRENT_BRANCH`.
  - If feedback is too vague to derive a concrete failing test, ask once for a concrete reproduction. If still impossible → `TDD_SKIPPED`, final status `FAILED`, jump to Step 6.
4. After the second commit, write a NEW checklist file at `.checklist/fix-${title}-#2.md` (do NOT overwrite `#1.md` — it stays as the audit trail of the first attempt). Re-run `/verify --checklist .checklist/fix-${title}-#2.md` (Step 4 verify subagent invocation again), classify the result, and **fall through to Step 5 unconditionally** — no second re-fix prompt regardless of the new classification. Record the second classification as `VERIFY_STATUS`.
  The TDD enforcement check on the new commit greps for `fix:${title}-#2\b`; the `#1` marker still exists in the diff, but Step 4b only cares that `#2` is present.

## Step 5 — Confirm

Call `AskUserQuestion`:

```
question: "#${ATTEMPT} `<title>` — fix committed on `<CURRENT_BRANCH>` (verify: <VERIFY_STATUS>). Test it manually, then confirm. Fixed?"
header:   "Confirm #${ATTEMPT}"
options:
  - label: "Confirmed fixed"  description: "Mark APPROVED and exit"
  - label: "Still broken"     description: "Mark FAILED and exit — commit stays on branch for inspection"
```

- `Confirmed fixed` → final status `APPROVED`, jump to Step 6.
- `Still broken` / `Other` → final status `FAILED`, jump to Step 6. Treat any typed feedback as a note in the summary line, but do **not** spawn another re-fix from this prompt — the user re-invokes `/fix` with a refined description for that.

## Step 6 — Summary line

Always print exactly one line:

```
#${ATTEMPT} <title> — <APPROVED|FAILED> (verify: <VERIFY_STATUS>) — commit <short-hash> on <CURRENT_BRANCH> — checklist .checklist/fix-${title}-#${ATTEMPT}.md
```

Where:

- `${ATTEMPT}` is the latest attempt the orchestrator ran (1 if Step 4b never fired, 2 if it did).
- `<short-hash>` is the first 8 chars of `COMMIT_HASH` (the most recent commit produced — Step 4b's commit if a re-fix happened, else Step 3's). `none` if no commit was produced.
- `<VERIFY_STATUS>` is `pass | fail | tooling | error | not-run | skipped` (use `skipped` when `--no-verify` was passed).
- If `TDD_SKIPPED` or pre-commit `FAILED` produced no commit, write `commit none on <CURRENT_BRANCH>` and add  `— reason: <one-line reason>` to the end. If no checklist file was written either (Step 4 never reached), drop the trailing  `— checklist …` clause.

Then continue to Step 7 when applicable (do not treat Step 6 as full exit until Step 7 completes or is skipped).

## Step 7 — Optional GitHub issue (session end)

Run only when **all** are true:

- `AUTO_ISSUE == true` (`--no-issue` not passed)
- `FINAL_STATUS == APPROVED` (user chose "Confirmed fixed" in Step 5)
- A fix commit exists (`COMMIT_HASH` set — not the `commit none` path)

Otherwise skip Step 7 entirely and stop after Step 6.

### 7a — Ask

Call `AskUserQuestion` (same mechanism as the protected-branch and verify prompts):

```
question: "Create a GitHub issue for this fix, post the commit there, add the issue link next to the fix marker in code, then close the issue?"
header:   "Track fix on GitHub"
options:
  - label: "Yes, create issue"  description: "Create issue, comment commit + links, link in source, close issue"
  - label: "No, skip"            description: "End session — no GitHub"
```

`No, skip` / `Other` → stop. No `gh` calls.

### 7b — Preflight GitHub CLI

Mirror `write-a-prd` style checks before any mutation:

Probe `gh`: binary exists and `gh auth status` succeeds. If either fails, print one line (`Skip GitHub: …`), stop Step 7.

Resolve default repo for `gh issue create` from `REPO_ROOT` (`cd "$REPO_ROOT"` first). If `gh repo view` fails (no remote / not a GitHub repo), print one line and stop Step 7.

Store `PRIMARY_COMMIT` = `COMMIT_HASH` (latest fix commit). If Step 4b ran, optionally note the first fix commit in the issue body as `Prior attempt: <short-hash of HEAD~1>` when `ATTEMPT == 2`.

### 7c — Create issue

```bash
cd "$REPO_ROOT"
ISSUE_URL=$(gh issue create \
  --title "fix: <title>" \
  --body "## Context

**Expected:** <expectedBehaviour>

**Actual (before fix):** <actualBehaviour>

**Branch:** \`<CURRENT_BRANCH>\`
**Latest fix commit:** \`<PRIMARY_COMMIT>\`
**Verify:** <VERIFY_STATUS>
**Checklist:** \`.checklist/fix-${title}-#${ATTEMPT}.md\`
")
```

Extract `ISSUE_NUMBER` from `ISSUE_URL` (trailing digits).

### 7d — Comment 1: commit

Post the fix commit to the issue (body = full commit message + hash; add a GitHub commit URL when the remote is `github.com`):

```bash
COMMIT_SUBJECT=$(git -C "$REPO_ROOT" show -s --format=%s "$PRIMARY_COMMIT")
gh issue comment "$ISSUE_NUMBER" --body "## Fix commit

**Subject:** ${COMMIT_SUBJECT}

\`\`\`
$(git -C "$REPO_ROOT" show -s --format=medium "$PRIMARY_COMMIT")
\`\`\`
"
```

### 7e — Comment 2: links

Second comment: make traceability obvious — include **issue URL** and **commit permalink** (from `gh browse --no-browser "$PRIMARY_COMMIT" 2>/dev/null` or equivalent), and if available a **blob URL** to the test file at `PRIMARY_COMMIT`:

```
gh issue comment "$ISSUE_NUMBER" --body "## Links

- **This issue:** ${ISSUE_URL}
- **Fix commit on GitHub:** <permalink or \`n/a\` if not resolve>
- **Test file (marker):** <blob URL to test file at PRIMARY_COMMIT, or file path if URL unknown>
"
```

### 7f — Link in source next to the marker

1. Find the test file(s) that contain the marker for this attempt: search for `fix:${title}-#${ATTEMPT}` in the tree (the line immediately above the test must already contain `${MARKER}` from Step 3 / 4b).
2. On the line **immediately after** the `${MARKER}` line (or immediately after the opening `test`/`it` line if the marker is inside a block — prefer **directly under** the marker line), add:
  ```
   ${COMMENT_PREFIX} fix-issue: <ISSUE_URL>
  ```
   If the next line is already a comment starting with `fix-issue:`, replace its URL instead of duplicating.
3. Stage only that file and commit:
  ```bash
   git add "<test-file>"
   git commit -m "chore: link fix:${title}-#${ATTEMPT} to GitHub issue #${ISSUE_NUMBER}"
  ```
   Store `TRACKING_COMMIT` = new HEAD hash. Never `git add .`.

### 7g — Close the issue

Close with a short comment pointing at the fix and the tracking commit:

```bash
gh issue close "$ISSUE_NUMBER" --comment "Addressed in commit ${PRIMARY_COMMIT}. Marker link added in ${TRACKING_COMMIT}."
```

### 7h — Final line

Print one more line after Step 6 output:

```
GitHub: issue #${ISSUE_NUMBER} ${ISSUE_URL} (closed) — tracking commit <first-8-of-TRACKING_COMMIT>
```

If Step 7 aborted mid-way after creating an issue, print `GitHub: partial — <one-line state>` instead of failing silently.

The fix commits and tracking commit stay on `CURRENT_BRANCH`. Never push to remote — the user pushes when they are happy. No queue drain.

## Rules

- Never push to remote — the user pushes when they are happy.
- Never spawn background agents — TDD work runs in the main conversation. The only foreground subagent allowed is the `/verify --checklist <path>` runner in Step 4.
- Do not file GitHub issues unless Step 7 ran and the user chose **Yes, create issue** — otherwise `/fix` stays local-only.
- Never run more than one inline re-fix per `/fix` invocation.
- Never auto-stash, auto-rebase, or auto-resolve conflicts — abort instead.
- Never call `git add .` or `git add -A` — stage explicit files.
- The TDD marker is `fix:<slug>-#<try>`; the slug must match the kebab title and the try must match the attempt counter so the enforcement check finds the marker in the test diff.


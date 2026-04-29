---
name: verify
description: Verify that a running app's behaviour matches a checklist of expected outcomes. Auto-starts the app if it isn't running, spawns a fresh-context subagent (curl-only, no code access) to verify each item, then shuts the app down. Reports PASS/FAIL/TIMEOUT/ASSUMED/UNVERIFIABLE per item. Invoke as /verify.
model: opus
argument-hint: "[--checklist <path>] [--prd <number>] [--qa <number>] [--base-url <url>] [--timeout <seconds>] [--ready-timeout <seconds>] [--start-cmd <command>] [--fix] [--no-browser]"
---

# /verify — Behavioural Verification

Check that an app matches a list of expected behaviours. Auto-starts the app if it isn't running. Verification runs in a fresh-context subagent with no code access. Results: `PASS`, `FAIL`, `TIMEOUT`, `ASSUMED`, `UNVERIFIABLE`.

**Critical rule:** the verification subagent has zero knowledge of the implementation — only the checklist and the running app. This prevents the implementer from rubber-stamping their own work.

---

## Arguments

Parse from the invocation string:

- `--checklist <path>` — path to checklist file (optional when `.checklist/` files exist — see auto-resolve below)
- `--prd <number>` — use `.checklist/prd-<number>.md` (shorthand for PRD-backed checklists; equivalent to `--checklist .checklist/prd-<number>.md`)
- `--qa <number>` — use `.checklist/qa-<number>.md` (shorthand for QA-session checklists; equivalent to `--checklist .checklist/qa-<number>.md`)
- `--base-url <url>` — base URL of the running app (default: `http://localhost:3000`). Trailing `/` stripped before use.
- `--timeout <seconds>` — max seconds to wait for async behaviours (default: 30). Must be a positive integer ≤ 600.
- `--ready-timeout <seconds>` — max seconds to wait for the app to become reachable in Step 3c (default: 30). Must be a positive integer ≤ 600.
- `--start-cmd <command>` — override auto-detected start command
- `--fix` — after verification, spawn a sequential TDD fix agent for each FAIL and TIMEOUT item; each agent opens a PR
- `--no-browser` — skip the browser verification pass (by default, UNVERIFIABLE items are re-verified with Playwright)

### Validation

Before any other step:

- If multiple checklist flags are provided, apply precedence: `--checklist` > `--prd` > `--qa`. Print: `Multiple checklist flags given; using --<winner>` and ignore the rest.
- If `--timeout` or `--ready-timeout` is missing, ≤ 0, non-numeric, or > 600 → abort: `Invalid <flag>: must be a positive integer ≤ 600.`
- Strip a single trailing `/` from `--base-url` so sub-path joins don't double-slash.

### Checklist auto-resolve (when `--checklist`, `--prd`, and `--qa` are all absent)

```bash
CHECKLIST_DIR="$(git rev-parse --show-toplevel 2>/dev/null)/.checklist"
[ -d "$CHECKLIST_DIR" ] || CHECKLIST_DIR="./.checklist"
```

- If `--qa <N>`: use `$CHECKLIST_DIR/qa-<N>.md`. Abort if not found.
- If `--prd <N>`: use `$CHECKLIST_DIR/prd-<N>.md`. Abort if not found.
- If no flag: list `.md` files in `$CHECKLIST_DIR`, sorted by modification time descending.
  - Zero files → abort: `"No checklist found. Run /interview-me, /grill-me, or /write-a-prd first, or pass --checklist <path>."`
  - Exactly one file → use it. Print: `Using checklist: <path>`
  - Multiple files → print the list and abort: `"Multiple checklists found. Specify one with --checklist <path> or --prd <number>:"`

---

## Step 1 — Checklist precheck

```bash
[ -f "<checklist-path>" ] || abort "Checklist file not found: <checklist-path>"
```

---

## Step 2 — App readiness

Check if the app is already running:

```bash
curl -s -o /dev/null --max-time 5 "<base-url>"
# exit 0 = already running; non-zero = not running
```

**If already running:** set `APP_STARTED_BY_VERIFY=false`. Skip to Step 4.

**If not running:** proceed to Step 3 (auto-start).

---

## Step 3 — Auto-start

### 3a. Resolve start command

If `--start-cmd` was provided: use it. Skip detection.

Otherwise detect from the project root (use `git rev-parse --show-toplevel` to find it):

**Detection order — stop at the first match:**

1. **`package.json` scripts** — look for scripts named `dev`, `start`, `serve`, `preview` in that priority order.
   - Detect package manager: `pnpm-lock.yaml` → `pnpm run`; `yarn.lock` → `yarn`; `bun.lockb` → `bun run`; else → `npm run`
   - Command: `<pm> run <script>`

2. **`Procfile`** — if a `web:` entry exists, use the value after `web:`.

3. **`Cargo.toml`** → `cargo run`

4. **`pyproject.toml` or `setup.py` / `requirements.txt`**:
   - `uvicorn` in deps → `uvicorn main:app --reload` (or `app:app` if `app.py` exists at root)
   - `django` in deps → `python manage.py runserver`
   - `flask` in deps → `flask run`

5. **`manage.py`** at project root → `python manage.py runserver`

6. **`Makefile`** with a `run`, `serve`, or `start` target → `make <target>`

7. **Nothing found:** abort with:
   ```
   Cannot detect start command. Start the app manually or re-run with:
     /verify --checklist <path> --start-cmd "<your start command>"
   ```

### 3b. Start the app

Run the resolved command in the background from the project root. Capture the process PID:

```bash
cd <project-root>
<start-command> &
APP_PID=$!
```

Set `APP_STARTED_BY_VERIFY=true`.

Install an EXIT trap so the app is killed even if /verify aborts before Step 6:

```bash
trap 'if [ "$APP_STARTED_BY_VERIFY" = "true" ]; then kill "$APP_PID" 2>/dev/null; wait "$APP_PID" 2>/dev/null; fi' EXIT
```

### 3c. Wait for ready

Poll `<base-url>` every 2 seconds for up to `<ready-timeout>` seconds (default 30):

```bash
attempts=$(( <ready-timeout> / 2 ))
for i in $(seq 1 "$attempts"); do
  curl -s -o /dev/null --max-time 2 "<base-url>" && break
  sleep 2
done
```

If still unreachable after `<ready-timeout>`s: kill the process (`kill $APP_PID 2>/dev/null`), then abort:
```
App failed to start within <ready-timeout>s. Check the start command output above for errors.
```

---

## Step 4 — Read the checklist

Read the checklist file. If it begins with a `---` YAML frontmatter block, strip the block before parsing — frontmatter lines must never be treated as checklist items:

```bash
awk 'BEGIN{f=0} /^---[[:space:]]*$/ && NR==1 {f=1; next} f==1 && /^---[[:space:]]*$/ {f=2; next} f!=1' <checklist-path>
```

From the stripped body, extract every distinct expected behaviour as an ordered list. Accept any format — numbered list, bullet list, checkbox list `[ ]`, prose paragraphs. Each sentence or item describing an observable outcome becomes one entry.

If the resulting list is empty, abort: `Checklist contains no behaviours after stripping frontmatter: <checklist-path>`.

Store as `CHECKLIST_ITEMS` (numbered, one per line).

---

## Step 5 — Spawn verification subagent

Spawn one `general-purpose` Agent (foreground). Pass **only** the checklist items and connection parameters — no codebase context, no git history, no PRD, no conversation history.

```
You are a behavioural verifier. Your only job: check whether a running app behaves as the checklist says.

You have NO access to the implementation code, git history, or PRD. You only know:
1. The checklist of expected behaviours
2. The app's base URL
3. How to make HTTP requests via curl

TOOL CONSTRAINTS — STRICT
- Use Bash ONLY for curl, jq, and shell expressions on curl output.
- DO NOT use Read, Grep, Glob, or Bash to access project files.
- DO NOT run: cat, ls, find, git, cd into any directory, or read any source file.
- DO NOT read package.json, route files, OpenAPI specs, or any codebase content.
- If you cannot determine an endpoint from the checklist text alone: mark UNVERIFIABLE — do not guess by reading code.

═══════════════════════════════════════════════════════
CONNECTION
═══════════════════════════════════════════════════════
BASE URL : <base-url>
TIMEOUT  : <timeout> seconds

═══════════════════════════════════════════════════════
CHECKLIST
═══════════════════════════════════════════════════════
<CHECKLIST_ITEMS — numbered, one per line>

═══════════════════════════════════════════════════════
VERIFICATION STEPS — repeat for EACH item in order
═══════════════════════════════════════════════════════

── STEP 1: CLASSIFY ────────────────────────────────────
Can this item be verified by making HTTP requests?

YES → proceed to STEP 2.
NO  → record UNVERIFIABLE — <one-line reason>. Move to next item.

── STEP 2: HANDLE VAGUE ITEMS ─────────────────────────
Is the item specific (exact status code, exact text, exact field names)?
  → YES: proceed as written.
  → NO (e.g. "appropriate error", "success", "displays correctly"):
      Make a reasonable inference. Document it.
      Mark result ASSUMED (not PASS) regardless of outcome.
      Example inference: "appropriate error" → HTTP 4xx with non-empty body.

── STEP 3: CONSTRUCT REQUEST ──────────────────────────
Build the minimal curl command(s) to exercise this behaviour.
  - Root all URLs at BASE URL.
  - Infer endpoint, method, headers, body from the behaviour description.
  - If prior state is required (e.g. "a logged-in user"), set it up with a
    preceding request. Document what setup you did.
  - If auth is needed but not described in the checklist: attempt unauthenticated
    first; if that returns 401/403, note it and mark UNVERIFIABLE.

── STEP 4: EXECUTE AND EVALUATE ───────────────────────
Run:
  curl -s -w "\n%{http_code}" --max-time <timeout> [other flags] <url>

Evaluate:
  - Check HTTP status code against expectation.
  - Check response body for expected content, fields, or messages.
  - If the behaviour involves a state change (record created, status updated):
    make a follow-up GET to confirm the change persisted.

── STEP 5: ASYNC BEHAVIOURS ───────────────────────────
If the expected outcome is asynchronous (email sent, job completed, webhook fired):
  - Poll a relevant status endpoint every 5 seconds, up to <timeout> seconds.
  - If resolved within timeout: evaluate and record normally.
  - If not resolved: record TIMEOUT — <what was waited for>.

── STEP 6: RECORD RESULT ──────────────────────────────
Assign exactly one status:

  PASS          — behaviour confirmed as described
  FAIL          — behaviour not observed (wrong status, wrong body, no response)
  TIMEOUT       — async outcome did not appear within <timeout>s
  ASSUMED       — vague item; documented inference held (or didn't)
  UNVERIFIABLE  — cannot be checked via HTTP

With each result, include brief evidence (≤100 chars): status code, response excerpt,
or reason for UNVERIFIABLE/TIMEOUT.

═══════════════════════════════════════════════════════
OUTPUT — your final output must be EXACTLY this format
═══════════════════════════════════════════════════════

## Verification Report

| # | Item | Status | Evidence |
|---|------|--------|----------|
| 1 | <item text, max 60 chars> | PASS | GET /users → 200, body has "id" field |
| 2 | <...> | FAIL | Expected 401, got 200 |
| 3 | <...> | ASSUMED | "success" inferred as 2xx. POST /orders → 201 ✓ |
| 4 | <...> | TIMEOUT | Waited 30s for job completion record — none appeared |
| 5 | <...> | UNVERIFIABLE | Requires browser UI interaction |

## Summary

- Total   : N
- PASS    : N
- FAIL    : N
- TIMEOUT : N
- ASSUMED : N  ← review these; assumptions may not match intent
- UNVERIFIABLE : N

<Only include this section when FAIL or TIMEOUT items exist>
## Items Requiring Attention

### #N — <item text>

**Expected:** <what the checklist says>
**Observed:** <what the app actually returned>
**Likely gap:** <missing endpoint / wrong status / business logic not implemented / etc.>
```

---

## Step 5b — Browser verification pass (playwright-cli)

Skip entirely if:
- `--no-browser` was passed
- Zero `UNVERIFIABLE` items in the Step 5 report

### 5b-1. playwright-cli availability check

Derive the screenshot output directory from the checklist path and create it lazily (only reached when Step 5b actually runs — i.e. `--no-browser` was not passed and at least one item is UNVERIFIABLE):

```bash
CHECKLIST_DIR_ABS="$(cd "$(dirname "<checklist-path>")" && pwd)"
CHECKLIST_STEM="$(basename "<checklist-path>" .md)"
SCREENSHOT_DIR="$CHECKLIST_DIR_ABS/$CHECKLIST_STEM-screenshots"
mkdir -p "$SCREENSHOT_DIR"
rm -f "$SCREENSHOT_DIR"/item-*.png
```

The `rm -f` clears stale `item-*.png` files from prior runs of the same checklist — otherwise screenshots from previously-UNVERIFIABLE-but-now-curl-PASS items would linger and mislead the reviewer. Other files (if any) are left untouched.

For example, `--qa 1` resolves to `.checklist/qa-1.md` → `SCREENSHOT_DIR=.checklist/qa-1-screenshots`. The folder inherits the existing `.checklist/` gitignore line written by /qa.

Mint a unique session name so concurrent CLI sessions (other `/verify` runs, manual debugging) don't collide on the same browser:

```bash
BROWSER_SESSION="verify-$(date +%s)-$$"
```

Resolve the CLI invocation once — global if available, otherwise local via `npx`:

```bash
if playwright-cli --version >/dev/null 2>&1; then
  BROWSER_CMD="playwright-cli"
elif npx --no-install playwright-cli --version >/dev/null 2>&1; then
  BROWSER_CMD="npx playwright-cli"
else
  BROWSER_CMD=""
fi
```

Confirm chromium is actually installed by opening + closing a throwaway probe session (a real session would pollute `BROWSER_SESSION` if `open` partially succeeds):

```bash
PROBE_SESSION="verify-probe-$$"
PROBE_OK=0
if [ -n "$BROWSER_CMD" ]; then
  if $BROWSER_CMD -s="$PROBE_SESSION" open about:blank >/dev/null 2>&1; then
    PROBE_OK=1
  fi
  $BROWSER_CMD -s="$PROBE_SESSION" close >/dev/null 2>&1 || true
fi
```

If `BROWSER_CMD` is empty or `PROBE_OK == 0`: print the following warning, then continue to Step 6 (UNVERIFIABLE items remain as-is):

```
Browser pass skipped: playwright-cli not installed or chromium binary missing.
To enable browser verification:
  npm install -g @playwright/cli@latest   # CLI
  playwright-cli install --skills         # bundled agent skills (one-time)
  npx playwright install chromium         # browser binary
```

### 5b-2. Spawn subagent

Collect UNVERIFIABLE items from the Step 5 report (item number + full item text). Spawn one `general-purpose` Agent (foreground) using verify-browser-agent-prompt.

Pass **only**: the UNVERIFIABLE items (numbered), the base URL, the timeout, `BROWSER_CMD` (from 5b-1, the resolved CLI invocation — `playwright-cli` or `npx playwright-cli`), `BROWSER_SESSION` (from 5b-1, scopes every CLI command), and `SCREENSHOT_DIR` (from 5b-1, where browser screenshots get written). No codebase context, no git history, no other lines from the report.

After the subagent returns → **5b-3. Merge results** (below).

---

### 5b-3. Merge results

After the subagent returns:
- For every item the subagent returned a row for: replace the corresponding UNVERIFIABLE row in the Step 5 report table with the new row.
- For every UNVERIFIABLE item the subagent did **not** return a row for (crash, malformed output, omission): leave the row as `UNVERIFIABLE` and set its evidence to `browser pass returned no result for this item`.
- Browser-pass rows are emitted with a `(browser)` suffix on every status (e.g. `PASS (browser)`, `FAIL (browser)`) — preserve the suffix verbatim so Step 7 can detect them.
- Recompute all Summary counts (the suffix does not change which bucket a row falls into — `PASS (browser)` still counts as PASS).
- In Step 6, print the merged report (not the original Step 5 report).

---

## Step 6 — Display result and shutdown

Print the subagent's full output verbatim.

If the subagent errors or produces no output:
```
VERIFY_ERROR: subagent did not produce a report.
```

**Always** shut down after, regardless of outcome:

```bash
# Defensive browser-session cleanup — the subagent's CLEANUP step closes
# BROWSER_SESSION on the happy path; this catches crashes, timeouts, and kills
# so chromium processes don't leak across runs.
if [ -n "$BROWSER_SESSION" ] && [ -n "$BROWSER_CMD" ]; then
  $BROWSER_CMD -s="$BROWSER_SESSION" close >/dev/null 2>&1 || true
fi

if [ "$APP_STARTED_BY_VERIFY" = "true" ]; then
  kill $APP_PID 2>/dev/null
  wait $APP_PID 2>/dev/null
  echo "App stopped."
fi
```

---

## Step 7 — Fix loop (only when `--fix` is set)

Skip entirely if `--fix` was not passed, or if there are zero FAIL/TIMEOUT items.

Resolve `BASE_BRANCH` once per /verify run (used by every fix agent's `gh pr create --base`):

```bash
BASE_BRANCH="$(git symbolic-ref refs/remotes/origin/HEAD --short 2>/dev/null | sed 's@^origin/@@')"
[ -n "$BASE_BRANCH" ] || BASE_BRANCH="$(git rev-parse --abbrev-ref HEAD)"
```

Parse FAIL and TIMEOUT items from the merged report (status cells `FAIL`, `TIMEOUT`, `FAIL (browser)`, or `TIMEOUT (browser)`). For each item **sequentially**:

1. Derive a branch slug: lowercase kebab of first 6 words of item text, prefixed `verify-fix/` and suffixed with `-<N>` where `<N>` is the item number. The number suffix prevents collisions when two items share their first 6 words.
   (e.g. item #3 → `verify-fix/post-orders-invalid-payload-returns-400-3`)
2. Determine `BROWSER_ITEM`: `true` if the item's status cell ends in `(browser)`, else `false`. The fix-agent prompt short-circuits when `BROWSER_ITEM=true` (auto-fix not supported for browser-verified items).
3. Spawn a foreground `general-purpose` Agent using verify-fix-agent-prompt, passing `BASE_BRANCH` as `<base-branch>`
4. Wait for completion before starting the next item

Each fix agent has a hard wall-clock cap of **15 minutes**. If the agent does not return its `FIX_*` final line within 900s, the orchestrator records `FIX_FAILED: agent timeout (>15min)` for that item and moves on.

After all fix agents complete, print:

```
Fix summary:
  FIX_COMPLETE    : N  (PRs opened — review and merge)
  FIX_FAILED      : N  (could not implement — manual fix needed)
  FIX_NOT_NEEDED  : N  (behaviour already works — checklist item may be inaccurate)
```

---

## verify-fix-agent-prompt

```
You are a fix agent. One behavioural verification item failed. Make it pass using strict TDD.

═══════════════════════════════════════════════════════
CONTEXT
═══════════════════════════════════════════════════════
REPO ROOT    : <repo-root>
BASE BRANCH  : <base-branch>
FIX BRANCH   : <fix-branch>
ITEM         : <failing checklist item — full text>
EVIDENCE     : <what the app returned, from the verification report>
BROWSER_ITEM : <true if item was verified by the browser pass, false if verified by curl pass>

═══════════════════════════════════════════════════════
STEPS
═══════════════════════════════════════════════════════

── SETUP ────────────────────────────────────────────────
  cd <repo-root>
  git checkout -b <fix-branch>

── DETECT TEST RUNNER ───────────────────────────────────
  Check package.json scripts (test:run → test), pyproject.toml/pytest.ini → pytest,
  Cargo.toml → cargo test, Makefile test target.
  Store as TEST_CMD.

── RED — write a failing test ───────────────────────────
  ▶ If BROWSER_ITEM=true:
    Output: FIX_FAILED: browser-verified item — auto-fix requires Playwright test setup
    Do NOT write tests. Do NOT commit. STOP.

  Write ONE test that captures the expected behaviour from ITEM.
  The test must exercise public interfaces only — no private methods.
  Add this marker on the line IMMEDIATELY above the test function/call:
    // verify-fix  (or # verify-fix for Python/Ruby)
  Run it:
    <TEST_CMD> <test-file>
  It MUST fail before you write any fix code.
  ▶ If it already passes: the behaviour works — the checklist item may be wrong.
    Output: FIX_NOT_NEEDED: test already passes — <one-line explanation>
    Do NOT commit. Do NOT open a PR. STOP.
  ▶ If you CANNOT write a meaningful failing test:
    Output: FIX_FAILED: cannot write failing test — <reason>. STOP.

── GREEN — minimal implementation ───────────────────────
  Write the minimal code to make the failing test pass.
  Run targeted test (must pass), then full suite (no regressions).
  ▶ If full suite fails due to your change after 3 attempts:
    Output: FIX_FAILED: regression introduced — <file:line>. STOP.

── REFACTOR ─────────────────────────────────────────────
  One focused pass: remove obvious duplication from GREEN phase only.
  Re-run full suite. If it fails: revert the refactor.

── COMMIT ───────────────────────────────────────────────
  git add <specific files — never git add . or git add -A>
  git commit -m "fix: <item-slug>

  Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>"

── PUSH + PR ────────────────────────────────────────────
  git push -u origin <fix-branch>
  gh pr create \
    --title "fix: <item-slug>" \
    --base <base-branch> \
    --body "## Failing verification item

<item text>

## Evidence of failure

<evidence>

## What was fixed

<one paragraph>

## Test marker

All new tests marked \`// verify-fix\`.
Run: \`<TEST_CMD>\`

🤖 Generated with [Claude Code](https://claude.com/claude-code)"

═══════════════════════════════════════════════════════
FINAL REPORT — last line must be EXACTLY one of:
═══════════════════════════════════════════════════════
  FIX_COMPLETE: <pr-url>
  FIX_FAILED: <one-sentence reason>
  FIX_NOT_NEEDED: <one-sentence reason>
```

---

## verify-browser-agent-prompt

```
You are a browser-based behavioural verifier. A curl-only verification pass already ran
and marked certain items UNVERIFIABLE. Your job: attempt to verify those items by
driving a headless browser via `playwright-cli`.

You have NO access to the implementation code, git history, or PRD. You only know:
1. The UNVERIFIABLE checklist items from the prior curl pass
2. The app's base URL
3. The CLI invocation (`playwright-cli` or `npx playwright-cli`, pre-resolved)
4. The session name to scope every CLI command to
5. The screenshot output directory

TOOL CONSTRAINTS — STRICT
- Use Bash ONLY to invoke `<browser-cmd>` (the pre-resolved CLI from the CONNECTION block).
- DO NOT use Read, Grep, Glob, or Bash to access any project file.
- DO NOT run: cat, ls, find, git, cd into any project directory, or read source files.
- You MAY only write files inside `/tmp/` and inside `<SCREENSHOT_DIR>` — no other paths.
- DO NOT shell out to `node`, `npm`, or write `.mjs`/`.js` scripts. Drive everything
  through `playwright-cli` subcommands.
- `cd /tmp` once at the start so playwright-cli's auto-snapshot files land in
  `/tmp/.playwright-cli/`, not the project root.
- Infer all navigation paths from checklist text alone. If a path cannot be inferred,
  mark the item UNVERIFIABLE (browser) — do NOT read routes or components.
- The bundled `playwright-cli` skill is installed; consult `playwright-cli --help` if
  unsure of a command. Prefer locators (`getByRole(...)`, `getByTestId(...)`,
  `getByText(...)`) or refs surfaced by snapshot output over raw CSS.

═══════════════════════════════════════════════════════
CONNECTION
═══════════════════════════════════════════════════════
BASE URL         : <base-url>
TIMEOUT          : <timeout> seconds
BROWSER_CMD      : <browser-cmd>       (substitute verbatim — `playwright-cli` or `npx playwright-cli`)
BROWSER_SESSION  : <browser-session>   (prepend `-s=<browser-session>` to every command)
SCREENSHOT_DIR   : <absolute path to <checklist-stem>-screenshots dir, pre-created>

═══════════════════════════════════════════════════════
UNVERIFIABLE ITEMS TO RE-CHECK
═══════════════════════════════════════════════════════
<UNVERIFIABLE_ITEMS — original item numbers and full text>

═══════════════════════════════════════════════════════
HOW TO VERIFY
═══════════════════════════════════════════════════════

── SETUP (once) ────────────────────────────────────────
  cd /tmp
  <browser-cmd> -s=<browser-session> open <base-url>

── PER ITEM ────────────────────────────────────────────
1. CLASSIFY — can this item be verified by controlling a browser (clicks, navigation,
   visible text, DOM state, form submission)? If still not verifiable even with a
   browser (e.g. email delivery, server-side-only state): mark
   `UNVERIFIABLE (browser)` — <reason>. Move to next item.

2. NAVIGATE — `<browser-cmd> -s=<browser-session> goto <url>` if the item targets a
   sub-path inferred from the checklist text.

3. ACT — drive the UI with the minimum command sequence needed to reach the state
   described by the item. Common commands: `click`, `fill`, `press`, `select`,
   `check`, `hover`. Every command emits the resulting page snapshot to stdout —
   read that to find the next ref or to decide outcome.

4. ASSERT — use the stdout snapshot from the last action, or take an explicit one
   to a known file for grep-based checks:
     <browser-cmd> -s=<browser-session> snapshot --filename=/tmp/snap-<n>.yml
     grep -F '<expected text>' /tmp/snap-<n>.yml
   For richer DOM checks use `eval` against the snapshot's refs or selectors.

5. SCREENSHOT — capture proof for the reviewer:
     <browser-cmd> -s=<browser-session> screenshot --filename=<SCREENSHOT_DIR>/item-<n>.png || true
   Track success per item. A screenshot failure must NOT change the item's status —
   only the trailing `[screenshot: ...]` evidence tag is omitted on failure.

── ASYNC UI BEHAVIOURS ────────────────────────────────
   If an item requires waiting (spinner resolves, toast appears), poll by re-running
   `snapshot` (or `eval`) up to <timeout> seconds with short sleeps between attempts.
   If still unresolved: mark `TIMEOUT (browser)` — <what was waited for>.

── VAGUE ITEMS ────────────────────────────────────────
   Same rule as curl pass: vague items → document inference, mark
   `ASSUMED (browser)` not `PASS (browser)`.

── CLEANUP (once) ─────────────────────────────────────
   <browser-cmd> -s=<browser-session> close
   rm -f /tmp/snap-*.yml

═══════════════════════════════════════════════════════
OUTPUT — your final output must be EXACTLY these rows
(only for the items you were assigned — use original item numbers)

EVERY status MUST be suffixed with " (browser)" so the orchestrator can
distinguish browser-pass results from curl-pass results in Step 7.

EVIDENCE COLUMN — when screenshot capture for an item succeeded, append a
single trailing tag to the evidence text: ` [screenshot: item-<#>.png]`
where `<#>` is the item number. Omit the tag only when capture errored.
═══════════════════════════════════════════════════════

| <#> | <item text, max 60 chars> | PASS (browser) | Heading "Create account" visible at /register [screenshot: item-<#>.png] |
| <#> | <...> | FAIL (browser) | Button disabled — expected enabled after valid input [screenshot: item-<#>.png] |
| <#> | <...> | ASSUMED (browser) | "friendly message" inferred as non-empty p tag. Found ✓ [screenshot: item-<#>.png] |
| <#> | <...> | TIMEOUT (browser) | Waited 30s for modal to close — still open [screenshot: item-<#>.png] |
| <#> | <...> | UNVERIFIABLE (browser) | Cannot infer UI path from checklist text |
```

---

## Rules

- Never pass codebase files, git history, PRD content, or implementation details to the verification subagent
- Always shut down the app if `/verify` started it — even on error or early abort
- Print the verification report verbatim — do not summarise, editorialize, or reformat it
- `--fix` runs sequentially — never spawn fix agents in parallel (risk of merge conflicts)
- Fix agents MAY read the codebase — unlike the verification subagent, they need code context to fix bugs
- Browser pass runs by default; `--no-browser` skips it
- Browser pass re-verifies only `UNVERIFIABLE` items — never re-runs curl-verified results
- Browser subagent has same code-isolation contract as the curl subagent; it drives `playwright-cli` only and may only write to `/tmp/` and `<SCREENSHOT_DIR>`
- Browser-pass rows always carry a `(browser)` suffix on their status — preserve it through merge so Step 7 can detect them
- Browser pass writes one PNG per re-checked item to `<checklist-dir>/<checklist-stem>-screenshots/item-<#>.png` (e.g. `.checklist/qa-1-screenshots/item-3.png`). Folder is created lazily by Step 5b-1 — absent when `--no-browser` skips the pass. Files inherit the existing `.checklist/` gitignore line. A failed screenshot capture must NOT change item status; the evidence cell simply omits the `[screenshot: ...]` tag
- Do not run two `/verify` invocations against the same project simultaneously — both will try to auto-start the app and race on the port

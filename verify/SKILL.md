---
name: verify
description: Verify that a running app's behaviour matches a checklist of expected outcomes. Auto-starts the app if it isn't running, spawns a fresh-context subagent (curl-only, no code access) to verify each item, then shuts the app down. Reports PASS/FAIL/TIMEOUT/ASSUMED/UNVERIFIABLE per item. Invoke as /verify.
model: opus
argument-hint: "[--checklist <path>] [--prd <number>] [--qa <number>] [--base-url <url>] [--timeout <seconds>] [--start-cmd <command>] [--fix] [--no-browser]"
---

# /verify — Behavioural Verification

Check that an app matches a list of expected behaviours. Auto-starts the app if it isn't running. Verification runs in a fresh-context subagent with no code access. Results: `PASS`, `FAIL`, `TIMEOUT`, `ASSUMED`, `UNVERIFIABLE`.

**Critical rule:** the verification subagent has zero knowledge of the implementation — only the checklist and the running app. This prevents the implementer from rubber-stamping their own work.

---

## Arguments

Parse from the invocation string:

- `--checklist <path>` — path to checklist file (optional when `.checklist/` files exist — see auto-resolve below)
- `--prd <number>` — use `.checklist/prd-<number>.md` (shorthand for PRD-backed checklists)
- `--qa <number>` — use `.checklist/qa-<number>.md` (shorthand for QA-session checklists; triggers browser MCP pass automatically when checklist has `type: ui`)
- `--base-url <url>` — base URL of the running app (default: `http://localhost:3000`)
- `--timeout <seconds>` — max seconds to wait for async behaviours (default: 30)
- `--start-cmd <command>` — override auto-detected start command
- `--fix` — after verification, spawn a sequential TDD fix agent for each FAIL and TIMEOUT item; each agent opens a PR
- `--no-browser` — skip the browser verification pass (by default, UNVERIFIABLE items are re-verified with Playwright if available)

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

**If already running:** set `APP_STARTED_BY_VERIFY=false`. Skip to §Step 4.

**If not running:** proceed to §Step 3 (auto-start).

---

## Step 3 — Auto-start

### 3a. Resolve start command

If `--start-cmd` was provided: use it. Skip detection.

Otherwise detect from the project root (use `git rev-parse --show-toplevel` to find it):

**Detection order — stop at the first match:**

1. **`package.json` scripts** — look for scripts named `dev`, `start`, `serve`, `preview` in that priority order.
   - Detect package manager: `pnpm-lock.yaml` → `pnpm run`; `yarn.lock` → `yarn`; else → `npm run`
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

### 3c. Wait for ready

Poll `<base-url>` every 2 seconds for up to 30 seconds:

```bash
for i in $(seq 1 15); do
  curl -s -o /dev/null --max-time 2 "<base-url>" && break
  sleep 2
done
```

If still unreachable after 30s: kill the process (`kill $APP_PID 2>/dev/null`), then abort:
```
App failed to start within 30s. Check the start command output above for errors.
```

---

## Step 4 — Read the checklist

Read the checklist file. Extract every distinct expected behaviour as an ordered list. Accept any format — numbered list, bullet list, checkbox list `[ ]`, prose paragraphs. Each sentence or item describing an observable outcome becomes one entry.

Store as `CHECKLIST_ITEMS` (numbered, one per line).

### 4a. Parse frontmatter (applies to all checklist sources)

If the file starts with a `---` YAML block, parse the leading frontmatter:

```bash
awk '/^---$/{c++; next} c==1' <checklist-path>
```

Then evaluate `type:` (case-insensitive):

- `type: ui`  → `CHECKLIST_UI=true`
- anything else (or missing) → `CHECKLIST_UI=false`

This applies regardless of how the checklist was selected (`--checklist`, `--prd`, `--qa`, or auto-resolve).

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

## Step 5b — Browser verification pass

Skip entirely if:
- `--no-browser` was passed
- Zero `UNVERIFIABLE` items in the Step 5 report

### 5b-1. Choose browser strategy

**If `CHECKLIST_UI=true`** (checklist came from `/qa --qa <N>` with `type: ui` frontmatter):
- Use the **browsermcp** MCP path (§5b-browsermcp). No Playwright needed.

**Otherwise:**
- Use the **Playwright** path (§5b-playwright).

---

### §5b-browsermcp — Browser MCP pass

#### Availability check

```bash
claude mcp list 2>/dev/null | grep -E '^browsermcp:.*Connected' >/dev/null
```

If exit code ≠ 0: print the following and abort the browser pass (UNVERIFIABLE items remain as-is — do **not** fall back to Playwright; the user explicitly chose browser MCP for this UI checklist):

```
Browser MCP pass skipped: browsermcp MCP server not configured or not connected.
Install with:
  claude mcp add browsermcp -s user -- npx @browsermcp/mcp@latest
Then verify:
  claude mcp list | grep browsermcp
```

#### Spawn subagent

Collect UNVERIFIABLE items from the Step 5 report (item number + full item text). Spawn one `general-purpose` Agent (foreground) using §verify-browsermcp-agent-prompt.

Pass **only**: the UNVERIFIABLE items (numbered), the base URL, and the timeout. No codebase context, no git history, no other lines from the report.

After the subagent returns → **5b-3. Merge results** (below).

---

### §5b-playwright — Playwright pass

```bash
npx playwright --version 2>/dev/null
```

If unavailable: print the following warning, then continue to §Step 6 (UNVERIFIABLE items remain as-is):

```
Browser pass skipped: Playwright not found.
To enable browser verification, install it:
  <pm> add -D @playwright/test && npx playwright install chromium
```

Where `<pm>` is the package manager detected in §Step 3a (`pnpm`/`yarn`/`npm`). If §Step 3a did not run (app was already running when /verify started), re-detect: `pnpm-lock.yaml` → `pnpm add`; `yarn.lock` → `yarn add`; else → `npm install`. If no lock file: use `npm install`.

Collect UNVERIFIABLE items. Spawn one `general-purpose` Agent (foreground) using §verify-browser-agent-prompt.

Pass **only**: the UNVERIFIABLE items (numbered), the base URL, and the timeout.

After the subagent returns → **5b-3. Merge results** (below).

---

### 5b-3. Merge results

After the subagent returns:
- Replace each UNVERIFIABLE row in the Step 5 report table with the browser result for that item number.
- Recompute all Summary counts.
- In §Step 6, print the merged report (not the original Step 5 report).

---

## Step 6 — Display result and shutdown

Print the subagent's full output verbatim.

If the subagent errors or produces no output:
```
VERIFY_ERROR: subagent did not produce a report.
```

**Always** shut down after, regardless of outcome:

```bash
if [ "$APP_STARTED_BY_VERIFY" = "true" ]; then
  kill $APP_PID 2>/dev/null
  wait $APP_PID 2>/dev/null
  echo "App stopped."
fi
```

---

## Step 7 — Fix loop (only when `--fix` is set)

Skip entirely if `--fix` was not passed, or if there are zero FAIL/TIMEOUT items.

Parse FAIL and TIMEOUT items from the subagent report. For each item **sequentially**:

1. Derive a branch slug: lowercase kebab of first 6 words of item text, prefixed `verify-fix/`  
   (e.g. `verify-fix/post-orders-invalid-payload-returns-400`)
2. Spawn a foreground `general-purpose` Agent using §verify-fix-agent-prompt
3. Wait for completion before starting the next item

After all fix agents complete, print:

```
Fix summary:
  FIX_COMPLETE    : N  (PRs opened — review and merge)
  FIX_FAILED      : N  (could not implement — manual fix needed)
  FIX_NOT_NEEDED  : N  (behaviour already works — checklist item may be inaccurate)
```

---

## §verify-fix-agent-prompt

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

## §verify-browsermcp-agent-prompt

```
You are a browser-based behavioural verifier. A curl-only verification pass already ran
and marked certain items UNVERIFIABLE. Your job: verify those items by controlling a
real browser via the browsermcp MCP tools.

You have NO access to the implementation code, git history, or PRD. You only know:
1. The UNVERIFIABLE checklist items from the prior curl pass
2. The app's base URL
3. The browsermcp MCP tools available to you

TOOL CONSTRAINTS — STRICT
- Use ONLY tools exposed by the `browsermcp` MCP server for browser interaction. Tool
  names typically appear as `mcp__browsermcp__<name>` (navigate, snapshot, click, type,
  screenshot, wait_for, press_key, etc.). Do NOT assume exact names — at the start, list
  the tools the server actually exposes and use those. If a needed capability is not
  available, mark the item UNVERIFIABLE (browser) and explain.
- Use Bash ONLY for shell expressions if needed to process text — no curl, no file reads.
- DO NOT use Read, Grep, Glob, or Bash to access any project file.
- DO NOT run: cat, ls, find, git, or read any source file.
- Infer all navigation paths from checklist text alone. If a path cannot be inferred,
  mark the item UNVERIFIABLE (browser) — do NOT read routes or components.

═══════════════════════════════════════════════════════
CONNECTION
═══════════════════════════════════════════════════════
BASE URL : <base-url>
TIMEOUT  : <timeout> seconds

═══════════════════════════════════════════════════════
UNVERIFIABLE ITEMS TO RE-CHECK
═══════════════════════════════════════════════════════
<UNVERIFIABLE_ITEMS — original item numbers and full text>

═══════════════════════════════════════════════════════
HOW TO VERIFY — repeat for EACH item
═══════════════════════════════════════════════════════

── STEP 1: CLASSIFY ────────────────────────────────────
Can this item be verified by controlling a browser (clicks, navigation, visible text,
DOM state, form submission)? If still not verifiable even with a browser (e.g. email
delivery, server-side-only state): mark UNVERIFIABLE — <reason>. Move to next item.

── STEP 2: NAVIGATE ────────────────────────────────────
Use browser_navigate to go to BASE URL (and sub-paths inferred from checklist text only).
Infer navigation target from checklist text — do not read source files.

── STEP 3: INSPECT ─────────────────────────────────────
Use browser_snapshot to get the accessibility tree, or browser_screenshot to see the page.
Interact as needed (browser_click, browser_type) to exercise the behaviour.

── STEP 4: HANDLE VAGUE ITEMS ─────────────────────────
Same rule as curl pass: vague items → document inference, mark ASSUMED not PASS.

── STEP 5: ASYNC UI BEHAVIOURS ────────────────────────
If a behaviour requires waiting (spinner resolves, toast appears):
  - Poll with browser_wait_for or repeated browser_snapshot up to <timeout> seconds.
  - If not resolved within timeout: mark TIMEOUT — <what was waited for>.

═══════════════════════════════════════════════════════
OUTPUT — your final output must be EXACTLY these rows
(only for the items you were assigned — use original item numbers)
═══════════════════════════════════════════════════════

| <#> | <item text, max 60 chars> | PASS | Heading "Create account" visible at /register |
| <#> | <...> | FAIL | Button disabled — expected enabled after valid input |
| <#> | <...> | ASSUMED | "friendly message" inferred as non-empty visible text. Found ✓ |
| <#> | <...> | TIMEOUT | Waited 30s for modal to close — still open |
| <#> | <...> | UNVERIFIABLE (browser) | Cannot infer UI path from checklist text |
```

---

## §verify-browser-agent-prompt

```
You are a browser-based behavioural verifier. A curl-only verification pass already ran
and marked certain items UNVERIFIABLE. Your job: attempt to verify those items by
controlling a headless browser via Playwright.

You have NO access to the implementation code, git history, or PRD. You only know:
1. The UNVERIFIABLE checklist items from the prior curl pass
2. The app's base URL
3. How to write and run a Playwright Node.js script

TOOL CONSTRAINTS — STRICT
- Use Bash ONLY to write ONE script to /tmp and run it with node / npx.
- DO NOT use Read, Grep, Glob, or Bash to access any project file.
- DO NOT run: cat, ls, find, git, cd into any directory, or read any source file.
- You may ONLY write to /tmp/verify-browser-<timestamp>.mjs — no other file paths.
- Infer all navigation paths from checklist text alone. If a path cannot be inferred,
  mark the item UNVERIFIABLE (browser) — do NOT read routes or components.

═══════════════════════════════════════════════════════
CONNECTION
═══════════════════════════════════════════════════════
BASE URL : <base-url>
TIMEOUT  : <timeout> seconds

═══════════════════════════════════════════════════════
UNVERIFIABLE ITEMS TO RE-CHECK
═══════════════════════════════════════════════════════
<UNVERIFIABLE_ITEMS — original item numbers and full text>

═══════════════════════════════════════════════════════
HOW TO VERIFY — repeat for EACH item
═══════════════════════════════════════════════════════

── STEP 1: CLASSIFY ────────────────────────────────────
Can this item be verified by controlling a browser (clicks, navigation, visible text,
DOM state, form submission)? If still not verifiable even with a browser (e.g. email
delivery, server-side-only state): mark UNVERIFIABLE — <reason>. Move to next item.

── STEP 2: WRITE PLAYWRIGHT SCRIPT ────────────────────
Write a single Node.js script to /tmp/verify-browser-<timestamp>.mjs that:
  - Uses `import { chromium } from 'playwright'`
  - Launches chromium headless: `const browser = await chromium.launch({ headless: true })`
  - Navigates to BASE URL (and sub-paths inferred from checklist text only)
  - Checks the relevant DOM state, visible text, or UI behaviour per item
  - Prints one JSON result object per item to stdout:
    { "item": <number>, "status": "PASS"|"FAIL"|"TIMEOUT"|"ASSUMED"|"UNVERIFIABLE",
      "evidence": "<≤100 chars>" }
  - Closes the browser and exits 0 regardless of result

Run:
  node /tmp/verify-browser-<timestamp>.mjs

── STEP 3: HANDLE VAGUE ITEMS ─────────────────────────
Same rule as curl pass: vague items → document inference, mark ASSUMED not PASS.

── STEP 4: ASYNC UI BEHAVIOURS ────────────────────────
If a behaviour requires waiting (e.g. spinner resolves, toast appears):
  - Poll with page.waitForSelector or page.waitForFunction up to <timeout> seconds.
  - If not resolved within timeout: mark TIMEOUT — <what was waited for>.

── STEP 5: CLEAN UP ───────────────────────────────────
\```bash
rm -f /tmp/verify-browser-<timestamp>.mjs
\```

═══════════════════════════════════════════════════════
OUTPUT — your final output must be EXACTLY these rows
(only for the items you were assigned — use original item numbers)
═══════════════════════════════════════════════════════

| <#> | <item text, max 60 chars> | PASS | Heading "Create account" visible at /register |
| <#> | <...> | FAIL | Button disabled — expected enabled after valid input |
| <#> | <...> | ASSUMED | "friendly message" inferred as non-empty p tag. Found ✓ |
| <#> | <...> | TIMEOUT | Waited 30s for modal to close — still open |
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
- Browser subagent has same code-isolation contract as the curl subagent; it may only write scripts to `/tmp`

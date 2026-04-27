---
name: verify
description: Verify that a running app's behaviour matches a checklist of expected outcomes. Auto-starts the app if it isn't running, spawns a fresh-context subagent (curl-only, no code access) to verify each item, then shuts the app down. Reports PASS/FAIL/TIMEOUT/ASSUMED/UNVERIFIABLE per item. Invoke as /verify.
model: opus
argument-hint: "--checklist <path> [--base-url <url>] [--timeout <seconds>] [--start-cmd <command>]"
---

# /verify — Behavioural Verification

Check that an app matches a list of expected behaviours. Auto-starts the app if it isn't running. Verification runs in a fresh-context subagent with no code access. Results: `PASS`, `FAIL`, `TIMEOUT`, `ASSUMED`, `UNVERIFIABLE`.

**Critical rule:** the verification subagent has zero knowledge of the implementation — only the checklist and the running app. This prevents the implementer from rubber-stamping their own work.

---

## Arguments

Parse from the invocation string:

- `--checklist <path>` — **(required)** path to a file containing expected behaviours
- `--base-url <url>` — base URL of the running app (default: `http://localhost:3000`)
- `--timeout <seconds>` — max seconds to wait for async behaviours (default: 30)
- `--start-cmd <command>` — override auto-detected start command

If `--checklist` is missing: abort with `"--checklist <path> is required. Example: /verify --checklist .checklist/my-feature.md"`

If `--fix` is passed: abort with `"--fix is not yet available. Remove the flag and re-run."`

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

## Step 6 — Display result and shutdown

Print the subagent's full output verbatim.

If the subagent errors or produces no output:
```
VERIFY_ERROR: subagent did not produce a report.
```

**Always** run shutdown after, regardless of outcome:

```bash
# Only kill if /verify started the app
if [ "$APP_STARTED_BY_VERIFY" = "true" ]; then
  kill $APP_PID 2>/dev/null
  wait $APP_PID 2>/dev/null
  echo "App stopped."
fi
```

---

## Rules

- Never pass codebase files, git history, PRD content, or implementation details to the subagent
- Never attempt to fix failures — this skill reports only
- Always shut down the app if `/verify` started it — even on error or early abort
- Print the subagent report verbatim — do not summarise, editorialize, or reformat it

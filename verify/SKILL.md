---
name: verify
description: Verify arbitrary checklist files against a running app. Use cURL for backend/API behaviours, bounded auth discovery when special authentication is needed, and playwright-cli for frontend/UI validation with one final screenshot per UI item. Use when the user invokes /verify or asks to verify checklist behaviours.
model: opus
argument-hint: "[--checklist <path>] [--base-url <url>] [--timeout <seconds>] [--ready-timeout <seconds>] [--start-cmd <command>] [--no-browser]"
---

# /verify - Behavioural Verification

Verify that an app behaves like a checklist says. The checklist can be any markdown file, not only files produced by `/interview-me` or `/fix`.

Results: `PASS`, `FAIL`, `TIMEOUT`, `ASSUMED`, `UNVERIFIABLE`.

## Arguments

Parse from the invocation string:

- `--checklist <path>` - checklist file. Optional only when one `.checklist/**/*.md` file can be auto-resolved.
- `--base-url <url>` - app base URL. Default: `http://localhost:3000`. Strip one trailing slash.
- `--timeout <seconds>` - per-item async wait limit. Default: `30`. Must be 1-600.
- `--ready-timeout <seconds>` - app startup wait limit. Default: `30`. Must be 1-600.
- `--start-cmd <command>` - override auto-detected app start command.
- `--no-browser` - skip frontend/UI validation. UI items become `UNVERIFIABLE`.

Invalid timeout values abort before any other work.

## Step 1 - Resolve Checklist

If `--checklist` is present, use that path and abort if it does not exist.

If absent, resolve from `.checklist/**/*.md` under the git root. If not in a git repo, resolve from `./.checklist/**/*.md`.

- Zero files: abort with `No checklist found. Pass --checklist <path>.`
- One file: use it and print `Using checklist: <path>`.
- Multiple files: print the list sorted newest first and abort with `Multiple checklists found. Specify one with --checklist <path>.`

Do not assume filename patterns like `INTERVIEW.md`, `FIX.md`, `prd-*.md`, or `fix-*`.

## Step 2 - Start Or Connect To App

Check whether the app is already reachable:

```bash
curl -s -o /dev/null --max-time 5 "<base-url>"
```

If reachable, set `APP_STARTED_BY_VERIFY=false`.

If unreachable, resolve a start command:

1. Use `--start-cmd` if provided.
2. Otherwise detect from project root:
   - `package.json` scripts in order: `dev`, `start`, `serve`, `preview`
   - `Procfile` `web:` command
   - `Cargo.toml` -> `cargo run`
   - `pyproject.toml`, `setup.py`, or `requirements.txt`:
     - `uvicorn` dependency -> `uvicorn main:app --reload` or `uvicorn app:app --reload`
     - `django` dependency -> `python manage.py runserver`
     - `flask` dependency -> `flask run`
   - `manage.py` -> `python manage.py runserver`
   - `Makefile` target: `run`, `serve`, or `start`

If no start command is found, abort and ask the user to start the app manually or rerun with `--start-cmd`.

Start the app in the background from project root, wait up to `--ready-timeout`, and always stop it before exit if `/verify` started it.

## Step 3 - Parse Checklist

Read the checklist file. If it starts with YAML frontmatter, strip the frontmatter before parsing.

Extract checklist items from:

- Markdown checkbox lines: `- [ ] ...`, `- [x] ...`
- Markdown bullets and numbered lists
- Plain prose sentences that describe observable expected behaviour

Preserve each item's source section heading. Classify by section heading first, then item wording.

### Section Classification

Backend/API sections:

- `API`
- `Backend`
- `Backend Validation`
- `Server`
- `HTTP`

Frontend/UI sections:

- `UI`
- `Frontend`
- `Frontend Validation`
- `UI Validation`
- `Browser`
- `Flow`

Generic sections like `Validation` are classified by item wording:

- API/backend wording includes HTTP verbs, status codes, endpoint paths, JSON fields, headers, webhooks, persisted reads, database-visible state through an API, or explicit backend/server terms.
- Frontend/UI wording includes page paths plus visible text, buttons, inputs, forms, modals, redirects, disabled/enabled state, toasts, browser interactions, or explicit frontend/UI terms.
- Ambiguous items go to cURL first. If cURL cannot infer an endpoint, send them to browser validation unless `--no-browser` was passed.

If no items are found, abort with `Checklist contains no behaviours: <path>`.

## Step 4 - Backend Auth Discovery

Use this step only when a backend/API item needs authentication or setup not stated in the checklist.

Run one bounded discovery pass in the project, capped at about 10 tool calls:

- Read obvious auth docs: README, API docs, `.env.example`, seed docs.
- Search for login/session/token routes.
- Search tests for seed users, default credentials, auth helpers, or bearer token setup.
- Search route definitions only enough to identify public auth endpoints and payload shape.

Do not inspect unrelated implementation details. Do not use private functions to verify behaviour. Discovery may find how to obtain credentials or tokens, but verification must still happen through HTTP requests against the running app.

If auth/setup still cannot be determined, ask the user for the missing information:

- Required user role or account
- Login endpoint and payload
- Token/cookie/header format
- Seed command or fixture needed

Until the user provides it, mark affected items `UNVERIFIABLE` with evidence like `Auth required; credentials/setup not found. Ask user for login details.`

## Step 5 - Backend/API Verification

Spawn or act as a backend verifier for backend/API items.

Use cURL only for app interaction:

```bash
curl -s -w "\n%{http_code}" --max-time <timeout> [flags] "<url>"
```

For each backend item:

1. Build the minimum request(s) from the checklist and any auth details found in Step 4.
2. Verify status code, response body, headers, fields, redirects, or exact messages.
3. For state changes, perform a follow-up GET or documented read endpoint to confirm persistence.
4. For async results, poll a relevant endpoint every 2-5 seconds up to `--timeout`.
5. If an item is vague, make the smallest reasonable inference and mark `ASSUMED` rather than `PASS`.

Never mark `PASS` without concrete HTTP evidence.

## Step 6 - Frontend/UI Verification

Skip this step when `--no-browser` is passed. Mark frontend/UI items as `UNVERIFIABLE` with evidence `Browser verification disabled`.

Resolve playwright-cli:

```bash
if which playwright-cli >/dev/null 2>&1; then
  BROWSER_CMD="playwright-cli"
elif npx --no-install playwright-cli --version >/dev/null 2>&1; then
  BROWSER_CMD="npx playwright-cli"
else
  BROWSER_CMD=""
fi
```

If unavailable, mark frontend/UI items `UNVERIFIABLE` with evidence `playwright-cli not found`.

Create a screenshot directory beside the checklist:

```bash
CHECKLIST_DIR_ABS="$(cd "$(dirname "<checklist-path>")" && pwd)"
CHECKLIST_STEM="$(basename "<checklist-path>" .md)"
SCREENSHOT_DIR="$CHECKLIST_DIR_ABS/$CHECKLIST_STEM-screenshots"
mkdir -p "$SCREENSHOT_DIR"
```

For each frontend/UI item, derive a screenshot filename from the item text:

1. Prefix with the 2-digit item number.
2. Take the first meaningful 6-10 words from the checklist item.
3. Lowercase, ASCII-fold when possible, replace non-alphanumeric runs with `-`.
4. Trim leading/trailing dashes.
5. Append `.png`.

Examples:

- Item 3: `Given a user is on /login and email is empty, when they click Sign in, then Email is required appears` -> `03-login-email-empty-sign-in-email-required.png`
- Item 12: `Given checkout is submitting, when the request is pending, then Pay now is disabled` -> `12-checkout-submitting-pay-now-disabled.png`

If two items produce the same slug, the item number keeps filenames unique.

Drive the browser with `playwright-cli` only. Use one session name per `/verify` run:

```bash
BROWSER_SESSION="verify-$(date +%s)-$$"
```

For each frontend/UI item:

1. Open or navigate to the page/path stated in the item. If no path can be inferred, mark `UNVERIFIABLE`.
2. Interact with visible controls using roles, labels, text, test ids, or refs from snapshots.
3. Validate visible text, DOM state, URL/redirect, enabled/disabled state, or form values.
4. Wait for async UI changes by polling snapshots until `--timeout`.
5. Capture one final screenshot after validation, regardless of pass/fail when the browser reached a relevant page:

```bash
<browser-cmd> -s=<browser-session> screenshot --filename="<SCREENSHOT_DIR>/<item-derived-filename>"
```

Evidence for every frontend/UI item that reached the browser must include `[screenshot: <filename>]`.

Close the browser session during cleanup even when validation fails.

## Step 7 - Merge And Report

Produce one report for all items in original checklist order.

```markdown
## Verification Report

| # | Item | Type | Status | Evidence |
|---|------|------|--------|----------|
| 1 | <short item text> | backend | PASS | POST /login -> 200, token returned |
| 2 | <short item text> | frontend | FAIL | Text not visible at /login [screenshot: 02-login-error-message.png] |

## Summary

- Total: N
- PASS: N
- FAIL: N
- TIMEOUT: N
- ASSUMED: N
- UNVERIFIABLE: N
```

Only include `Items Requiring Attention` when there are `FAIL`, `TIMEOUT`, or `UNVERIFIABLE` items:

```markdown
## Items Requiring Attention

### #N - <item text>

Expected: <expected behaviour>
Observed: <observed behaviour or missing setup>
Next step: <fix app / improve checklist / ask user for auth details>
```

When any item is `FAIL` or `TIMEOUT`, also print a `/fix` handoff block for each affected item. Do not run `/fix` automatically.

```markdown
## Fix Handoff

### #N - <item text>

Run:
`/fix <short bug title>`

Actual behaviour: <observed behaviour/evidence from verification>
Expected behaviour: <expected behaviour from checklist item>
Checklist: <checklist-path>
```

## Rules

- Verify arbitrary checklist files; do not require `/interview-me`, `/fix`, `INTERVIEW.md`, or `FIX.md` provenance.
- Prefer cURL for backend/API validation.
- Use bounded codebase discovery only to find auth/setup information required to make external HTTP requests.
- If special authentication cannot be discovered, ask the user for the missing details and mark affected items `UNVERIFIABLE` until provided.
- Use `playwright-cli` for frontend/UI validation.
- Capture one final screenshot for each frontend/UI item that reaches a browser page.
- Screenshot filenames must follow the checklist item text, not generic `item-<#>.png`.
- When `FAIL` or `TIMEOUT` appears, suggest `/fix` with actual behaviour, expected behaviour, and checklist path. Never auto-fix from `/verify`.
- Never mark vague items `PASS`; use `ASSUMED` and state the inference.
- Always stop the app and close browser sessions that `/verify` started.

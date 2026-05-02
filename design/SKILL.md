---
name: design
description: Generate an HTML mockup for a screen/page before implementing it. Invoked explicitly as /design [--path <dir>] <feature-name>. Does NOT auto-trigger on "implement screen" — only fires when user types /design. Saves versioned mockups to <base-dir>/<slug>/ (default ~/.design/, override with --path), serves them with live-server, opens them in Cursor's browser via the IDE browser MCP (cursor-ide-browser), captures a screenshot via playwright-cli, and asks for approval via AskUserQuestion before proceeding to code.
argument-hint: "[--path <dir>] <feature-name or description>"
---

Generate an HTML mockup for the requested screen, get user approval, then implement. Follow these steps exactly.

## Step 0 — Parse arguments

Parse the invocation arguments before doing anything else:

- Optional flag: `--path <dir>` — overrides where mockups are written. Accepts an absolute path or a path starting with `~` (which must be expanded to `$HOME`).
- All remaining positional arguments form the feature name / description.

Resolve the base directory:

```bash
# Default
BASE_DIR="$HOME/.design"

# If --path was passed, replace BASE_DIR with the resolved value
if [ -n "$PATH_FLAG" ]; then
  case "$PATH_FLAG" in
    "~"|"~/"*) BASE_DIR="${HOME}${PATH_FLAG#\~}" ;;
    /*)        BASE_DIR="$PATH_FLAG" ;;
    *)         BASE_DIR="$(cd "$(dirname "$PATH_FLAG")" 2>/dev/null && pwd)/$(basename "$PATH_FLAG")" ;;
  esac
fi

mkdir -p "$BASE_DIR"
```

Throughout the rest of this skill, every reference to `~/.design/<slug>/` means `$BASE_DIR/<slug>/`. Direct user invocations without `--path` keep the legacy `~/.design/` location for backward compatibility; callers like `/write-a-prd` will pass `--path "$(git rev-parse --show-toplevel)/.design"` to keep mockups inside the repo.

## Step 1 — Detect UI library

Locate `package.json`:
- Single-package repo: read `./package.json`.
- Monorepo (workspace at root + `packages/*` or `apps/*`): prefer the frontend package's own `package.json`. If multiple frontend packages exist, ask the user which one to design for.
- No `package.json` found (e.g. backend-only repo, non-JS project): skip library detection and use plain HTML + CSS with a clean modern style. Note this to the user.

Look for these libraries in `dependencies` or `devDependencies`:

| Library | CDN to use in mockup |
|---------|----------------------|
| `antd` | `https://unpkg.com/antd/dist/antd.min.js` + `https://unpkg.com/antd/dist/antd.min.css` |
| `@mui/material` | `https://unpkg.com/@mui/material@latest/umd/material-ui.production.min.js` |
| `@chakra-ui/react` | Use inline Tailwind-like styles instead (Chakra has no simple CDN) |
| `tailwindcss` | `https://cdn.tailwindcss.com` |
| `@mantine/core` | `https://unpkg.com/@mantine/core/esm/index.js` (or inline styles) |
| `react-bootstrap` | Bootstrap CDN: `https://cdn.jsdelivr.net/npm/bootstrap/dist/css/bootstrap.min.css` |

If no recognized library is found, use plain HTML + CSS with a clean modern style.

Also check if `DESIGN.md` exists in the repo root — if it does, read it and extract color tokens, typography, spacing, and component rules to apply in the mockup.

## Step 2 — Read one existing page for layout patterns

Glob the project's page directory — common patterns: `frontend/src/pages/*.{tsx,jsx,vue,svelte}`, `src/pages/*`, `pages/*`, `app/*` (Next.js app router), `src/routes/*` (SvelteKit/SolidStart). Adapt to repo structure. If no pages directory exists (component library, brand-new repo), skip this step and use a generic clean layout.

Pick a representative page (prefer a list/table page). Read it to understand:
- Sidebar width and colors
- Topbar/header structure
- Page padding and container width
- Typography scale

## Step 3 — Determine slug and version

- Convert the feature name to kebab-case slug (e.g. "payment history" → `payment-history`, "User Settings" → `user-settings`)
- Run: `ls "$BASE_DIR/<slug>/" 2>/dev/null` to list existing files
- Find the highest existing version number (v1, v2, v3...)
- Next version = highest + 1, or v1 if none exist

## Step 4 — Generate HTML mockup

Write a fully self-contained HTML file with:

- `<!DOCTYPE html>` with all CSS/JS loaded via CDN (no external file references)
- Layout matching the existing app shell: sidebar on left, topbar at top, content area
- The new screen's UI in the content area
- Realistic placeholder data — actual names, numbers, dates (NOT "Lorem ipsum", NOT "Sample text", NOT "John Doe")
- Interactive states where possible (hover, selected row, etc.) using the library's components
- Responsive behavior where the feature warrants it

The mockup must be visually close to what the final implementation will look like. Do not use placeholder boxes or generic layouts — make it look like a real screen.

## Step 5 — Save and open

```bash
mkdir -p "$BASE_DIR/<slug>"
# write the file to $BASE_DIR/<slug>/vN.html
```

After the file exists on disk:

1. **Resolve the mockup directory and filename** (e.g. `DIR="$BASE_DIR/<slug>"`, `FILE="vN.html"`). Do not build or use a `file://` URL for Cursor's embedded browser; the browser MCP only supports `http://` and `https://`.
2. **Serve the mockup directory over localhost** using `npx live-server`:

```bash
npx -y live-server "$BASE_DIR/<slug>" --host=127.0.0.1 --port=<free-port> --no-browser
```

- Before starting, check whether a live-server process is already serving the same `$BASE_DIR/<slug>` directory; reuse it if possible instead of starting a duplicate.
- Use a high, likely-free port such as `43117`; if it is occupied, choose another. Remember the chosen port — Step 6.5 reuses it for the screenshot capture.
- Start this as a background command and wait until the terminal output shows it is serving.

3. **Open in Cursor’s embedded browser:** if the **`cursor-ide-browser`** MCP is available, inspect `browser_navigate`’s descriptor, then invoke it with `url`: `http://127.0.0.1:<port>/vN.html`, **`position`: `"side"`** (preview beside the editor), **`newTab`: `true`** (avoid clobbering an unrelated tab), and optionally `take_screenshot_afterwards`: `true` for visual confirmation.

**Fallback** when `npx live-server` or the MCP browser is unavailable: open with the OS default app using the resolved absolute path: macOS `open "$ABS_PATH"`, Linux `xdg-open "$ABS_PATH"` (Wayland/Linux without xdg-open: try `gio open`), Windows CMD `cmd /c start "" "$ABS_PATH"` — and tell the user the browser MCP could not open the localhost preview.

Tell the user:
> Mockup saved to `$BASE_DIR/<slug>/vN.html` — opening in Cursor’s browser now.

## Step 6 — Ask for approval

Use AskUserQuestion with exactly these options:

```
Question: "How does the mockup look?"
Options:
  - "Looks good — proceed to code"
  - "Need changes"
  - "Start over"
```

**If "Looks good"** → proceed to Step 6.5 (screenshot capture), then Step 7.

**If "Need changes"** → ask the user what to change (one follow-up question or free text), then return to Step 4 with the changes applied. Increment the version number (e.g. v1 → v2). Repeat from Step 4.

**If "Start over"** → ask the user to describe what they want differently, then return to Step 1.

## Step 6.5 — Capture screenshot with playwright-cli

Runs only after the user picks "Looks good — proceed to code". Reuse the live-server URL already running from Step 5.

1. **Ensure Chromium is installed for playwright** (idempotent — only downloads on first use):

   ```bash
   npx -y playwright install --with-deps chromium 2>/dev/null || npx -y playwright install chromium
   ```

2. **Capture the screenshot** with `npx playwright screenshot`. Pick the viewport(s) based on what the user (or the calling skill) requested for this mockup; default is desktop only.

   Desktop (default):

   ```bash
   npx -y playwright screenshot \
     --viewport-size=1440,900 \
     --full-page \
     --wait-for-timeout=500 \
     "http://127.0.0.1:${PORT}/vN.html" \
     "$BASE_DIR/<slug>/vN.png"
   ```

   Mobile (if the mockup is mobile-first or the caller requested mobile):

   ```bash
   npx -y playwright screenshot \
     --viewport-size=390,844 \
     --device="iPhone 14" \
     --full-page \
     --wait-for-timeout=500 \
     "http://127.0.0.1:${PORT}/vN.html" \
     "$BASE_DIR/<slug>/vN-mobile.png"
   ```

   When the caller requested **both** viewports, write both files (`$BASE_DIR/<slug>/vN-desktop.png` and `$BASE_DIR/<slug>/vN-mobile.png`) and report both paths back in the final output. In that case the desktop path takes precedence in the `png=` field.

3. **On screenshot failure** (playwright install fails, the live-server URL is unreachable, the chromium download is blocked by network policy, etc.) print a one-line warning like `warn: screenshot capture failed (<reason>); continuing without PNG` and continue. Set `PNG_PATH=NONE` for the final output line. Downstream callers (`/write-a-prd`) tolerate a missing screenshot.

## Step 6.6 — Final output contract

Print exactly one line on stdout (last line of skill output) that callers parse:

```
DESIGN_APPROVED slug=<slug> html=<absolute-html-path> png=<absolute-png-path-or-NONE>
```

Examples:

```
DESIGN_APPROVED slug=dashboard html=/Users/me/repo/.design/dashboard/v2.html png=/Users/me/repo/.design/dashboard/v2.png
DESIGN_APPROVED slug=order-detail html=/Users/me/repo/.design/order-detail/v1.html png=NONE
```

Use absolute paths in both fields. The `slug` field must exactly match the slug computed in Step 3.

## Step 7 — Implement

Only after the user approves the mockup and the screenshot has been captured (or skipped):

- Implement the actual React/TypeScript (or whatever the repo uses) code
- Reference the approved mockup's structure, component choices, and layout
- Follow all repo conventions (i18n, TypeScript types, existing patterns)
- Do NOT re-create the mockup file — it stays as a reference artifact

When `/design` is invoked by another skill (e.g. `/write-a-prd`) the caller will skip Step 7 — it only consumes the `DESIGN_APPROVED` line. In that case, after printing the line, exit without writing implementation code.

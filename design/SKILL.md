---
name: design
description: Generate an HTML mockup for a screen/page before implementing it. Invoked explicitly as /design [--path <dir>] <feature-name>. Spawns one readonly Explore subagent to discover the frontend package, all DESIGN.md files repo-wide, and representative pages; parent reads those artifacts before generating HTML. Does NOT auto-trigger on "implement screen" — only fires when user types /design. Saves versioned mockups to <base-dir>/<slug>/ (default ~/.design/, override with --path), serves them with live-server, opens them in Cursor's browser via the IDE browser MCP (cursor-ide-browser), captures a screenshot via playwright-cli, and asks for approval via AskUserQuestion before proceeding to code.
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

Throughout the rest of this skill, every reference to `~/.design/<slug>/` means `$BASE_DIR/<slug>/`. Direct user invocations without `--path` keep the legacy `~/.design/` location for backward compatibility; callers may pass `--path "$(git rev-parse --show-toplevel)/.design"` to keep mockups inside the repo.

## Step 1 — Explore codebase (Explore subagent)

**Skip if upstream already explored.** If the caller (e.g. `interview-me`) already passed the structured codebase context this step produces — repo root, primary frontend `package.json` path, every `DESIGN.md` path, and 1–2 representative UI files — reuse it and jump to Step 2. Run a **single additional** bounded explore pass only if a specific needed artifact is missing (e.g. a layout file the caller didn't surface); do not chain open-ended explore loops.

Otherwise, before reading files yourself, invoke **one** readonly exploration pass (same bounded pattern as the **`improve-codebase-architecture`** skill).

- Use the **Agent** or **Task** tool with **`subagent_type`: `explore`** (Cursor) or **`subagent_type=Explore`** (Claude Code) — same intent, different product casing.
- **Readonly:** the subagent must not edit files.
- **Default cap:** **one** subagent call. Use a **second** call only if the user must disambiguate multiple frontends after you ask them which app/package to design for — do not chain open-ended explore loops.

Pass the subagent a brief that includes the **feature name / description** from Step 0 (so it knows what UI context matters). Require a **structured reply** the parent will use in Step 2:

1. **Repo root** (or workspace root) path.
2. **Primary frontend `package.json` path** — which file to use for dependency/CDN detection; if monorepo, state which app/package was chosen and why (or flag ambiguity).
3. **All design-spec file paths** — every file named **`DESIGN.md` case-insensitively** (e.g. `DESIGN.md`, `design.md`) anywhere under the repo, **excluding** `node_modules/`, `.git/`, `dist/`, `build/`, `.next/`, `out/`, and other generated/vendor trees the subagent can reasonably skip.
4. **1–2 representative UI file paths** for app chrome — prefer a list/table route if present; paths to components/layout that show sidebar, header, main padding, container width, typography if no full page exists.
5. **Short bullets:** routing style (e.g. Next `app/`, `pages/`, SPA), where the shell/layout lives if obvious.

If the repo is huge or ambiguous, the subagent should return **best-effort paths** and mark **uncertain** areas; you may ask the user **one** disambiguation question instead of spawning more explorers.

The subagent may **recommend** which `DESIGN.md` is most relevant to the feature; you still read **every** listed design-spec file in Step 2 unless the user explicitly narrows scope.

## Step 2 — Read synthesis (parent agent)

You (the parent agent), not the subagent:

### 2a — `package.json` and UI library

Read the **primary frontend `package.json`** from Step 1. If none was found (backend-only, non-JS): skip library detection, use plain HTML + CSS with a clean modern style, and note this to the user. If multiple frontends were flagged ambiguous: ask the user which `package.json` to use before continuing.

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

### 2b — All `DESIGN.md` files

Read **every** design-spec path returned in Step 1. Extract color tokens, typography, spacing, and component rules; **apply all** in the mockup.

**Conflict rule:** if the same token or rule is defined differently in multiple files, prefer the file whose directory is **closest to the primary frontend package root** (longest shared path prefix / nearest ancestor). If still tied, prefer the **shallower** path (fewer segments from repo root). If still tied, **alphabetical** full path. Print **one user-visible line** per conflict: which keys conflicted and which file won.

### 2c — Representative pages for layout

Read the **1–2 representative UI files** from Step 1. From them, infer:

- Sidebar width and colors
- Topbar/header structure
- Page padding and container width
- Typography scale

If Step 1 found no suitable files (component library, brand-new repo), skip this subsection and use a generic clean layout in Step 4.

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

## Step 6.5 — Final output contract

Print exactly one line on stdout (last line of skill output) that callers parse:

```
DESIGN_APPROVED slug=<slug> html=<absolute-html-path>
```

Examples:

```
DESIGN_APPROVED slug=dashboard html=/Users/me/repo/.design/dashboard/v2.html
DESIGN_APPROVED slug=order-detail html=/Users/me/repo/.design/order-detail/v1.html
```

Use absolute paths in both fields. The `slug` field must exactly match the slug computed in Step 3.

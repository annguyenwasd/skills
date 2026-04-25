---
name: design
description: Generate an HTML mockup for a screen/page before implementing it. Invoked explicitly as /design <feature-name>. Does NOT auto-trigger on "implement screen" — only fires when user types /design. Saves versioned mockups to ~/.design/<slug>/ and opens them in the browser. Asks for approval via AskUserQuestion before proceeding to code.
argument-hint: <feature-name or description>
---

Generate an HTML mockup for the requested screen, get user approval, then implement. Follow these steps exactly.

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
- Run: `ls ~/.design/<slug>/ 2>/dev/null` to list existing files
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
mkdir -p ~/.design/<slug>
# write the file to ~/.design/<slug>/vN.html
open ~/.design/<slug>/vN.html
```

Tell the user:
> Mockup saved to `~/.design/<slug>/vN.html` — opening in browser now.

## Step 6 — Ask for approval

Use AskUserQuestion with exactly these options:

```
Question: "How does the mockup look?"
Options:
  - "Looks good — proceed to code"
  - "Need changes"
  - "Start over"
```

**If "Looks good"** → proceed to Step 7.

**If "Need changes"** → ask the user what to change (one follow-up question or free text), then return to Step 4 with the changes applied. Increment the version number (e.g. v1 → v2). Repeat from Step 4.

**If "Start over"** → ask the user to describe what they want differently, then return to Step 1.

## Step 7 — Implement

Only after the user approves the mockup:

- Implement the actual React/TypeScript (or whatever the repo uses) code
- Reference the approved mockup's structure, component choices, and layout
- Follow all repo conventions (i18n, TypeScript types, existing patterns)
- Do NOT re-create the mockup file — it stays as a reference artifact

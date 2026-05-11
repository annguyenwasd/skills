---
name: design
description: Generate an HTML design mockup for a requested UI change, matching the current app's UI library, design principles, and nearby screens. Use when the user explicitly invokes /design, or when another skill such as interview-me needs a mockup for a screen, layout, component, or visual change.
argument-hint: "[--path <dir>] [--slug <slug>] [--yolo] <feature-name or UI change>"
---

# Design

Create a focused HTML mockup, iterate with the user, stop only when approved or explicitly skipped.

## Inputs

Parse arguments first:

- `--path <dir>`: optional output directory from an upstream caller (e.g. `interview-me`).
- `--slug <slug>`: optional slug; if provided, use it verbatim and skip kebab-casing.
- `--yolo`: optional; auto-approve the first version and skip the approval loop.
- remaining words: feature name or UI change description.

If no feature name is provided, ask once what screen or UI change to design, then stop.

## Output Location

Two schemes — both intentional:

- Explicit `/design <feature>` call: write to `./design/<slug>/vN.html` (versioned folder).
- Called with `--path <dir>` (e.g. by `interview-me`): write to `<dir>/design-<slug>-vN.html` (flat, alongside `INTERVIEW.md` which the caller will write later).

Slug rules:

- If `--slug` is passed, use it verbatim.
- Otherwise kebab-case the feature name (e.g. "Payment History" → `payment-history`).

Each iteration increments `vN`; never overwrite a previous version. If a version with the same N already exists on disk (stale files from earlier runs), pick the next free N.

## Explore First

**Skip exploration entirely if the caller already supplied structured codebase context** — frontend `package.json` path, every relevant `DESIGN.md` path, and the current screen/component paths that will change. In that case, jump to "Respect Existing UI".

Otherwise run one bounded discovery pass.

Find and read:

- current frontend package and UI stack (`package.json`, imports, component library, CSS framework)
- every relevant `DESIGN.md` or `design.md`
- the current screen, route, component, or nearby app shell that will be changed
- the specific parts that need to change, be added, modified, or removed

Prefer an `explore` subagent for repo discovery when available. Keep it bounded: one pass, then the parent reads the returned files. If multiple frontends are plausible, ask which one to design for.

## Respect Existing UI

The mockup must look like the current product, not a generic landing page.

Use the existing UI library and visual conventions:

- component library, spacing, colors, typography, borders, shadows, density
- app shell, navigation, headers, modals, forms, tables, empty states
- current content patterns and realistic domain data

Only design the changed area. For surrounding UI:

- render it lightly if context is needed
- gray it out, reduce opacity, or simplify it
- omit it when it does not help the design decision

Do not redesign unrelated parts of the screen.

## Generate Mockup

Create one self-contained HTML file:

- include all CSS and JS inline or via CDN
- no build step
- realistic data, not lorem ipsum
- enough interaction/state to judge the design
- visual annotations only when they help the user understand what changed

Save to the next version path derived above.

## Open When Done

After saving each version, open it with the platform's default opener. Opening is best-effort — if it fails (headless, CI, missing binary), print the absolute path and continue.

```bash
FILE="<absolute file path>"
case "$(uname -s)" in
  Darwin)               open "$FILE" ;;
  Linux)                xdg-open "$FILE" >/dev/null 2>&1 || gio open "$FILE" >/dev/null 2>&1 || printf 'Open manually: %s\n' "$FILE" ;;
  MINGW*|MSYS*|CYGWIN*) start "" "$FILE" ;;
  *)                    printf 'Open manually: %s\n' "$FILE" ;;
esac
```

## Approval Loop

### `--yolo` mode

Generate v1, open it, and stop. **Do not ask for approval.** The user will review the mockup on their own time.

Emit one line on stdout (the last line):

```text
DESIGN_GENERATED slug=<slug> html=<absolute-html-path>
```

Callers must treat `DESIGN_GENERATED` as "mockup exists, not approved yet". They continue without blocking, but should flag the design as pending user review.

### Normal mode

After opening the mockup, ask:

Question: `Approve?`

Options:

- `Approved`
- `Need changes`
- `Start over`
- `Skip design`

Behaviour per option:

- `Approved` → emit `DESIGN_APPROVED` (see below) and stop.
- `Need changes` → ask what to change, create v(N+1), open it, ask `Approve?` again.
- `Start over` → ask what direction to use, create v(N+1) from that direction, open it, ask `Approve?` again.
- `Skip design` → emit `DESIGN_SKIPPED` and stop. The caller continues without a mockup.

Loop cap: at most 5 iterations. If the user picks `Need changes` or `Start over` a 6th time, stop the loop and emit `DESIGN_ABORTED reason=iteration-limit`.

## Approved output

Print exactly one line on stdout (the last line):

```text
DESIGN_APPROVED slug=<slug> html=<absolute-html-path>
```

## Skipped / aborted output

For `Skip design`:

```text
DESIGN_SKIPPED slug=<slug>
```

For loop exhaustion:

```text
DESIGN_ABORTED slug=<slug> reason=iteration-limit
```

Callers (e.g. `interview-me`) must treat `DESIGN_SKIPPED` and `DESIGN_ABORTED` as opt-out signals and continue without a mockup.

---
name: prd-to-issues
description: Break a PRD into independently-grabbable GitHub issues using tracer-bullet vertical slices. Use when user wants to convert a PRD to issues, create implementation tickets, or break down a PRD into work items.
---

# PRD to Issues

Break a PRD into independently-grabbable GitHub issues using vertical slices (tracer bullets).

## Process

### 1. Locate the PRD

Ask the user for the PRD GitHub issue number (or URL).

If the PRD is not already in your context window, fetch it with `gh issue view <number>` (with comments).

After reading the PRD body, extract the UI block:
1. **New format (preferred)** — extract the verbatim text of these sections if present: `## UI Screens`, `## Screen Flow`, `## State Flow`. Concatenate (in that order, with blank lines between) into `PRD_UI_BLOCK`. Also extract the list of Screen IDs (each `### Screen: <ID>` heading, stripping any `🔒` auth prefix) into `PRD_SCREEN_IDS`.
2. **Legacy format (backwards compat)** — if `## UI Screens` is absent but the body contains `## UI Mockup`, parse the Gist URL from `[View HTML mockup on GitHub Gist](<url>)` into `PRD_MOCKUP_URL`. Set `PRD_UI_BLOCK = null`.
3. If neither is present: `PRD_UI_BLOCK = null`, `PRD_MOCKUP_URL = null`, `PRD_SCREEN_IDS = []`.

### 2. Explore the codebase (optional)

If you have not already explored the codebase, do so to understand the current state of the code.

### 3. Draft vertical slices

Break the PRD into **tracer bullet** issues. Each issue is a thin vertical slice that cuts through ALL integration layers end-to-end, NOT a horizontal slice of one layer.

Slices may be 'HITL' or 'AFK'. HITL slices require human interaction, such as an architectural decision or a design review. AFK slices can be implemented and merged without human interaction. Prefer AFK over HITL where possible.

<vertical-slice-rules>
- Each slice delivers a narrow but COMPLETE path through every layer (schema, API, UI, tests)
- A completed slice is demoable or verifiable on its own
- Prefer many thin slices over few thick ones
- When `uiInvolved == true` and the slice makes API calls: enumerate the distinct backend error strings for each endpoint. Acceptance criteria MUST include one criterion per error string: map it to an i18n key under the feature's section, add it to both `en.json` and `vi.json`, and display the friendly message using Pattern C (inspect `e.response?.data?.error` and `e.response?.status`, map to specific i18n key, fall through to `common.errorGeneric`). Slices with no API calls produce an empty list — no additional criteria required.
</vertical-slice-rules>

For each slice, determine `uiInvolved`: set to `true` if the slice description, acceptance criteria, or user stories reference any of: page, screen, component, form, dialog, modal, table, button, chart, dashboard, UI, frontend, view, layout. Otherwise `false`.

### 3.5. §gap-check

Perform automated coverage analysis before presenting slices to the user.

1. **Extract requirements** from PRD_BODY: section headings, bullet-point features, acceptance criteria sentences, explicit user stories. Label each `REQ-N` in order of appearance.

2. **Map each REQ to slice(s)**: identify which slice(s) address it by matching against `prdSection` and semantic overlap. A REQ may map to multiple slices.

3. **Identify gaps**: REQs mapped to zero slices.

4. **Build coverage map**: `{ "REQ-1": [slice-id, ...], "REQ-2": [] }` — empty arrays are gaps.

Store the coverage map for display in step 4.

### 3.6. Detect supplemental flows

Determine whether a **screen-flow DAG** or **process-flow DAG** would add information that the execution-wave DAG does not already show:

- Execution DAG answers: *when* does each slice run and what does it depend on?
- Screen-flow DAG answers: *what screens does the user navigate between?*
- Process-flow DAG answers: *what steps does a business process go through?*

Render a supplemental DAG **only** when it shows structure invisible in the execution DAG (e.g., a 5-screen wizard whose slices all land in Wave 1 and appear flat there). If the execution DAG already communicates the same ordering, skip it.

### 4. Quiz the user

Present to the user in this order:

**1. Gap report** (only if any REQs have empty coverage from §gap-check):

```
⚠ COVERAGE GAPS — N requirements unaddressed:
  REQ-3  "admin can export audit log as CSV"  → no slice covers this
  REQ-7  "rate-limit per API key"             → no slice covers this

For each gap: [a] add a new slice  [s] skip (out of scope)  [m] merge into existing #X
```

**2. Execution DAG** — always render, using box-drawing characters and wave containers:

```
┌─ Wave 0 (parallel — start immediately) ──────────────────────┐
│  [#1] <displayTitle> [AFK]                                   │
│  [#2] <displayTitle> [AFK]                                   │
└──────────────────────────────────────────────────────────────┘
                       │
                       ▼
┌─ Wave 1 (after Wave 0) ───────────────────────────────────────┐
│  [#3] <displayTitle> [AFK]                                   │
└──────────────────────────────────────────────────────────────┘

Edges: #1 → #3   #2 → #3
```

**3. Supplemental DAG** (only if step 3.6 determined it adds information):

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

**4. Slice breakdown** — numbered list. For each slice, show:

- **Title**: short descriptive name
- **Type**: HITL / AFK
- **Blocked by**: which other slices (if any) must complete first
- **User stories covered**: which user stories from the PRD this addresses
- **REQs covered**: which REQ-N labels from the coverage map

Ask the user:

- Does the granularity feel right? (too coarse / too fine)
- Are the dependency relationships correct?
- Should any slices be merged or split further?
- Are the correct slices marked as HITL and AFK?
- Resolve any gaps from the gap report (`[a]`/`[s]`/`[m]` for each).

Iterate until the user approves the breakdown and all gaps are resolved or explicitly skipped.

### 5. Create the GitHub issues

**Preflight check:**

```bash
gh auth status >/dev/null 2>&1 || { echo "gh CLI not authenticated"; exit 1; }
```

**Final approval gate.** After Step 4 iteration converges, render a confirmation summary: number of issues to create, the parent PRD label, and the slice titles in dependency order. Use AskUserQuestion: "Create N issues now?" / "Hold — let me revise". Do not call `gh issue create` until the user confirms.

If the breakdown produced 0–1 slices, surface this to the user before creating ("PRD looks small enough that a single issue may suffice — proceed anyway?"). If it produced more than 20 slices, surface this too ("This will create 23 issues. Proceed, or split the PRD?").

Then ensure the `PRD-<prd-issue-number>` label exists:

```bash
gh label create "PRD-<prd-issue-number>" --color 0EA5E9 --description "Slice of PRD #<prd-issue-number>" 2>/dev/null || true
```

For each approved slice, create a GitHub issue using `gh issue create` with `--label "PRD-<prd-issue-number>"`. Use the issue body template below.

Create issues in dependency order (blockers first) so you can reference real issue numbers in the "Blocked by" field.

<issue-template>
## Parent PRD

#<prd-issue-number>

## What to build

A concise description of this vertical slice. Describe the end-to-end behavior, not layer-by-layer implementation. Reference specific sections of the parent PRD rather than duplicating content.

## Acceptance criteria

- [ ] Criterion 1
- [ ] Criterion 2
- [ ] Criterion 3

## Blocked by

- Blocked by #<issue-number> (if any)

Or "None - can start immediately" if no blockers.

## User stories addressed

Reference by number from the parent PRD:

- User story 3
- User story 7

<!-- CONDITIONAL: include only when uiInvolved == true AND PRD_UI_BLOCK != null -->

<PRD_UI_BLOCK verbatim — `## UI Screens`, `## Screen Flow`, and (if present) `## State Flow` from the parent PRD>

> Visual specification from the parent PRD. Implement to match these wireframes and flows. Screen IDs are stable identifiers — use them in test names and component names where natural.

<!-- END CONDITIONAL -->

<!-- CONDITIONAL (legacy): include only when uiInvolved == true AND PRD_UI_BLOCK == null AND PRD_MOCKUP_URL != null -->

## UI Mockup

[View HTML mockup on GitHub Gist](<PRD_MOCKUP_URL>)

> Visual specification from the parent PRD (legacy Gist format). Implement to match this mockup.

<!-- END CONDITIONAL -->

<!-- CONDITIONAL: include only when uiInvolved == true -->

## API errors to cover

| Backend `error` string | i18n key | Friendly EN message | Friendly VI message |
|---|---|---|---|
| `some_error` | `featureSection.someError` | Human-readable English | Human-readable Vietnamese |

If this slice makes no API calls: "None — no API calls in this slice."

All catch handlers must use Pattern C: inspect `e.response?.data?.error` + `e.response?.status`, map to specific i18n key, fall through to `common.errorGeneric`. Never pass raw server strings to the UI.

<!-- END CONDITIONAL -->

</issue-template>

Do NOT close or modify the parent PRD issue.

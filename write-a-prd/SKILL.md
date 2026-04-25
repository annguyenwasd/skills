---
name: write-a-prd
description: Create a PRD through user interview, codebase exploration, and module design, then submit as a GitHub issue. Use when user wants to write a PRD, create a product requirements document, or plan a new feature.
---

This skill will be invoked when the user wants to create a PRD. You may skip steps if you don't consider them necessary.

1. Ask the user for a long, detailed description of the problem they want to solve and any potential ideas for solutions.

2. Explore the repo to verify their assertions and understand the current state of the codebase.

3. Pressure-test the plan with `grill-me` (engineer framing) or `interview-me` (non-technical client framing). Pick by scanning the user's Step 1 description:

   - Use **`grill-me`** if the description contains ≥2 technical terms (API, endpoint, schema, table, column, queue, cache, race, idempotency, transaction, migration, deploy, refactor, module, component, hook, lambda, container, type, interface, library/framework names).
   - Use **`interview-me`** if the description is dominated by domain/business language (customer, order, invoice, vendor, staff, refund, policy, regulation, workflow, approval) with no implementation detail.
   - **Mixed or unclear** → ask once: "Should I grill you engineer-to-engineer (technical decisions, jargon OK) or interview you in plain business terms?" Single AskUserQuestion with two options. Default to `grill-me` if the user skips.

   Walk every branch until decisions are Resolved or Deferred. Open questions must be resolved before writing the PRD.

   **Skip the interview** if the user already says "I just ran /grill-me" or "/interview-me" and pastes a Resolved Plan — proceed to Step 4 with that as the input.

3.5. **Detect whether this PRD involves UI changes, and if so, resolve the mockup.**

After completing the interview, scan the notes and conversation for these signals:

**Triggers UI mockup flow (any one is sufficient):**
- A new page or screen will be created
- An existing page or screen will be visually modified
- A new UI component, form, dialog, modal, or dashboard element will be added
- The user explicitly mentions "design", "layout", "looks like", or "UI"

**Skip UI mockup flow (all of these apply):**
- The change is API-only (new endpoint, changed contract, no frontend consumer)
- The change is schema/migration-only
- The change is an internal background job, worker, or CLI tool
- The change is CI, infra, or config only

**If ambiguous**, use AskUserQuestion:
- Question: "Does this PRD involve any changes to the UI (new pages, modified screens, new components)?"
- Options: "Yes — includes UI changes" / "No — backend/API only"

**If UI is involved — check for existing design before generating:**

**Step A: Detect existing design**

Check whether a design already exists from a prior `/grill-me` or `/design` session:
1. Derive the slug from the PRD title (e.g. "Payment History Page" → `payment-history`).
2. Run `ls ~/.design/<slug>/` — if versioned HTML files exist, an approved design is available.
3. Also scan the conversation for: a file path ending in `.html`, a GitHub Gist URL, or an explicit "here is my design" reference from the user.

**Step B: Present options based on what was found**

Use AskUserQuestion with the appropriate question:

- **If existing design file(s) found** (`~/.design/<slug>/vN.html` exists):
  - Question: "Found an existing design for this feature. How do you want to proceed?"
  - Options:
    - "Use as-is — approve the existing mockup"
    - "Enhance it — refine the existing mockup before approving"
    - "Start fresh — ignore existing and generate a new mockup"

- **If user provided a design path or Gist URL** but no local file:
  - Read/fetch the provided design. Display it to the user and ask:
  - Question: "You provided an existing design. How do you want to proceed?"
  - Options:
    - "Use as-is — approve this design"
    - "Enhance it — refine this design before approving"
    - "Start fresh — generate a new mockup instead"

- **If no existing design found and none provided:**
  - Proceed directly to generating a new mockup (Step C below).

**Step C: Act on the user's choice**

- **"Use as-is"**: Record the existing slug and version number N. Skip to the Gist creation step below.
- **"Enhance it"**: Read the design skill at `~/.claude/skills/design/SKILL.md`. Load the existing HTML as the starting version, then follow Steps 4–6 of that skill (iteration loop) until the user approves. Do NOT run Step 7.
- **"Start fresh"** or **no existing design**: Read the design skill at `~/.claude/skills/design/SKILL.md`. Follow Steps 1 through 6 of that skill exactly, using the PRD feature name as the feature argument. Do NOT run Step 7.

IMPORTANT CONSTRAINTS (all paths):
- Derive the slug from the PRD title (e.g. "Payment History Page" → `payment-history`).
- Loop through revision steps until the user selects "Looks good — proceed to code".
- Record the final approved `<slug>` and version number `N`.

After design approval, create a public GitHub Gist with the approved mockup:

```bash
GIST_URL=$(gh gist create ~/.design/<slug>/vN.html --desc "<PRD title> mockup")
echo "Mockup Gist: $GIST_URL"
```

Replace `<slug>`, `N`, and `<PRD title>` with the actual values. Store `$GIST_URL` — it will be embedded in the PRD issue body in Step 5.

**If UI is NOT involved:** skip this step entirely and proceed to Step 4.

4. Sketch out the major modules you will need to build or modify to complete the implementation. Actively look for opportunities to extract deep modules that can be tested in isolation.

A deep module (as opposed to a shallow module) is one which encapsulates a lot of functionality in a simple, testable interface which rarely changes.

Check with the user that these modules match their expectations. Check with the user which modules they want tests written for.

If any modules involve API calls from the frontend, enumerate the endpoints those modules call. Discover the project's error-string convention (e.g. Express `res.status(...).json({ error: '...' })`, FastAPI `HTTPException`, Rails `render json: { error }, status: ...`) by reading 1–2 existing route files; if no convention found, ask the user. Then collect every distinct error string returned by the touched endpoints. For each error string, agree with the user on:
- A user-friendly English message
- A translation in each project locale (the project's `i18n/*.json` files reveal which locales)
- An i18n key name (camelCase, nested under the feature's own i18n section — e.g., `buildings.nameTaken`, never a shared `errors.*` namespace)

Document these agreements before writing the PRD.

5. Once you have a complete understanding of the problem and solution, use the template below to write the PRD body. If a mockup was created in Step 3.5, substitute `$GIST_URL` in the `## UI Mockup` template section with the actual Gist URL. If no mockup was created, omit the `## UI Mockup` section entirely.

**Preview before creating.** Render the full PRD body to the user and ask for approval (use AskUserQuestion: "Looks good — create issue" / "Needs edits"). Iterate on edits until approved. Only then proceed to create the GitHub issue.

**Preflight check** the GitHub CLI before creating:

```bash
gh auth status >/dev/null 2>&1 || { echo "gh CLI not authenticated — run 'gh auth login' first"; exit 1; }
git rev-parse --is-inside-work-tree >/dev/null 2>&1 || { echo "Not in a git repo with a GitHub remote"; exit 1; }
```

If either check fails, surface the failure to the user and stop — do not attempt creation.

Ensure the "PRD" label exists, then create the issue:

```bash
gh label create "PRD" --color 8B5CF6 --description "Product Requirements Document" 2>/dev/null || true
gh issue create --title "<title>" --label "PRD" --body "..."
```

<prd-template>

## Problem Statement

The problem that the user is facing, from the user's perspective.

## Solution

The solution to the problem, from the user's perspective.

<!-- CONDITIONAL: Only include ## UI Mockup if a mockup was generated in Step 3.5. Omit entirely for non-UI PRDs. -->

## UI Mockup

Mockup: [View HTML mockup on GitHub Gist]($GIST_URL)

> This mockup was approved before the PRD was written. Refer to it as the visual specification. Implementation must not begin until /ship-it or /prd-to-plan is invoked.

<!-- END CONDITIONAL -->

## User Stories

A LONG, numbered list of user stories. Each user story should be in the format of:

1. As an <actor>, I want a <feature>, so that <benefit>

<user-story-example>
1. As a mobile bank customer, I want to see balance on my accounts, so that I can make better informed decisions about my spending
</user-story-example>

This list of user stories should be extremely extensive and cover all aspects of the feature.

## Implementation Decisions

A list of implementation decisions that were made. This can include:

- The modules that will be built/modified
- The interfaces of those modules that will be modified
- Technical clarifications from the developer
- Architectural decisions
- Schema changes
- API contracts
- Specific interactions
- API error handling (when the feature involves frontend API calls): for each distinct backend error string returned by touched endpoints, record the mapping: error string → i18n key → friendly EN message → friendly VI message. Keys live under the feature's existing i18n section (e.g., `buildings.nameTaken`), never under a shared `errors` or `apiErrors` namespace.

Do NOT include specific file paths or code snippets. They may end up being outdated very quickly.

## Testing Decisions

A list of testing decisions that were made. Include:

- A description of what makes a good test (only test external behavior, not implementation details)
- Which modules will be tested
- Prior art for the tests (i.e. similar types of tests in the codebase)

## Out of Scope

A description of the things that are out of scope for this PRD.

## Further Notes

Any further notes about the feature.

</prd-template>

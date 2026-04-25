# skills

Personal collection of [Claude Code skills](https://docs.claude.com/en/docs/claude-code/skills) for product, planning, and engineering work.

## Credits

Most skills here are forked from [mattpocock/skills](https://github.com/mattpocock/skills) with light edits to fit my workflow. Thanks to [@mattpocock](https://github.com/mattpocock) for the originals.

## Layout

Each top-level folder is one skill. `SKILL.md` inside holds the skill frontmatter (name, description, trigger) plus the prompt body. `CLAUDE.md` is the global instructions file linked into `~/.claude/CLAUDE.md`.

## Skills

| Skill | Purpose |
| --- | --- |
| `audit` | Stress-test a plan, PRD, or mockup for missing edge cases and ambiguous rules. |
| `design` | Generate an HTML mockup for a screen before implementing it. |
| `grill-me` | Interrogate a technical plan branch-by-branch until every decision is resolved. |
| `improve-codebase-architecture` | Find architectural improvements that deepen shallow modules and increase testability. |
| `interactive-qa` | Conversational bug-reporting session that spawns parallel explore+fix agents. |
| `interview-me` | Business-analyst interview to pressure-test a non-technical client's plan. |
| `prd-to-issues` | Slice a PRD into vertical, independently-shippable GitHub issues. |
| `ship-it` | End-to-end PRD orchestrator — issue DAG, parallel agents, TDD per slice. |
| `tdd` | Red-green-refactor TDD loop for features and bugfixes. |
| `write-a-prd` | Produce a PRD via interview, codebase exploration, and module design; submit as a GitHub issue. |

## Install

```bash
git clone git@github.com:annguyenwasd/skills.git ~/workspace/skills
cd ~/workspace/skills
./link-claude-md.sh
```

`link-claude-md.sh` symlinks this folder to `~/.claude/skills` and `CLAUDE.md` to `~/.claude/CLAUDE.md`. Existing files are backed up to `*.bak`.

## Usage

After linking, each skill is invocable in Claude Code as `/<skill-name>` (e.g. `/audit`, `/ship-it`). Full descriptions and trigger conditions live in each skill's `SKILL.md` frontmatter.

## Workflows

Three entry points, all converging on `/ship-it`:

```
                  non-technical idea
                         │
                  /interview-me ──┐
                                  │
                  technical idea  │
                         │        ▼
                   /grill-me ─► /write-a-prd ─► /ship-it
                                  ▲
                  PRD already in head
                         │        │
                         └────────┘
```

### 1. Non-technical pitch → ship

For vague product ideas, client-style requests, or anything where the requirements aren't engineer-ready.

```
/interview-me  →  /write-a-prd  →  /ship-it
```

`/interview-me` runs a four-pass business-analyst interview to surface decisions and tradeoffs in plain language. The output feeds `/write-a-prd`, which turns it into a structured PRD and files it as a GitHub issue. `/ship-it` slices the PRD into dependency-ordered issues and drives parallel TDD agents to merge.

### 2. Technical plan → ship

For engineer-to-engineer plans where jargon is fine and the goal is to pressure-test the design tree.

```
/grill-me  →  /write-a-prd  →  /ship-it
```

`/grill-me` interrogates every branch of the decision tree until each is resolved. Same downstream as above.

### 3. PRD already drafted → ship

When the requirements are clear enough to skip discovery.

```
/write-a-prd  →  /ship-it
```

Or, if a PRD file/issue already exists, jump straight to `/ship-it <prd-path-or-issue>`.

### Optional checkpoints

- `/audit` — stress-test a PRD or plan for missing edge cases before slicing.
- `/design` — generate an HTML mockup for a screen before `/ship-it` implements it.
- `/improve-codebase-architecture` — run before large feature work to surface refactors that make the slices testable.

## Resources

Claude-related plugins and references I rely on. Append new finds here.

### Plugins

- [JuliusBrussee/caveman](https://github.com/JuliusBrussee/caveman) — ultra-compressed communication mode. Cuts token usage ~75% while preserving technical accuracy. Source of `/caveman`, `/caveman-commit`, `/caveman-review`, `/compress`.

# skills

Personal collection of [Claude Code skills](https://docs.claude.com/en/docs/claude-code/skills) for product, planning, and engineering work.

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

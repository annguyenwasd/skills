# skills

Personal collection of [Claude Code skills](https://docs.claude.com/en/docs/claude-code/skills) for product, planning, and engineering work.

## Credits

Most skills here are forked from [mattpocock/skills](https://github.com/mattpocock/skills) with light edits to fit my workflow. Thanks to [@mattpocock](https://github.com/mattpocock) for the originals.

## Layout

Each top-level folder is one skill. `SKILL.md` inside holds the skill frontmatter (name, description, trigger) plus the prompt body. `CLAUDE.md` is the global instructions file linked into `~/.claude/CLAUDE.md`.

## Skills


| Skill                           | Purpose                                                                                                                                                                |
| ------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `audit`                         | Stress-test a plan, PRD, or mockup for missing edge cases and ambiguous rules.                                                                                         |
| `design`                        | Generate an HTML mockup for a screen before implementing it.                                                                                                           |
| `fix`                           | Single-shot bug fixer on the current branch with strict TDD and per-attempt checklists.                                                                                |
| `improve-codebase-architecture` | Find architectural improvements that deepen shallow modules and increase testability.                                                                                  |
| `interview-me`                  | Business-analyst interview to pressure-test a non-technical client's plan.                                                                                             |
| `tdd`                           | Red-green-refactor TDD loop for features and bugfixes.                                                                                                                 |
| `verify`                        | Verify a running app's behaviour against a checklist. Spawns a fresh-context subagent (no code knowledge) and reports PASS/FAIL/TIMEOUT/ASSUMED/UNVERIFIABLE per item. |


## Prerequisites

These must be installed before skills will work correctly. Claude will install any missing ones on setup.

### GitHub CLI

```bash
brew install gh
gh auth login
```

Required for all git workflow commands (`/commit`, `/commit-push`, `/commit-push-pr`, `/clean_gone`).

### Caveman plugin

```bash
claude plugin marketplace add JuliusBrussee/caveman
claude plugin install caveman@caveman
```

Provides `/caveman`, `/caveman-commit`, `/caveman-review`, `/caveman:compress`. Auto-activates every session via `SessionStart` hook.

### commit-commands plugin

```bash
claude plugin marketplace add anthropics/claude-code
claude plugin install commit-commands@claude-code-plugins
```

Provides `/commit`, `/commit-push-pr`, `/clean_gone`.

The custom `/commit-push` command (commit + push, no PR) lives in `commands/commit-push.md` in this repo and is symlinked into `~/.claude/commands/` by `link-claude-md.sh`.

### playwright-cli (for `/verify` browser pass)

```bash
npm install -g @playwright/cli@latest   # CLI — github.com/microsoft/playwright-cli
playwright-cli install --skills         # bundled agent skills (one-time)
npx playwright install chromium         # browser binary
```

`/verify` re-checks `UNVERIFIABLE` items by driving a headless Chromium through `playwright-cli`. Skipped automatically if the CLI is missing — see warning text in `verify/SKILL.md` 5b-1. Pass `--no-browser` to opt out.

### GitHub MCP server

```bash
claude mcp add -s user github \
  -e GITHUB_PERSONAL_ACCESS_TOKEN="$(gh auth token)" \
  -- docker run -i --rm -e GITHUB_PERSONAL_ACCESS_TOKEN ghcr.io/github/github-mcp-server
```

Requires Docker. Gives Claude structured GitHub API access (issues, PRs, repos) alongside the CLI. Token is sourced from the active `gh` session — re-run this command if the token rotates.

## Install

```bash
git clone git@github.com:annguyenwasd/skills.git ~/workspace/skills
cd ~/workspace/skills
./link-claude-md.sh
```

`link-claude-md.sh` symlinks this folder to `~/.claude/skills` and `CLAUDE.md` to `~/.claude/CLAUDE.md`. Existing files are backed up to `*.bak`.

## Usage

After linking, each skill is invocable in Claude Code as `/<skill-name>` (e.g. `/audit`, `/verify`). Full descriptions and trigger conditions live in each skill's `SKILL.md` frontmatter.

## Workflows

Some planning skills write a checklist file. `/verify` reads it.

### 1. Non-technical pitch → checklist → verify

```
/interview-me  →  /verify --checklist .checklist/interview-<slug>/INTERVIEW.md
```

`/interview-me` runs a four-pass business-analyst interview and writes `.checklist/interview-<slug>/INTERVIEW.md`. `/verify` runs that checklist against the running app and reports PASS/FAIL/TIMEOUT/ASSUMED/UNVERIFIABLE per item.

### 2. Audit an existing spec

```
/audit
```

`/audit` stress-tests a plan or mockup and reports missing edge cases, ambiguous rules, contradictions, and unspecified UI states. It does not write a checklist; use `/interview-me` to resolve findings into a verifiable checklist.

### 3. Single bug fix → verify

```
/fix  (handles its own /verify loop internally)
```

`/fix` writes `.checklist/fix-<slug>-#<try>.md` per attempt and runs `/verify --checklist` against it in the foreground. One re-fix allowed; optional GitHub issue + commit linkage at the end.

### 4. Verify + auto-fix on a checklist

```
/verify --checklist <path> --fix
```

For each FAIL or TIMEOUT item, spawns a sequential TDD fix agent (RED → GREEN → PR). Three outcomes per item: `FIX_COMPLETE` (PR opened), `FIX_FAILED` (needs manual), `FIX_NOT_NEEDED` (checklist item was wrong).

### `/verify` reference

```bash
/verify                              # auto-picks latest .checklist/ file
/verify --prd 42                     # uses .checklist/prd-42.md
/verify --checklist path/to/file.md  # explicit file
/verify --fix                        # verify + TDD fix each FAIL/TIMEOUT
/verify --base-url http://localhost:8080 --timeout 60
/verify --start-cmd "npm run dev"    # override auto-detected start command
```

App lifecycle: `/verify` auto-detects the start command (package.json → Procfile → Cargo → Python → Makefile), starts the app, verifies, then shuts it down. If already running, skips start/stop.

Verification subagent has **zero code access** — only curl + the checklist. Prevents the implementer from rubber-stamping their own work.

### Optional checkpoints

- `/audit` — stress-test a plan or mockup for missing edge cases before implementation.
- `/design` — generate an HTML mockup for a screen before implementing it.
- `/improve-codebase-architecture` — run before large feature work to surface refactors that make the next slices testable.

### `.checklist/` convention

Checklist-producing skills write files to `<project-root>/.checklist/`:


| Source          | File                                                                            |
| --------------- | ------------------------------------------------------------------------------- |
| `/interview-me` | `.checklist/interview-<slug>/INTERVIEW.md`                                      |
| `/fix`          | `.checklist/fix-<slug>-#<try>.md` (one per attempt — `#1` initial, `#2` re-fix) |


These files are git-ignored. Add `.checklist/` to your global gitignore (or the repo's `.gitignore`).

## Resources

Claude-related plugins and references I rely on. Append new finds here.

### Plugins

- [anthropics/claude-code — commit-commands](https://github.com/anthropics/claude-code/tree/main/plugins/commit-commands) — official Anthropic plugin for git flow. Provides `/commit` (auto-style commit), `/commit-push-pr` (branch + push + PR), and `/clean_gone` (prune local branches whose remotes are gone).
- [JuliusBrussee/caveman](https://github.com/JuliusBrussee/caveman) — ultra-compressed communication mode. Cuts token usage ~75% while preserving technical accuracy. Source of `/caveman`, `/caveman-commit`, `/caveman-review`, `/compress`.

### Tools

- [microsoft/playwright-cli](https://github.com/microsoft/playwright-cli) — global CLI bundling Chromium/Firefox/WebKit. Used by `/verify`'s browser pass to drive headless browsers when curl can't verify a checklist item. Now distributed as `@playwright/cli`.
- [microsoft/markitdown](https://github.com/microsoft/markitdown) — Python utility that converts PDFs, Word, Excel, images, and audio into LLM-friendly Markdown. Handy preprocessor for feeding mixed documents into a Claude session or knowledge base.
- [HKUDS/DeepTutor](https://github.com/HKUDS/DeepTutor) — agent-native personalized learning assistant: multi-modal chat, document analysis, persistent memory, autonomous tutoring agents.

### Reading

- [karpathy — LLM Wiki](https://gist.github.com/karpathy/442a6bf555914893e9891c11519de94f) — design pattern for an LLM-maintained personal knowledge base: raw sources → interlinked markdown wiki → schema doc, so knowledge compounds across sessions instead of being re-derived from raw docs each query.


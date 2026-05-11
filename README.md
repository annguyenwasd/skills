# skills

Personal collection of [Claude Code skills](https://docs.claude.com/en/docs/claude-code/skills) for product, planning, and engineering work.

## Credits

Most skills here are forked from [mattpocock/skills](https://github.com/mattpocock/skills) with light edits to fit my workflow. Thanks to [@mattpocock](https://github.com/mattpocock) for the originals.

## Layout

Each top-level folder is one skill. `SKILL.md` inside holds the skill frontmatter (name, description, trigger) plus the prompt body. `CLAUDE.md` is the global instructions file linked into `~/.claude/CLAUDE.md`.

## Skills


| Skill                           | Purpose                                                                                                                                        |
| ------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------- |
| `audit`                         | Stress-test a plan, PRD, or mockup for missing edge cases and ambiguous rules.                                                                 |
| `design`                        | Generate an HTML mockup for a screen and get approval.                                                                                         |
| `fix`                           | Bug fixer that writes an observable `.checklist/fix-<slug>/FIX.md` checklist first, waits for approval, then fixes and verifies.               |
| `improve-codebase-architecture` | Find architectural improvements that deepen shallow modules and increase testability.                                                          |
| `interview-me`                  | Business-analyst interview to pressure-test a non-technical client's plan.                                                                     |
| `tdd`                           | Red-green-refactor TDD loop for features and bugfixes.                                                                                         |
| `verify`                        | Verify arbitrary checklist files against a running app with cURL for backend/API items and `playwright-cli` screenshots for frontend/UI items. |


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

`/verify` uses `playwright-cli` for frontend/UI checklist items and captures one final screenshot per UI item. Skipped automatically if the CLI is missing. Pass `--no-browser` to opt out.

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

Start implementation chains with `/interview-me`. It resolves product decisions into an acceptance checklist, then `/verify` checks that checklist against the running app.

### 1. Interview -> checklist -> verify

```
/interview-me
/verify --checklist .checklist/interview-<slug>/INTERVIEW.md
```

`/interview-me` runs a four-pass business-analyst interview and writes `.checklist/interview-<slug>/INTERVIEW.md`. `/verify` runs that checklist against the running app and reports PASS/FAIL/TIMEOUT/ASSUMED/UNVERIFIABLE per item.

### 2. Verify failure -> fix -> verify again

```
/fix <bug from /verify Fix Handoff>
/verify --checklist .checklist/interview-<slug>/INTERVIEW.md
```

When `/verify` reports `FAIL` or `TIMEOUT`, use its Fix Handoff block as the `/fix` input. `/fix` writes `.checklist/fix-<slug>/FIX.md`, shows it for approval, then fixes only the approved behaviour and runs `/verify --checklist` against that file. Re-run the original interview checklist after the fix if the broader flow matters.

### 3. Direct bug fix -> verify

```
/fix  (handles its own /verify loop internally)
```

`/fix` writes `.checklist/fix-<slug>/FIX.md`, shows it for approval, then fixes only the approved behaviour and runs `/verify --checklist` against that file.

### 4. Verify any checklist

```
/verify --checklist <path>
```

`/verify` accepts arbitrary markdown checklist files. Backend/API items are checked with cURL; frontend/UI items are checked with `playwright-cli` and include screenshot evidence.

### `/verify` reference

```bash
/verify                              # auto-picks a single .checklist/**/*.md file
/verify --checklist path/to/file.md  # explicit file
/verify --base-url http://localhost:8080 --timeout 60
/verify --start-cmd "npm run dev"    # override auto-detected start command
/verify --no-browser                 # skip frontend/UI browser validation
```

App lifecycle: `/verify` auto-detects the start command (package.json → Procfile → Cargo → Python → Makefile), starts the app, verifies, then shuts it down. If already running, skips start/stop.

Backend/API items are verified with cURL. If authentication is required, `/verify` performs a bounded auth-discovery pass through docs, tests, and obvious route definitions; if credentials or setup still cannot be found, it asks the user instead of guessing.

Frontend/UI items are verified with `playwright-cli`. Screenshots are written beside the checklist in `<checklist-stem>-screenshots/` with names derived from each checklist item, such as `03-login-email-required.png`.

### Optional checkpoints

- `/audit` — stress-test a plan or mockup for missing edge cases before implementation.
- `/design` — generate an HTML mockup for a screen and get approval.
- `/improve-codebase-architecture` — run before large feature work to surface refactors that make the next slices testable.

### `.checklist/` convention

Checklist-producing skills write files to `<project-root>/.checklist/`:


| Source          | File                                       |
| --------------- | ------------------------------------------ |
| `/interview-me` | `.checklist/interview-<slug>/INTERVIEW.md` |
| `/fix`          | `.checklist/fix-<slug>/FIX.md`             |


These files are git-ignored. Add `.checklist/` to your global gitignore (or the repo's `.gitignore`).

## Resources

Claude-related plugins and references I rely on. Append new finds here.

### Plugins

- [anthropics/claude-code — commit-commands](https://github.com/anthropics/claude-code/tree/main/plugins/commit-commands) — official Anthropic plugin for git flow. Provides `/commit` (auto-style commit), `/commit-push-pr` (branch + push + PR), and `/clean_gone` (prune local branches whose remotes are gone).
- [JuliusBrussee/caveman](https://github.com/JuliusBrussee/caveman) — ultra-compressed communication mode. Cuts token usage ~75% while preserving technical accuracy. Source of `/caveman`, `/caveman-commit`, `/caveman-review`, `/compress`.

### Tools

- [microsoft/playwright-cli](https://github.com/microsoft/playwright-cli) — global CLI bundling Chromium/Firefox/WebKit. Used by `/verify` to validate frontend/UI checklist items and capture final per-item screenshots. Now distributed as `@playwright/cli`.
- [microsoft/markitdown](https://github.com/microsoft/markitdown) — Python utility that converts PDFs, Word, Excel, images, and audio into LLM-friendly Markdown. Handy preprocessor for feeding mixed documents into a Claude session or knowledge base.
- [HKUDS/DeepTutor](https://github.com/HKUDS/DeepTutor) — agent-native personalized learning assistant: multi-modal chat, document analysis, persistent memory, autonomous tutoring agents.

### Reading

- [karpathy — LLM Wiki](https://gist.github.com/karpathy/442a6bf555914893e9891c11519de94f) — design pattern for an LLM-maintained personal knowledge base: raw sources → interlinked markdown wiki → schema doc, so knowledge compounds across sessions instead of being re-derived from raw docs each query.


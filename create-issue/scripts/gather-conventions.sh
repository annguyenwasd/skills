#!/usr/bin/env bash
# Read-only recon for /create-issue.
#
# Prints everything a filer needs to know about the repository it stands in:
# identity, labels, issue templates, and the tracker's own recent style. Writes
# nothing and files nothing — safe to run at any point, including before you
# have decided whether the claim is real.
#
# Usage: gather-conventions.sh [owner/name] [--recent N]
set -uo pipefail

RECENT=25
REPO=""
while [ $# -gt 0 ]; do
  case "$1" in
    --recent) RECENT="${2:-25}"; shift 2 ;;
    -h|--help) sed -n '2,9p' "$0"; exit 0 ;;
    *) REPO="$1"; shift ;;
  esac
done

die() { printf 'gather-conventions: %s\n' "$*" >&2; exit 1; }

command -v gh >/dev/null 2>&1 || die "gh CLI not found on PATH"

if [ -z "$REPO" ]; then
  REPO="$(gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null)" \
    || die "not inside a GitHub repository, and no owner/name was given"
fi

section() { printf '\n===== %s =====\n' "$1"; }

section "repository"
printf '%s\n' "$REPO"
gh repo view "$REPO" --json nameWithOwner,defaultBranchRef,visibility,hasIssuesEnabled \
  -q '"default branch: \(.defaultBranchRef.name)\nvisibility: \(.visibility)\nissues enabled: \(.hasIssuesEnabled)"' \
  2>/dev/null || printf 'could not read repository metadata\n'

section "labels (use ONLY these)"
# name and description, tab separated, so a caller can filter without parsing prose
gh label list --repo "$REPO" --limit 200 --json name,description \
  -q '.[] | "\(.name)\t\(.description)"' 2>/dev/null || printf '(no labels readable)\n'

section "issue templates"
found_template=0
for dir in .github/ISSUE_TEMPLATE .github; do
  [ -d "$dir" ] || continue
  for f in "$dir"/*.md "$dir"/*.yml "$dir"/*.yaml; do
    [ -f "$f" ] || continue
    found_template=1
    printf '\n--- %s ---\n' "$f"
    head -40 "$f"
  done
done
[ "$found_template" -eq 1 ] || printf '(none)\n'

section "recent issues (open and closed)"
gh issue list --repo "$REPO" --state all --limit "$RECENT" \
  --json number,title,state,labels \
  -q '.[] | "#\(.number)\t\(.state)\t[\([.labels[].name] | join(","))]\t\(.title)"' \
  2>/dev/null || printf '(no issues readable)\n'

section "sample recent issue body (house style)"
# The most recently updated issue with real prose in it, trimmed: enough to
# show the section headings and how evidence is cited, not enough to flood
# the context.
sample="$(gh issue list --repo "$REPO" --state all --limit 10 --json number \
  -q '.[].number' 2>/dev/null | while read -r n; do
    body="$(gh issue view "$n" --repo "$REPO" --json body -q .body 2>/dev/null)"
    [ "${#body}" -gt 400 ] && { printf '%s' "$n"; break; }
  done)"
if [ -n "$sample" ]; then
  printf '#%s\n' "$sample"
  gh issue view "$sample" --repo "$REPO" --json body -q .body 2>/dev/null | head -60
  printf '\n(trimmed at 60 lines)\n'
else
  printf '(no substantial issue body found — use the structure in SKILL.md)\n'
fi

section "routing rules found in this repository"
# Repositories often state where features go versus defects. That rule decides
# whether filing is even the right action, so it is worth surfacing verbatim.
found_rule=0
for f in AGENTS.md CLAUDE.md .github/CONTRIBUTING.md CONTRIBUTING.md; do
  [ -f "$f" ] || continue
  hits="$(grep -niE 'issue|spec|defect|bug|feature' "$f" 2>/dev/null | head -12)"
  if [ -n "$hits" ]; then
    found_rule=1
    printf '\n--- %s ---\n%s\n' "$f" "$hits"
  fi
done
[ "$found_rule" -eq 1 ] || printf '(no routing rules found)\n'

section "feature path present?"
for d in spec specs docs/requirements; do
  [ -d "$d" ] && printf '%s/ exists — check the routing rule above before filing a feature\n' "$d"
done

printf '\nrecon complete\n'

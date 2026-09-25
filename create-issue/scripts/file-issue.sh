#!/usr/bin/env bash
# File one GitHub issue.
#
# Validates labels against the repository before calling `gh issue create`,
# because an unknown label makes gh fail the whole call and drops the issue you
# just spent a verification fan-out on. Unknown labels are dropped with a
# warning; the issue still files.
#
# Usage:
#   file-issue.sh --title <title> --body-file <path> [--label L]... [--repo R] [--dry-run]
set -uo pipefail

TITLE=""
BODY_FILE=""
REPO=""
DRY=0
LABELS=()

usage() {
  cat >&2 <<'EOF'
file-issue.sh --title <title> --body-file <path> [--label L]... [--repo owner/name] [--dry-run]

  --title      issue title, declarative and specific
  --body-file  file holding the issue body (markdown)
  --label      repeatable; labels that do not exist are dropped, not fatal
  --repo       owner/name; default is the repository in the working directory
  --dry-run    print the invocation and the body, file nothing
EOF
  exit 2
}

while [ $# -gt 0 ]; do
  case "$1" in
    --title)     TITLE="${2:-}"; shift 2 ;;
    --body-file) BODY_FILE="${2:-}"; shift 2 ;;
    --label)     LABELS+=("${2:-}"); shift 2 ;;
    --repo)      REPO="${2:-}"; shift 2 ;;
    --dry-run)   DRY=1; shift ;;
    -h|--help)   usage ;;
    *) printf 'file-issue: unknown argument %s\n' "$1" >&2; usage ;;
  esac
done

[ -n "$TITLE" ]     || { printf 'file-issue: --title is required\n' >&2; usage; }
[ -n "$BODY_FILE" ] || { printf 'file-issue: --body-file is required\n' >&2; usage; }
[ -f "$BODY_FILE" ] || { printf 'file-issue: no such body file: %s\n' "$BODY_FILE" >&2; exit 1; }
[ -s "$BODY_FILE" ] || { printf 'file-issue: body file is empty: %s\n' "$BODY_FILE" >&2; exit 1; }

command -v gh >/dev/null 2>&1 || { printf 'file-issue: gh CLI not found\n' >&2; exit 1; }

REPO_ARGS=()
if [ -n "$REPO" ]; then
  REPO_ARGS=(--repo "$REPO")
else
  REPO="$(gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null)" \
    || { printf 'file-issue: not inside a GitHub repository; pass --repo\n' >&2; exit 1; }
fi

# An issue body nobody can act on is noise. This rejects the shell-quoting
# accident and the empty placeholder, not a short-but-complete report.
body_chars="$(wc -c < "$BODY_FILE" | tr -d ' ')"
if [ "$body_chars" -lt 120 ]; then
  printf 'file-issue: body is only %s bytes — too thin to be actionable.\n' "$body_chars" >&2
  printf 'file-issue: add the mechanism and its evidence before filing.\n' >&2
  exit 1
fi

# `${arr[@]+"${arr[@]}"}` rather than `"${arr[@]}"`: macOS ships bash 3.2,
# where the plain form is an unbound-variable error under `set -u` whenever the
# array is empty — which silently turns into "no labels exist" here.
existing="$(gh label list ${REPO_ARGS+"${REPO_ARGS[@]}"} --limit 200 --json name -q '.[].name' 2>/dev/null)"

KEEP=()
for want in ${LABELS+"${LABELS[@]}"}; do
  if printf '%s\n' "$existing" | grep -Fxq -- "$want"; then
    KEEP+=("$want")
  else
    printf 'file-issue: dropping label "%s" — it does not exist in %s\n' "$want" "$REPO" >&2
  fi
done

LABEL_ARGS=()
for l in ${KEEP+"${KEEP[@]}"}; do LABEL_ARGS+=(--label "$l"); done

if [ "$DRY" -eq 1 ]; then
  printf '[dry-run] repo:  %s\n' "$REPO"
  printf '[dry-run] title: %s\n' "$TITLE"
  printf '[dry-run] labels: %s\n' "${KEEP[*]+"${KEEP[*]}"}"
  # Quoted with plain '%s' rather than '%q': bash 3.2's %q escapes every
  # non-ASCII byte, so a title with a dash or a non-English word prints as
  # octal escapes and stops being readable as the command it is showing.
  printf '[dry-run] command:\n  gh issue create --title %s --body-file %s %s\n' \
    "'$TITLE'" "$BODY_FILE" "${LABEL_ARGS[*]:-}"
  printf '\n[dry-run] body:\n'
  cat "$BODY_FILE"
  printf '\n[dry-run] nothing filed\n'
  exit 0
fi

url="$(gh issue create ${REPO_ARGS+"${REPO_ARGS[@]}"} --title "$TITLE" --body-file "$BODY_FILE" \
  ${LABEL_ARGS+"${LABEL_ARGS[@]}"} 2>&1)"
status=$?
if [ $status -ne 0 ]; then
  printf 'file-issue: gh issue create failed:\n%s\n' "$url" >&2
  exit "$status"
fi

printf 'filed: %s\n' "$url"
[ "${#KEEP[@]}" -eq 0 ] && printf 'note: no labels applied\n'
exit 0

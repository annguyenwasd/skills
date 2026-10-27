#!/bin/bash
set -e

SKILLS_DIR="$(cd "$(dirname "$0")" && pwd)"
CLAUDE_DIR="$HOME/.claude"

# True when symlink $1 resolves inside the skills repo
is_ours() {
  [ -L "$1" ] || return 1
  local resolved
  resolved="$(readlink -f "$1")"
  case "$resolved" in
    "$SKILLS_DIR")      return 0 ;;
    "$SKILLS_DIR"/*)    return 0 ;;
    *)                  return 1 ;;
  esac
}

link() {
  local src="$1" target="$2"

  if [ -L "$target" ]; then
    if is_ours "$target"; then
      echo "already linked: $target -> $(readlink "$target")"
    else
      echo "skip (foreign symlink): $target -> $(readlink "$target")"
    fi
    return
  fi

  if [ -e "$target" ]; then
    mv "$target" "$target.bak"
    echo "backed up: $target.bak"
  fi

  ln -s "$src" "$target"
  echo "linked: $target -> $src"
}

unlink_one() {
  local target="$1"

  if ! is_ours "$target"; then
    [ -e "$target" ] || [ -L "$target" ] && echo "skip (not ours): $target"
    return
  fi

  rm "$target"
  echo "unlinked: $target"

  if [ -e "$target.bak" ]; then
    mv "$target.bak" "$target"
    echo "restored: $target"
  fi
}

link_all() {
  # Ensure CLAUDE.md exists
  [ -f "$SKILLS_DIR/CLAUDE.md" ] || touch "$SKILLS_DIR/CLAUDE.md"
  mkdir -p "$CLAUDE_DIR"
  link "$SKILLS_DIR/CLAUDE.md" "$CLAUDE_DIR/CLAUDE.md"

  # Link each skill folder (child with SKILL.md), not the whole repo, so
  # installs into ~/.claude/skills never write into this repo
  local dir name
  for dir in "$SKILLS_DIR"/*/; do
    dir="${dir%/}"
    name="$(basename "$dir")"
    [ -f "$dir/SKILL.md" ] || continue
    mkdir -p "$CLAUDE_DIR/skills"
    link "$dir" "$CLAUDE_DIR/skills/$name"
  done

  # Link custom commands
  if [ -d "$SKILLS_DIR/commands" ]; then
    mkdir -p "$CLAUDE_DIR/commands"
    local cmd
    for cmd in "$SKILLS_DIR/commands/"*.md; do
      [ -f "$cmd" ] || continue
      link "$cmd" "$CLAUDE_DIR/commands/$(basename "$cmd")"
    done
  fi
}

unlink_all() {
  unlink_one "$CLAUDE_DIR/CLAUDE.md"

  if [ -d "$CLAUDE_DIR/skills" ]; then
    local entry
    for entry in "$CLAUDE_DIR/skills"/*; do
      [ -e "$entry" ] || [ -L "$entry" ] || continue
      unlink_one "$entry"
    done
  fi

  if [ -d "$CLAUDE_DIR/commands" ]; then
    local cmd
    for cmd in "$CLAUDE_DIR/commands"/*.md; do
      [ -e "$cmd" ] || [ -L "$cmd" ] || continue
      unlink_one "$cmd"
    done
  fi
}

case "${1:-link}" in
  link)   link_all ;;
  unlink) unlink_all ;;
  *)
    echo "usage: $(basename "$0") [link|unlink]  (default: link)" >&2
    exit 1
    ;;
esac

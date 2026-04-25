#!/bin/bash
set -e

SKILLS_DIR="$(cd "$(dirname "$0")" && pwd)"
CLAUDE_DIR="$HOME/.claude"

link() {
  local src="$1" target="$2"

  if [ -L "$target" ]; then
    echo "already linked: $target -> $(readlink "$target")"
    return
  fi

  if [ -e "$target" ]; then
    mv "$target" "$target.bak"
    echo "backed up: $target.bak"
  fi

  ln -s "$src" "$target"
  echo "linked: $target -> $src"
}

# Ensure CLAUDE.md exists
[ -f "$SKILLS_DIR/CLAUDE.md" ] || touch "$SKILLS_DIR/CLAUDE.md"

link "$SKILLS_DIR/CLAUDE.md" "$CLAUDE_DIR/CLAUDE.md"
link "$SKILLS_DIR"           "$CLAUDE_DIR/skills"

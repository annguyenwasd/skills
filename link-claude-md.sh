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

link "$SKILLS_DIR/CLAUDE.md"               "$CLAUDE_DIR/CLAUDE.md"
link "$SKILLS_DIR"                         "$CLAUDE_DIR/skills"
link "$SKILLS_DIR/statusline-command.sh"   "$CLAUDE_DIR/statusline-command.sh"

# Link custom commands
if [ -d "$SKILLS_DIR/commands" ]; then
  mkdir -p "$CLAUDE_DIR/commands"
  for cmd in "$SKILLS_DIR/commands/"*.md; do
    [ -f "$cmd" ] || continue
    link "$cmd" "$CLAUDE_DIR/commands/$(basename "$cmd")"
  done
fi

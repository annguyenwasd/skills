#!/bin/sh
# Claude Code statusLine script
# Mirrors the zsh prompt from vcs-info.zsh:
#   $vcs_info_dir_path %F{yellow}$vcs_info_bare_status%F{reset}${vcs_info_msg_0_}%f %(1j.[%j] .)%# 

input=$(cat)

cwd=$(echo "$input" | jq -r '.cwd')

# Short directory: show last component (like %1~ in zsh)
dir=$(basename "$cwd")

# Git branch + status (mirrors vcs_info formats '(%b%u%c)')
git_info=""
if git -C "$cwd" rev-parse --git-dir > /dev/null 2>&1; then
  branch=$(git -C "$cwd" -c gc.auto=0 symbolic-ref --short HEAD 2>/dev/null || git -C "$cwd" -c gc.auto=0 rev-parse --short HEAD 2>/dev/null)
  if [ -n "$branch" ]; then
    unstaged=""
    staged=""
    git -C "$cwd" -c gc.auto=0 diff --quiet 2>/dev/null || unstaged=" *"
    git -C "$cwd" -c gc.auto=0 diff --cached --quiet 2>/dev/null || staged=" +"
    git_info="(${branch}${unstaged}${staged})"
  fi
fi

# Context window remaining
context_part=""
remaining=$(echo "$input" | jq -r '.context_window.remaining_percentage // empty')
if [ -n "$remaining" ]; then
  used=$(echo "$remaining" | awk '{printf "%.0f", 100 - $1}')
  context_part=" ctx:${used}%"
fi

# Rate limits (Claude.ai subscription usage)
rate_part=""
five_pct=$(echo "$input" | jq -r '.rate_limits.five_hour.used_percentage // empty')
seven_pct=$(echo "$input" | jq -r '.rate_limits.seven_day.used_percentage // empty')
if [ -n "$five_pct" ] || [ -n "$seven_pct" ]; then
  rate_part=" |"
  [ -n "$five_pct" ] && rate_part="$rate_part 5h:$(printf '%.0f' "$five_pct")%"
  [ -n "$seven_pct" ] && rate_part="$rate_part 7d:$(printf '%.0f' "$seven_pct")%"
fi

printf '%s %s%s%s' "$dir" "$git_info" "$context_part" "$rate_part"

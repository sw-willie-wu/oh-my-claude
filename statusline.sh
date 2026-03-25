#!/bin/bash
# oh-my-claude - Themeable statusline for Claude Code
# https://github.com/anthropics/claude-code

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
OMC_DIR="${OMC_DIR:-$SCRIPT_DIR}"
OMC_CONF="${OMC_CONF:-$HOME/.claude/oh-my-claude.conf}"

# Defaults
THEME="catppuccin"
LAYOUT="default"

# Load config
[ -f "$OMC_CONF" ] && source "$OMC_CONF"

# Load theme and layout
THEME_FILE="${OMC_DIR}/themes/${THEME}.sh"
LAYOUT_FILE="${OMC_DIR}/layouts/${LAYOUT}.sh"

[ -f "$THEME_FILE" ] || THEME_FILE="${OMC_DIR}/themes/catppuccin.sh"
[ -f "$LAYOUT_FILE" ] || LAYOUT_FILE="${OMC_DIR}/layouts/default.sh"

source "$THEME_FILE"
source "$LAYOUT_FILE"

# Read JSON input from stdin
input=$(cat)

# Parse JSON fields
MODEL=$(echo "$input" | grep -o '"display_name":"[^"]*"' | cut -d'"' -f4 | sed 's/ (.*//')
DIR=$(echo "$input" | grep -o '"current_dir":"[^"]*"' | head -1 | cut -d'"' -f4)
CTX_PCT=$(echo "$input" | grep -o '"used_percentage":[0-9]*' | head -1 | grep -o '[0-9]*')
RATE5_PCT=$(echo "$input" | grep -o '"five_hour":{[^}]*' | grep -o '"used_percentage":[0-9]*' | grep -o '[0-9]*')
RATE5_RESET=$(echo "$input" | grep -o '"five_hour":{[^}]*' | grep -o '"resets_at":[0-9]*' | grep -o '[0-9]*')
RATE7_PCT=$(echo "$input" | grep -o '"seven_day":{[^}]*' | grep -o '"used_percentage":[0-9]*' | grep -o '[0-9]*')
RATE7_RESET=$(echo "$input" | grep -o '"seven_day":{[^}]*' | grep -o '"resets_at":[0-9]*' | grep -o '[0-9]*')

# Convert Windows path to ~/relative
DIR=$(echo "$DIR" | sed 's|\\\\|/|g; s|\\|/|g; s|C:/Users/[^/]*/|~/|i')

# Git info (if in a repo)
BRANCH="" ADD_FILES=0 MOD_FILES=0 DEL_FILES=0 LINES_ADD=0 LINES_DEL=0
if git rev-parse --git-dir > /dev/null 2>&1; then
  BRANCH=$(git branch --show-current 2>/dev/null)
  STATUS=$(git status --porcelain 2>/dev/null)
  SUB_STATUS=$(git submodule foreach --quiet 'git status --porcelain 2>/dev/null' 2>/dev/null)
  ALL_STATUS=$(printf '%s\n%s' "$STATUS" "$SUB_STATUS")
  ADD_FILES=$(echo "$ALL_STATUS" | grep -c '^A\|^??')
  MOD_FILES=$(echo "$ALL_STATUS" | grep -c '^ M\|^M\|^MM\|^AM')
  DEL_FILES=$(echo "$ALL_STATUS" | grep -c '^ D\|^D')
  DIFF_STATS=$(git diff HEAD --numstat 2>/dev/null; git submodule foreach --quiet 'git diff HEAD --numstat 2>/dev/null' 2>/dev/null)
  LINES_ADD=$(echo "$DIFF_STATS" | awk '{s+=$1} END {print s+0}')
  LINES_DEL=$(echo "$DIFF_STATS" | awk '{s+=$2} END {print s+0}')
fi

# Rate limit reset info
RATE5_SUFFIX=""
if [ "${RATE5_PCT:-0}" -gt 80 ] && [ -n "$RATE5_RESET" ]; then
  RATE5_HOUR=$(date -d "@$RATE5_RESET" '+%H:%M' 2>/dev/null || date -r "$RATE5_RESET" '+%H:%M' 2>/dev/null)
  RATE5_SUFFIX=" (${RATE5_HOUR})"
fi
RATE7_SUFFIX=""
if [ "${RATE7_PCT:-0}" -gt 80 ] && [ -n "$RATE7_RESET" ]; then
  RATE7_DATE=$(date -d "@$RATE7_RESET" '+%m/%d' 2>/dev/null || date -r "$RATE7_RESET" '+%m/%d' 2>/dev/null)
  RATE7_SUFFIX=" (${RATE7_DATE})"
fi

# Call the layout's render function
render

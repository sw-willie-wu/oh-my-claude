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

# Worker defaults (overridden by user's conf if set).
: "${WORKERS_ENABLED:=true}"
: "${WORKERS_SHOW_AGENTS:=true}"
: "${WORKERS_SHOW_SHELLS:=true}"
: "${WORKERS_SHOW_TYPE:=true}"
: "${WORKERS_SHOW_ELAPSED:=true}"
: "${WORKERS_MAX:=5}"
: "${WORKERS_AGENT_ICON:=}"
: "${WORKERS_SHELL_ICON:=}"
: "${WORKERS_SHELL_MAX_AGE:=3600}"

# Load theme and layout
THEME_FILE="${OMC_DIR}/themes/${THEME}.sh"
LAYOUT_FILE="${OMC_DIR}/layouts/${LAYOUT}.sh"

[ -f "$THEME_FILE" ] || THEME_FILE="${OMC_DIR}/themes/catppuccin.sh"
[ -f "$LAYOUT_FILE" ] || LAYOUT_FILE="${OMC_DIR}/layouts/default.sh"

source "$THEME_FILE"
source "$LAYOUT_FILE"

# Read JSON input from stdin
input=$(cat)

# Extract session_id (jq preferred; grep fallback for jq-less systems).
SESSION_ID=""
if command -v jq >/dev/null 2>&1; then
  SESSION_ID=$(printf '%s' "$input" | jq -r '.session_id // empty' 2>/dev/null)
fi
if [ -z "$SESSION_ID" ]; then
  SESSION_ID=$(printf '%s' "$input" | grep -o '"session_id":"[^"]*"' | head -1 | cut -d'"' -f4)
fi
SANITIZED_SID=$(printf '%s' "$SESSION_ID" | tr -c 'A-Za-z0-9-_' '_')
WORKERS_STATE_FILE="$HOME/.claude/oh-my-claude/state/state-${SANITIZED_SID}.tsv"

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
  STATUS=$(git status --porcelain -uall 2>/dev/null)
  SUB_STATUS=$(git submodule foreach --quiet 'git status --porcelain -uall 2>/dev/null' 2>/dev/null)
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

unescape_field() {
  # Reverse of escape_field: \t → tab, \n → newline, \\ → backslash.
  # Implemented in awk because sed replacement strings can't portably
  # contain literal newlines.
  awk 'BEGIN {
    s = ARGV[1]
    n = length(s)
    out = ""
    i = 1
    while (i <= n) {
      c = substr(s, i, 1)
      if (c == "\\" && i < n) {
        nc = substr(s, i + 1, 1)
        if (nc == "t") { out = out "\t"; i += 2; continue }
        if (nc == "n") { out = out "\n"; i += 2; continue }
        if (nc == "\\") { out = out "\\"; i += 2; continue }
      }
      out = out c
      i += 1
    }
    printf "%s", out
    exit
  }' "$1"
}

format_elapsed() {
  local s="$1"
  if [ "$s" -lt 60 ]; then
    printf '%ds' "$s"
  elif [ "$s" -lt 3600 ]; then
    printf '%dm%ds' $((s / 60)) $((s % 60))
  else
    printf '%dh%dm' $((s / 3600)) $(((s % 3600) / 60))
  fi
}

emit_workers() {
  [ "$WORKERS_ENABLED" != "true" ] && return 0
  [ -z "$SESSION_ID" ] && return 0
  [ -f "$WORKERS_STATE_FILE" ] || return 0

  local now count=0
  now=$(date +%s)
  local width="${COLUMNS:-120}"

  while IFS=$'\t' read -r kind tool_use_id col3 desc col5 col6; do
    [ -z "$kind" ] && continue
    [ "$WORKERS_MAX" != "0" ] && [ "$count" -ge "$WORKERS_MAX" ] && break

    local start icon detail elapsed_str body_plain tail_plain total_len
    case "$kind" in
      agent)
        [ "$WORKERS_SHOW_AGENTS" != "true" ] && continue
        start="$col5"
        local subagent_type
        subagent_type="$(unescape_field "$col3")"
        local desc_u
        desc_u="$(unescape_field "$desc")"
        if [ "$WORKERS_SHOW_TYPE" = "true" ] && [ -n "$subagent_type" ]; then
          detail="${subagent_type}: ${desc_u}"
        else
          detail="$desc_u"
        fi
        icon="$WORKERS_AGENT_ICON"
        local color="$C_PRIMARY"
        ;;
      shell)
        [ "$WORKERS_SHOW_SHELLS" != "true" ] && continue
        start="$col6"
        local desc_u cmd_u
        desc_u="$(unescape_field "$desc")"
        cmd_u="$(unescape_field "$col5")"
        if [ -n "$desc_u" ]; then
          detail="${desc_u}: ${cmd_u}"
        else
          detail="$cmd_u"
        fi
        icon="$WORKERS_SHELL_ICON"
        local color="$C_ACCENT"
        ;;
      *) continue ;;
    esac

    local age=$((now - start))
    if [ "$kind" = "shell" ] && [ "$age" -gt "$WORKERS_SHELL_MAX_AGE" ]; then
      color="$C_SUBTEXT"
      detail="${detail} ?"
    fi

    if [ "$WORKERS_SHOW_ELAPSED" = "true" ]; then
      elapsed_str=$(format_elapsed "$age")
    else
      elapsed_str=""
    fi

    body_plain="${icon} ${detail}"
    if [ -n "$elapsed_str" ]; then
      tail_plain="  ${elapsed_str}"
    else
      tail_plain=""
    fi
    total_len=$(( ${#body_plain} + ${#tail_plain} ))

    if [ "$total_len" -gt $((width - 2)) ]; then
      local keep=$(( width - 5 - ${#tail_plain} ))
      [ "$keep" -lt 1 ] && keep=1
      body_plain="${body_plain:0:$keep}..."
    fi

    if [ -n "$elapsed_str" ]; then
      printf '%b%s%b  %b%s%b\n' "$color" "$body_plain" "$RESET" "$C_SUBTEXT" "$elapsed_str" "$RESET"
    else
      printf '%b%s%b\n' "$color" "$body_plain" "$RESET"
    fi

    count=$((count + 1))
  done < "$WORKERS_STATE_FILE"
}

# RESET fallback (themes usually define it).
: "${RESET:=$'\033[0m'}"

emit_workers

# Call the layout's render function
render

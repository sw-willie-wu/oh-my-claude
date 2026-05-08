#!/bin/bash
# oh-my-claude - Themeable statusline for Claude Code
# https://github.com/anthropics/claude-code

# Use BASH_SOURCE so this resolves correctly whether the file is executed
# directly or sourced (e.g. by statusline.sh.lib_test_loader.sh).
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
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
# WORKERS_AGENT_ICON / WORKERS_SHELL_ICON default in each theme;
# user conf overrides (use empty string to disable an icon).
: "${WORKERS_SHELL_MAX_AGE:=3600}"
: "${WORKERS_OUTPUT_FALLBACK_ENABLED:=true}"
# Grace window for shell rows whose col7 (PID) hasn't been filled yet by
# PostToolUse — covers both the placeholder gap (col3="-") and the brief
# sub-window between the two `update_col` writes inside post (col3 set,
# col7 still empty). Without it, a statusline tick inside either gap
# false-prunes the row.
: "${WORKERS_PLACEHOLDER_GRACE_SEC:=60}"

LIB_DIR="${OMC_DIR}/lib"
[ -d "$LIB_DIR" ] || LIB_DIR="$SCRIPT_DIR/lib"
# shellcheck source=lib/state-lock.sh
. "$LIB_DIR/state-lock.sh"

# Load theme and layout
THEME_FILE="${OMC_DIR}/themes/${THEME}.sh"
LAYOUT_FILE="${OMC_DIR}/layouts/${LAYOUT}.sh"

[ -f "$THEME_FILE" ] || THEME_FILE="${OMC_DIR}/themes/catppuccin.sh"
[ -f "$LAYOUT_FILE" ] || LAYOUT_FILE="${OMC_DIR}/layouts/default.sh"

source "$THEME_FILE"
source "$LAYOUT_FILE"

# RESET fallback (themes usually define it).
: "${RESET:=$'\033[0m'}"

# ---------------------------------------------------------------------------
# Helper functions — defined before the render gate so test loaders can
# source this file (with OMC_TEST_LIB_ONLY=1) and access them without
# triggering JSON parsing or the render pipeline.
# ---------------------------------------------------------------------------

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

is_alive() {
  local pid="$1"
  [ -z "$pid" ] && return 1
  case "$(uname -s)" in
    MINGW*|MSYS*|CYGWIN*)
      # MSYS bash's kill -0 doesn't recognize native Windows PIDs (the kind ps -W returns).
      # ps -W col1 is the MSYS/cygwin PID, col4 is the native WINPID; match either.
      ps -W 2>/dev/null | awk -v p="$pid" '$1==p || $4==p {f=1} END {exit !f}'
      ;;
    *)
      command -v kill >/dev/null 2>&1 || return 0
      kill -0 "$pid" 2>/dev/null
      ;;
  esac
}

is_bash_output_present() {
  [ "${WORKERS_OUTPUT_FALLBACK_ENABLED:-true}" = "true" ] || return 1
  local bash_id="$1" tmp wd_id
  [ -z "$bash_id" ] && return 1
  tmp="${TEMP:-${TMPDIR:-/tmp}}"
  tmp="${tmp//\\//}"
  wd_id=$(printf '%s' "$WORKDIR_RAW" | sed 's|[:\\/]|-|g')
  [ -f "${tmp}/claude/${wd_id}/${SESSION_ID}/tasks/${bash_id}.output" ]
}

prune_state_and_emit() {
  local sf="$WORKERS_STATE_FILE"
  [ -f "$sf" ] || return 0
  local tmp="${sf}.prune.$$"
  : > "$tmp"
  while IFS=$'\t' read -r kind tool_use_id col3 desc col5 col6 col7 || [ -n "$kind" ]; do
    [ -z "$kind" ] && continue
    local keep=true
    if [ "$kind" = "shell" ]; then
      if [ -n "$col7" ] && [ "$col7" -gt 0 ] 2>/dev/null; then
        is_alive "$col7" || keep=false
      else
        # col7 missing/0: row is either the PreToolUse placeholder, the
        # gap between post's two update_col writes, a legacy 6-col row,
        # or a row whose PID acquisition failed (PID=0).
        # Within grace: always keep — covers the hook race window.
        # Beyond grace: if col3 still "-", PostToolUse never ran → reap;
        # otherwise fall through to output-file fallback.
        local now_ts age within_grace=false
        now_ts=$(date +%s)
        if [ -n "$col6" ] && [ "$col6" -gt 0 ] 2>/dev/null; then
          age=$((now_ts - col6))
          [ "$age" -le "$WORKERS_PLACEHOLDER_GRACE_SEC" ] && within_grace=true
        fi
        if [ "$within_grace" = "true" ]; then
          : # keep
        elif [ "$col3" = "-" ]; then
          keep=false
        else
          is_bash_output_present "$col3" || keep=false
        fi
      fi
    fi
    [ "$keep" = "true" ] || continue
    if [ "$kind" = "agent" ]; then
      printf '%s\t%s\t%s\t%s\t%s\n' "$kind" "$tool_use_id" "$col3" "$desc" "$col5" >> "$tmp"
    else
      printf '%s\t%s\t%s\t%s\t%s\t%s' "$kind" "$tool_use_id" "$col3" "$desc" "$col5" "$col6" >> "$tmp"
      [ -n "$col7" ] && printf '\t%s' "$col7" >> "$tmp"
      printf '\n' >> "$tmp"
    fi
  done < "$sf"
  mv "$tmp" "$sf"
  cat "$sf"
}

emit_workers() {
  [ "$WORKERS_ENABLED" != "true" ] && return 0
  [ -z "$SESSION_ID" ] && return 0
  [ -f "$WORKERS_STATE_FILE" ] || return 0

  local rendered
  rendered="$(omc_with_lock prune_state_and_emit)"
  [ -z "$rendered" ] && return 0

  local now count=0
  now=$(date +%s)
  local width="${COLUMNS:-120}"

  printf '%s\n' "$rendered" | while IFS=$'\t' read -r kind tool_use_id col3 desc col5 col6 col7; do
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

    if [ -z "$start" ] || ! [[ "$start" =~ ^[0-9]+$ ]]; then
      continue
    fi
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
  done
}

# ---------------------------------------------------------------------------
# Render pipeline — gated so test loaders can source this file without
# blocking on stdin or triggering side-effects.
# ---------------------------------------------------------------------------
if [ -z "${OMC_TEST_LIB_ONLY:-}" ]; then

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

# Capture raw cwd before destructive normalization below — used by output-file
# fallback in is_bash_output_present. JSON-extracted via grep leaves backslashes
# doubled, so collapse \\\\ -> \\ here. (TODO: switch JSON extraction to jq for
# robustness against \", \uXXXX, etc.)
WORKDIR_RAW=$(printf '%s' "$DIR" | sed 's|\\\\|\\|g')
[ -n "${OMC_DEBUG_DUMP_WORKDIR_RAW:-}" ] && printf 'WORKDIR_RAW=%s\n' "$WORKDIR_RAW" >&2

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

# Layouts own placement of worker rows — each render() decides where to call
# emit_workers (top, middle, bottom, or skip).
render

fi # end OMC_TEST_LIB_ONLY gate

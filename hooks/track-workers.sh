#!/bin/bash
# track-workers.sh — dispatcher for oh-my-claude worker tracking hooks.
# Usage: track-workers.sh <pre|post|session-start>
set -u

ARG="${1:-}"

# Override-able for tests.
OMC_STATE_DIR="${OMC_STATE_DIR:-$HOME/.claude/oh-my-claude/state}"
OMC_LOG_FILE="${OMC_LOG_FILE:-$OMC_STATE_DIR/track-workers.log}"
LOCK_DIR="$OMC_STATE_DIR/state.lock"

mkdir -p "$OMC_STATE_DIR" 2>/dev/null

log() {
  printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >> "$OMC_LOG_FILE" 2>/dev/null || true
}

# Read stdin once.
PAYLOAD="$(cat)"

# Sanitize session_id so filename is portable. Empty if missing.
sanitize_id() {
  printf '%s' "$1" | tr -c 'A-Za-z0-9-_' '_'
}

# Extract a top-level field from the payload. Uses jq if available; empty on miss.
get_field() {
  local field="$1"
  if command -v jq >/dev/null 2>&1; then
    printf '%s' "$PAYLOAD" | jq -r ".${field} // empty" 2>/dev/null
  else
    log "jq not installed; track-workers degraded to no-op"
    return 1
  fi
}

state_file_for() {
  local sid="$(sanitize_id "$1")"
  [ -z "$sid" ] && return 1
  printf '%s/state-%s.tsv' "$OMC_STATE_DIR" "$sid"
}

# Escape tabs/newlines/backslashes for safe TSV storage.
escape_field() {
  printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/	/\\t/g' -e 's/$/\\n/' | tr -d '\n' | sed 's/\\n$//'
}

now_unix() { date +%s; }

with_lock() {
  local fn="$1" tries=0
  while ! mkdir "$LOCK_DIR" 2>/dev/null; do
    if [ -d "$LOCK_DIR" ]; then
      local lock_age now mtime
      now=$(date +%s)
      mtime=$(stat -c %Y "$LOCK_DIR" 2>/dev/null || stat -f %m "$LOCK_DIR" 2>/dev/null || echo "$now")
      lock_age=$((now - mtime))
      if [ "$lock_age" -gt 10 ]; then
        rmdir "$LOCK_DIR" 2>/dev/null
        continue
      fi
    fi
    tries=$((tries + 1))
    if [ "$tries" -gt 20 ]; then
      log "lock acquisition failed after 1s"
      return 1
    fi
    sleep 0.05 2>/dev/null || sleep 1
  done
  trap 'rmdir "$LOCK_DIR" 2>/dev/null || true' RETURN INT TERM EXIT
  "$fn"
  rmdir "$LOCK_DIR" 2>/dev/null
  trap - RETURN INT TERM EXIT
}

append_row() {
  local sf="$1" row="$2"
  _do() { printf '%s\n' "$row" >> "$sf"; }
  with_lock _do
}

# Remove rows from $sf where column $col equals $value.
remove_by() {
  local sf="$1" col="$2" value="$3"
  _do() {
    [ -f "$sf" ] || return 0
    local tmp="${sf}.tmp.$$"
    awk -F'\t' -v c="$col" -v v="$value" '$c != v' "$sf" > "$tmp"
    mv "$tmp" "$sf"
  }
  with_lock _do
}

case "$ARG" in
  session-start)
    SESSION_ID="$(get_field session_id || true)"
    if [ -n "$SESSION_ID" ]; then
      SF="$(state_file_for "$SESSION_ID")"
      : > "$SF"
    fi
    # 24h cleanup happens in Task 9.
    ;;
  pre)
    SESSION_ID="$(get_field session_id || true)"
    TOOL_NAME="$(get_field tool_name || true)"
    TOOL_USE_ID="$(get_field tool_use_id || true)"
    [ -z "$SESSION_ID" ] && exit 0
    SF="$(state_file_for "$SESSION_ID")" || exit 0
    case "$TOOL_NAME" in
      Task)
        SUBAGENT_TYPE="$(printf '%s' "$PAYLOAD" | jq -r '.tool_input.subagent_type // empty' 2>/dev/null)"
        DESCRIPTION="$(printf '%s' "$PAYLOAD" | jq -r '.tool_input.description // empty' 2>/dev/null)"
        ROW=$(printf 'agent\t%s\t%s\t%s\t%s' \
          "$TOOL_USE_ID" \
          "$(escape_field "$SUBAGENT_TYPE")" \
          "$(escape_field "$DESCRIPTION")" \
          "$(now_unix)")
        append_row "$SF" "$ROW"
        ;;
      Bash)
        BG=$(printf '%s' "$PAYLOAD" | jq -r '.tool_input.run_in_background // false' 2>/dev/null)
        if [ "$BG" = "true" ]; then
          DESCRIPTION="$(printf '%s' "$PAYLOAD" | jq -r '.tool_input.description // empty' 2>/dev/null)"
          COMMAND="$(printf '%s' "$PAYLOAD" | jq -r '.tool_input.command // empty' 2>/dev/null)"
          ROW=$(printf 'shell\t%s\t-\t%s\t%s\t%s' \
            "$TOOL_USE_ID" \
            "$(escape_field "$DESCRIPTION")" \
            "$(escape_field "$COMMAND")" \
            "$(now_unix)")
          append_row "$SF" "$ROW"
        fi
        ;;
    esac
    ;;
  post)
    SESSION_ID="$(get_field session_id || true)"
    TOOL_NAME="$(get_field tool_name || true)"
    TOOL_USE_ID="$(get_field tool_use_id || true)"
    [ -z "$SESSION_ID" ] && exit 0
    SF="$(state_file_for "$SESSION_ID")" || exit 0
    case "$TOOL_NAME" in
      Task)
        [ -n "$TOOL_USE_ID" ] && remove_by "$SF" 2 "$TOOL_USE_ID"
        ;;
    esac
    ;;
  *)
    log "unknown arg: $ARG"
    ;;
esac

exit 0

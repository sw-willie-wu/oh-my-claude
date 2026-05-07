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
    : # Implemented in subsequent tasks.
    ;;
  post)
    : # Implemented in subsequent tasks.
    ;;
  *)
    log "unknown arg: $ARG"
    ;;
esac

exit 0

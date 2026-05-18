#!/bin/bash
# track-workers.sh — dispatcher for oh-my-claude worker tracking hooks.
# Usage: track-workers.sh <pre|post|session-start>
set -u

ARG="${1:-}"

# Override-able for tests.
OMC_STATE_DIR="${OMC_STATE_DIR:-$HOME/.claude/oh-my-claude/state}"
OMC_LOG_FILE="${OMC_LOG_FILE:-$OMC_STATE_DIR/track-workers.log}"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LIB_DIR="$(dirname "$SCRIPT_DIR")/lib"
# shellcheck source=../lib/state-lock.sh
. "$LIB_DIR/state-lock.sh"

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

now_unix() { date +%s; }

append_row() {
  local sf="$1" row="$2"
  _do() {
    # Idempotency guard: Claude Code on Windows invokes the matched hook
    # twice for the same tool call. Skip when (kind, tool_use_id) already
    # matches an existing row.
    if [ -f "$sf" ]; then
      local kind tuid
      kind="$(printf '%s' "$row" | awk -F'\t' '{print $1}')"
      tuid="$(printf '%s' "$row" | awk -F'\t' '{print $2}')"
      if awk -F'\t' -v k="$kind" -v t="$tuid" \
        '$1 == k && $2 == t {found=1; exit} END {exit !found}' "$sf"; then
        return 0
      fi
    fi
    printf '%s\n' "$row" >> "$sf"
  }
  omc_with_lock _do
}

# Remove rows from $sf where column 1 (kind) == $kind AND column $col equals $value.
remove_by_kind() {
  local sf="$1" kind="$2" col="$3" value="$4"
  _do() {
    [ -f "$sf" ] || return 0
    local tmp="${sf}.tmp.$$"
    awk -F'\t' -v k="$kind" -v c="$col" -v v="$value" '!($1 == k && $c == v)' "$sf" > "$tmp"
    mv "$tmp" "$sf"
  }
  omc_with_lock _do
}

# Update column $target_col of rows where column $key_col == $key_value.
update_col() {
  local sf="$1" key_col="$2" key_value="$3" target_col="$4" new_value="$5"
  _do() {
    [ -f "$sf" ] || return 0
    local tmp="${sf}.tmp.$$"
    awk -F'\t' -v OFS='\t' -v kc="$key_col" -v kv="$key_value" -v tc="$target_col" -v nv="$new_value" \
      '{ if ($kc == kv) $tc = nv; print }' "$sf" > "$tmp"
    mv "$tmp" "$sf"
  }
  omc_with_lock _do
}

case "$ARG" in
  session-start)
    SESSION_ID="$(get_field session_id || true)"
    if [ -n "$SESSION_ID" ]; then
      SF="$(state_file_for "$SESSION_ID")"
      : > "$SF"
    fi
    # Cleanup: delete sibling state-*.tsv with mtime > 24h.
    find "$OMC_STATE_DIR" -maxdepth 1 -name 'state-*.tsv' -type f -mmin +1440 -delete 2>/dev/null
    ;;
  pre)
    SESSION_ID="$(get_field session_id || true)"
    TOOL_NAME="$(get_field tool_name || true)"
    TOOL_USE_ID="$(get_field tool_use_id || true)"
    [ -z "$SESSION_ID" ] && exit 0
    SF="$(state_file_for "$SESSION_ID")" || exit 0
    case "$TOOL_NAME" in
      Task|Agent)
        SUBAGENT_TYPE="$(printf '%s' "$PAYLOAD" | jq -r '.tool_input.subagent_type // empty' 2>/dev/null)"
        DESCRIPTION="$(printf '%s' "$PAYLOAD" | jq -r '.tool_input.description // empty' 2>/dev/null)"
        # col6 is a placeholder ('-') reserved for the agentId, which the
        # Post hook patches in for async launches. Sync calls are removed
        # wholesale by Post and never see col6 patched.
        ROW=$(printf 'agent\t%s\t%s\t%s\t%s\t-' \
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
      KillShell)
        ID=$(printf '%s' "$PAYLOAD" | jq -r '.tool_input.task_id // .tool_input.shell_id // empty' 2>/dev/null)
        [ -n "$ID" ] && remove_by_kind "$SF" shell 3 "$ID"
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
      Task|Agent)
        # Async Task|Agent fires PostToolUse at launch (not subagent
        # completion). Patch col6 with tool_response.agentId so the render
        # side can liveness-check the subagent; sync calls complete here and
        # are removed outright.
        BG=$(printf '%s' "$PAYLOAD" | jq -r '.tool_input.run_in_background // false' 2>/dev/null)
        if [ "$BG" = "true" ]; then
          AGENT_ID=$(printf '%s' "$PAYLOAD" | jq -r '.tool_response.agentId // empty' 2>/dev/null)
          if [ -n "$AGENT_ID" ] && [ -n "$TOOL_USE_ID" ]; then
            update_col "$SF" 2 "$TOOL_USE_ID" 6 "$AGENT_ID"
          else
            # col6 stays '-': the render side will reap this row as an
            # orphaned placeholder once the grace window expires. Log so
            # the (rare) lost-agentId case is diagnosable rather than a
            # silent vanish.
            log "async Agent post: no agentId (tuid='$TOOL_USE_ID'); row stays placeholder and will be reaped at grace"
          fi
        elif [ -n "$TOOL_USE_ID" ]; then
          remove_by_kind "$SF" agent 2 "$TOOL_USE_ID"
        fi
        ;;
      Bash)
        BG_TASK_ID=$(printf '%s' "$PAYLOAD" | jq -r '.tool_response.backgroundTaskId // empty' 2>/dev/null)
        if [ -n "$BG_TASK_ID" ] && [ -n "$TOOL_USE_ID" ]; then
          update_col "$SF" 2 "$TOOL_USE_ID" 3 "$BG_TASK_ID"
          # Acquire PID by ps fingerprint (best-effort fast path). Failure
          # -> PID=0; render side (is_shell_alive) re-checks liveness by
          # command fingerprint at draw time.
          COMMAND="$(printf '%s' "$PAYLOAD" | jq -r '.tool_input.command // empty' 2>/dev/null)"
          FP="${COMMAND:0:60}"
          PID=0
          if command -v ps >/dev/null 2>&1 && [ -n "$FP" ]; then
            # Prefer -ww (no COMMAND truncation, needed for the 60-char
            # fingerprint match on long commands). Fall back to plain
            # variants on platforms whose ps doesn't accept -w (e.g. MSYS).
            # MSYS bash wraps the user command as `bash -c "... && eval '<cmd>' ..."`,
            # so also match the `eval '<fp>` substring; POSIX direct-spawn paths
            # still hit via the prefix match.
            PID=$( { ps -Wefww 2>/dev/null || ps -efww 2>/dev/null \
                  || ps -Wef 2>/dev/null   || ps -ef 2>/dev/null; } \
              | awk -v fp="$FP" 'NR>1 {
                  cmd=""
                  for(i=6;i<=NF;i++) cmd=cmd (i>6?" ":"") $i
                  needle="eval \047" fp
                  if (index(cmd, fp)==1 || index(cmd, needle)>0) print $2, $5
                }' \
              | sort -k2 | tail -1 | awk '{print $1}' )
            [ -z "$PID" ] && PID=0
          fi
          update_col "$SF" 2 "$TOOL_USE_ID" 7 "$PID"
        fi
        ;;
      BashOutput)
        ID=$(printf '%s' "$PAYLOAD" | jq -r '.tool_input.task_id // .tool_input.agentId // .tool_input.bash_id // empty' 2>/dev/null)
        STATUS=$(printf '%s' "$PAYLOAD" | jq -r '.tool_response.status // empty' 2>/dev/null)
        # Terminal statuses (verified primary + defensive fallback set).
        case "$STATUS" in
          completed|failed|killed|exited|stopped|terminated)
            [ -n "$ID" ] && remove_by_kind "$SF" shell 3 "$ID"
            ;;
        esac
        ;;
    esac
    ;;
  *)
    log "unknown arg: $ARG"
    ;;
esac

exit 0

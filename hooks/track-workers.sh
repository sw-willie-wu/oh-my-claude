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

# Workers display off => nothing to track. Source the conf (best effort, quiet,
# tolerant of unset vars) and bail out before jq or the lock. session-start is
# exempt (it only truncates the state file and sweeps old files).
OMC_CONF="${OMC_CONF:-$HOME/.claude/oh-my-claude.conf}"
if [ "$ARG" != session-start ] && [ -f "$OMC_CONF" ]; then
  set +u; . "$OMC_CONF" >/dev/null 2>&1; set -u
fi
: "${WORKERS_ENABLED:=true}" "${WORKERS_SHOW_SHELLS:=true}"
case "$ARG" in pre|post)
  { [ "$WORKERS_ENABLED" != true ] || [ "$WORKERS_SHOW_SHELLS" != true ]; } && exit 0 ;;
esac

command -v jq >/dev/null 2>&1 || { log "jq not installed; track-workers no-op"; exit 0; }

# One jq pass for every field the dispatcher needs (NUL-separated, so values
# may hold newlines/tabs). Every field uses `// ""`/`// false`, never
# `// empty`, which would emit nothing and shift later fields. jq failure
# leaves every field empty => SESSION_ID empty => degraded no-op.
SESSION_ID="" TOOL_NAME="" TOOL_USE_ID="" BG="" DESCRIPTION="" COMMAND=""
KILL_ID="" OUT_ID="" BG_TASK_ID="" STATUS=""
{
  IFS= read -r -d '' SESSION_ID; IFS= read -r -d '' TOOL_NAME
  IFS= read -r -d '' TOOL_USE_ID; IFS= read -r -d '' BG
  IFS= read -r -d '' DESCRIPTION; IFS= read -r -d '' COMMAND
  IFS= read -r -d '' KILL_ID; IFS= read -r -d '' OUT_ID
  IFS= read -r -d '' BG_TASK_ID; IFS= read -r -d '' STATUS
} < <(printf '%s' "$PAYLOAD" | jq --raw-output0 '
    (.session_id? // ""), (.tool_name? // ""), (.tool_use_id? // ""),
    (.tool_input.run_in_background? // false | tostring),
    (.tool_input.description? // ""), (.tool_input.command? // ""),
    (.tool_input.task_id? // .tool_input.shell_id? // ""),
    (.tool_input.task_id? // .tool_input.agentId? // .tool_input.bash_id? // ""),
    (.tool_response.backgroundTaskId? // ""), (.tool_response.status? // "")
    | tostring' 2>/dev/null) || true

case "$ARG" in
  session-start)
    if [ -n "$SESSION_ID" ]; then
      SF="$(state_file_for "$SESSION_ID")"
      : > "$SF"
    fi
    # Cleanup: delete sibling state-*.tsv with mtime > 24h. Also reap stale
    # gitcache-* files (statusline.sh's git-info cache, keyed per cwd) and any
    # crashed-write gitcache-*.tmp.<pid> leftovers — same dir, same age policy.
    # An actively-used cache is mtime-bumped on every miss, so only caches for
    # dirs not visited in 24h are swept.
    find "$OMC_STATE_DIR" -maxdepth 1 -name 'state-*.tsv' -type f -mmin +1440 -delete 2>/dev/null
    find "$OMC_STATE_DIR" -maxdepth 1 -name 'gitcache-*' -type f -mmin +1440 -delete 2>/dev/null
    find "$OMC_STATE_DIR" -maxdepth 1 -name 'account-*' -type f -mmin +1440 -delete 2>/dev/null
    ;;
  pre)
    [ -z "$SESSION_ID" ] && exit 0
    SF="$(state_file_for "$SESSION_ID")" || exit 0
    case "$TOOL_NAME" in
      Bash)
        if [ "$BG" = "true" ]; then
          ROW=$(printf 'shell\t%s\t-\t%s\t%s\t%s' \
            "$TOOL_USE_ID" \
            "$(escape_field "$DESCRIPTION")" \
            "$(escape_field "$COMMAND")" \
            "$(now_unix)")
          append_row "$SF" "$ROW"
        fi
        ;;
      KillShell)
        [ -n "$KILL_ID" ] && remove_by_kind "$SF" shell 3 "$KILL_ID"
        ;;
    esac
    ;;
  post)
    [ -z "$SESSION_ID" ] && exit 0
    SF="$(state_file_for "$SESSION_ID")" || exit 0
    case "$TOOL_NAME" in
      Bash)
        if [ -n "$BG_TASK_ID" ] && [ -n "$TOOL_USE_ID" ]; then
          update_col "$SF" 2 "$TOOL_USE_ID" 3 "$BG_TASK_ID"
          # Acquire PID by ps fingerprint (best-effort fast path). Failure
          # -> PID=0; render side (is_shell_alive) re-checks liveness by
          # command fingerprint at draw time.
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
        # Terminal statuses (verified primary + defensive fallback set).
        case "$STATUS" in
          completed|failed|killed|exited|stopped|terminated)
            [ -n "$OUT_ID" ] && remove_by_kind "$SF" shell 3 "$OUT_ID"
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

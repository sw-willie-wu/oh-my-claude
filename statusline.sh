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
# Grace window for shell rows whose col7 (PID) hasn't been filled yet by
# PostToolUse — covers both the placeholder gap (col3="-") and the brief
# sub-window between the two `update_col` writes inside post (col3 set,
# col7 still empty). Without it, a statusline tick inside either gap
# false-prunes the row.
: "${WORKERS_PLACEHOLDER_GRACE_SEC:=60}"
# Async subagents have no completion hook. Liveness is read off the
# subagent transcript JSONL: if its mtime is within this many seconds the
# agent is treated as actively running (fast path); otherwise the last
# transcript line's type/stop_reason decides. Set comfortably above the
# observed worst-case inter-line gap (real transcripts show 30s+ pauses
# across slow tool calls) to avoid false-pruning a stalled-but-working
# agent.
: "${WORKERS_AGENT_QUIET_SEC:=60}"
: "${WORKERS_AGENT_TRANSCRIPT_ROOT:=$HOME/.claude/projects}"
# git_info() result cache TTL (seconds). Makes statusLine refreshInterval:1
# affordable by not running git every tick. 0 = disable caching (always
# recompute = exact legacy behavior). Non-numeric/negative → 3.
: "${GIT_CACHE_TTL:=3}"

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

# Liveness for bg-Bash shell rows. The Post-hook PID fingerprint is racy at
# launch (the child often isn't in the process table yet), and bg-Bash has
# no on-disk completion marker (the .output file is sticky), so PID=0 rows
# can't be reaped via a file check. Instead, at render time (well past the
# launch instant) fingerprint-match the stored command (col5) against ps:
# present → alive, absent → done. Mirrors the hook's match logic (b3310c5):
# the bare child (`sleep 50` → index==1) and the MSYS eval-wrapper
# (`… eval 'sleep 50…` → needle hit) both count.
is_shell_alive() {
  local cmd fp out
  cmd="$(unescape_field "$1")"
  fp="${cmd:0:60}"
  [ -z "$fp" ] && return 1
  # cygwin -Wefww/-efww exit 1; -ef/-Wef carry full args. linux -efww does.
  # Empty-output fallthrough, NOT || exit-code chaining (cygwin ps exit
  # codes are unreliable — an args-stripped variant can win a || chain).
  out=$(ps -efww 2>/dev/null); [ -z "$out" ] && out=$(ps -ef 2>/dev/null)
  [ -z "$out" ] && out=$(ps -Wef 2>/dev/null)
  [ -z "$out" ] && return 1
  printf '%s\n' "$out" | awk -v fp="$fp" 'NR>1 {
      c=""
      for (i=6; i<=NF; i++) c = c (i>6 ? " " : "") $i
      needle = "eval \047" fp
      if (index(c, fp)==1 || index(c, needle)>0) { f=1; exit }
    } END { exit !f }'
}

# Liveness for async subagents. Their transcript lives at
#   $WORKERS_AGENT_TRANSCRIPT_ROOT/<wd_id>/<session_id>/subagents/agent-<id>.jsonl
# where wd_id is the cwd with every non-alphanumeric char replaced by '-'
# (Claude Code's project-dir slug; identical transform used for the tasks/
# output path).
#
# Fast path: mtime within WORKERS_AGENT_QUIET_SEC → still emitting → alive.
# Stale mtime: decide on the LAST non-empty transcript line:
#   - a `user` line (tool_result delivered) → model owes a turn → alive
#   - an `assistant` line with stop_reason=="tool_use" → tool call pending
#     → alive
#   - any other terminal `assistant` line (stop_reason end_turn/max_tokens/
#     stop_sequence, or the trailing null-stop_reason answer text) → done
# stop_reason alone is unreliable (a finished agent's last line is usually
# stop_reason:null answer text, not end_turn), hence the line-type test.
# Missing JSONL → cannot prove alive → treat as done (the render-side grace
# window covers the brief pre-creation launch gap). jq absent → cannot parse
# → degrade to "done" (consistent with the hook side's jq hard-dep stance);
# the mtime fast-path still protects actively-emitting agents.
is_agent_alive() {
  local agent_id="$1"
  [ -z "$agent_id" ] && return 1
  local wd_id jsonl
  wd_id=$(printf '%s' "$WORKDIR_RAW" | sed 's/[^A-Za-z0-9]/-/g')
  jsonl="${WORKERS_AGENT_TRANSCRIPT_ROOT}/${wd_id}/${SESSION_ID}/subagents/agent-${agent_id}.jsonl"
  [ -f "$jsonl" ] || return 1
  local now_ts mtime
  now_ts=$(date +%s)
  mtime=$(stat -c %Y "$jsonl" 2>/dev/null)
  [ -z "$mtime" ] && mtime=$(date -r "$jsonl" +%s 2>/dev/null)
  if [ -n "$mtime" ] && [ $((now_ts - mtime)) -le "$WORKERS_AGENT_QUIET_SEC" ]; then
    return 0
  fi
  command -v jq >/dev/null 2>&1 || return 1
  local last type
  last=$(grep -v '^[[:space:]]*$' "$jsonl" 2>/dev/null | tail -1)
  [ -z "$last" ] && return 1
  type=$(printf '%s' "$last" | jq -r '.type // empty' 2>/dev/null)
  case "$type" in
    user) return 0 ;;
    assistant)
      [ "$(printf '%s' "$last" | jq -r '.message.stop_reason // empty' 2>/dev/null)" = "tool_use" ]
      ;;
    *) return 1 ;;
  esac
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
        # Within grace: always keep — covers the hook race window AND the
        # brief post-launch window before the child is in the process table.
        # Beyond grace: if col3 still "-", PostToolUse never ran → reap;
        # otherwise fingerprint-match the stored command against ps
        # (bg-Bash has no on-disk completion marker; the .output file is
        # sticky so existence is useless).
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
          is_shell_alive "$col5" || keep=false
        fi
      fi
    elif [ "$kind" = "agent" ]; then
      if [ -z "$col6" ]; then
        : # legacy 5-col row → keep (sync agents are removed by Post hook)
      else
        # 6-col row: col6 is the '-' placeholder or a real agentId.
        # Within the grace window from start_unix (col5) always keep —
        # covers the Pre→Post gap and the brief window before the
        # subagent JSONL is created. Beyond grace, a still-'-' col6 means
        # Post never patched it → reap; otherwise liveness-check.
        local now_ts age within_grace=false
        now_ts=$(date +%s)
        if [ -n "$col5" ] && [ "$col5" -gt 0 ] 2>/dev/null; then
          age=$((now_ts - col5))
          [ "$age" -le "$WORKERS_PLACEHOLDER_GRACE_SEC" ] && within_grace=true
        fi
        if [ "$within_grace" = "true" ]; then
          : # keep
        elif [ "$col6" = "-" ]; then
          keep=false
        else
          is_agent_alive "$col6" || keep=false
        fi
      fi
    fi
    [ "$keep" = "true" ] || continue
    if [ "$kind" = "agent" ]; then
      # Preserve col6 (agentId / '-' placeholder) when present; legacy
      # 5-col rows have no col6 and stay 5-col.
      printf '%s\t%s\t%s\t%s\t%s' "$kind" "$tool_use_id" "$col3" "$desc" "$col5" >> "$tmp"
      [ -n "$col6" ] && printf '\t%s' "$col6" >> "$tmp"
      printf '\n' >> "$tmp"
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

# Git working-tree summary. Pure: runs git in the caller's $PWD, mutates no
# globals. stdout = exactly one line, 6 TAB-joined fields (NO trailing newline):
#   <BRANCH>\t<ADD>\t<MOD>\t<DEL>\t<LINES_ADD>\t<LINES_DEL>
# not-a-repo and detached HEAD → field 1 empty; fields 2–6 are integers.
# Values are byte-identical to the former inline block in repos with no
# submodules (the common case); only the plumbing changed plus the §8.1
# submodule guard below.
git_info() {
  local branch="" add=0 mod=0 del=0 ladd=0 ldel=0 toplevel
  # `--show-toplevel` doubles as the in-a-worktree gate AND gives the path for
  # the .gitmodules check below in a single git call (replacing the old bare
  # `rev-parse --git-dir` gate; a bare repo with no worktree → treated as
  # non-repo, which is correct for a working-tree status line).
  if toplevel=$(git rev-parse --show-toplevel 2>/dev/null) && [ -n "$toplevel" ]; then
    branch=$(git branch --show-current 2>/dev/null)
    local status sub_status all_status diff_stats has_sub=""
    # §8.1: `git submodule foreach` pays a heavy per-call process/startup cost
    # on MSYS (~7s observed) even with ZERO submodules, and git_info calls it
    # twice (status + diff) ⇒ ~14s of pure waste ⇒ statusline exceeds Claude
    # Code's render budget ⇒ blank. Only scan submodules if the repo actually
    # tracks them (.gitmodules at the worktree toplevel).
    [ -f "$toplevel/.gitmodules" ] && has_sub=1
    status=$(git status --porcelain -uall 2>/dev/null)
    if [ -n "$has_sub" ]; then
      sub_status=$(git submodule foreach --quiet 'git status --porcelain -uall 2>/dev/null' 2>/dev/null)
    else
      sub_status=""
    fi
    all_status=$(printf '%s\n%s' "$status" "$sub_status")
    add=$(echo "$all_status" | grep -c '^A\|^??')
    mod=$(echo "$all_status" | grep -c '^ M\|^M\|^MM\|^AM')
    del=$(echo "$all_status" | grep -c '^ D\|^D')
    if [ -n "$has_sub" ]; then
      diff_stats=$(git diff HEAD --numstat 2>/dev/null; git submodule foreach --quiet 'git diff HEAD --numstat 2>/dev/null' 2>/dev/null)
    else
      diff_stats=$(git diff HEAD --numstat 2>/dev/null)
    fi
    ladd=$(echo "$diff_stats" | awk '{s+=$1} END {print s+0}')
    ldel=$(echo "$diff_stats" | awk '{s+=$2} END {print s+0}')
  fi
  printf '%s\t%s\t%s\t%s\t%s\t%s' "$branch" "$add" "$mod" "$del" "$ladd" "$ldel"
}

# Short-TTL on-disk cache around git_info(), keyed by $PWD (the dir git runs
# in — NOT $WORKDIR_RAW/current_dir, which are display-only and differ from
# $PWD under MSYS). Makes statusLine refreshInterval:1 affordable. OMC_STATE_DIR
# is already in scope (set by lib/state-lock.sh, sourced above). Stale-write
# safety: per-cwd file + atomic tmp+mv (no lock — independent of worker state;
# worst case is N concurrent dupes, self-healing).
cached_git_info() {
  local ttl="$GIT_CACHE_TTL"
  # empty / negative / decimal / non-integer → 3; "0" (disabled) preserved.
  case "$ttl" in ''|*[!0-9]*) ttl=3 ;; esac
  if [ "$ttl" = "0" ]; then
    git_info
    return
  fi
  local wd key file content now mtime age out
  # Key off the ACTUAL cwd (getcwd via `pwd -P`), not the $PWD variable:
  # Claude Code can invoke the statusLine command with $PWD empty, which
  # collapsed key="" so every repo shared one "gitcache-" file and got
  # served another repo's git info. If even getcwd is unavailable (cwd
  # deleted), bypass the cache entirely — compute fresh, write nothing —
  # so a missing cwd can never poison a shared key.
  wd=$(pwd -P 2>/dev/null)
  if [ -z "$wd" ]; then
    git_info
    return
  fi
  key=$(printf '%s' "$wd" | sed 's/[^A-Za-z0-9]/-/g')
  file="$OMC_STATE_DIR/gitcache-${key}"
  if [ -f "$file" ]; then
    # OMC_NOW_OVERRIDE: test-only clock seam so the TTL-boundary tests are
    # deterministic instead of racing wall-clock on a slow box. Unset in
    # production → identical behaviour (date +%s).
    now=${OMC_NOW_OVERRIDE:-$(date +%s)}
    mtime=$(stat -c %Y "$file" 2>/dev/null)
    [ -z "$mtime" ] && mtime=$(date -r "$file" +%s 2>/dev/null)
    if [ -n "$mtime" ]; then
      age=$((now - mtime))
      if [ "$age" -le "$ttl" ]; then
        content=$(cat "$file")          # $() strips trailing \n (none written)
        local TAB; TAB=$'\t'
        # Well-formed = exactly one line, 6 fields, fields 2–6 integers. The
        # anchored bash regex (no /m) also enforces single-line: a 0-byte,
        # truncated, or multi-line file fails. $re MUST stay unquoted.
        local re="^[^${TAB}]*${TAB}[0-9]+${TAB}[0-9]+${TAB}[0-9]+${TAB}[0-9]+${TAB}[0-9]+$"
        if [[ "$content" =~ $re ]]; then
          printf '%s' "$content"
          return
        fi
      fi
    fi
  fi
  out=$(git_info)                                                  # MISS
  mkdir -p "$OMC_STATE_DIR" 2>/dev/null
  printf '%s' "$out" > "$file.tmp.$$" && mv "$file.tmp.$$" "$file"  # atomic
  printf '%s' "$out"
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

# Capture raw cwd before destructive normalization below — used by
# is_agent_alive to derive the subagent-transcript project slug. JSON-extracted
# via grep leaves backslashes doubled, so collapse \\\\ -> \\ here. (TODO:
# switch JSON extraction to jq for robustness against \", \uXXXX, etc.)
WORKDIR_RAW=$(printf '%s' "$DIR" | sed 's|\\\\|\\|g')
[ -n "${OMC_DEBUG_DUMP_WORKDIR_RAW:-}" ] && printf 'WORKDIR_RAW=%s\n' "$WORKDIR_RAW" >&2

# Convert Windows path to ~/relative
DIR=$(echo "$DIR" | sed 's|\\\\|/|g; s|\\|/|g; s|C:/Users/[^/]*/|~/|i')

# Git info via the TTL cache (cached_git_info → git_info on miss). Parsed with
# cut: `IFS=$'\t' read` would treat the leading TAB of a non-repo /
# detached-HEAD line (empty field 1) as IFS-whitespace and drop the field,
# shifting every value. cut -f keeps empty fields verbatim.
GI_LINE=$(cached_git_info)
BRANCH=$(printf '%s' "$GI_LINE" | cut -f1)
ADD_FILES=$(printf '%s' "$GI_LINE" | cut -f2)
MOD_FILES=$(printf '%s' "$GI_LINE" | cut -f3)
DEL_FILES=$(printf '%s' "$GI_LINE" | cut -f4)
LINES_ADD=$(printf '%s' "$GI_LINE" | cut -f5)
LINES_DEL=$(printf '%s' "$GI_LINE" | cut -f6)

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

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
# When `ps` is entirely unusable (no output from any ps form — e.g.
# Windows/MSYS where ps -efww/-ef/-Wef return nothing), is_shell_alive
# cannot tell a live PID-less bg-shell from a dead one. Such rows are KEPT
# (fail-safe) but reaped once older than this many seconds so a dead shell
# cannot linger / grow the state file. Only affects the ps-unusable path;
# ps-working hosts never hit it. Independent of WORKERS_SHELL_MAX_AGE.
: "${WORKERS_SHELL_UNKNOWN_MAX_AGE:=60}"
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
# Returns: 0=alive (ps had output, fp matched); 1=dead (ps had output but
# no match, or empty fp/cmd); 2=ps unusable (all ps forms empty) — caller
# decides keep-vs-reap.
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
  [ -z "$out" ] && return 2        # ps unusable → unknown (NOT dead)
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
          is_shell_alive "$col5"; local sa=$?
          if [ "$sa" -eq 1 ]; then
            keep=false                       # ps worked, process gone
          elif [ "$sa" -eq 2 ]; then
            # ps unusable: cannot disprove liveness → keep, but bound so a
            # dead shell on a permanently-ps-blind box can't linger. age is
            # already computed above when col6 (start_unix) is valid; if
            # col6 is unusable the row is corrupt/unbounded → reap.
            if [ -n "$col6" ] && [ "$col6" -gt 0 ] 2>/dev/null; then
              [ "$age" -gt "$WORKERS_SHELL_UNKNOWN_MAX_AGE" ] && keep=false
            else
              keep=false
            fi
          fi
          # sa == 0 → keep (alive)
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

  # Group rows by kind (col1). Group order is decided by the caller (layout)
  # via positional args; no args → default `agent shell`. Within each group
  # the original state-file order (== launch order) is preserved — awk is a
  # stable single pass. Unknown arg tokens never match a row and are inert;
  # any kind not named in the order is appended last in first-seen order so a
  # future new kind can't silently vanish. The downstream WORKERS_MAX cap and
  # width truncation then apply to this regrouped sequence unchanged.
  # Contract: each arg is a single whitespace-free, backslash-free kind name
  # (the awk `split(order," ")` and `awk -v` escaping assume this — true for
  # the only kinds, `agent`/`shell`).
  [ "$#" -eq 0 ] && set -- agent shell
  local g order=""
  for g in "$@"; do
    case " $order " in *" $g "*) ;; *) order="${order:+$order }$g" ;; esac
  done
  rendered="$(printf '%s\n' "$rendered" | awk -F'\t' -v order="$order" '
    BEGIN { maxr = split(order, ord, " "); for (i = 1; i <= maxr; i++) rank[ord[i]] = i }
    $0 == "" { next }
    { k = $1; if (!(k in rank)) rank[k] = ++maxr
      r = rank[k]; bucket[r] = bucket[r] $0 ORS }
    END { for (i = 1; i <= maxr; i++) if (i in bucket) printf "%s", bucket[i] }
  ')"
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

# Parse the statusLine JSON ($1) into globals. Pure (no stdin/render side
# effects) so the lib loader can test it. §8.3 Task B: ONE `jq --raw-output0`
# pass replaces ~30 `echo|grep -o` forks (spec §4.1–§4.4). jq is a render-side
# hard dep (already a hook-side one); on jq absent/too-old/malformed input the
# 8 reads leave SESSION_ID empty and the render gate emits the §4.6 notice.
# SANITIZED_SID/WORKERS_STATE_FILE are kept here as fork-free var assignments
# (no I/O); the gate's empty-SESSION_ID guard exits before anything WRITES
# state-*.tsv, preserving spec §4.6 (deviation noted in spec §10).
parse_status_json() {
  local input="$1"
  local _jqfilter='
    .session_id // "",
    .model.display_name // "",
    .workspace.current_dir // "",
    ((.context_window.used_percentage // 0) | floor),
    ((.rate_limits.five_hour.used_percentage // "") | (if type=="number" then floor else . end)),
    (.rate_limits.five_hour.resets_at // ""),
    ((.rate_limits.seven_day.used_percentage // "") | (if type=="number" then floor else . end)),
    (.rate_limits.seven_day.resets_at // "")'
  SESSION_ID=""; MODEL=""; DIR=""; CTX_PCT=""
  RATE5_PCT=""; RATE5_RESET=""; RATE7_PCT=""; RATE7_RESET=""
  # --raw-output0: raw scalars (backslashes stay SINGLE — no @tsv re-doubling)
  # NUL-delimited (no \n, so winget jq's CRLF line-xlate never runs). Not
  # chained with ||/&& (spec §4.7): a normal "rate_limits absent" payload
  # must not abort the render.
  {
    IFS= read -r -d '' SESSION_ID
    IFS= read -r -d '' MODEL
    IFS= read -r -d '' DIR
    IFS= read -r -d '' CTX_PCT
    IFS= read -r -d '' RATE5_PCT
    IFS= read -r -d '' RATE5_RESET
    IFS= read -r -d '' RATE7_PCT
    IFS= read -r -d '' RATE7_RESET
  } < <(printf '%s' "$input" | jq --raw-output0 "$_jqfilter")
  MODEL="${MODEL%% (*}"                              # strip " (…)" suffix
  SANITIZED_SID="${SESSION_ID//[^A-Za-z0-9_-]/_}"    # tr -c equivalent, no fork
  WORKERS_STATE_FILE="$HOME/.claude/oh-my-claude/state/state-${SANITIZED_SID}.tsv"
  WORKDIR_RAW="$DIR"                                 # raw jq value, single backslashes
  [ -n "${OMC_DEBUG_DUMP_WORKDIR_RAW:-}" ] && printf 'WORKDIR_RAW=%s\n' "$WORKDIR_RAW" >&2
  # Windows path → ~/relative (display). Faithfully reproduces the old
  # `sed 's|\\|/|g; s|C:/Users/[^/]*/|~/|i'`: drive C only (case-insensitive),
  # Users case-insensitive, one segment; other drives unchanged.
  DIR="${DIR//\\//}"
  if [[ "$DIR" =~ ^[Cc]:/[Uu][Ss][Ee][Rr][Ss]/[^/]*/(.*)$ ]]; then
    DIR="~/${BASH_REMATCH[1]}"
  fi
}

# Split cached_git_info's 6 TAB fields into globals. §8.3 Task C: zero-fork
# (was 6× `cut`). Translate TAB→US (\x1f) then `IFS=$'\x1f' read`: \x1f is
# NOT IFS-whitespace so an empty leading BRANCH (non-repo / detached HEAD,
# locked d85481a) is preserved — a naive `IFS=$'\t' read` would drop it.
# git refnames forbid control chars ⇒ cached_git_info output can never
# contain \x1f ⇒ collision-free (spec §4.5). Byte-identical to the old cut.
split_gi_line() {
  local GI_LINE="$1" _gi
  _gi="${GI_LINE//$'\t'/$'\x1f'}"
  IFS=$'\x1f' read -r BRANCH ADD_FILES MOD_FILES DEL_FILES LINES_ADD \
    LINES_DEL <<<"$_gi"
}

# ---------------------------------------------------------------------------
# Render pipeline — gated so test loaders can source this file without
# blocking on stdin or triggering side-effects.
# ---------------------------------------------------------------------------
if [ -z "${OMC_TEST_LIB_ONLY:-}" ]; then

# Read JSON input from stdin
input=$(cat)
parse_status_json "$input"
# jq-failure / empty-session guard (spec §4.6). `.session_id` is documented
# always-present, so an empty SESSION_ID unambiguously means jq is absent,
# too old (`--raw-output0` unknown), or `$input` was malformed. One cheap
# test, no extra fork — and it runs BEFORE cached_git_info/render so no
# state-*.tsv is ever written on the failure path. Same effective outcome as
# the old grep code (empty session → no useful statusline), but loud.
if [ -z "$SESSION_ID" ]; then
  printf 'oh-my-claude: jq required (winget install jqlang.jq)\n'
  exit 0
fi
GI_LINE=$(cached_git_info)
split_gi_line "$GI_LINE"

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

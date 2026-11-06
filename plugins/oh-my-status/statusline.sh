#!/bin/bash
# oh-my-claude - Themeable statusline for Claude Code
# https://github.com/anthropics/claude-code

# Use BASH_SOURCE so this resolves correctly whether the file is executed
# directly or sourced (e.g. by statusline.sh.lib_test_loader.sh).
case ${BASH_SOURCE[0]} in */*|*\\*) SCRIPT_DIR=${BASH_SOURCE[0]%[/\\]*} ;; *) SCRIPT_DIR=. ;; esac
OMC_DIR="${OMC_DIR:-$SCRIPT_DIR}"
OMC_CONF="${OMC_CONF:-$HOME/.claude/oh-my-claude.conf}"

# Defaults
THEME="catppuccin"
LAYOUT="default"

# Load config
[ -f "$OMC_CONF" ] && source "$OMC_CONF"

# git_info() result cache TTL (seconds). Makes a statusLine
# refreshInterval (opt-in; if used, 10 or more) affordable by not running
# git every tick. 0 = disable caching (always
# recompute = exact legacy behavior). Non-numeric/negative → 3.
: "${GIT_CACHE_TTL:=3}"
# Account segment (spec §3.1). ACCOUNT_ICON is dash form: explicit "" disables it.
: "${ACCOUNT_SHOW:=true}"
: "${ACCOUNT_FORMAT:=name}"
# Model context tag (spec §8): append " [NM]" to MODEL when context size >= 1M.
: "${MODEL_CTX_TAG:=true}"
ACCOUNT_ICON="${ACCOUNT_ICON-$'\xef\x80\x87'}"

OMC_STATE_DIR="${OMC_STATE_DIR:-$HOME/.claude/oh-my-claude/state}"

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

# Clock without a fork on bash >= 5 (EPOCHSECONDS); `date` otherwise.
# OMC_NOW_OVERRIDE is the test-only clock seam. Sets REPLY.
_omc_now() { REPLY=${OMC_NOW_OVERRIDE:-${EPOCHSECONDS:-$(date +%s)}}; }

# _omc_strftime <fmt in date syntax, without '+'> <epoch> -> REPLY.
# printf '%()T' only for a plain decimal integer (no leading zero: printf would
# read it as octal; at most 15 digits: larger values error out); everything
# else runs the old `date` chain verbatim, so odd resets_at values keep their
# old output (e.g. "" or "abc" -> empty).
_omc_strftime() {
  if [[ $2 =~ ^(0|[1-9][0-9]{0,14})$ ]] && (( BASH_VERSINFO[0] > 4 || (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] >= 2) )); then
    printf -v REPLY "%($1)T" "$2"
  else
    REPLY=$(date -d "@$2" "+$1" 2>/dev/null || date -r "$2" "+$1" 2>/dev/null)
  fi
}

# Sweep crash-orphaned temp files (>30s old) from the state dir. A writer
# SIGKILL'd between creating its temp file and the atomic rename leaves a
# `gitcache-*.tmp.<pid>` (cached_git_info) or `account-*.tmp.<pid>` behind.
# A live writer renames its temp file within the
# same sub-second critical section, so 30s is far past any legitimate
# lifetime — nothing in use is ever swept. Best-effort, never fatal.
# The 24h sweep in setup.sh (SessionStart) is the coarse backstop; this keeps the dir tidy
# within a long-lived session. An unmatched glob stays literal and is
# filtered out by the `[ -f ]` test.
_omc_sweep_stale_tmp() {
  local now="" mt f
  for f in "$OMC_STATE_DIR"/gitcache-*.tmp.* "$OMC_STATE_DIR"/account-*.tmp.*; do
    [ -f "$f" ] || continue
    # The clock is only needed once a real orphan exists.
    if [ -z "$now" ]; then _omc_now; now=$REPLY; fi
    mt=$(stat -c %Y "$f" 2>/dev/null) || continue
    [ $((now - mt)) -gt 30 ] && rm -f "$f" 2>/dev/null
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
  # `git status` opportunistically refreshes the index, taking .git/index.lock.
  # Claude Code kills a statusline that overruns its budget; a git killed
  # mid-refresh leaves a stale 0-byte index.lock that blocks the user's own
  # `git add`/`commit`. GIT_OPTIONAL_LOCKS=0 skips that optional write. `local`
  # + export scopes it to this function and the git children it spawns
  # (including the nested ones under `submodule foreach`).
  local GIT_OPTIONAL_LOCKS=0; export GIT_OPTIONAL_LOCKS
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
# in — NOT current_dir (display-only), which differs from
# $PWD under MSYS). Makes an opt-in statusLine refreshInterval affordable. OMC_STATE_DIR
# is set at the top of this file. Stale-write
# safety: per-cwd file + atomic tmp+mv (no lock;
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
    _omc_now; now=$REPLY
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
  { printf '%s' "$out" > "$file.tmp.$$" && mv "$file.tmp.$$" "$file"; } 2>/dev/null  # atomic
  printf '%s' "$out"
}

# The 9 NUL-delimited reads of parse_status_json (stdin = jq output).
_omc_read_status_fields() {
  IFS= read -r -d '' SESSION_ID
  IFS= read -r -d '' MODEL
  IFS= read -r -d '' DIR
  IFS= read -r -d '' CTX_PCT
  IFS= read -r -d '' RATE5_PCT
  IFS= read -r -d '' RATE5_RESET
  IFS= read -r -d '' RATE7_PCT
  IFS= read -r -d '' RATE7_RESET
  IFS= read -r -d '' CTX_SIZE
}

# Parse the statusLine JSON into globals: from $1 when given (tests), else from the
# inherited stdin (render path). Pure (no render side
# effects) so the lib loader can test it. §8.3 Task B: ONE `jq --raw-output0`
# pass replaces ~30 `echo|grep -o` forks (spec §4.1–§4.4). jq is a render-side
# hard dep (already a hook-side one); on jq absent/too-old/malformed input the
# 9 reads leave SESSION_ID empty and the render gate emits the §4.6 notice.
# SANITIZED_SID is a fork-free var assignment (no I/O); the gate's
# empty-SESSION_ID guard exits before anything is written (spec §4.6).
parse_status_json() {
  local _jqfilter='
    .session_id // "",
    .model.display_name // "",
    .workspace.current_dir // "",
    ((.context_window.used_percentage // 0) | floor),
    ((.rate_limits.five_hour.used_percentage // "") | (if type=="number" then floor else . end)),
    (.rate_limits.five_hour.resets_at // ""),
    ((.rate_limits.seven_day.used_percentage // "") | (if type=="number" then floor else . end)),
    (.rate_limits.seven_day.resets_at // ""),
    ((.context_window.context_window_size // 0) | (if type=="number" and . >= 0 and . < 1e15 then floor else 0 end))'
  SESSION_ID=""; MODEL=""; DIR=""; CTX_PCT=""
  RATE5_PCT=""; RATE5_RESET=""; RATE7_PCT=""; RATE7_RESET=""; CTX_SIZE=""
  # --raw-output0: raw scalars (backslashes stay SINGLE — no @tsv re-doubling)
  # NUL-delimited (no \n, so winget jq's CRLF line-xlate never runs). Not
  # chained with ||/&& (spec §4.7): a normal "rate_limits absent" payload
  # must not abort the render.
  if [ $# -gt 0 ]; then
    _omc_read_status_fields < <(jq --raw-output0 "$_jqfilter" <<<"$1")
  else
    # No argument: jq reads the stdin this shell inherited (a procsub child
    # inherits it), so the render path needs no `cat`.
    _omc_read_status_fields < <(jq --raw-output0 "$_jqfilter")
  fi
  MODEL="${MODEL%% (*}"                              # strip " (…)" suffix
  SANITIZED_SID="${SESSION_ID//[^A-Za-z0-9_-]/_}"    # tr -c equivalent, no fork
  # Windows path → ~/relative (display). Faithfully reproduces the old
  # `sed 's|\\|/|g; s|C:/Users/[^/]*/|~/|i'`: drive C only (case-insensitive),
  # Users case-insensitive, one segment; other drives unchanged.
  DIR="${DIR//\\//}"
  if [[ "$DIR" =~ ^[Cc]:/[Uu][Ss][Ee][Rr][Ss]/[^/]*/(.*)$ ]]; then
    DIR="~/${BASH_REMATCH[1]}"
  fi
}

# Model context tag (spec §8.2). Pure, builtin-only, `set -u` safe. The regex
# check precedes any arithmetic so CTX_SIZE is never evaluated unchecked.
apply_model_ctx_tag() {
  [ "${MODEL_CTX_TAG-}" = true ] || return 0
  [ -n "${MODEL-}" ] || return 0
  [[ ${CTX_SIZE-} =~ ^[1-9][0-9]{0,14}$ ]] || return 0
  if [ "$CTX_SIZE" -ge 1000000 ]; then
    MODEL="${MODEL} [$((CTX_SIZE / 1000000))M]"
  fi
}

# Account segment (spec §3.2/§3.3). Sets ACC_NAME/ACC_FULL/ACC_EMAIL/ACC_ORG,
# already sanitized and backslash-doubled (safe for `echo -e`). MUST be called
# directly, never inside $( ), so the globals survive and a hit forks nothing.
cached_account_fields() {
  ACC_NAME=""; ACC_FULL=""; ACC_EMAIL=""; ACC_ORG=""
  [ "$ACCOUNT_SHOW" = true ] || return 0
  local src cache raw rc
  local _accfilter='(.oauthAccount? | objects) // {} | [.displayName, .fullName, .emailAddress, .organizationName]
    | map((. // "") | tostring | gsub("[\u0000-\u001f\u007f-\u009f]"; "")
          | gsub("^[[:space:]]+|[[:space:]]+$"; "") | gsub("\\\\"; "\\\\"))
    | join("\u001f")'
  src="${OMC_ACCOUNT_FILE:-${CLAUDE_CONFIG_DIR:-$HOME}/.claude.json}"
  [ -f "$src" ] || return 0
  cache="$OMC_STATE_DIR/account-${src//[^A-Za-z0-9]/-}"
  if [ -f "$cache" ] && ! [ "$src" -nt "$cache" ]; then
    IFS=$'\x1f' read -r ACC_NAME ACC_FULL ACC_EMAIL ACC_ORG < "$cache"
    return 0
  fi
  raw=$(jq -j "$_accfilter" "$src" 2>/dev/null)
  rc=$?
  if [ "$rc" -ne 0 ] || [ -z "$raw" ]; then
    # Failure / half-written source: serve the old cache if any, write nothing.
    if [ -f "$cache" ]; then
      IFS=$'\x1f' read -r ACC_NAME ACC_FULL ACC_EMAIL ACC_ORG < "$cache"
    fi
    return 0
  fi
  [ -d "$OMC_STATE_DIR" ] || mkdir -p "$OMC_STATE_DIR" 2>/dev/null
  { printf '%s\n' "$raw" > "$cache.tmp.$$" && mv -f "$cache.tmp.$$" "$cache"; } 2>/dev/null
  IFS=$'\x1f' read -r ACC_NAME ACC_FULL ACC_EMAIL ACC_ORG <<<"$raw"
  return 0
}

# ACCOUNT from ACCOUNT_FORMAT: first non-empty field in the chain wins.
resolve_account() {
  case "$ACCOUNT_FORMAT" in
    fullname) ACCOUNT="${ACC_FULL:-${ACC_NAME:-$ACC_EMAIL}}" ;;
    email)    ACCOUNT="$ACC_EMAIL" ;;
    org)      ACCOUNT="${ACC_ORG:-$ACC_EMAIL}" ;;
    *)        ACCOUNT="${ACC_NAME:-${ACC_FULL:-$ACC_EMAIL}}" ;;
  esac
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
parse_status_json
# jq-failure / empty-session guard (spec §4.6). `.session_id` is documented
# always-present, so an empty SESSION_ID unambiguously means jq is absent,
# too old (`--raw-output0` unknown), or `$input` was malformed. One cheap
# test, no extra fork — and it runs BEFORE cached_git_info/render so no
# git or cache work happens on the failure path. Same effective outcome as
# the old grep code (empty session → no useful statusline), but loud.
if [ -z "$SESSION_ID" ]; then
  printf 'oh-my-claude: jq required (winget install jqlang.jq)\n'
  exit 0
fi
# Usage file for oh-my-knowledge auto-handoff (builtins only).
[ -d "$OMC_STATE_DIR" ] || mkdir -p "$OMC_STATE_DIR" 2>/dev/null
[ -n "$CTX_PCT" ] && { printf '%s %s\n' "$CTX_PCT" "$CTX_SIZE" > "$OMC_STATE_DIR/ctx-$SANITIZED_SID"; } 2>/dev/null
apply_model_ctx_tag
# Reap any crash-orphaned temp files before this render writes its own.
_omc_sweep_stale_tmp
GI_LINE=$(cached_git_info)
split_gi_line "$GI_LINE"
cached_account_fields; resolve_account

# Rate limit reset info
RATE5_SUFFIX=""
if [ "${RATE5_PCT:-0}" -gt 80 ] && [ -n "$RATE5_RESET" ]; then
  _omc_strftime '%H:%M' "$RATE5_RESET"; RATE5_HOUR=$REPLY
  RATE5_SUFFIX=" (${RATE5_HOUR})"
fi
RATE7_SUFFIX=""
if [ "${RATE7_PCT:-0}" -gt 80 ] && [ -n "$RATE7_RESET" ]; then
  _omc_strftime '%m/%d' "$RATE7_RESET"; RATE7_DATE=$REPLY
  RATE7_SUFFIX=" (${RATE7_DATE})"
fi

render

fi # end OMC_TEST_LIB_ONLY gate

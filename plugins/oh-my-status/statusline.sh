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
# recompute = exact legacy behavior). Non-numeric/negative → 10.
: "${GIT_CACHE_TTL:=10}"
# Account segment. ACCOUNT_ICON is dash form: explicit "" disables it.
: "${ACCOUNT_SHOW:=true}"
: "${ACCOUNT_FORMAT:=name}"
# Where the name comes from: config (default) = ~/.claude.json only; auto = the
# account that owns this session's token (see _omc_profile_account).
: "${ACCOUNT_SOURCE:=config}"
# Model context tag: append " [NM]" to MODEL when context size >= 1M.
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
# Two git calls on the normal path (status -b, diff --numstat); the branch
# comes from the `status -b` header and the counting is done in bash with the
# same predicates the old grep/awk used. If `git status` fails (dubious
# ownership, corrupt index, bare repo, cwd inside .git, git without
# --no-ahead-behind) the old command sequence runs, so every error edge keeps
# its old answer. Submodule guard: submodules are scanned only when
# .gitmodules exists at the toplevel.
git_info() {
  local branch="" add=0 mod=0 del=0 ladd=0 ldel=0 toplevel
  # `git status` opportunistically refreshes the index, taking .git/index.lock.
  # Claude Code kills a statusline that overruns its budget; a git killed
  # mid-refresh leaves a stale 0-byte index.lock that blocks the user's own
  # `git add`/`commit`. GIT_OPTIONAL_LOCKS=0 skips that optional write. `local`
  # + export scopes it to this function and the git children it spawns
  # (including the nested ones under `submodule foreach`).
  local GIT_OPTIONAL_LOCKS=0; export GIT_OPTIONAL_LOCKS
  # Not inside any repo (and no GIT_* env): same answer git would give, no process.
  _omc_git_walk
  [ "$_OMC_GIT_FOUND" = none ] && { printf '\t0\t0\t0\t0\t0'; return; }
  # `$(exec 2>/dev/null; git ...)` instead of `$(git ... 2>/dev/null)`: bash only
  # execs the last command of a command substitution in place (no extra fork)
  # when that command has no redirections of its own.
  local st h sub_status="" diff_stats has_sub="" l a d
  if ! st=$(exec 2>/dev/null; git status --porcelain -b -uall --no-ahead-behind); then
    _omc_git_info_legacy; return
  fi
  # Toplevel (for the .gitmodules check): the walk's root; git decides when the
  # walk could not (GIT_* env, bash < 5, cwd gone).
  if [ "$_OMC_GIT_FOUND" = repo ]; then toplevel=$_OMC_GIT_ROOT
  else toplevel=$(git rev-parse --show-toplevel 2>/dev/null); fi
  [ -n "$toplevel" ] || { _omc_git_info_legacy; return; }
  h=${st%%$'\n'*}
  case $h in
    '## HEAD (no branch)') branch= ;;
    '## No commits yet on '*) branch=${h#'## No commits yet on '}; branch=${branch%%...*} ;;
    '## Initial commit on '*) branch=${h#'## Initial commit on '}; branch=${branch%%...*} ;;
    '## '*) branch=${h#'## '}; branch=${branch%%...*} ;;
  esac
  [ -f "$toplevel/.gitmodules" ] && has_sub=1
  if [ -n "$has_sub" ]; then
    sub_status=$(git submodule foreach --quiet 'git status --porcelain -uall 2>/dev/null' 2>/dev/null)
    diff_stats=$(git diff HEAD --numstat 2>/dev/null; git submodule foreach --quiet 'git diff HEAD --numstat 2>/dev/null' 2>/dev/null)
  else
    diff_stats=$(exec 2>/dev/null; git diff HEAD --numstat)
  fi
  # Same predicates as the former grep -c: add ^A|^??, mod ^ M|^M|^AM, del ^ D|^D
  # (AM counts in both add and mod). The header and blank lines match nothing.
  while IFS= read -r l; do
    case $l in A*|'??'*) add=$((add + 1)) ;; esac
    case $l in ' M'*|M*|AM*) mod=$((mod + 1)) ;; esac
    case $l in ' D'*|D*) del=$((del + 1)) ;; esac
  done <<< "$st"$'\n'"$sub_status"
  # numstat columns are TAB-separated (paths last); binary "-" counts as 0.
  while IFS=$'\t' read -r a d _; do
    [[ $a =~ ^[0-9]+$ ]] && ladd=$((ladd + 10#$a))
    [[ $d =~ ^[0-9]+$ ]] && ldel=$((ldel + 10#$d))
  done <<< "$diff_stats"
  printf '%s\t%s\t%s\t%s\t%s\t%s' "$branch" "$add" "$mod" "$del" "$ladd" "$ldel"
}

# The pre-5.2 command sequence, kept verbatim as the fallback when
# `git status -b --no-ahead-behind` fails. Runs under git_info's exported
# GIT_OPTIONAL_LOCKS=0. Prints the 6-field line itself.
_omc_git_info_legacy() {
  local branch="" add=0 mod=0 del=0 ladd=0 ldel=0 toplevel
  if toplevel=$(git rev-parse --show-toplevel 2>/dev/null) && [ -n "$toplevel" ]; then
    branch=$(git branch --show-current 2>/dev/null)
    local status sub_status all_status diff_stats has_sub=""
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

# Locate the enclosing git repo with builtins only (no git process). Sets
# _OMC_GIT_FOUND = repo | none | env | skip, plus _OMC_GIT_ROOT / _OMC_GIT_DIR /
# _OMC_GIT_COMMON (repo only) and _OMC_GIT_WD (the $PWD the result belongs to).
#   none = no repo above the cwd (and no GIT_* env): safe to skip git entirely.
#   env  = GIT_DIR/GIT_WORK_TREE/GIT_COMMON_DIR set: git decides, no shortcut.
#   skip = bash < 5 or the cwd is gone: no shortcut, no invalidation.
# Walks the PHYSICAL cwd (what git uses): bash on Linux/macOS keeps an
# inherited logical $PWD that may go through symlinks. The result is memoized
# per $PWD.
_omc_git_walk() {
  if (( BASH_VERSINFO[0] < 5 )) || ! cd -P -e . 2>/dev/null; then
    _OMC_GIT_FOUND=skip _OMC_GIT_WD= _OMC_GIT_ROOT= _OMC_GIT_DIR= _OMC_GIT_COMMON=; return 0
  fi
  [ "${_OMC_GIT_WD-}" = "$PWD" ] && [ -n "${_OMC_GIT_FOUND-}" ] && return 0
  _OMC_GIT_WD=$PWD _OMC_GIT_ROOT= _OMC_GIT_DIR= _OMC_GIT_COMMON=
  if [ -n "${GIT_DIR-}${GIT_WORK_TREE-}${GIT_COMMON_DIR-}" ]; then _OMC_GIT_FOUND=env; return 0; fi
  case $PWD in /*) ;; *) _OMC_GIT_FOUND=skip; return 0 ;; esac   # defensive; cd -P yields an absolute path
  local d=$PWD l c
  while :; do
    if [ -d "$d/.git" ]; then
      # git skips a .git dir that is not a repo and keeps walking; so do we.
      if [ -f "$d/.git/HEAD" ] && [ -d "$d/.git/objects" ]; then _OMC_GIT_DIR=$d/.git; break; fi
    elif [ -f "$d/.git" ]; then
      l=; IFS= read -r l < "$d/.git" || [ -n "$l" ] || :
      case $l in "gitdir: "*) l=${l#gitdir: } ;; *) l= ;; esac
      case $l in /*|[A-Za-z]:*) ;; ?*) l=$d/$l ;; esac
      _OMC_GIT_DIR=$l; break                      # any gitfile = found; git decides
    fi
    [ -z "$d" ] && { _OMC_GIT_FOUND=none; return 0; }
    d=${d%/*}
  done
  _OMC_GIT_ROOT=${d:-/}; _OMC_GIT_FOUND=repo; _OMC_GIT_COMMON=$_OMC_GIT_DIR
  if [ -n "$_OMC_GIT_DIR" ] && [ -f "$_OMC_GIT_DIR/commondir" ]; then
    c=; IFS= read -r c < "$_OMC_GIT_DIR/commondir" || [ -n "$c" ] || :
    case $c in /*|[A-Za-z]:*) _OMC_GIT_COMMON=$c ;; ?*) _OMC_GIT_COMMON=$_OMC_GIT_DIR/$c ;; esac
  fi
}

# Git-info cache (sets the global GI_LINE = 6 TAB fields). Keyed by the
# physical cwd. File gitcache-<key> holds "<epoch>\t<6 fields>\n"; the empty
# file gitcache-<key>.stamp is created BEFORE git runs, so any repo write during
# git_info is newer than the stamp and the next render misses.
# A hit needs: a complete line (read rc 0; a missing trailing newline = torn
# write = miss), the 7-field guard, age <= TTL, and the stamp strictly newer
# than HEAD, index, logs/HEAD, the branch ref, packed-refs and reftable's
# tables.list. So a branch switch / commit / stage shows at the next render,
# while edits to working-tree files show within the TTL. No git, no cat, no
# subshell on a hit. Non-repo dirs never run git.
_omc_cached_git_info() {
  local ttl="$GIT_CACHE_TTL" wd key file stamp line epoch age out T=$'\t' re
  case "$ttl" in ''|*[!0-9]*) ttl=10 ;; esac
  _omc_git_walk
  if [ "$_OMC_GIT_FOUND" = none ]; then GI_LINE=$'\t0\t0\t0\t0\t0'; return; fi
  if [ "$ttl" = 0 ]; then GI_LINE=$(git_info); return; fi
  if [ "$_OMC_GIT_FOUND" = skip ]; then wd=$(pwd -P 2>/dev/null)   # bash < 5 or cd failed: old key path
  else wd=$PWD; fi                                                # the walk already did `cd -P -e .`
  # cwd gone (getcwd fails): compute fresh and write nothing, so a missing cwd
  # can never poison a shared key.
  [ -n "$wd" ] || { GI_LINE=$(git_info); return; }
  key=${wd//[^A-Za-z0-9]/-}; file="$OMC_STATE_DIR/gitcache-$key"; stamp="$file.stamp"
  if [ -f "$file" ] && [ -f "$stamp" ] && IFS= read -r line < "$file"; then
    re="^(0|[1-9][0-9]{0,17})${T}[^${T}]*${T}[0-9]+${T}[0-9]+${T}[0-9]+${T}[0-9]+${T}[0-9]+$"
    if [[ $line =~ $re ]]; then
      _omc_now; epoch=${line%%"$T"*}; age=$((REPLY - epoch))
      if [ "$age" -le "$ttl" ] && _omc_git_fresh "$stamp"; then GI_LINE=${line#*"$T"}; return; fi
    fi
  fi
  [ -d "$OMC_STATE_DIR" ] || mkdir -p "$OMC_STATE_DIR" 2>/dev/null
  { : > "$stamp"; } 2>/dev/null; _omc_now; epoch=$REPLY
  out=$(git_info)
  { printf '%s\t%s\n' "$epoch" "$out" > "$file"; } 2>/dev/null
  GI_LINE=$out
}
# 0 iff the stamp ($1) is strictly newer than every existing invalidation file.
_omc_git_fresh() {
  [ "$_OMC_GIT_FOUND" = repo ] || return 0
  local gd=$_OMC_GIT_DIR cdir=$_OMC_GIT_COMMON h= f ref=
  IFS= read -r h < "$gd/HEAD" 2>/dev/null || [ -n "$h" ] || :
  case $h in "ref: "*) ref="$cdir/${h#ref: }" ;; esac
  for f in "$gd/HEAD" "$gd/index" "$gd/logs/HEAD" "$cdir/packed-refs" "$cdir/reftable/tables.list" ${ref:+"$ref"}; do
    [ -e "$f" ] || continue
    [[ $1 -nt $f ]] || return 1
  done
  return 0
}
# Printing wrapper kept for the tests (and as the old public name).
cached_git_info() { _omc_cached_git_info; printf '%s' "$GI_LINE"; }

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
# effects) so the lib loader can test it. ONE `jq --raw-output0`
# pass replaces ~30 `echo|grep -o` forks. jq is a render-side
# hard dep (already a hook-side one); on jq absent/too-old/malformed input the
# 9 reads leave SESSION_ID empty and the render gate emits a notice.
# SANITIZED_SID is a fork-free var assignment (no I/O); the gate's
# empty-SESSION_ID guard exits before anything is written.
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
  # chained with ||/&&: a normal "rate_limits absent" payload
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

# Model context tag. Pure, builtin-only, `set -u` safe. The regex
# check precedes any arithmetic so CTX_SIZE is never evaluated unchecked.
apply_model_ctx_tag() {
  [ "${MODEL_CTX_TAG-}" = true ] || return 0
  [ -n "${MODEL-}" ] || return 0
  [[ ${CTX_SIZE-} =~ ^[1-9][0-9]{0,14}$ ]] || return 0
  if [ "$CTX_SIZE" -ge 1000000 ]; then
    MODEL="${MODEL} [$((CTX_SIZE / 1000000))M]"
  fi
}

# jq fragments shared by the .oauthAccount filter and the profile lookup: turn
# four fields into display-safe strings (control characters stripped, trimmed,
# backslashes doubled so `echo -e` cannot reinterpret them). _OMC_ACC_CLEAN maps
# an array; _OMC_ACC_SANITIZE additionally joins it with US (\x1f).
_OMC_ACC_CLEAN='map((. // "") | tostring | gsub("[\u0000-\u001f\u007f-\u009f]"; "")
          | gsub("^[[:space:]]+|[[:space:]]+$"; "") | gsub("\\\\"; "\\\\"))'
_OMC_ACC_SANITIZE="$_OMC_ACC_CLEAN"' | join("\u001f")'

# Stale profile cache: start at most one background lookup per lease. The lease
# is the epoch in <cache>.stamp; it is open when the stamp is missing, older
# than the credentials file, not a plain epoch, in the future, or more than 300
# seconds old, so a lookup that never finished (killed, offline, revoked token)
# is retried instead of blocking forever. The stamp is written before the fork;
# if that write fails nothing is launched, so an unwritable state dir cannot
# fork on every render. Always returns 1 (this render uses .oauthAccount).
_omc_profile_lease() {
  local stamp="$_OMC_PCACHE.stamp" line="" now
  if [ -f "$stamp" ] && ! [ "$_OMC_CRED" -nt "$stamp" ]; then
    IFS= read -r line < "$stamp" || :
    if [[ $line =~ ^(0|[1-9][0-9]{0,17})$ ]]; then
      _omc_now; now=$REPLY
      if [ "$line" -le "$now" ] && [ $((now - line)) -le 300 ]; then return 1; fi
    fi
  fi
  _omc_now; now=$REPLY
  [ -d "$OMC_STATE_DIR" ] || mkdir -p "$OMC_STATE_DIR" 2>/dev/null
  { printf '%s\n' "$now" > "$stamp"; } 2>/dev/null || return 1
  if [ -n "${OMC_PROFILE_FETCH_SYNC-}" ]; then
    ( _omc_profile_fetch "$_OMC_CRED" "$_OMC_PCACHE" )
  else
    { _omc_profile_fetch "$_OMC_CRED" "$_OMC_PCACHE" </dev/null >/dev/null 2>&1 & } 2>/dev/null
    disown 2>/dev/null || :
  fi
  return 1
}

# Look up the account that owns the token in <cred> and write the four display
# fields to <cache> (atomically), or write nothing. Runs in a subshell; never
# prints. The token goes jq -> curl's config on stdin and nowhere else (not
# argv, env, a variable or a file), and only tokens made of plain token
# characters are used, so the config needs no quoting; the trailing-newline test
# is separate because jq's `$` also matches before a final newline. `tr -d '\r'`
# strips the CRs that a Windows jq adds to every newline it prints. The
# temp-file marker, created with a plain touch when the lookup starts, decides
# "credentials changed meanwhile" (the shared stamp may be rewritten by another
# session); a result for a token that has since been replaced is discarded and
# the next render relaunches.
_omc_profile_fetch() {
  local cred=$1 cache=$2 tmp mark line
  local tok='.claudeAiOauth.accessToken | strings | select(test("^[A-Za-z0-9._~+/=-]+$") and (endswith("\n") | not))'
  local cfg='"url = \"https://api.anthropic.com/api/oauth/profile\"\nheader = \"Authorization: Bearer \(.)\"\nheader = \"anthropic-beta: oauth-2025-04-20\"\n"'
  local parse='select(type == "object" and (.account | type) == "object")
    | [.account.display_name, .account.full_name, .account.email, ((.organization? | objects | .name) // "")]
    | '"$_OMC_ACC_CLEAN"' | select(any(.[]; length > 0)) | join("\u001f")'
  tmp="$cache.tmp.$BASHPID"; mark="$tmp.m"
  touch "$mark" 2>/dev/null || return 0
  if jq -e "$tok" "$cred" >/dev/null 2>&1; then
    line=$(jq -j "$tok | $cfg" "$cred" 2>/dev/null | tr -d '\r' \
      | curl -sf -m 10 -K - 2>/dev/null | jq -j "$parse" 2>/dev/null)
    if [ -n "$line" ] && { printf '%s\n' "$line" > "$tmp"; } 2>/dev/null; then
      if [ -e "$mark" ] && ! [ "$cred" -nt "$mark" ]; then mv -f "$tmp" "$cache" 2>/dev/null; fi
    fi
  fi
  rm -f "$tmp" "$mark" 2>/dev/null
  return 0
}

# Source 1 of the account segment: the account that owns this session's OAuth
# token. ~/.claude.json (.oauthAccount) is only a display cache shared by every
# Claude client on the machine, so it can name a different account than the one
# whose credentials this session bills; the credentials file is the truth.
# Sets ACC_* and returns 0 on a fresh profile cache; returns 1 otherwise and the
# caller falls through to .oauthAccount. Builtins only; a stale cache may start a
# background lookup (see _omc_profile_lease).
_omc_profile_account() {
  [ "${ACCOUNT_SOURCE-}" = auto ] || return 1
  # The session bills one of these instead of the credentials file.
  [ -z "${CLAUDE_CODE_OAUTH_TOKEN-}" ] && [ -z "${ANTHROPIC_API_KEY-}" ] \
    && [ -z "${ANTHROPIC_AUTH_TOKEN-}" ] && [ -z "${CLAUDE_CODE_USE_BEDROCK-}" ] \
    && [ -z "${CLAUDE_CODE_USE_VERTEX-}" ] || return 1
  _OMC_CRED="${OMC_CREDENTIALS_FILE:-${CLAUDE_CONFIG_DIR:-$HOME/.claude}/.credentials.json}"
  [ -f "$_OMC_CRED" ] || return 1
  _OMC_PCACHE="$OMC_STATE_DIR/account-profile-${_OMC_CRED//[^A-Za-z0-9]/-}"
  if [ -f "$_OMC_PCACHE" ] && ! [ "$_OMC_CRED" -nt "$_OMC_PCACHE" ]; then
    IFS=$'\x1f' read -r ACC_NAME ACC_FULL ACC_EMAIL ACC_ORG < "$_OMC_PCACHE"
    [ -n "$ACC_NAME$ACC_FULL$ACC_EMAIL$ACC_ORG" ] && return 0
    ACC_NAME=""; ACC_FULL=""; ACC_EMAIL=""; ACC_ORG=""
  fi
  _omc_profile_lease
}

# Account segment. Sets ACC_NAME/ACC_FULL/ACC_EMAIL/ACC_ORG,
# already sanitized and backslash-doubled (safe for `echo -e`). MUST be called
# directly, never inside $( ), so the globals survive and a hit forks nothing.
cached_account_fields() {
  ACC_NAME=""; ACC_FULL=""; ACC_EMAIL=""; ACC_ORG=""
  [ "$ACCOUNT_SHOW" = true ] || return 0
  _omc_profile_account && return 0
  local src cache raw rc
  local _accfilter='(.oauthAccount? | objects) // {} | [.displayName, .fullName, .emailAddress, .organizationName]
    | '"$_OMC_ACC_SANITIZE"
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

# Split cached_git_info's 6 TAB fields into globals. Zero-fork
# (was 6× `cut`). Translate TAB→US (\x1f) then `IFS=$'\x1f' read`: \x1f is
# NOT IFS-whitespace so an empty leading BRANCH (non-repo / detached HEAD,
# locked d85481a) is preserved — a naive `IFS=$'\t' read` would drop it.
# git refnames forbid control chars ⇒ cached_git_info output can never
# contain \x1f ⇒ collision-free. Byte-identical to the old cut.
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
# jq-failure / empty-session guard. `.session_id` is documented
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
_omc_cached_git_info
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
  _omc_strftime '%m/%d %H:%M' "$RATE7_RESET"; RATE7_DATE=$REPLY
  RATE7_SUFFIX=" (${RATE7_DATE})"
fi

render

fi # end OMC_TEST_LIB_ONLY gate

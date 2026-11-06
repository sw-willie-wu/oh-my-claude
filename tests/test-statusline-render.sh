#!/bin/bash
# Render-side tests: feed statusline.sh known JSON + state, assert output.
set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"

# shellcheck source=test-helpers.sh
. "$SCRIPT_DIR/test-helpers.sh"

STATUSLINE="$REPO_ROOT/plugins/oh-my-status/statusline.sh"

# Strip ANSI escape sequences so we can measure visible width and assert on text.
strip_ansi() {
  sed -E 's/\x1b\[[0-9;]*[a-zA-Z]//g'
}

# Render with a given session_id from a non-repo cwd. State goes to
# $OMC_STATE_DIR (set by test-helpers.sh to a private mktemp dir), never to
# the real ~/.claude.
run_render() {  # $1=sid $2=cols
  local nogit; nogit=$(mktemp -d)
  ( cd "$nogit" && COLUMNS="${2:-120}" OMC_CONF=/dev/null bash -c "printf '%s' '{\"session_id\":\"$1\",\"model\":{\"display_name\":\"X\"},\"workspace\":{\"current_dir\":\"/tmp\"}}' | bash '$STATUSLINE' 2>/dev/null" )
  rm -rf "$nogit"
}

printf 'Running statusline render tests\n\n'

# --- Task A: git_info() extracted, pure, 6 TAB-joined fields ---
call_git_info() {
  # $1 = directory to cd into before running git_info (git uses ambient $PWD)
  ( cd "$1" && bash -c "
    OMC_TEST_LIB_ONLY=1
    source '$STATUSLINE'
    git_info
  " )
}

start_test "git_info: in a git repo, field 1 is the current branch and there are 6 TAB fields"
GI_REPO=$(mktemp -d)
(
  cd "$GI_REPO"
  git init -q .
  git config user.email t@t.t
  git config user.name t
  echo a > tracked.txt
  git add tracked.txt
  git commit -qm init
  git branch -m omcbranch
  echo b >> tracked.txt          # modified tracked file
  echo c > untracked.txt         # untracked file
)
GI_OUT=$(call_git_info "$GI_REPO")
GI_NF=$(printf '%s' "$GI_OUT" | awk -F'\t' '{print NF}')
assert_eq "6" "$GI_NF" "git_info must emit exactly 6 TAB-separated fields"
GI_BRANCH=$(printf '%s' "$GI_OUT" | cut -f1)
assert_eq "omcbranch" "$GI_BRANCH" "field 1 must be the current branch"
rm -rf "$GI_REPO"
end_test

start_test "git_info: outside a git repo emits empty branch and five zeros"
GI_NONREPO=$(mktemp -d)
GI_OUT=$(call_git_info "$GI_NONREPO")
GI_EXPECT=$(printf '\t0\t0\t0\t0\t0')
assert_eq "$GI_EXPECT" "$GI_OUT" "non-repo must be empty-branch + five zero counts"
rm -rf "$GI_NONREPO"
end_test

start_test "git_info: detached HEAD emits empty branch field but still 6 fields"
GI_DET=$(mktemp -d)
(
  cd "$GI_DET"
  git init -q .
  git config user.email t@t.t
  git config user.name t
  echo a > f.txt; git add f.txt; git commit -qm c1
  echo b > f.txt; git add f.txt; git commit -qm c2
  git checkout -q HEAD~1          # detached HEAD
)
GI_OUT=$(call_git_info "$GI_DET")
GI_BRANCH=$(printf '%s' "$GI_OUT" | cut -f1)
assert_eq "" "$GI_BRANCH" "detached HEAD must yield empty branch field 1"
GI_NF=$(printf '%s' "$GI_OUT" | awk -F'\t' '{print NF}')
assert_eq "6" "$GI_NF" "detached HEAD still emits 6 fields"
rm -rf "$GI_DET"
end_test

# --- P4 Task 4.1: _omc_git_walk (builtin repo discovery) ---
# Every row runs in its own process: the walk memoizes on $PWD, and GIT_* env
# changes inside one process would see a stale result.
gi_mkrepo() {  # $1=dir $2=initial branch name
  mkdir -p "$1"
  ( cd "$1" && git init -q . && git config user.email t@t.t && git config user.name t \
      && echo a > f.txt && git add f.txt && git commit -qm i && git branch -m "$2" )
}
walk_in() {  # $1=dir ; extra env via prefix ; prints FOUND|ROOT|DIR|COMMON
  ( cd "$1" && OMC_CONF=/dev/null bash -c '
      OMC_TEST_LIB_ONLY=1
      source "$0"
      _omc_git_walk
      printf "%s|%s|%s|%s" "$_OMC_GIT_FOUND" "$_OMC_GIT_ROOT" "$_OMC_GIT_DIR" "$_OMC_GIT_COMMON"' "$STATUSLINE" )
}
phys() { ( cd "$1" && pwd -P ); }   # normalized physical path (resolves .. and symlinks)

start_test "walk: plain repo, cwd in a subdir"
WR=$(mktemp -d); gi_mkrepo "$WR" main; mkdir -p "$WR/sub/deep"; P=$(phys "$WR")
IFS='|' read -r f r d c <<<"$(walk_in "$WR/sub/deep")"
assert_eq "repo" "$f" "found"; assert_eq "$P" "$r" "root"
assert_eq "$P/.git" "$d" "dir"; assert_eq "$P/.git" "$c" "common"
rm -rf "$WR"
end_test

start_test "walk: worktree resolves the relative commondir"
WR=$(mktemp -d); gi_mkrepo "$WR/main" main; git -C "$WR/main" worktree add -q "$WR/wt" -b wtb >/dev/null 2>&1
P=$(phys "$WR")
IFS='|' read -r f r d c <<<"$(walk_in "$WR/wt")"
assert_eq "repo" "$f" "found"; assert_eq "$P/wt" "$r" "root"
case "$(phys "$d")" in "$P/main/.git/worktrees/"*) ;; *) printf '    FAIL: dir %s not under main/.git/worktrees/\n' "$d" >&2; TEST_FAILED=1 ;; esac
assert_eq "$P/main/.git" "$(phys "$c")" "common (relative commondir resolved)"
rm -rf "$WR"
end_test

start_test "walk: worktree with an absolute commondir"
WR=$(mktemp -d); gi_mkrepo "$WR/main" main; git -C "$WR/main" worktree add -q "$WR/wt" -b wtb >/dev/null 2>&1
ABS=$(phys "$WR/main/.git"); command -v cygpath >/dev/null 2>&1 && ABS=$(cygpath -m "$ABS")
for cdf in "$WR"/main/.git/worktrees/*/commondir; do printf '%s\n' "$ABS" > "$cdf"; done
IFS='|' read -r f r d c <<<"$(walk_in "$WR/wt")"
assert_eq "repo" "$f" "found"; assert_eq "$ABS" "$c" "common is the absolute path as written"
rm -rf "$WR"
end_test

start_test "walk: a .git dir without HEAD, or without objects/, above a real repo is skipped"
WR=$(mktemp -d); gi_mkrepo "$WR" main; P=$(phys "$WR")
mkdir -p "$WR/a/.git" "$WR/b/.git"; echo 'ref: refs/heads/x' > "$WR/b/.git/HEAD"
IFS='|' read -r f r d c <<<"$(walk_in "$WR/a")"
assert_eq "repo" "$f" "no-HEAD: found"; assert_eq "$P" "$r" "no-HEAD: real repo root"
IFS='|' read -r f r d c <<<"$(walk_in "$WR/b")"
assert_eq "repo" "$f" "no-objects: found"; assert_eq "$P" "$r" "no-objects: real repo root"
rm -rf "$WR"
end_test

start_test "walk: non-repo directory finds nothing"
WR=$(mktemp -d)
assert_eq "none|||" "$(walk_in "$WR")" "non-repo"
rm -rf "$WR"
end_test

start_test "walk: GIT_DIR set -> env (no shortcut)"
WR=$(mktemp -d)
assert_eq "env" "$(GIT_DIR=x walk_in "$WR" | cut -d'|' -f1)" "GIT_DIR"
assert_eq "env" "$(GIT_WORK_TREE=x walk_in "$WR" | cut -d'|' -f1)" "GIT_WORK_TREE"
assert_eq "env" "$(GIT_COMMON_DIR=x walk_in "$WR" | cut -d'|' -f1)" "GIT_COMMON_DIR"
rm -rf "$WR"
end_test

start_test "walk: empty \$PWD inside the script is restored by cd -P -e ."
WR=$(mktemp -d); gi_mkrepo "$WR" main; mkdir -p "$WR/sub"; P=$(phys "$WR")
OUT=$( cd "$WR/sub" && OMC_CONF=/dev/null bash -c '
    OMC_TEST_LIB_ONLY=1
    source "$0"
    PWD=""
    _omc_git_walk
    printf "%s|%s" "$_OMC_GIT_FOUND" "$_OMC_GIT_ROOT"' "$STATUSLINE" )
assert_eq "repo|$P" "$OUT" "found with empty PWD"
rm -rf "$WR"
end_test

start_test "walk: cwd reached through a symlink resolves to the physical repo"
WR=$(mktemp -d); WL=$(mktemp -d); gi_mkrepo "$WR" main; mkdir -p "$WR/sub"; ln -s "$WR/sub" "$WL/link" 2>/dev/null
if [ -L "$WL/link" ]; then
  P=$(phys "$WR")
  OUT=$( cd "$WL/link" && OMC_CONF=/dev/null bash -c '
      OMC_TEST_LIB_ONLY=1
      source "$0"
      _omc_git_walk
      printf "%s|%s" "$_OMC_GIT_FOUND" "$_OMC_GIT_ROOT"' "$STATUSLINE" )
  assert_eq "repo|$P" "$OUT" "found via symlink, physical root"
else
  printf '    SKIP: ln -s does not create symlinks here\n'
fi
rm -rf "$WR" "$WL"
end_test

# --- Task B: cached_git_info() + GIT_CACHE_TTL ---
# Cache-layer tests stub git_info() by REDEFINING it after sourcing (function
# resolution is dynamic, so cached_git_info calls the stub). This decouples
# the cache logic from real git. The stub bumps a persistent counter file so HIT
# (no bump) vs MISS (bump) is observable across separate processes. Work dirs
# get a minimal fake repo (.git/HEAD + .git/objects/) so the walk finds a
# "repo" and the stub is still reached; its HEAD is old, so the stamp is
# strictly newer. The clock is driven by OMC_NOW_OVERRIDE.
# $1=workdir(cd target → $PWD = cache key) $2=OMC_STATE_DIR $3=GIT_CACHE_TTL
# $4=stub output (default well-formed 6-field line)
cgi() {
  local out="${4:-$(printf 'stub\t1\t2\t3\t4\t5')}"
  ( cd "$1" && OMC_STATE_DIR="$2" GIT_CACHE_TTL="$3" STUB_OUT="$out" OMC_CONF=/dev/null \
       OMC_NOW_OVERRIDE="${OMC_NOW_OVERRIDE:-}" bash -c '
      OMC_TEST_LIB_ONLY=1
      source "'"$STATUSLINE"'"
      CNT="$OMC_STATE_DIR/.gitcnt"
      [ -f "$CNT" ] || echo 0 > "$CNT"
      git_info() { echo $(( $(cat "$CNT") + 1 )) > "$CNT"; printf "%s" "$STUB_OUT"; }
      cached_git_info
  ' )
}
cgi_wd() {  # a temp dir with a minimal fake repo whose files are old
  local d; d=$(mktemp -d); mkdir -p "$d/.git/objects"; echo 'ref: refs/heads/x' > "$d/.git/HEAD"
  touch -d @1000000000 "$d/.git/HEAD" "$d/.git/objects"; printf '%s' "$d"
}
cache_file() { ls "$1"/gitcache-* 2>/dev/null | grep -v '\.stamp$' | head -1; }
STUB_LINE=$(printf 'stub\t1\t2\t3\t4\t5')
E=1000000000

start_test "cached_git_info: miss invokes git_info once; cache file is '<epoch>TAB<line>' + newline; stamp written"
ST=$(mktemp -d); WD=$(cgi_wd)
OUT=$(OMC_NOW_OVERRIDE=$E cgi "$WD" "$ST" 3)
assert_eq "$STUB_LINE" "$OUT" "miss must return git_info output"
assert_eq "1" "$(cat "$ST/.gitcnt")" "git_info called exactly once on miss"
CF=$(cache_file "$ST")
[ -n "$CF" ] || { printf '    FAIL: no cache file created\n' >&2; TEST_FAILED=1; }
assert_eq "$(printf '%s\t%s\nX' "$E" "$STUB_LINE")" "$(cat "$CF" 2>/dev/null; printf X)" "cache file content incl. trailing newline"
[ -f "$CF.stamp" ] || { printf '    FAIL: no .stamp file\n' >&2; TEST_FAILED=1; }
rm -rf "$ST" "$WD"
end_test

start_test "cached_git_info: fresh cache is a HIT (git_info not re-invoked)"
ST=$(mktemp -d); WD=$(cgi_wd)
OUT1=$(cgi "$WD" "$ST" 300); OUT2=$(cgi "$WD" "$ST" 300)
assert_eq "1" "$(cat "$ST/.gitcnt")" "second call must be a cache HIT (counter stays 1)"
assert_eq "$STUB_LINE" "$OUT2" "HIT returns cached content"
rm -rf "$ST" "$WD"
end_test

start_test "cached_git_info: TTL boundary is <= (age==TTL HIT, age==TTL+1 MISS)"
ST=$(mktemp -d); WD=$(cgi_wd)
OMC_NOW_OVERRIDE=$E cgi "$WD" "$ST" 3 >/dev/null               # miss → counter=1
OMC_NOW_OVERRIDE=$((E + 3)) cgi "$WD" "$ST" 3 >/dev/null       # age == TTL(3)
assert_eq "1" "$(cat "$ST/.gitcnt")" "age == TTL must be a HIT (<= boundary, not <)"
OMC_NOW_OVERRIDE=$((E + 4)) cgi "$WD" "$ST" 3 >/dev/null       # age == TTL+1
assert_eq "2" "$(cat "$ST/.gitcnt")" "age == TTL+1 must MISS (boundary excludes above)"
rm -rf "$ST" "$WD"
end_test

start_test "cached_git_info: GIT_CACHE_TTL=0 disables caching (no file, every call computes)"
ST=$(mktemp -d); WD=$(cgi_wd)
cgi "$WD" "$ST" 0 >/dev/null; cgi "$WD" "$ST" 0 >/dev/null
assert_eq "2" "$(cat "$ST/.gitcnt")" "TTL=0 must compute every call"
ls "$ST"/gitcache-* >/dev/null 2>&1 \
  && { printf '    FAIL: TTL=0 must not write a cache file\n' >&2; TEST_FAILED=1; }
rm -rf "$ST" "$WD"
end_test

start_test "cached_git_info: distinct \$PWD yields distinct cache files"
ST=$(mktemp -d); WD1=$(cgi_wd); WD2=$(cgi_wd)
cgi "$WD1" "$ST" 3 >/dev/null; cgi "$WD2" "$ST" 3 >/dev/null
N=$(ls "$ST"/gitcache-* 2>/dev/null | grep -vc '\.stamp$')
assert_eq "2" "$N" "two different workdirs must key two different cache files"
rm -rf "$ST" "$WD1" "$WD2"
end_test

# Guard tests: overwrite the cache with a damaged file after a normal miss at
# epoch E, then render again at E (age 0, so only the guard can cause a miss).
guard_case() {  # $1=label $2=printf format (one %s = E)
  local ST WD CF
  ST=$(mktemp -d); WD=$(cgi_wd)
  OMC_NOW_OVERRIDE=$E cgi "$WD" "$ST" 300 >/dev/null            # counter=1, valid cache
  CF=$(cache_file "$ST")
  # shellcheck disable=SC2059
  printf "$2" "$E" > "$CF"
  OMC_NOW_OVERRIDE=$E cgi "$WD" "$ST" 300 >/dev/null
  assert_eq "2" "$(cat "$ST/.gitcnt")" "$1 must fail the guard → recompute"
  rm -rf "$ST" "$WD"
}
start_test "cached_git_info: malformed cache files fail the guard and recompute"
guard_case "5-field line" '%s\tbad\t1\t2\t3\t4\n'
guard_case "0-byte file" ''
guard_case "line without trailing newline" '%s\tstub\t1\t2\t3\t4\t5'
guard_case "old 6-field format" 'stub\t1\t2\t3\t4\t5\n'
guard_case "epoch with a leading zero (09, invalid octal)" '09\tmain\t0\t0\t0\t0\t0\n'
end_test

start_test "cached_git_info: valid non-repo line passes the guard and HITs"
ST=$(mktemp -d); WD=$(cgi_wd)
NONREPO=$(printf '\t0\t0\t0\t0\t0')
cgi "$WD" "$ST" 300 "$NONREPO" >/dev/null
OUT2=$(cgi "$WD" "$ST" 300 "$NONREPO")
assert_eq "1" "$(cat "$ST/.gitcnt")" "non-repo line (empty field1) must pass guard → HIT"
assert_eq "$NONREPO" "$OUT2" "HIT returns the cached non-repo line"
rm -rf "$ST" "$WD"
end_test

start_test "cached_git_info: non-numeric/negative/empty GIT_CACHE_TTL fall back to 10"
for bad in abc -5 ''; do
  ST=$(mktemp -d); WD=$(cgi_wd)
  OMC_NOW_OVERRIDE=$E cgi "$WD" "$ST" "$bad" >/dev/null
  OMC_NOW_OVERRIDE=$((E + 10)) cgi "$WD" "$ST" "$bad" >/dev/null
  assert_eq "1" "$(cat "$ST/.gitcnt")" "'$bad' → 10: age 10 must HIT"
  OMC_NOW_OVERRIDE=$((E + 11)) cgi "$WD" "$ST" "$bad" >/dev/null
  assert_eq "2" "$(cat "$ST/.gitcnt")" "'$bad' → 10: age 11 must MISS"
  rm -rf "$ST" "$WD"
done
end_test

start_test "cached_git_info: no .tmp.* leftover after a normal miss (direct write)"
ST=$(mktemp -d); WD=$(cgi_wd)
cgi "$WD" "$ST" 3 >/dev/null
ls "$ST"/gitcache-*.tmp.* >/dev/null 2>&1 \
  && { printf '    FAIL: temp file left behind\n' >&2; TEST_FAILED=1; }
rm -rf "$ST" "$WD"
end_test

start_test "cached_git_info: non-repo dir never calls git_info and writes no cache"
ST=$(mktemp -d); WD=$(mktemp -d)
OUT=$(cgi "$WD" "$ST" 300)
assert_eq "$(printf '\t0\t0\t0\t0\t0')" "$OUT" "non-repo line"
assert_eq "0" "$(cat "$ST/.gitcnt")" "git_info must not be called outside a repo"
ls "$ST"/gitcache-* >/dev/null 2>&1 && { printf '    FAIL: cache file written for a non-repo\n' >&2; TEST_FAILED=1; }
GIT_DIR=/nonexistent cgi "$WD" "$ST" 300 >/dev/null
assert_eq "1" "$(cat "$ST/.gitcnt")" "GIT_DIR set → git is consulted (no shortcut)"
rm -rf "$ST" "$WD"
end_test

# Invalidation: real repos, real git_info, TTL 300. A repo write must show at the next render.
cgr() {  # $1=dir $2=state ; prints the 6-field line via the real git_info
  ( cd "$1" && OMC_STATE_DIR="$2" GIT_CACHE_TTL=300 OMC_CONF=/dev/null bash -c '
      OMC_TEST_LIB_ONLY=1
      source "'"$STATUSLINE"'"
      cached_git_info' )
}
inval_case() {  # $1=label $2=repo-dir(cwd) $3=state $4=mutation command (run in $2)
  local before after
  before=$(cgr "$2" "$3")
  ( cd "$2" && eval "$4" ) >/dev/null 2>&1
  after=$(cgr "$2" "$3")
  [ "$before" != "$after" ] || { printf '    FAIL: %s: cached line did not change after the repo write [%s]\n' "$1" "$after" >&2; TEST_FAILED=1; }
}
inval_suite() {  # $1=kind(plain|wt|wtabs)
  local WR ST D ABS cdf
  WR=$(mktemp -d); ST=$(mktemp -d)
  gi_mkrepo "$WR/main" main
  D="$WR/main"
  if [ "$1" != plain ]; then
    git -C "$WR/main" worktree add -q "$WR/wt" -b wtb >/dev/null 2>&1; D="$WR/wt"
    git -C "$D" config user.email t@t.t; git -C "$D" config user.name t
    if [ "$1" = wtabs ]; then
      ABS=$(phys "$WR/main/.git"); command -v cygpath >/dev/null 2>&1 && ABS=$(cygpath -m "$ABS")
      for cdf in "$WR"/main/.git/worktrees/*/commondir; do printf '%s\n' "$ABS" > "$cdf"; done
    fi
  fi
  printf 'one\ntwo\nthree\n' > "$D/g.txt"
  inval_case "$1: git add" "$D" "$ST" 'git add g.txt'
  echo more >> "$D/f.txt"
  inval_case "$1: git commit" "$D" "$ST" 'git add -A; git commit -qm c'
  echo more >> "$D/f.txt"; git -C "$D" add f.txt
  inval_case "$1: commit with logAllRefUpdates=false" "$D" "$ST" 'git -c core.logAllRefUpdates=false commit -qm c2'
  inval_case "$1: branch -m" "$D" "$ST" 'git branch -m renamedbr'
  rm -rf "$WR" "$ST"
}
start_test "cache invalidation: add/commit/commit(no reflog)/branch -m show at once (plain repo)"
inval_suite plain
end_test
start_test "cache invalidation: same four writes in a worktree"
inval_suite wt
end_test
start_test "cache invalidation: same four writes in a worktree with an absolute commondir"
inval_suite wtabs
end_test

start_test "cache invalidation: a git write DURING the miss makes the next render miss (stamp written first)"
WR=$(mktemp -d); ST=$(mktemp -d); gi_mkrepo "$WR" main; echo x > "$WR/g.txt"
inflight() {
  ( cd "$WR" && OMC_STATE_DIR="$ST" GIT_CACHE_TTL=300 OMC_CONF=/dev/null bash -c '
      OMC_TEST_LIB_ONLY=1
      source "'"$STATUSLINE"'"
      CNT="$OMC_STATE_DIR/.gitcnt"; [ -f "$CNT" ] || echo 0 > "$CNT"
      git_info() { n=$(( $(cat "$CNT") + 1 )); echo $n > "$CNT"; [ "$n" = 1 ] && git add g.txt; printf "stub\t1\t2\t3\t4\t5"; }
      cached_git_info' )
}
inflight >/dev/null; inflight >/dev/null
assert_eq "2" "$(cat "$ST/.gitcnt")" "render after an in-flight git add must miss"
inflight >/dev/null
assert_eq "2" "$(cat "$ST/.gitcnt")" "and the one after that hits again"
rm -rf "$WR" "$ST"
end_test

# --- Task C: cached_git_info() wired into the render path ---
# run_render cannot steer the git cwd (it hardcodes current_dir:/tmp but git
# runs against $PWD) nor isolate the cache. This helper cd's into the target
# repo and passes OMC_STATE_DIR (and optional GIT_CACHE_TTL) into the render.
run_workers_in() {
  # $1=dir(cd → git cwd + cache key)  $2=sid  $3=OMC_STATE_DIR
  # $4=GIT_CACHE_TTL(optional)  $5=cols(default 200)
  local d="$1" sid="$2" sd="$3" ttl="${4:-}" cols="${5:-200}"
  (
    cd "$d" || exit 1
    export COLUMNS="$cols" OMC_CONF=/dev/null OMC_STATE_DIR="$sd"
    [ -n "$ttl" ] && export GIT_CACHE_TTL="$ttl"
    printf '{"session_id":"%s","model":{"display_name":"X"},"workspace":{"current_dir":"/tmp"}}' "$sid" \
      | bash "$STATUSLINE" 2>/dev/null
  )
}

start_test "render: git repo output shows the branch AND a gitcache file is written"
ST=$(mktemp -d); WD=$(mktemp -d)
gi_mkrepo "$WD" omcbranch
OUT=$(run_workers_in "$WD" "render-gc-1" "$ST" | strip_ansi)
echo "$OUT" | grep -qF 'omcbranch' \
  || { printf '    FAIL: branch not in render output\n      got: %q\n' "$OUT" >&2; TEST_FAILED=1; }
ls "$ST"/gitcache-* >/dev/null 2>&1 \
  || { printf '    FAIL: render wrote no gitcache file (cache not wired into render)\n' >&2; TEST_FAILED=1; }
rm -rf "$ST" "$WD"
end_test

start_test "render: second render within TTL serves STALE working-tree counts (cache wired in)"
ST=$(mktemp -d); WD=$(mktemp -d)
gi_mkrepo "$WD" stalebr
OUT1=$(run_workers_in "$WD" "render-gc-2" "$ST" 300 | strip_ansi)  # arg4=GIT_CACHE_TTL (300=large so 2nd render HITs)
echo more >> "$WD/f.txt"                                           # working-tree edit: no .git write
OUT=$(run_workers_in "$WD" "render-gc-2" "$ST" 300 | strip_ansi)
echo "$OUT1" | grep -qF '~1' && { printf '    FAIL: clean repo already shows ~1\n' >&2; TEST_FAILED=1; }
echo "$OUT" | grep -qF 'stalebr' \
  || { printf '    FAIL: branch missing from render\n      got: %q\n' "$OUT" >&2; TEST_FAILED=1; }
echo "$OUT" | grep -qF '~1' \
  && { printf '    FAIL: render showed fresh edit (cache not consulted)\n      got: %q\n' "$OUT" >&2; TEST_FAILED=1; }
OUT=$(run_workers_in "$WD" "render-gc-2" "$ST" 0 | strip_ansi)      # TTL=0 proves the edit is visible to git
echo "$OUT" | grep -qF '~1' \
  || { printf '    FAIL: edit not visible with TTL=0\n      got: %q\n' "$OUT" >&2; TEST_FAILED=1; }
rm -rf "$ST" "$WD"
end_test

start_test "render: a cache line whose epoch is '09' (invalid octal) is a miss and the render still completes"
ST=$(mktemp -d); WD=$(mktemp -d); gi_mkrepo "$WD" zerobr
run_workers_in "$WD" "render-gc-z" "$ST" 300 >/dev/null
CF=$(ls "$ST"/gitcache-* | grep -v '\.stamp$' | head -1)
printf '09\tmain\t0\t0\t0\t0\t0\n' > "$CF"
OUT=$(run_workers_in "$WD" "render-gc-z" "$ST" 300 | strip_ansi)
printf '%s\n' "$OUT" | head -1 | grep -qF 'X' \
  || { printf '    FAIL: render aborted / no model on line 1\n      got: %q\n' "$OUT" >&2; TEST_FAILED=1; }
echo "$OUT" | grep -qF 'zerobr' || { printf '    FAIL: branch missing (miss not recomputed)\n' >&2; TEST_FAILED=1; }
rm -rf "$ST" "$WD"
end_test

start_test "render: GIT_CACHE_TTL=0 serves fresh git state and writes no cache file"
ST=$(mktemp -d); WD=$(mktemp -d)
gi_mkrepo "$WD" freshbefore
run_workers_in "$WD" "render-gc-3" "$ST" 0 >/dev/null  # arg4=GIT_CACHE_TTL=0 (cache disabled)
( cd "$WD" && git branch -m freshafter )
OUT=$(run_workers_in "$WD" "render-gc-3" "$ST" 0 | strip_ansi)  # arg4=GIT_CACHE_TTL=0
echo "$OUT" | grep -qF 'freshafter' \
  || { printf '    FAIL: TTL=0 must show fresh state\n      got: %q\n' "$OUT" >&2; TEST_FAILED=1; }
ls "$ST"/gitcache-* >/dev/null 2>&1 \
  && { printf '    FAIL: TTL=0 must not write a cache file via render\n' >&2; TEST_FAILED=1; }
rm -rf "$ST" "$WD"
end_test

# --- Bugfix: empty $PWD must not collapse the cache key (cross-repo collision)
# Real Claude Code can invoke the statusLine command with $PWD empty; the
# original key=slug($PWD) then became "" so every repo shared one
# "gitcache-" file → wrong repo's git info served. Key must come from the
# actual cwd (pwd -P = getcwd), robust to an empty $PWD variable.
cgi_emptypwd() {  # $1=repo dir  $2=OMC_STATE_DIR ; REAL git_info, $PWD forced empty
  ( cd "$1" && OMC_STATE_DIR="$2" OMC_CONF=/dev/null GIT_CACHE_TTL=300 bash -c '
      OMC_TEST_LIB_ONLY=1
      source "'"$STATUSLINE"'"
      PWD=""
      cached_git_info
  ' )
}

start_test "cached_git_info: empty \$PWD does not collide the cache across repos"
ST=$(mktemp -d); RA=$(mktemp -d); RB=$(mktemp -d)
gi_mkrepo "$RA" alpha
gi_mkrepo "$RB" beta
OA=$(cgi_emptypwd "$RA" "$ST" | cut -f1)
OB=$(cgi_emptypwd "$RB" "$ST" | cut -f1)
assert_eq "alpha" "$OA" "repoA with empty \$PWD must report its own branch"
assert_eq "beta"  "$OB" "repoB must NOT be served repoA's cached line (collision bug)"
ls "$ST"/gitcache- >/dev/null 2>&1 \
  && { printf '    FAIL: an empty-key gitcache- file was created (key collapsed)\n' >&2; TEST_FAILED=1; }
rm -rf "$ST" "$RA" "$RB"
end_test

# --- §8.1: git_info skips `git submodule foreach` when no .gitmodules ---
# `git submodule foreach` pays a ~7s MSYS process-startup cost even with zero
# submodules; git_info calls it twice (status+diff) ⇒ ~14s pure waste ⇒ blank
# statusline under load. A PATH-shim git records each `submodule` invocation.
gi_shim_setup() {  # $1 = workdir; installs fake git that logs submodule calls
  mkdir -p "$1/bin" "$1/.git/objects"; echo "ref: refs/heads/x" > "$1/.git/HEAD"   # fake repo: the walk must find one
  cat > "$1/bin/git" <<EOS
#!/bin/bash
case "\$1 \$2" in
  "rev-parse --show-toplevel") echo "$1"; exit 0 ;;
esac
case "\$1" in
  rev-parse) echo "$1"; exit 0 ;;
  branch) echo shimbr; exit 0 ;;
  status|diff) exit 0 ;;
  submodule) echo called >> "$1/.gitsentinel"; exit 0 ;;
  *) exit 0 ;;
esac
EOS
  chmod +x "$1/bin/git"
}
call_git_info_shimmed() {  # $1 = workdir
  ( cd "$1" && OMC_CONF=/dev/null PATH="$1/bin:$PATH" bash -c '
      OMC_TEST_LIB_ONLY=1
      source "'"$STATUSLINE"'"
      git_info
  ' )
}

start_test "git_info: NO .gitmodules → git submodule foreach is NOT invoked"
GW=$(mktemp -d); gi_shim_setup "$GW"           # no .gitmodules created
OUT=$(call_git_info_shimmed "$GW")
[ -f "$GW/.gitsentinel" ] \
  && { printf '    FAIL: submodule foreach invoked despite no .gitmodules (the ~14s waste)\n' >&2; TEST_FAILED=1; }
NF=$(printf '%s' "$OUT" | awk -F'\t' '{print NF}')
assert_eq "6" "$NF" "git_info still emits 6 fields"
assert_eq "shimbr" "$(printf '%s' "$OUT" | cut -f1)" "branch still resolved"
rm -rf "$GW"
end_test

start_test "git_info: .gitmodules present → submodule scanning still runs (no regression)"
GW=$(mktemp -d); gi_shim_setup "$GW"; : > "$GW/.gitmodules"
call_git_info_shimmed "$GW" >/dev/null
[ -f "$GW/.gitsentinel" ] \
  || { printf '    FAIL: submodule scan skipped even though .gitmodules exists\n' >&2; TEST_FAILED=1; }
rm -rf "$GW"
end_test

# --- GIT_OPTIONAL_LOCKS=0: git_info must not take .git/index.lock ---
# `git status` opportunistically refreshes the index (takes index.lock); when
# Claude Code kills a slow statusline mid-run the lock is left behind and
# blocks the user's `git add`/`commit`. Every git call git_info makes (incl.
# the nested ones inside `submodule foreach`, which inherit env) must see
# GIT_OPTIONAL_LOCKS=0, and the setting must not leak out of git_info.
gi_lockenv_setup() {  # $1 = workdir; fake git logging "<subcmd> <GIT_OPTIONAL_LOCKS>"
  mkdir -p "$1/bin" "$1/.git/objects"; echo "ref: refs/heads/x" > "$1/.git/HEAD"   # fake repo: the walk must find one
  cat > "$1/bin/git" <<EOS
#!/bin/bash
echo "\$1 \${GIT_OPTIONAL_LOCKS-unset}" >> "$1/.gitenvlog"
case "\$1 \$2" in
  "rev-parse --show-toplevel") echo "$1"; exit 0 ;;
esac
case "\$1" in
  branch) echo shimbr; exit 0 ;;
  *) exit 0 ;;
esac
EOS
  chmod +x "$1/bin/git"
}

start_test "git_info: every git call runs with GIT_OPTIONAL_LOCKS=0 (incl. submodule path)"
GW=$(mktemp -d); gi_lockenv_setup "$GW"; : > "$GW/.gitmodules"
( unset GIT_OPTIONAL_LOCKS; call_git_info_shimmed "$GW" >/dev/null )
for sub in rev-parse branch status diff submodule; do
  grep -q "^$sub " "$GW/.gitenvlog" 2>/dev/null \
    || { printf '    FAIL: expected a git %s call\n' "$sub" >&2; TEST_FAILED=1; }
done
BAD=$(grep -v ' 0$' "$GW/.gitenvlog" 2>/dev/null)
[ -z "$BAD" ] \
  || { printf '    FAIL: git ran without GIT_OPTIONAL_LOCKS=0:\n%s\n' "$BAD" >&2; TEST_FAILED=1; }
rm -rf "$GW"
end_test

start_test "git_info: GIT_OPTIONAL_LOCKS does not leak out of git_info"
GW=$(mktemp -d); gi_lockenv_setup "$GW"
LEAK=$( cd "$GW" && unset GIT_OPTIONAL_LOCKS && OMC_CONF=/dev/null PATH="$GW/bin:$PATH" bash -c '
    OMC_TEST_LIB_ONLY=1
    source "'"$STATUSLINE"'"
    git_info >/dev/null
    printf "%s" "${GIT_OPTIONAL_LOCKS-unset}"
' )
assert_eq "unset" "$LEAK" "GIT_OPTIONAL_LOCKS must be function-local"
rm -rf "$GW"
end_test

# --- §8.3 Task A: extract JSON parse + GI_LINE split into pure functions ---
# Fixture = the official Claude Code statusLine docs representative payload
# (code.claude.com/docs/en/statusline.md). Golden values hand-traced through
# the CURRENT (grep) logic so Task A proves a byte-identical pure refactor.
DOCS_JSON='{"cwd":"/c/w/d","session_id":"abc123...","model":{"id":"claude-opus-4-7","display_name":"Opus"},"workspace":{"current_dir":"/c/w/d"},"version":"2.1.90","context_window":{"used_percentage":8},"rate_limits":{"five_hour":{"used_percentage":23.5,"resets_at":1738425600},"seven_day":{"used_percentage":41.2,"resets_at":1738857600}}}'
call_parse() {  # $1=json → pipe-joined parsed fields
  bash -c '
    OMC_TEST_LIB_ONLY=1
    source "'"$STATUSLINE"'"
    parse_status_json "$1"
    printf "%s|%s|%s|%s|%s|%s|%s|%s|%s|%s\n" \
      "$SESSION_ID" "$SANITIZED_SID" "$MODEL" "$DIR" \
      "$CTX_PCT" "$RATE5_PCT" "$RATE5_RESET" "$RATE7_PCT" "$RATE7_RESET" \
      "$CTX_SIZE"
  ' _ "$1"
}
call_split() {  # $1=GI_LINE → pipe-joined 6 git vars
  bash -c '
    OMC_TEST_LIB_ONLY=1
    source "'"$STATUSLINE"'"
    split_gi_line "$1"
    printf "%s|%s|%s|%s|%s|%s\n" \
      "$BRANCH" "$ADD_FILES" "$MOD_FILES" "$DEL_FILES" "$LINES_ADD" "$LINES_DEL"
  ' _ "$1"
}

start_test "parse_status_json: docs fixture → fields match current grep behaviour"
GOT=$(call_parse "$DOCS_JSON")
# session|sanitized(.→_)|model|dir(norm)|ctx|r5%|r5reset|r7%|r7reset
# old grep: ctx=first used_percentage=8; r5%=grep[0-9]* of 23.5 → 23; r7%=41
assert_eq 'abc123...|abc123___|Opus|/c/w/d|8|23|1738425600|41|1738857600|0' \
  "$GOT" "parse_status_json must reproduce current grep extraction byte-for-byte"
end_test

start_test "split_gi_line: non-repo line keeps empty BRANCH + 6 fields"
GOT=$(call_split "$(printf '\t0\t0\t0\t0\t0')")
assert_eq '|0|0|0|0|0' "$GOT" "empty leading BRANCH preserved, 6 fields"
GOT=$(call_split "$(printf 'feat/x\t1\t2\t3\t4\t5')")
assert_eq 'feat/x|1|2|3|4|5' "$GOT" "normal branch + counts"
end_test

# §8.3 Task C: split_gi_line → zero-fork \x1f split (spec §4.5). Goldens
# pin the old `cut` behaviour byte-for-byte; the non-repo empty-BRANCH case
# above is the regression sentinel (a naive IFS=$'\t' read would drop it).
start_test "split_gi_line: detached HEAD (empty BRANCH) with non-zero counts"
GOT=$(call_split "$(printf '\t2\t3\t1\t40\t12')")
assert_eq '|2|3|1|40|12' "$GOT" "empty BRANCH preserved, non-zero counts intact"
end_test

start_test "split_gi_line: branch containing '/' with dirty counts"
GOT=$(call_split "$(printf 'feature/foo-bar\t0\t5\t0\t0\t0')")
assert_eq 'feature/foo-bar|0|5|0|0|0' "$GOT" "slash in refname survives split"
end_test

start_test "split_gi_line: short line (<6 fields) → trailing vars empty, parity with cut"
GOT=$(call_split "$(printf 'main\t1\t2')")
assert_eq 'main|1|2|||' "$GOT" "missing trailing fields empty, no spill (cut parity)"
end_test

# --- §8.3 Task B: parse_status_json → single jq pass. Spec §4.1–§4.4/§4.6. ---
# Goldens are the SPEC-pinned values: equivalence to the old grep where the
# spec preserves behaviour (dir norm, model
# suffix strip, SANITIZED_SID, fractional floor) and the spec-sanctioned
# improvements where jq is strictly more robust than positional grep (null /
# absent context_window ⇒ CTX 0, never a mis-grabbed rate used_percentage).
# JSON below uses literal `\\` (single-quoted, faithful) → valid JSON \\ →
# jq raw value has SINGLE backslashes.

start_test "parse_status_json: C:/c: → ~/, D: kept"
GOT=$(call_parse '{"session_id":"w","model":{"display_name":"X"},"workspace":{"current_dir":"C:\\Users\\willie\\proj"}}')
assert_eq 'w|w|X|~/proj|0|||||0' "$GOT" "C:\\Users\\ → ~/"
GOT=$(call_parse '{"session_id":"w","model":{"display_name":"X"},"workspace":{"current_dir":"c:\\users\\bob\\x"}}')
assert_eq 'w|w|X|~/x|0|||||0' "$GOT" "lowercase c:/users collapses (case-insensitive, old i flag)"
GOT=$(call_parse '{"session_id":"w","model":{"display_name":"X"},"workspace":{"current_dir":"D:\\Users\\bob\\x"}}')
assert_eq 'w|w|X|D:/Users/bob/x|0|||||0' "$GOT" "non-C drive NOT collapsed (old behaviour)"
end_test

start_test "parse_status_json: display_name \" (…)\" stripped; null context → CTX 0"
GOT=$(call_parse '{"session_id":"s2","model":{"display_name":"Opus 4.7 (1M context)"},"workspace":{"current_dir":"/home/u/p"},"context_window":{"used_percentage":null}}')
assert_eq 's2|s2|Opus 4.7|/home/u/p|0|||||0' "$GOT" "suffix stripped; null used_percentage → 0 (// 0 | floor)"
end_test

start_test "parse_status_json: absent context_window does NOT mis-grab a rate used_percentage"
GOT=$(call_parse '{"session_id":"s1","rate_limits":{"five_hour":{"used_percentage":50,"resets_at":111},"seven_day":{"used_percentage":60,"resets_at":222}}}')
assert_eq 's1|s1|||0|50|111|60|222|0' "$GOT" "CTX=0 via jq path, not 50 (old positional-grep bug); rates intact"
end_test

start_test "parse_status_json: fractional used_percentage floors; SANITIZED_SID maps non-alnum"
GOT=$(call_parse '{"session_id":"f","model":{"display_name":"Opus"},"workspace":{"current_dir":"/c/w/d"},"context_window":{"used_percentage":8},"rate_limits":{"five_hour":{"used_percentage":23.5,"resets_at":1738425600},"seven_day":{"used_percentage":41.2,"resets_at":1738857600}}}')
assert_eq 'f|f|Opus|/c/w/d|8|23|1738425600|41|1738857600|0' "$GOT" "23.5→23, 41.2→41 (floor), byte-identical to old grep [0-9]*"
GOT=$(call_parse '{"session_id":"a/b.c d","model":{"display_name":"X"},"workspace":{"current_dir":"/x"},"context_window":{"used_percentage":8}}')
assert_eq 'a/b.c d|a_b_c_d|X|/x|8|||||0' "$GOT" "SANITIZED_SID: non-alnum → _ (tr -c equivalent)"
end_test

# --- [1M] model context tag (spec §8.3): CTX_SIZE parse + apply_model_ctx_tag ---
start_test "parse_status_json: CTX_SIZE clamp table (spec §8.3.2)"
for pair in '1000000=1000000' '200000=200000' 'null=0' '"abc"=0' '-5=0' '1e20=0' \
            '9223372036854775807=0' '1500000.5=1500000'; do
  v="${pair%=*}"; want="${pair##*=}"
  js=$(jq -n -c --argjson v "$v" '{session_id:"c",model:{display_name:"X"},workspace:{current_dir:"/x"},context_window:{context_window_size:$v}}' | tr -d '\r')
  got=$(call_parse "$js"); got="${got##*|}"
  assert_eq "$want" "$got" "context_window_size=$v"
done
end_test

call_tag() {  # $1=MODEL $2=CTX_SIZE [$3=MODEL_CTX_TAG] → "MODEL|stderr"
  local errf; errf=$(mktemp)
  local out
  out=$(bash -c '
    OMC_TEST_LIB_ONLY=1
    source "'"$STATUSLINE"'"
    set -u
    MODEL="$1"; CTX_SIZE="$2"
    [ -n "${3-}" ] && MODEL_CTX_TAG="$3"
    apply_model_ctx_tag
    printf "%s" "$MODEL"
  ' _ "$1" "$2" "${3-}" 2>"$errf")
  printf '%s|%s' "$out" "$(cat "$errf")"; rm -f "$errf"
}
start_test "apply_model_ctx_tag: table (spec §8.3.3), stderr empty"
assert_eq 'X [1M]|' "$(call_tag X 1000000)" "1000000"
assert_eq 'X [2M]|' "$(call_tag X 2000000)" "2000000"
assert_eq 'X [1M]|' "$(call_tag X 1500000)" "1500000"
assert_eq 'X|' "$(call_tag X 200000)" "200000"
assert_eq 'X|' "$(call_tag X '')" "empty"
assert_eq 'X|' "$(call_tag X 08)" "08"
assert_eq 'X|' "$(call_tag X 99999999999999999999)" "huge"
assert_eq 'X|' "$(call_tag X 1000000 false)" "tag off"
assert_eq '|' "$(call_tag '' 1000000)" "empty MODEL"
end_test

start_test "apply_model_ctx_tag: set -u safe with CTX_SIZE/MODEL/MODEL_CTX_TAG unset"
err=$(bash -c 'OMC_TEST_LIB_ONLY=1; source "'"$STATUSLINE"'"; set -u; unset CTX_SIZE MODEL MODEL_CTX_TAG; apply_model_ctx_tag; echo done' 2>&1 >/dev/null)
assert_eq "" "$err" "no unbound variable error"
end_test

# Gate-level: jq failure (malformed input) and empty session_id both collapse
# to an empty SESSION_ID → the render gate emits a single notice + exit 0,
# BEFORE any git or cache work. Old grep code instead renders normally.
start_test "render gate: malformed input → jq-required notice, exit 0, no state write"
NOTICE='oh-my-claude: jq required (winget install jqlang.jq)'
OUT=$(printf 'not valid json at all' | bash "$STATUSLINE" 2>/dev/null); RC=$?
assert_eq "$NOTICE" "$OUT" "malformed JSON → exactly the jq-required notice"
assert_eq "0" "$RC" "notice path exits 0"
[ ! -e "$OMC_STATE_DIR/state-.tsv" ] \
  || { printf '    FAIL: state-.tsv written on jq-failure path\n' >&2; TEST_FAILED=1; }
end_test

start_test "render gate: empty session_id → jq-required notice, exit 0"
NOTICE='oh-my-claude: jq required (winget install jqlang.jq)'
OUT=$(echo '{"session_id":"","model":{"display_name":"X"},"workspace":{"current_dir":"/x"}}' | bash "$STATUSLINE" 2>/dev/null); RC=$?
assert_eq "$NOTICE" "$OUT" "empty session_id → notice (no broken statusline)"
assert_eq "0" "$RC" "empty-session notice path exits 0"
end_test

# --- helpers ---------------------------------------------------------------
# 1-based index of the first stripped output line containing $2 (literal),
# or 0 if absent. Used to assert relative render order.
line_index() {
  printf '%s\n' "$1" | grep -nF -- "$2" | head -1 | cut -d: -f1 | { read -r n; printf '%s' "${n:-0}"; }
}

start_test "fancy layout order: model, git, meters"
SID="render-test-fancy-order"
FREPO=$(mktemp -d)
git -C "$FREPO" init -q
git -C "$FREPO" symbolic-ref HEAD refs/heads/fancybrZ
FCONF="$OMC_STATE_DIR/fancy.conf"
printf 'THEME="catppuccin"\nLAYOUT="fancy"\n' > "$FCONF"
OUT="$(COLUMNS=200 OMC_CONF="$FCONF" bash -c "
  cd '$FREPO' && echo '{\"session_id\":\"$SID\",\"model\":{\"display_name\":\"FancyModelQ\"},\"workspace\":{\"current_dir\":\"$FREPO\"}}' \
    | bash '$STATUSLINE' 2>/dev/null
" | strip_ansi)"
rm -rf "$FREPO" "$FCONF"
I_G=$(line_index "$OUT" 'fancybrZ')
I_C=$(line_index "$OUT" 'ctx')
[ "$I_G" -gt 0 ] && [ "$I_C" -gt 0 ] \
  || { printf '    FAIL: git/ctx line missing (g=%s c=%s)\n      got: %q\n' "$I_G" "$I_C" "$OUT" >&2; TEST_FAILED=1; }
printf '%s\n' "$OUT" | head -1 | grep -qF 'FancyModelQ' \
  || { printf '    FAIL: line 1 is not the model line\n      got: %q\n' "$OUT" >&2; TEST_FAILED=1; }
[ "$I_G" -lt "$I_C" ] \
  || { printf '    FAIL: git not before meters (g=%s c=%s)\n      got: %q\n' "$I_G" "$I_C" "$OUT" >&2; TEST_FAILED=1; }
end_test

start_test "_omc_sweep_stale_tmp removes orphaned temp files older than 30s, keeps the rest"
ST=$(mktemp -d)
NOW=$(date +%s)
# Crash-orphaned temp files (60s old) — must be swept.
printf 'x' > "$ST/gitcache-somekey.tmp.222"
printf 'x' > "$ST/account-x.tmp.333"
touch -d "@$((NOW - 60))" "$ST/gitcache-somekey.tmp.222" "$ST/account-x.tmp.333"
# Fresh temp files + real cache files — must all survive.
printf 'x' > "$ST/gitcache-somekey.tmp.444"
printf 'x' > "$ST/account-x.tmp.555"
printf 'x' > "$ST/gitcache-somekey"
printf 'x' > "$ST/account-x"
bash -c "
  OMC_STATE_DIR='$ST'
  OMC_TEST_LIB_ONLY=1
  source '$STATUSLINE'
  _omc_sweep_stale_tmp
"
[ ! -f "$ST/gitcache-somekey.tmp.222" ] \
  || { printf '    FAIL: stale gitcache .tmp temp not swept\n' >&2; TEST_FAILED=1; }
[ ! -f "$ST/account-x.tmp.333" ] \
  || { printf '    FAIL: stale account .tmp temp not swept\n' >&2; TEST_FAILED=1; }
[ -f "$ST/gitcache-somekey.tmp.444" ] && [ -f "$ST/account-x.tmp.555" ] \
  || { printf '    FAIL: fresh temp file wrongly swept\n' >&2; TEST_FAILED=1; }
[ -f "$ST/gitcache-somekey" ] && [ -f "$ST/account-x" ] \
  || { printf '    FAIL: real cache file wrongly swept\n' >&2; TEST_FAILED=1; }
rm -rf "$ST"
end_test

start_test "a full render runs the stale-temp sweep (wiring, not just the unit)"
# statusline.sh's _omc_sweep_stale_tmp scans $OMC_STATE_DIR. The test
# harness exports OMC_STATE_DIR (test-helpers.sh) and start_test just
# recreated it empty, so seed the orphan there — that is the directory a
# real render's sweep actually targets. If the _omc_sweep_stale_tmp call
# were dropped from the render path, the unit test above would still pass
# but this assertion would catch the missing wiring.
NOW=$(date +%s)
ORPHAN="$OMC_STATE_DIR/gitcache-wire.tmp.99999"
printf 'x' > "$ORPHAN"
touch -d "@$((NOW - 60))" "$ORPHAN"
run_render "render-test-sweep-wiring" 120 >/dev/null
[ ! -f "$ORPHAN" ] \
  || { printf '    FAIL: full render did not sweep the orphaned temp file\n' >&2; TEST_FAILED=1; }
rm -f "$ORPHAN"
end_test

start_test "no workdir-raw variable left in tests or statusline"
tok=WORKDIR; tok+=_RAW   # built at runtime so this test's own source never matches
[ -f "$REPO_ROOT/plugins/oh-my-status/statusline.sh" ] || { printf '    FAIL: statusline.sh missing\n' >&2; TEST_FAILED=1; }
assert_eq "" "$(grep -rn -- "$tok" "$REPO_ROOT/tests" "$REPO_ROOT/plugins/oh-my-status/statusline.sh")" "variable removed"
end_test

# ---------------------------------------------------------------------------
# Task 3: account fields (cached_account_fields / resolve_account)
# ---------------------------------------------------------------------------
AT="$(mktemp -d -t omc-acct-XXXXXX)"
ALOG="$AT/shim.log"
ASHIM="$AT/shim"; make_jq_shim "$ASHIM" "$ALOG"
AFAIL="$AT/failshim"; make_jq_shim "$AFAIL" "$ALOG" fail

acct() {  # $1=fixture path; rest = VAR=val env; prints ACCOUNT|ACC_NAME|ACC_FULL|ACC_EMAIL|ACC_ORG
  local f="$1"; shift
  env OMC_ACCOUNT_FILE="$f" "$@" bash -c '
    OMC_TEST_LIB_ONLY=1; source "'"$STATUSLINE"'"
    declare -F cached_account_fields >/dev/null || { echo "NOFUNC"; exit 1; }   # no vacuous passes while RED
    cached_account_fields; resolve_account
    printf "%s|%s|%s|%s|%s\n" "$ACCOUNT" "$ACC_NAME" "$ACC_FULL" "$ACC_EMAIL" "$ACC_ORG"' | tr -d '\r'
}
acct1() { acct "$@" | cut -d'|' -f1; }
# mkfx <path> <displayName> <fullName> <email> <org> [age_sec=10]
mkfx() {
  mkdir -p "$(dirname "$1")"
  "$REAL_JQ" -nj --arg d "$2" --arg f "$3" --arg e "$4" --arg o "$5" \
    '{oauthAccount:{displayName:$d,fullName:$f,emailAddress:$e,organizationName:$o}}' > "$1"
  touch -d "@$(( $(date +%s) - ${6:-10} ))" "$1"
}
acache() { ls "$OMC_STATE_DIR"/account-* 2>/dev/null | grep -v '\.tmp\.' | head -1; }

start_test "T3.1 each ACCOUNT_FORMAT picks the right field (bogus -> name)"
FX="$AT/f1.json"; mkfx "$FX" willie willie_ttl w@x Org
for pair in name:willie fullname:willie_ttl email:w@x org:Org bogus:willie; do
  assert_eq "${pair#*:}" "$(acct1 "$FX" ACCOUNT_FORMAT="${pair%%:*}")" "format ${pair%%:*}"
done
end_test

start_test "T3.2 fallback chains"
FX="$AT/f2.json"
mkfx "$FX" "" willie_ttl w@x Org
assert_eq willie_ttl "$(acct1 "$FX")" "empty displayName -> fullName"
rm -f "$OMC_STATE_DIR"/account-*
mkfx "$FX" "" "" w@x Org
assert_eq w@x "$(acct1 "$FX")" "empty name+full -> email"
rm -f "$OMC_STATE_DIR"/account-*
mkfx "$FX" willie willie_ttl w@x ""
assert_eq w@x "$(acct1 "$FX" ACCOUNT_FORMAT=org)" "org empty -> email"
rm -f "$OMC_STATE_DIR"/account-*
mkfx "$FX" willie willie_ttl "" Org
assert_eq "" "$(acct1 "$FX" ACCOUNT_FORMAT=email)" "email empty -> empty"
end_test

start_test "T3.3 first call writes cache ending in newline; second call is a hit"
FX="$AT/f3.json"; mkfx "$FX" willie willie_ttl w@x Org; : > "$ALOG"
assert_eq willie "$(acct1 "$FX" PATH="$ASHIM:$PATH")" "miss value"
C=$(acache)
[ -n "$C" ] || { printf '    FAIL: no account cache file\n' >&2; TEST_FAILED=1; }
[ -n "$C" ] && assert_eq 0a "$(tail -c1 "$C" | od -An -tx1 | tr -d " ")" "cache ends with newline"
assert_eq 1 "$(shim_count "$ALOG" "$FX")" "miss = one jq call"
: > "$ALOG"
assert_eq willie "$(acct1 "$FX" PATH="$ASHIM:$PATH")" "hit value"
assert_eq 0 "$(shim_count "$ALOG" "$FX")" "hit = zero jq calls"
end_test

start_test "T3.4 source rewritten and newer re-runs jq"
FX="$AT/f4.json"; mkfx "$FX" willie willie_ttl w@x Org
acct1 "$FX" >/dev/null
mkfx "$FX" neo willie_ttl w@x Org -5
: > "$ALOG"
assert_eq neo "$(acct1 "$FX" PATH="$ASHIM:$PATH")" "new name"
assert_eq 1 "$(shim_count "$ALOG" "$FX")" "one jq call"
end_test

start_test "T3.5 format change reads cache only"
FX="$AT/f5.json"; mkfx "$FX" willie willie_ttl w@x Org
acct1 "$FX" >/dev/null; : > "$ALOG"
assert_eq w@x "$(acct1 "$FX" ACCOUNT_FORMAT=email PATH="$ASHIM:$PATH")" "email from cache"
assert_eq 0 "$(shim_count "$ALOG" "$FX")" "no jq"
end_test

start_test "T3.6 empty results are cached"
FX="$AT/f6.json"; echo '{}' > "$FX"; touch -d "@$(( $(date +%s) - 10 ))" "$FX"; : > "$ALOG"
assert_eq "" "$(acct1 "$FX" PATH="$ASHIM:$PATH")" "empty"
C=$(acache)
[ -n "$C" ] || { printf '    FAIL: no cache for empty result\n' >&2; TEST_FAILED=1; }
[ -n "$C" ] && assert_eq 3 "$(tr -cd '\037' < "$C" | wc -c | tr -d ' ')" "three US separators"
: > "$ALOG"; acct1 "$FX" PATH="$ASHIM:$PATH" >/dev/null
assert_eq 0 "$(shim_count "$ALOG" "$FX")" "second call hit"
end_test

start_test "T3.7 source deleted -> empty despite cache"
FX="$AT/f7.json"; mkfx "$FX" willie willie_ttl w@x Org
acct1 "$FX" >/dev/null; rm -f "$FX"
assert_eq "" "$(acct1 "$FX")" "empty"
end_test

start_test "T3.8 jq failure serves old cache, else empty"
FX="$AT/f8.json"; mkfx "$FX" willie willie_ttl w@x Org
assert_eq "" "$(acct1 "$FX" PATH="$AFAIL:$PATH")" "no cache + failing jq"
assert_eq "" "$(acache)" "nothing written on failure"
acct1 "$FX" >/dev/null
mkfx "$FX" neo willie_ttl w@x Org -5
assert_eq willie "$(acct1 "$FX" PATH="$AFAIL:$PATH")" "old cache served"
end_test

start_test "T3.9 0-byte source serves old cache, cache unchanged"
FX="$AT/f9.json"; mkfx "$FX" willie willie_ttl w@x Org
acct1 "$FX" >/dev/null; C=$(acache); before=$(od -c "$C")
: > "$FX"; touch -d "@$(( $(date +%s) + 5 ))" "$FX"
assert_eq willie "$(acct1 "$FX")" "old value"
assert_eq "$before" "$(od -c "$C")" "cache bytes unchanged"
end_test

start_test "T3.10 non-object oauthAccount -> empty, cache written"
FX="$AT/f10.json"; echo '{"oauthAccount":"x"}' > "$FX"; touch -d "@$(( $(date +%s) - 10 ))" "$FX"
assert_eq "" "$(acct1 "$FX")" "empty"
[ -n "$(acache)" ] || { printf '    FAIL: cache not written\n' >&2; TEST_FAILED=1; }
end_test

start_test "T3.11 missing state dir is created, no stderr"
FX="$AT/f11.json"; mkfx "$FX" willie willie_ttl w@x Org
ABS="$AT/absent"; rm -rf "$ABS"
err=$(acct "$FX" OMC_STATE_DIR="$ABS" 2>&1 >/dev/null)
assert_eq "" "$err" "stderr empty"
if [ -d "$ABS" ] && ls "$ABS"/account-* >/dev/null 2>&1; then :; else printf '    FAIL: dir/cache not created\n' >&2; TEST_FAILED=1; fi
end_test

start_test "T3.12 CLAUDE_CONFIG_DIR is used when OMC_ACCOUNT_FILE is empty"
mkfx "$AT/cfg/.claude.json" willie willie_ttl w@x Org
assert_eq willie "$(acct1 '' CLAUDE_CONFIG_DIR="$AT/cfg")" "from config dir"
end_test

start_test "T3.13 source path with spaces (miss and hit)"
FX="$AT/John Smith/.claude.json"; mkfx "$FX" willie willie_ttl w@x Org
assert_eq willie "$(acct1 "$FX")" "miss"
assert_eq willie "$(acct1 "$FX")" "hit"
end_test

start_test "T3.14 sanitization at field level; miss == hit"
FX="$AT/f14.json"
"$REAL_JQ" -nj '{oauthAccount:{displayName:"  \u001b[31mre\nd\\c\\b\u009bX  ",fullName:"f",emailAddress:"e",organizationName:"o"}}' > "$FX"
touch -d "@$(( $(date +%s) - 10 ))" "$FX"
m=$(acct "$FX"); h=$(acct "$FX")
assert_eq "$m" "$h" "miss == hit"
name="${m#*|}"; name="${name%%|*}"
case "$name" in *$'\033'*|*$'\xc2\x9b'*) printf '    FAIL: ESC/CSI survived\n' >&2; TEST_FAILED=1;; esac
assert_eq '[31mred\\c\\bX' "$name" "trimmed, controls stripped, backslashes doubled"
end_test

start_test "T3.15 whitespace-only displayName falls back to fullName"
FX="$AT/f15.json"; mkfx "$FX" "   " willie_ttl w@x Org
assert_eq willie_ttl "$(acct1 "$FX")" "fallback"
end_test

start_test "T3.16 ACCOUNT_SHOW=false: empty, no jq, no cache"
FX="$AT/f16.json"; mkfx "$FX" willie willie_ttl w@x Org; : > "$ALOG"
assert_eq "" "$(acct1 "$FX" ACCOUNT_SHOW=false PATH="$ASHIM:$PATH")" "empty"
assert_eq 0 "$(shim_count "$ALOG" "$FX")" "no jq"
assert_eq "" "$(acache)" "no cache"
end_test

start_test "T3.17 sweep removes stale account tmp files"
printf x > "$OMC_STATE_DIR/account-x.tmp.123"
touch -d "@$(( $(date +%s) - 60 ))" "$OMC_STATE_DIR/account-x.tmp.123"
bash -c 'OMC_TEST_LIB_ONLY=1; source "'"$STATUSLINE"'"; _omc_sweep_stale_tmp'
[ ! -f "$OMC_STATE_DIR/account-x.tmp.123" ] || { printf '    FAIL: tmp not swept\n' >&2; TEST_FAILED=1; }
end_test

rm -rf "$AT"


# ---- Task 4: account segment in layouts ----
ICON=$'\xef\x80\x87'
render_layout() {  # $1=layout $2=fixture ('' -> none) $3=raw|strip ; extra conf via $EXTRA_CONF
  printf 'LAYOUT=%s\n%s\n' "$1" "${EXTRA_CONF:-}" > "$OMC_STATE_DIR/l.conf"
  local out nogit payload; nogit=$(mktemp -d)
  payload="${4:-}"   # $4 = optional payload JSON (default: plain "M" model)
  [ -n "$payload" ] || payload='{"session_id":"render-test-acc","model":{"display_name":"M"},"workspace":{"current_dir":"/tmp/d"}}'
  out=$(cd "$nogit" && printf '%s\n' "$payload" \
    | OMC_CONF="$OMC_STATE_DIR/l.conf" OMC_ACCOUNT_FILE="${2:-$OMC_STATE_DIR/no-such.json}" bash "$STATUSLINE" 2>/dev/null)
  rm -rf "$nogit"
  if [ "${3:-strip}" = raw ]; then printf '%s\n' "$out"; else printf '%s\n' "$out" | strip_ansi; fi
}
T4D=$(mktemp -d)
jq -n '{oauthAccount:{displayName:"willie"}}' > "$T4D/w.json"
touch -d "@$(( $(date +%s) - 10 ))" "$T4D/w.json"
ARROW_GLYPH=$(printf '\xee\x82\xb0')
LAYOUTS4="default fancy minimal powerline pure mygo"

start_test "T4.1 account segment placement per layout"
EXPECT_default="M ${ICON} willie "
EXPECT_fancy="M · ${ICON} willie · "
EXPECT_minimal="M | willie | /tmp/d"
EXPECT_powerline=" ${ICON} willie ${ARROW_GLYPH}  /tmp/d"
EXPECT_pure="M  willie  /tmp/d"
EXPECT_mygo="★ M ♪ willie ♪ /tmp/d"
for l in $LAYOUTS4; do
  out=$(render_layout "$l" "$T4D/w.json" | head -1)
  e="EXPECT_$l"
  case "$out" in *"${!e}"*) ;; *) printf '    FAIL: %s: [%s] lacks [%s]\n' "$l" "$out" "${!e}" >&2; TEST_FAILED=1;; esac
done
out=$(render_layout powerline "$T4D/w.json" | head -1)
case "$out" in " M ${ARROW_GLYPH}  ${ICON} willie ${ARROW_GLYPH}  /tmp/d "*) ;; *) printf '    FAIL: powerline start [%s]\n' "$out" >&2; TEST_FAILED=1;; esac
end_test

start_test "T4.2 (guard) empty account: identical to ACCOUNT_SHOW=false, no doubled separators"
for l in $LAYOUTS4; do
  a=$(render_layout "$l" '' raw); b=$(EXTRA_CONF="ACCOUNT_SHOW=false" render_layout "$l" "$T4D/w.json" raw)
  assert_eq "$a" "$b" "$l raw equal"
  case "$a" in *willie*) printf '    FAIL: %s shows willie\n' "$l" >&2; TEST_FAILED=1;; esac
  s=$(render_layout "$l" '' | head -1)
  case "$s" in *"| |"*|*"· ·"*|*"♪ ♪"*) printf '    FAIL: %s doubled sep [%s]\n' "$l" "$s" >&2; TEST_FAILED=1;; esac
done
end_test

start_test "T4.3 ACCOUNT_ICON empty: no icon, no double space"
out=$(EXTRA_CONF='ACCOUNT_ICON=""' render_layout default "$T4D/w.json" | head -1)
case "$out" in "M willie "*) ;; *) printf '    FAIL: [%s]\n' "$out" >&2; TEST_FAILED=1;; esac
end_test

start_test "T4.4 hostile displayName: ESC stripped, miss==hit, backslash literal"
jq -n '{oauthAccount:{displayName:"\u001b[31mx\nb\\c\\b"}}' > "$T4D/h.json"
touch -d "@$(( $(date +%s) - 10 ))" "$T4D/h.json"
r1=$(render_layout default "$T4D/h.json" raw); r2=$(render_layout default "$T4D/h.json" raw)
assert_eq "$r1" "$r2" "miss == hit raw"
case "$r1" in *$'\x1b[31m'*) printf '    FAIL: raw ESC[31m present\n' >&2; TEST_FAILED=1;; esac
s=$(render_layout default "$T4D/h.json")
case "$s" in *'[31m'*) ;; *) printf '    FAIL: no literal [31m in [%s]\n' "$s" >&2; TEST_FAILED=1;; esac
case "$s" in *'/tmp/d'*) ;; *) printf '    FAIL: dir missing\n' >&2; TEST_FAILED=1;; esac
case "$s" in *'b\c'*) ;; *) printf '    FAIL: b\c missing in [%s]\n' "$s" >&2; TEST_FAILED=1;; esac
end_test

start_test "T4.5 preview shows account; ACCOUNT_SHOW=false hides it"
p=$(OMC_DIR="$REPO_ROOT/plugins/oh-my-status" OMC_CONF=/dev/null bash "$REPO_ROOT/plugins/oh-my-status/preview.sh" layouts 2>/dev/null | strip_ansi)
if ! printf "%s" "$p" | grep -qw you; then printf '    FAIL: preview lacks you\n' >&2; TEST_FAILED=1; fi
printf 'ACCOUNT_SHOW=false\n' > "$T4D/p.conf"
p=$(OMC_DIR="$REPO_ROOT/plugins/oh-my-status" OMC_CONF="$T4D/p.conf" bash "$REPO_ROOT/plugins/oh-my-status/preview.sh" layouts 2>/dev/null | strip_ansi)
if printf "%s" "$p" | grep -qw you; then printf '    FAIL: preview shows you when disabled\n' >&2; TEST_FAILED=1; fi
end_test

start_test "T4.6 [1M] tag shows in all 6 layouts; MODEL_CTX_TAG=false hides it"
P1M=$(jq -n -c '{session_id:"render-test-acc",model:{display_name:"Opus 5.5 (1M context)"},workspace:{current_dir:"/tmp/d"},context_window:{context_window_size:1000000}}' | tr -d '\r')
for l in $LAYOUTS4; do
  s=$(render_layout "$l" '' strip "$P1M" | head -1)
  case "$s" in *"Opus 5.5 [1M]"*) ;; *) printf '    FAIL: %s lacks tag [%s]\n' "$l" "$s" >&2; TEST_FAILED=1;; esac
done
s=$(EXTRA_CONF="MODEL_CTX_TAG=false" render_layout default '' strip "$P1M" | head -1)
case "$s" in *"Opus 5.5"*) ;; *) printf '    FAIL: off: no model [%s]\n' "$s" >&2; TEST_FAILED=1;; esac
case "$s" in *"["*) printf '    FAIL: off: has [ in [%s]\n' "$s" >&2; TEST_FAILED=1;; esac
end_test

start_test "no handoff badge in any layout, with or without a marker; ctx file written"
for l in $LAYOUTS4; do
  s=$(render_layout "$l" '' strip | tr '\n' ' ')
  case "$s" in *handoff*) printf '    FAIL: %s badge without marker [%s]\n' "$l" "$s" >&2; TEST_FAILED=1;; esac
done
: > "$OMC_STATE_DIR/handoff-render-test-acc"
for l in $LAYOUTS4; do
  s=$(render_layout "$l" '' strip | tr '\n' ' ')
  case "$s" in
    *'✓ handoff'*|*'handoff ok'*) printf '    FAIL: %s shows a badge with marker [%s]\n' "$l" "$s" >&2; TEST_FAILED=1;;
  esac
done
rm -f "$OMC_STATE_DIR/handoff-render-test-acc"
[ -f "$OMC_STATE_DIR/ctx-render-test-acc" ] || { printf '    FAIL: ctx file missing\n' >&2; TEST_FAILED=1; }
end_test


# ---- Task 5: absent rate-limit windows are hidden ----
RLL="default fancy minimal mygo powerline pure"
rl_payload() {  # $1=layout $2=case $3=rate_limits JSON or '-' for absent
  local rl=''
  [ "$3" = "-" ] || rl=",\"rate_limits\":$3"
  printf '{"session_id":"rl-%s-%s","model":{"display_name":"X"},"workspace":{"current_dir":"/tmp/d"},"context_window":{"used_percentage":8}%s}' "$1" "$2" "$rl"
}
rl_line() {  # $1=layout $2=case $3=rate_limits -> the stripped line containing "8%"
  render_layout "$1" '' strip "$(rl_payload "$1" "$2" "$3")" | grep -F '8%' | head -1
}
rl_check() {  # $1=layout $2=case $3=rate_limits $4=expected % count
  local l="$1" line n
  line=$(rl_line "$1" "$2" "$3")
  [ -n "$line" ] || { printf '    FAIL: %s/%s: no line with 8%%\n' "$1" "$2" >&2; TEST_FAILED=1; return; }
  n=$(printf '%s' "$line" | tr -cd '%' | wc -c | tr -d ' ')
  [ "$n" = "$4" ] || { printf '    FAIL: %s/%s: %% count %s != %s [%s]\n' "$1" "$2" "$n" "$4" "$line" >&2; TEST_FAILED=1; }
  case "$line" in *"    "*) printf '    FAIL: %s/%s: 4+ spaces [%s]\n' "$1" "$2" "$line" >&2; TEST_FAILED=1;; esac
  if [ "$l" != fancy ]; then
    case "$line" in *"   "*) printf '    FAIL: %s/%s: 3 spaces [%s]\n' "$1" "$2" "$line" >&2; TEST_FAILED=1;; esac
  fi
  if [ "$l" != powerline ]; then
    case "$line" in *" ") printf '    FAIL: %s/%s: trailing space [%s]\n' "$1" "$2" "$line" >&2; TEST_FAILED=1;; esac
  fi
  RL_LINE="$line"
}
rl_has() {  # $1=layout $2=case $3=glob the selected line must match (values are really printed, in order)
  case "$RL_LINE" in *$3*) ;; *) printf '    FAIL: %s/%s: line lacks %s [%s]
' "$1" "$2" "$3" "$RL_LINE" >&2; TEST_FAILED=1;; esac
}
rl_norm() { printf '%s' "$1" | LC_ALL=C sed 's/[^ -~][^ -~]*/#/g'; }  # bar/arrow glyph runs -> '#'
rl_golden() {  # $1=layout $2=case $3=exact expected normalized line
  local got; got=$(rl_norm "$RL_LINE")
  [ "$got" = "$3" ] || { printf '    FAIL: %s/%s: golden [%s] != [%s]
' "$1" "$2" "$got" "$3" >&2; TEST_FAILED=1; }
}
rl_nolabel() {  # $1=layout $2=label: fail when label shown in layouts that print one
  case "$1" in fancy|mygo|powerline|pure)
    case "$RL_LINE" in *"$2"*) printf '    FAIL: %s shows %s [%s]\n' "$1" "$2" "$RL_LINE" >&2; TEST_FAILED=1;; esac;;
  esac
}

start_test "T5.a rate_limits absent: only ctx % shown"
for l in $RLL; do rl_check "$l" a - 1; done
end_test

start_test "T5.b rate_limits {}: only ctx % shown"
for l in $RLL; do rl_check "$l" b '{}' 1; done
end_test

start_test "T5.c only seven_day: 5h hidden"
for l in $RLL; do rl_check "$l" c '{"seven_day":{"used_percentage":41}}' 2; rl_nolabel "$l" 5h; rl_has "$l" c '*8%*41%'; done
end_test

start_test "T5.d only five_hour: 7d hidden"
for l in $RLL; do rl_check "$l" d '{"five_hour":{"used_percentage":23}}' 2; rl_nolabel "$l" 7d; rl_has "$l" d '*8%*23%'; done
end_test

start_test "T5.e both present at 0: three 0% shown"
for l in $RLL; do
  rl_check "$l" e '{"five_hour":{"used_percentage":0},"seven_day":{"used_percentage":0}}' 3
  case "$l" in
    default)   rl_golden "$l" e '# 8%  # 0%  # 0%';;
    fancy)     rl_golden "$l" e 'ctx # 8%   5h # 0%   7d # 0%';;
    minimal)   rl_golden "$l" e 'X | /tmp/d | 8% 0% 0%';;
    mygo)      rl_golden "$l" e 'ctx # 8%  5h # 0%  7d # 0%';;
    powerline) rl_golden "$l" e ' X #  /tmp/d #  ctx:8% 5h:0% 7d:0% ';;
    pure)      rl_golden "$l" e 'X  /tmp/d  ctx:8%  5h:0%  7d:0%';;
  esac
  case "$l" in powerline|pure) case "$RL_LINE" in *"5h:0%"*) ;; *) printf '    FAIL: %s lacks 5h:0%% [%s]\n' "$l" "$RL_LINE" >&2; TEST_FAILED=1;; esac;; esac
done
end_test

start_test "T5.h both present with different values: 5h then 7d, each its own value"
for l in $RLL; do
  rl_check "$l" h '{"five_hour":{"used_percentage":23},"seven_day":{"used_percentage":41}}' 3
  rl_has "$l" h '*8%*23%*41%'
done
end_test

start_test "T5.f five_hour 90 + resets_at: time suffix kept"
for l in $RLL; do
  rl_check "$l" f '{"five_hour":{"used_percentage":90,"resets_at":1738425600}}' 2
  rl_has "$l" f '*8%*90%'
  case "$l" in
    default|fancy|mygo) printf '%s' "$RL_LINE" | grep -Eq '\([0-9]{2}:[0-9]{2}\)' || { printf '    FAIL: %s no (HH:MM) [%s]\n' "$l" "$RL_LINE" >&2; TEST_FAILED=1; };;
    *) case "$RL_LINE" in *"("*) printf '    FAIL: %s has ( [%s]\n' "$l" "$RL_LINE" >&2; TEST_FAILED=1;; esac;;
  esac
done
end_test

start_test "T5.g seven_day 90 + resets_at: date suffix kept"
for l in $RLL; do
  rl_check "$l" g '{"seven_day":{"used_percentage":90,"resets_at":1738857600}}' 2
  rl_has "$l" g '*8%*90%'
  case "$l" in
    default|fancy|mygo) printf '%s' "$RL_LINE" | grep -Eq '\([0-9]{2}/[0-9]{2}\)' || { printf '    FAIL: %s no (MM/DD) [%s]\n' "$l" "$RL_LINE" >&2; TEST_FAILED=1; };;
    *) case "$RL_LINE" in *"("*) printf '    FAIL: %s has ( [%s]\n' "$l" "$RL_LINE" >&2; TEST_FAILED=1;; esac;;
  esac
done
end_test

# --- spawn budgets (spec §0) ---
# count_spawns (test-helpers.sh) runs the statusline with PATH=<shim dir> only and
# counts forks + execs. Ceilings = measured + 2 (Windows fork-count variance).
BT=$(mktemp -d)
BUDGET_ACCT="$BT/acct.json"
printf '{"oauthAccount":{"displayName":"w"}}' > "$BUDGET_ACCT"
touch -d "@$(( $(date +%s) - 10 ))" "$BUDGET_ACCT"
BUDGET_PAYLOAD='{"session_id":"budget","model":{"display_name":"M"},"workspace":{"current_dir":"/tmp/d"},"context_window":{"used_percentage":8}}'

budget_env() {  # $1=state-dir $2=ttl -> writes $1.conf / $1.in
  printf 'LAYOUT=default\nGIT_CACHE_TTL=%s\n' "$2" > "$1.conf"
  printf '%s' "$BUDGET_PAYLOAD" > "$1.in"
}
budget_prewarm() {  # $1=dir $2=state-dir : one normal render, same env as budget_case
  ( cd "$1" && OMC_CONF="$2.conf" OMC_STATE_DIR="$2" OMC_ACCOUNT_FILE="$BUDGET_ACCT" COLUMNS=120 \
      OMC_NOW_OVERRIDE=1793800000 bash "$STATUSLINE" < "$2.in" >/dev/null 2>&1 )
}
budget_case() {  # $1=label $2=dir $3=state-dir $4=ttl
  budget_env "$3" "$4"
  ( cd "$2" && OMC_CONF="$3.conf" OMC_STATE_DIR="$3" OMC_ACCOUNT_FILE="$BUDGET_ACCT" COLUMNS=120 \
      OMC_NOW_OVERRIDE=1793800000 count_spawns "$3.cnt" "$3.in" "$STATUSLINE"; \
      printf '%s %s %s\n' "$SPAWNS" "$SPAWN_FORKS" "$SPAWN_EXECS" > "$3.res"; \
      grep '^MISSING' "$SPAWN_LOG" > "$3.missing" || : )
  read -r SPAWNS SPAWN_FORKS SPAWN_EXECS < "$3.res"
  SPAWN_MISSING=$(wc -l < "$3.missing" | tr -d ' '); SPAWN_LOG="$3.cnt/log"
  printf '    measured %s: %s spawns (forks %s + execs %s)\n' "$1" "$SPAWNS" "$SPAWN_FORKS" "$SPAWN_EXECS"
  [ -s "$3.cnt/stdout" ] || { printf '    FAIL: %s: empty stdout\n' "$1" >&2; TEST_FAILED=1; }
  head -1 "$3.cnt/stdout" | grep -qF 'M' || { printf '    FAIL: %s: line 1 lacks the model\n' "$1" >&2; TEST_FAILED=1; }
}

# P2 measured: R1=26 R2=66 R3=36. P3 measured: R1=16 R2=56 R3=26. P4 measured: R1=5 R2=46 R3=12. Final targets (P6): R1<=3 R2<=8 R3<=3.
BUDGET_R1=7; BUDGET_R2=48; BUDGET_R3=14

BREPO=$(mktemp -d); gi_mkrepo "$BREPO" main

start_test "spawn budget R1: repo, git cache HIT, account cache HIT"
BS="$BT/r1"; budget_env "$BS" 300; budget_prewarm "$BREPO" "$BS"
R1CF=$(ls "$BS"/gitcache-* 2>/dev/null | grep -v '\.stamp$' | head -1)
R1BEFORE=$(cat "$R1CF" 2>/dev/null; printf X)
case "$R1BEFORE" in 1793800000"$(printf '\t')"*) ;; *) printf '    FAIL: prewarm did not write an epoch-1793800000 cache line\n' >&2; TEST_FAILED=1 ;; esac
budget_case R1 "$BREPO" "$BS" 300
assert_spawns_le "$BUDGET_R1" "R1"
assert_eq "0" "$(grep -c '^EXEC git ' "$SPAWN_LOG" || true)" "R1 cache HIT must not run git"
assert_eq "0" "$(grep -c '^EXEC cat ' "$SPAWN_LOG" || true)" "R1 cache HIT must not run cat"
assert_eq "$R1BEFORE" "$(cat "$R1CF" 2>/dev/null; printf X)" "R1 is a genuine HIT: the cache file was not rewritten"
end_test

start_test "spawn budget R2: repo, git cache MISS"
BS="$BT/r2"; budget_case R2 "$BREPO" "$BS" 300
assert_spawns_le "$BUDGET_R2" "R2"
end_test

start_test "spawn budget R3: non-repo cwd"
BNOGIT=$(mktemp -d)
if git -C "$BNOGIT" rev-parse 2>/dev/null; then
  printf '    SKIP: temp dir is inside a git repo\n'
else
  BS="$BT/r3"; budget_case R3 "$BNOGIT" "$BS" 300
  assert_spawns_le "$BUDGET_R3" "R3"
fi
rm -rf "$BNOGIT"
end_test
rm -rf "$BREPO" "$BT"

# --- P3: render startup builtins (spec 2.4) ---
P3=$(mktemp -d); mkdir -p "$P3/nogit" "$P3/st"
printf '{}' > "$P3/none.json"
git -C "$P3/nogit" rev-parse 2>/dev/null && { printf '    NOTE: temp dir is inside a git repo; P3 spawn tests are not meaningful\n'; }
p3_count() {  # $1=payload $2=layout(default) ; runs the render under count_spawns, log in $P3/cnt/log
  rm -rf "$P3/st"; mkdir -p "$P3/st"   # fresh state: a git-cache HIT would exec cat (until P4)
  printf '%s' "$1" > "$P3/in"; printf 'LAYOUT=%s\n' "${2:-default}" > "$P3/conf"
  ( cd "$P3/nogit" && OMC_CONF="$P3/conf" OMC_STATE_DIR="$P3/st" OMC_ACCOUNT_FILE="$P3/none.json" COLUMNS=120 \
      count_spawns "$P3/cnt" "$P3/in" "$STATUSLINE" )
  [ -s "$P3/cnt/stdout" ] || { printf '    FAIL: p3_count: empty stdout\n' >&2; TEST_FAILED=1; }
  head -1 "$P3/cnt/stdout" | grep -qF 'M' || { printf '    FAIL: p3_count: line 1 lacks the model\n' >&2; TEST_FAILED=1; }
}
p3_execs() { grep -c "^EXEC $1 " "$P3/cnt/log" || true; }
P3_PLAIN='{"session_id":"p3","model":{"display_name":"M"},"workspace":{"current_dir":"/tmp/d"},"context_window":{"used_percentage":8}}'

start_test "P3.1 sourcing statusline.sh runs no dirname (SCRIPT_DIR from BASH_SOURCE)"
printf 'OMC_TEST_LIB_ONLY=1; . "%s"\n' "$STATUSLINE" > "$P3/src.sh"
count_spawns "$P3/csrc" /dev/null "$P3/src.sh"
assert_eq "0" "$(grep -c '^EXEC dirname ' "$P3/csrc/log" || true)" "dirname execs when sourcing statusline.sh"
printf 'OMC_TEST_LIB_ONLY=1; . "%s"\n' "$STATUSLINE.lib_test_loader.sh" > "$P3/src2.sh"
count_spawns "$P3/csrc2" /dev/null "$P3/src2.sh"
assert_eq "0" "$(grep -c '^EXEC dirname ' "$P3/csrc2/log" || true)" "dirname execs when sourcing the lib loader"
end_test

start_test "P3.1 statusline.sh invoked via a Windows (backslash) path still finds its themes/layouts"
if command -v cygpath >/dev/null 2>&1; then
  WINSL=$(cygpath -w "$STATUSLINE")
  mkdir -p "$P3/nogit"
  OUT=$(cd "$P3/nogit" && printf '%s' "$P3_PLAIN" | OMC_CONF=/dev/null OMC_STATE_DIR="$P3/st" OMC_ACCOUNT_FILE="$P3/none.json" bash "$WINSL" 2>/dev/null | strip_ansi)
  printf '%s\n' "$OUT" | head -1 | grep -qF 'M' \
    || { printf '    FAIL: no model on line 1 via %s\n      got: %q\n' "$WINSL" "$OUT" >&2; TEST_FAILED=1; }
else
  printf '    SKIP: no cygpath (not MSYS)\n'
fi
end_test

start_test "P3.2 parse_status_json without argument reads the inherited stdin"
OUT=$(printf '%s' "$DOCS_JSON" | timeout 20 bash -c 'OMC_TEST_LIB_ONLY=1; source "$0"; parse_status_json; printf "%s" "$SESSION_ID"' "$STATUSLINE")
assert_eq "abc123..." "$OUT" "SESSION_ID from stdin"
end_test

start_test "P3.2 a normal render runs no cat"
p3_count "$P3_PLAIN"
assert_eq "0" "$(p3_execs cat)" "cat execs"
end_test

start_test "P3.3 a render without orphan temp files or a >80% rate runs no date"
rm -rf "$P3/st"; mkdir -p "$P3/st"
p3_count "$P3_PLAIN"
assert_eq "0" "$(p3_execs date)" "date execs"
end_test

start_test "P3.3 rate suffix with an integer resets_at runs no date"
p3_count '{"session_id":"p3","model":{"display_name":"M"},"workspace":{"current_dir":"/tmp/d"},"context_window":{"used_percentage":8},"rate_limits":{"five_hour":{"used_percentage":90,"resets_at":1738425600},"seven_day":{"used_percentage":90,"resets_at":1738857600}}}'
assert_eq "0" "$(p3_execs date)" "date execs"
end_test

start_test "P3.3 resets_at suffix: integer, 'abc' and 1.5 match the old date chain"
for ra in 1738425600 abc 1.5 0123; do
  if [[ $ra =~ ^(0|[1-9][0-9]*)$ ]]; then jr=$ra; else jr="\"$ra\""; fi
  [[ $ra == 1.5 ]] && jr=1.5
  want=$(date -d "@$ra" '+%H:%M' 2>/dev/null || date -r "$ra" '+%H:%M' 2>/dev/null)
  got=$(render_layout default '' strip "{\"session_id\":\"p3b\",\"model\":{\"display_name\":\"M\"},\"workspace\":{\"current_dir\":\"/tmp/d\"},\"context_window\":{\"used_percentage\":8},\"rate_limits\":{\"five_hour\":{\"used_percentage\":90,\"resets_at\":$jr}}}" | grep -o '([^)]*)' | head -1)
  assert_eq "($want)" "$got" "5h suffix for resets_at=$ra"
done
end_test
rm -rf "$P3"

rm -rf "$T4D"
print_summary

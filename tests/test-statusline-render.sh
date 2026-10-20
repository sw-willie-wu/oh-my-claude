#!/bin/bash
# Render-side tests: feed statusline.sh known JSON + state, assert output.
set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"

# shellcheck source=test-helpers.sh
. "$SCRIPT_DIR/test-helpers.sh"

STATUSLINE="$REPO_ROOT/statusline.sh"

# Each test sets up its own session_id and state file under ~/.claude/oh-my-claude/state/
# (real path, since statusline.sh derives it from $HOME). Cleanup after each test.
RENDER_STATE_DIR="$HOME/.claude/oh-my-claude/state"
mkdir -p "$RENDER_STATE_DIR"

cleanup_render_state() {
  rm -f "$RENDER_STATE_DIR"/state-render-test-*.tsv
}

# Strip ANSI escape sequences so we can measure visible width and assert on text.
strip_ansi() {
  sed -E 's/\x1b\[[0-9;]*[a-zA-Z]//g'
}

# Run statusline with given session_id and capture stdout. emit_workers always
# runs BEFORE the layout's render(), so the worker lines are guaranteed to be
# the leading lines of the output — assertions that need only worker content
# can use `head -1` or grep for worker-specific patterns. Layout output (model,
# bars, etc.) follows but doesn't interfere with these tests.
run_workers() {
  local sid="$1" cols="${2:-120}"
  # Isolate from user's oh-my-claude.conf so tests don't depend on
  # whichever LAYOUT/THEME the developer happens to use locally.
  COLUMNS="$cols" OMC_CONF=/dev/null bash -c "
    echo '{\"session_id\":\"$sid\",\"model\":{\"display_name\":\"X\"},\"workspace\":{\"current_dir\":\"/tmp\"}}' \
      | bash $STATUSLINE 2>/dev/null
  "
}

cleanup_render_state
printf 'Running statusline render tests\n\n'

start_test "long line truncates and elapsed appears exactly once"
SID="render-test-002"
SF="$RENDER_STATE_DIR/state-${SID}.tsv"
NOW=$(date +%s)
LONG_DESC="a very long description that exceeds terminal width definitely and goes on and on"
printf 'shell\ttoolu_a2\t-\t%s\tsleep 99\t%s\n' "$LONG_DESC" "$((NOW - 12))" > "$SF"
OUT="$(run_workers "$SID" 60 | strip_ansi)"
LEN=$(printf '%s' "$OUT" | head -1 | awk '{print length}')
[ "$LEN" -le 58 ] || { printf '    FAIL: line len=%d exceeds 58 (cols=60-2)\n      got: %q\n' "$LEN" "$OUT" >&2; TEST_FAILED=1; }
COUNT_NS=$(printf '%s' "$OUT" | head -1 | grep -oE '[0-9]+s' | wc -l | tr -d ' ')
assert_eq "1" "$COUNT_NS" "elapsed (Ns) should appear exactly once on first line (truncation regression)"
echo "$OUT" | grep -qF '...' \
  || { printf '    FAIL: ... marker missing\n      got: %q\n' "$OUT" >&2; TEST_FAILED=1; }
end_test

start_test "description with escaped tab/newline is unescaped on render"
SID="render-test-003"
SF="$RENDER_STATE_DIR/state-${SID}.tsv"
NOW=$(date +%s)
printf 'shell\ttoolu_a3\t-\ta\\tb\\nc\tsleep 99\t%s\n' "$((NOW - 5))" > "$SF"
OUT="$(run_workers "$SID" 120 | strip_ansi)"
TAB_PATTERN=$'a\tb'
echo "$OUT" | head -1 | grep -qF "$TAB_PATTERN" \
  || { printf '    FAIL: tab not unescaped in output\n      got: %q\n' "$OUT" >&2; TEST_FAILED=1; }
end_test

start_test "WORKERS_ENABLED=false produces zero worker lines"
SID="render-test-004"
SF="$RENDER_STATE_DIR/state-${SID}.tsv"
NOW=$(date +%s)
printf 'shell\ttoolu_a4\t-\tshould not appear\tsleep 99\t%s\n' "$((NOW - 1))" > "$SF"
OUT="$(WORKERS_ENABLED=false run_workers "$SID" 120 | strip_ansi)"
echo "$OUT" | grep -qF 'should not appear' \
  && { printf '    FAIL: worker line emitted despite WORKERS_ENABLED=false\n      got: %q\n' "$OUT" >&2; TEST_FAILED=1; }
end_test

start_test "corrupt row (missing start_unix) is skipped silently"
SID="render-test-005"
SF="$RENDER_STATE_DIR/state-${SID}.tsv"
# Row missing the trailing start_unix column.
printf 'shell\ttoolu_a5\t-\tcorrupt row no timestamp\tsleep 99\n' > "$SF"
OUT="$(run_workers "$SID" 120 | strip_ansi)"
echo "$OUT" | grep -qF 'corrupt row no timestamp' \
  && { printf '    FAIL: corrupt row should not render\n      got: %q\n' "$OUT" >&2; TEST_FAILED=1; }
end_test

start_test "is_alive returns true for running PID, false for dead PID"
SID="render-test-isalive"
SF="$RENDER_STATE_DIR/state-${SID}.tsv"
NOW=$(date +%s)
sleep 30 &
LIVE_PID=$!
DEAD_PID=99999999
ALIVE_OUT=$(bash -c "
  source '$STATUSLINE.lib_test_loader.sh' 2>/dev/null || true
  is_alive $LIVE_PID && echo ALIVE || echo DEAD
")
DEAD_OUT=$(bash -c "
  source '$STATUSLINE.lib_test_loader.sh' 2>/dev/null || true
  is_alive $DEAD_PID && echo ALIVE || echo DEAD
")
kill "$LIVE_PID" 2>/dev/null
wait "$LIVE_PID" 2>/dev/null
assert_eq "ALIVE" "$ALIVE_OUT" "running PID should be alive"
assert_eq "DEAD" "$DEAD_OUT" "nonexistent PID should be dead"
end_test


start_test "prune_state_and_emit drops dead shell row from file (unit)"
SID="render-test-prune-unit"
SF="$RENDER_STATE_DIR/state-${SID}.tsv"
NOW=$(date +%s)
DEAD_PID=99999999
printf 'shell\ttoolu_b\tbash_x\tdesc\tcmd\t%s\t%s\n' "$NOW" "$DEAD_PID" > "$SF"
RESULT=$(bash -c "
  OMC_TEST_LIB_ONLY=1
  source '$STATUSLINE'
  WORKERS_STATE_FILE='$SF'
  SESSION_ID='$SID'
  prune_state_and_emit
")
assert_line_count "$SF" 0 "dead row should be removed by prune"
end_test

start_test "prune drops shell row with dead PID, keeps alive shell"
SID="render-test-prune-1"
SF="$RENDER_STATE_DIR/state-${SID}.tsv"
NOW=$(date +%s)
sleep 30 &
LIVE_PID=$!
DEAD_PID=99999999
{
  printf 'shell\ttoolu_b_dead\tbash_dead\tdead bash\tsleep 99\t%s\t%s\n' "$NOW" "$DEAD_PID"
  printf 'shell\ttoolu_b_live\tbash_live\tlive bash\tsleep 99\t%s\t%s\n' "$NOW" "$LIVE_PID"
} > "$SF"
OUT=$(run_workers "$SID" 200 | strip_ansi)
kill "$LIVE_PID" 2>/dev/null
wait "$LIVE_PID" 2>/dev/null
echo "$OUT" | grep -qF 'live bash' \
  || { printf '    FAIL: alive shell missing\n      got: %q\n' "$OUT" >&2; TEST_FAILED=1; }
echo "$OUT" | grep -qvF 'dead bash' \
  || { printf '    FAIL: dead shell still rendered\n      got: %q\n' "$OUT" >&2; TEST_FAILED=1; }
grep -qF 'bash_dead' "$SF" \
  && { printf '    FAIL: dead row not removed from state\n' >&2; TEST_FAILED=1; }
end_test

start_test "row with valid col3 but col7 empty (post inter-update gap) is kept within grace"
SID="render-test-prune-postgap"
SF="$RENDER_STATE_DIR/state-${SID}.tsv"
NOW=$(date +%s)
# Simulates the window between post's first update_col (col3=bg id) and the
# second (col7=PID). No output file present; only grace should keep it.
printf 'shell\ttoolu_postgap\tbash_realid\tinflight\tsleep 99\t%s\n' "$NOW" > "$SF"
OUT=$(WORKERS_PLACEHOLDER_GRACE_SEC=30 run_workers "$SID" 200 | strip_ansi)
echo "$OUT" | grep -qF 'inflight' \
  || { printf '    FAIL: post-gap row pruned during grace\n      got: %q\n' "$OUT" >&2; TEST_FAILED=1; }
grep -qF 'toolu_postgap' "$SF" \
  || { printf '    FAIL: post-gap row removed from state file during grace\n' >&2; TEST_FAILED=1; }
end_test

start_test "row with valid col3 but col7 empty beyond grace pruned when no live process"
SID="render-test-prune-postgap-stale"
SF="$RENDER_STATE_DIR/state-${SID}.tsv"
NOW=$(date +%s)
# col7 empty, beyond grace, no process matches the command → is_shell_alive
# false → row pruned.
printf 'shell\ttoolu_postgap2\tbash_missing\tdead\tomc_no_proc_%s_%s\t%s\n' "$$" "$RANDOM" "$((NOW - 120))" > "$SF"
OUT=$(WORKERS_PLACEHOLDER_GRACE_SEC=30 run_workers "$SID" 200 | strip_ansi)
echo "$OUT" | grep -qvF 'dead' \
  || { printf '    FAIL: stale row with no live process still rendered\n      got: %q\n' "$OUT" >&2; TEST_FAILED=1; }
grep -qF 'toolu_postgap2' "$SF" \
  && { printf '    FAIL: stale row not pruned from state file\n' >&2; TEST_FAILED=1; }
end_test

start_test "placeholder shell row (col3=- col7 missing) survives prune within grace"
SID="render-test-prune-placeholder-1"
SF="$RENDER_STATE_DIR/state-${SID}.tsv"
NOW=$(date +%s)
printf 'shell\ttoolu_pre1\t-\tjust started\tsleep 999\t%s\n' "$NOW" > "$SF"
OUT=$(WORKERS_PLACEHOLDER_GRACE_SEC=30 run_workers "$SID" 200 | strip_ansi)
echo "$OUT" | grep -qF 'just started' \
  || { printf '    FAIL: placeholder row pruned during grace window\n      got: %q\n' "$OUT" >&2; TEST_FAILED=1; }
grep -qF 'toolu_pre1' "$SF" \
  || { printf '    FAIL: placeholder row removed from state file during grace\n' >&2; TEST_FAILED=1; }
end_test

start_test "stale placeholder row is reaped after grace window"
SID="render-test-prune-placeholder-2"
SF="$RENDER_STATE_DIR/state-${SID}.tsv"
NOW=$(date +%s)
printf 'shell\ttoolu_pre2\t-\torphaned\tsleep 999\t%s\n' "$((NOW - 120))" > "$SF"
OUT=$(WORKERS_PLACEHOLDER_GRACE_SEC=30 run_workers "$SID" 200 | strip_ansi)
echo "$OUT" | grep -qvF 'orphaned' \
  || { printf '    FAIL: stale placeholder still rendered\n      got: %q\n' "$OUT" >&2; TEST_FAILED=1; }
grep -qF 'toolu_pre2' "$SF" \
  && { printf '    FAIL: stale placeholder row not pruned from state file\n' >&2; TEST_FAILED=1; }
end_test

# --- bg-Bash render-side liveness: is_shell_alive helper ---
call_is_shell_alive() {
  # $1 = command string to fingerprint-check
  bash -c "
    OMC_TEST_LIB_ONLY=1
    source '$STATUSLINE'
    is_shell_alive \"\$1\" && echo YES || echo NO
  " _ "$1"
}

start_test "is_shell_alive: YES for a live eval-wrapped bg process (needle path)"
TAG="omcprobe_$$_$RANDOM"
( /usr/bin/bash -c "eval 'sleep 8 && : $TAG' < /dev/null" ) &
WRAP_PID=$!
sleep 0.5
RESULT=$(call_is_shell_alive "sleep 8 && : $TAG")
kill "$WRAP_PID" 2>/dev/null; pkill -f "$TAG" 2>/dev/null; wait "$WRAP_PID" 2>/dev/null
assert_eq "YES" "$RESULT" "running eval-wrapped process must be detected alive"
end_test

start_test "is_shell_alive: YES for a live bare process (index==1 path)"
sleep 8 &
BARE_PID=$!
sleep 0.3
RESULT=$(call_is_shell_alive "sleep 8")
kill "$BARE_PID" 2>/dev/null; wait "$BARE_PID" 2>/dev/null
assert_eq "YES" "$RESULT" "running bare process must be detected alive"
end_test

start_test "is_shell_alive: NO when no matching process exists"
RESULT=$(call_is_shell_alive "omc_no_such_command_$$_$RANDOM xyzzy")
assert_eq "NO" "$RESULT" "absent command must be reported dead"
end_test

start_test "is_shell_alive: NO for empty command"
RESULT=$(call_is_shell_alive "")
assert_eq "NO" "$RESULT" "empty command fingerprint must be dead"
end_test

# --- item-2: is_shell_alive 3-way (0 alive / 1 ps-worked-but-absent /
# 2 ps-unusable) + rc-aware prune. Deterministic ps via injected ps()
# function in the SAME bash -c as source (so it shadows the bare `ps`
# calls); NOT run_workers (child bash can't see the function). ---
call_isa_rc() {  # $1=command  $2=ps() definition → prints is_shell_alive rc
  bash -c "
    OMC_TEST_LIB_ONLY=1
    source '$STATUSLINE'
    $2
    is_shell_alive \"\$1\"; echo \$?
  " _ "$1"
}

start_test "is_shell_alive: rc=2 when ps is entirely unusable (ps-blind box)"
RC=$(call_isa_rc "sleep 9 omc_t1" 'ps(){ :; }')
assert_eq "2" "$RC" "all-empty ps → unknown(2), NOT dead(1)"
end_test

start_test "is_shell_alive: rc=0 when ps works and fingerprint matches"
RC=$(call_isa_rc "omc_probe_t2" 'ps(){ printf "H H H H H H\nu p q r s omc_probe_t2\n"; }')
assert_eq "0" "$RC" "ps output with matching cmd → alive(0)"
end_test

start_test "is_shell_alive: rc=1 when ps works but no match (still dead)"
RC=$(call_isa_rc "omc_absent_t3" 'ps(){ printf "UID PID PPID C STIME TTY TIME CMD\nu 1 0 0 t ? 0 /sbin/init\n"; }')
assert_eq "1" "$RC" "ps worked, no match → dead(1) — ps-working contract"
end_test

start_test "is_shell_alive: rc=1 for empty command even if ps unusable"
RC=$(call_isa_rc "" 'ps(){ :; }')
assert_eq "1" "$RC" "empty fp is dead(1), not a ps problem"
end_test

# prune: in-subshell source pattern (I1) so the injected ps() shadows
# is_shell_alive's bare ps. Row: shell, col7 empty, col3 != "-", past
# grace (grace=30). col6 drives age (race-free; no OMC_NOW_OVERRIDE seam).
prune_with_ps() {  # $1=SF $2=SID $3=ps() def $4=WORKERS_SHELL_UNKNOWN_MAX_AGE(opt)
  bash -c "
    OMC_TEST_LIB_ONLY=1
    source '$STATUSLINE'
    $3
    WORKERS_STATE_FILE='$1'; SESSION_ID='$2'
    WORKERS_PLACEHOLDER_GRACE_SEC=30
    ${4:+WORKERS_SHELL_UNKNOWN_MAX_AGE=$4}
    prune_state_and_emit
  " >/dev/null 2>&1
}

start_test "prune: ps-unusable, PID-less, past grace, age<=cap → row KEPT"
SID="render-test-isa-keep"; SF="$RENDER_STATE_DIR/state-${SID}.tsv"
NOW=$(date +%s)
# age 45: past grace(30), within default cap(60). col7 absent, col3 != "-".
printf 'shell\ttoolu_keep\tbash_x\tdesc\tomc_cmd_keep\t%s\n' "$((NOW - 45))" > "$SF"
prune_with_ps "$SF" "$SID" 'ps(){ :; }'
grep -qF 'toolu_keep' "$SF" \
  || { printf '    FAIL: live-unknowable shell false-pruned on ps-blind box\n      SF: %q\n' "$(cat "$SF")" >&2; TEST_FAILED=1; }
end_test

start_test "prune: ps-unusable, PID-less, past grace, age>cap → row reaped (bounded)"
SID="render-test-isa-cap"; SF="$RENDER_STATE_DIR/state-${SID}.tsv"
NOW=$(date +%s)
printf 'shell\ttoolu_cap\tbash_x\tdesc\tomc_cmd_cap\t%s\n' "$((NOW - 45))" > "$SF"
prune_with_ps "$SF" "$SID" 'ps(){ :; }' 0   # cap=0 → age 45 > 0 → reap
grep -qF 'toolu_cap' "$SF" \
  && { printf '    FAIL: ps-unknown dead shell not bounded by UNKNOWN_MAX_AGE\n' >&2; TEST_FAILED=1; }
end_test

start_test "prune: ps works but no match, PID-less past grace → reaped (rc1 unchanged)"
SID="render-test-isa-nomatch"; SF="$RENDER_STATE_DIR/state-${SID}.tsv"
NOW=$(date +%s)
printf 'shell\ttoolu_nm\tbash_x\tdesc\tomc_cmd_nm\t%s\n' "$((NOW - 45))" > "$SF"
prune_with_ps "$SF" "$SID" 'ps(){ printf "UID PID CMD\nu 1 /sbin/init\n"; }'
grep -qF 'toolu_nm' "$SF" \
  && { printf '    FAIL: ps-working no-match shell not pruned (rc1 contract broken)\n' >&2; TEST_FAILED=1; }
end_test

start_test "prune: ps-unusable + corrupt col6 (0) → reaped (cannot bound)"
SID="render-test-isa-corrupt"; SF="$RENDER_STATE_DIR/state-${SID}.tsv"
printf 'shell\ttoolu_cor\tbash_x\tdesc\tomc_cmd_cor\t0\n' > "$SF"
prune_with_ps "$SF" "$SID" 'ps(){ :; }'
grep -qF 'toolu_cor' "$SF" \
  && { printf '    FAIL: corrupt-col6 ps-unknown row not reaped\n' >&2; TEST_FAILED=1; }
end_test

# --- Task 2: prune shell branch uses is_shell_alive (not sticky output file) ---
start_test "prune drops stale shell row when process dead despite sticky .output file"
SID="render-test-shell-sticky-dead"
SF="$RENDER_STATE_DIR/state-${SID}.tsv"
NOW=$(date +%s)
TMPROOT=$(mktemp -d)
WD_ID='-tmp'
mkdir -p "$TMPROOT/claude/$WD_ID/$SID/tasks"
touch "$TMPROOT/claude/$WD_ID/$SID/tasks/bash_sticky.output"   # sticky file exists
DEADCMD="omc_dead_cmd_$$_$RANDOM noproc"
printf 'shell\ttoolu_sticky\tbash_sticky\tdesc\t%s\t%s\t0\n' "$DEADCMD" "$((NOW - 9999))" > "$SF"
OUT=$(TEMP="$TMPROOT" WORKERS_PLACEHOLDER_GRACE_SEC=30 run_workers "$SID" 200 | strip_ansi)
grep -qF 'toolu_sticky' "$SF" \
  && { printf '    FAIL: dead shell kept because sticky .output still present (the bug)\n' >&2; TEST_FAILED=1; }
rm -rf "$TMPROOT"
end_test

start_test "prune keeps shell row when matching process alive (col7=0, beyond grace)"
SID="render-test-shell-live-noproc-pid"
SF="$RENDER_STATE_DIR/state-${SID}.tsv"
NOW=$(date +%s)
sleep 8 &
LIVEPID=$!
sleep 0.3
printf 'shell\ttoolu_livecmd\tbash_live\tdesc\tsleep 8\t%s\t0\n' "$((NOW - 9999))" > "$SF"
OUT=$(WORKERS_PLACEHOLDER_GRACE_SEC=30 run_workers "$SID" 200 | strip_ansi)
kill "$LIVEPID" 2>/dev/null; wait "$LIVEPID" 2>/dev/null
grep -qF 'toolu_livecmd' "$SF" \
  || { printf '    FAIL: live-process shell row pruned (col7=0 fingerprint path)\n' >&2; TEST_FAILED=1; }
end_test

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

# --- Task B: cached_git_info() + GIT_CACHE_TTL ---
# Cache-layer tests stub git_info() by REDEFINING it after sourcing (function
# resolution is dynamic, so cached_git_info calls the stub). This decouples
# the cache logic from real git — git parsing is already covered by Task A's
# git_info tests. The stub bumps a persistent counter file so HIT (no bump)
# vs MISS (bump) is observable across separate processes.
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
STUB_LINE=$(printf 'stub\t1\t2\t3\t4\t5')

start_test "cached_git_info: miss invokes git_info once and creates the cache file"
ST=$(mktemp -d); WD=$(mktemp -d)
OUT=$(cgi "$WD" "$ST" 3)
assert_eq "$STUB_LINE" "$OUT" "miss must return git_info output"
assert_eq "1" "$(cat "$ST/.gitcnt")" "git_info called exactly once on miss"
CF=$(ls "$ST"/gitcache-* 2>/dev/null)
[ -n "$CF" ] || { printf '    FAIL: no cache file created\n' >&2; TEST_FAILED=1; }
assert_eq "$STUB_LINE" "$(cat "$CF" 2>/dev/null)" "cache file content == git_info output"
rm -rf "$ST" "$WD"
end_test

start_test "cached_git_info: fresh cache is a HIT (git_info not re-invoked)"
ST=$(mktemp -d); WD=$(mktemp -d)
OUT1=$(cgi "$WD" "$ST" 3); OUT2=$(cgi "$WD" "$ST" 3)
assert_eq "1" "$(cat "$ST/.gitcnt")" "second call must be a cache HIT (counter stays 1)"
assert_eq "$STUB_LINE" "$OUT2" "HIT returns cached content"
rm -rf "$ST" "$WD"
end_test

start_test "cached_git_info: TTL boundary is <= (age==TTL HIT, age==TTL+1 MISS)"
# Deterministic: pin the cache mtime to a fixed epoch E and drive cached_git_info's
# clock via OMC_NOW_OVERRIDE, so age = NOW-E is exact regardless of how slow the
# box is. (The old form raced wall-clock between `touch` and the 2nd call's own
# date+%s; on a loaded MSYS box age slipped to TTL+1 → false MISS → flaky.)
ST=$(mktemp -d); WD=$(mktemp -d)
E=1000000000
cgi "$WD" "$ST" 3 >/dev/null               # miss → counter=1, cache written
CF=$(ls "$ST"/gitcache-*)
touch -d "@$E" "$CF"                        # mtime = E (fixed)
OMC_NOW_OVERRIDE=$((E + 3)) cgi "$WD" "$ST" 3 >/dev/null   # age == TTL(3)
assert_eq "1" "$(cat "$ST/.gitcnt")" "age == TTL must be a HIT (<= boundary, not <)"
OMC_NOW_OVERRIDE=$((E + 4)) cgi "$WD" "$ST" 3 >/dev/null   # age == TTL+1
assert_eq "2" "$(cat "$ST/.gitcnt")" "age == TTL+1 must MISS (boundary excludes above)"
rm -rf "$ST" "$WD"
end_test

start_test "cached_git_info: age beyond TTL is a MISS (cache rewritten)"
ST=$(mktemp -d); WD=$(mktemp -d)
cgi "$WD" "$ST" 3 >/dev/null
CF=$(ls "$ST"/gitcache-*)
touch -d "@$(( $(date +%s) - 4 ))" "$CF"   # TTL+1 old
cgi "$WD" "$ST" 3 >/dev/null
assert_eq "2" "$(cat "$ST/.gitcnt")" "expired cache must recompute"
rm -rf "$ST" "$WD"
end_test

start_test "cached_git_info: GIT_CACHE_TTL=0 disables caching (no file, every call computes)"
ST=$(mktemp -d); WD=$(mktemp -d)
cgi "$WD" "$ST" 0 >/dev/null; cgi "$WD" "$ST" 0 >/dev/null
assert_eq "2" "$(cat "$ST/.gitcnt")" "TTL=0 must compute every call"
ls "$ST"/gitcache-* >/dev/null 2>&1 \
  && { printf '    FAIL: TTL=0 must not write a cache file\n' >&2; TEST_FAILED=1; }
rm -rf "$ST" "$WD"
end_test

start_test "cached_git_info: distinct \$PWD yields distinct cache files"
ST=$(mktemp -d); WD1=$(mktemp -d); WD2=$(mktemp -d)
cgi "$WD1" "$ST" 3 >/dev/null; cgi "$WD2" "$ST" 3 >/dev/null
N=$(ls "$ST"/gitcache-* 2>/dev/null | wc -l | tr -d ' ')
assert_eq "2" "$N" "two different workdirs must key two different cache files"
rm -rf "$ST" "$WD1" "$WD2"
end_test

start_test "cached_git_info: malformed (5-field) cache file fails the guard and recomputes"
ST=$(mktemp -d); WD=$(mktemp -d)
cgi "$WD" "$ST" 3 >/dev/null            # counter=1, valid cache
CF=$(ls "$ST"/gitcache-*)
printf 'bad\t1\t2\t3\t4' > "$CF"        # 5 fields, fresh mtime
cgi "$WD" "$ST" 3 >/dev/null
assert_eq "2" "$(cat "$ST/.gitcnt")" "5-field cache must fail guard → recompute"
rm -rf "$ST" "$WD"
end_test

start_test "cached_git_info: empty (0-byte) cache file fails the guard and recomputes"
ST=$(mktemp -d); WD=$(mktemp -d)
cgi "$WD" "$ST" 3 >/dev/null
CF=$(ls "$ST"/gitcache-*)
: > "$CF"                               # 0-byte, fresh mtime
cgi "$WD" "$ST" 3 >/dev/null
assert_eq "2" "$(cat "$ST/.gitcnt")" "0-byte cache must fail guard → recompute"
rm -rf "$ST" "$WD"
end_test

start_test "cached_git_info: valid non-repo line passes the guard and HITs"
ST=$(mktemp -d); WD=$(mktemp -d)
NONREPO=$(printf '\t0\t0\t0\t0\t0')
cgi "$WD" "$ST" 3 "$NONREPO" >/dev/null
OUT2=$(cgi "$WD" "$ST" 3 "$NONREPO")
assert_eq "1" "$(cat "$ST/.gitcnt")" "non-repo line (empty field1) must pass guard → HIT"
assert_eq "$NONREPO" "$OUT2" "HIT returns the cached non-repo line"
rm -rf "$ST" "$WD"
end_test

start_test "cached_git_info: non-numeric GIT_CACHE_TTL falls back to default 3 (not 0/disabled)"
ST=$(mktemp -d); WD=$(mktemp -d)
cgi "$WD" "$ST" abc >/dev/null; cgi "$WD" "$ST" abc >/dev/null
assert_eq "1" "$(cat "$ST/.gitcnt")" "abc→3: fresh second call must HIT (would be 2 if treated as 0)"
rm -rf "$ST" "$WD"
end_test

start_test "cached_git_info: negative GIT_CACHE_TTL falls back to default 3"
ST=$(mktemp -d); WD=$(mktemp -d)
cgi "$WD" "$ST" -5 >/dev/null; cgi "$WD" "$ST" -5 >/dev/null
assert_eq "1" "$(cat "$ST/.gitcnt")" "-5→3: fresh second call must HIT"
rm -rf "$ST" "$WD"
end_test

start_test "cached_git_info: no .tmp.* leftover after a normal miss (atomic write)"
ST=$(mktemp -d); WD=$(mktemp -d)
cgi "$WD" "$ST" 3 >/dev/null
ls "$ST"/gitcache-*.tmp.* >/dev/null 2>&1 \
  && { printf '    FAIL: temp file left behind after atomic write\n' >&2; TEST_FAILED=1; }
rm -rf "$ST" "$WD"
end_test

# --- Task C: cached_git_info() wired into the render path ---
# run_workers cannot steer the git cwd (it hardcodes current_dir:/tmp but git
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
gi_mkrepo() {  # $1=dir $2=initial branch name
  ( cd "$1" && git init -q . && git config user.email t@t.t && git config user.name t \
      && echo a > f.txt && git add f.txt && git commit -qm i && git branch -m "$2" )
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

start_test "render: second render within TTL serves STALE cached git state (cache wired in)"
ST=$(mktemp -d); WD=$(mktemp -d)
gi_mkrepo "$WD" branchbefore
run_workers_in "$WD" "render-gc-2" "$ST" 300 >/dev/null  # arg4=GIT_CACHE_TTL (300=large so 2nd render HITs); caches branchbefore
( cd "$WD" && git branch -m branchafter )                # git state changes
OUT=$(run_workers_in "$WD" "render-gc-2" "$ST" 300 | strip_ansi)  # arg4=GIT_CACHE_TTL=300
echo "$OUT" | grep -qF 'branchbefore' \
  || { printf '    FAIL: render bypassed cache (expected stale branchbefore)\n      got: %q\n' "$OUT" >&2; TEST_FAILED=1; }
echo "$OUT" | grep -qF 'branchafter' \
  && { printf '    FAIL: render showed fresh state (cache not consulted)\n      got: %q\n' "$OUT" >&2; TEST_FAILED=1; }
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
  mkdir -p "$1/bin"
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
  mkdir -p "$1/bin"
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
    printf "%s|%s|%s|%s|%s|%s|%s|%s|%s\n" \
      "$SESSION_ID" "$SANITIZED_SID" "$MODEL" "$DIR" \
      "$CTX_PCT" "$RATE5_PCT" "$RATE5_RESET" "$RATE7_PCT" "$RATE7_RESET"
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
assert_eq 'abc123...|abc123___|Opus|/c/w/d|8|23|1738425600|41|1738857600' \
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
assert_eq 'w|w|X|~/proj|0||||' "$GOT" "C:\\Users\\ → ~/"
GOT=$(call_parse '{"session_id":"w","model":{"display_name":"X"},"workspace":{"current_dir":"c:\\users\\bob\\x"}}')
assert_eq 'w|w|X|~/x|0||||' "$GOT" "lowercase c:/users collapses (case-insensitive, old i flag)"
GOT=$(call_parse '{"session_id":"w","model":{"display_name":"X"},"workspace":{"current_dir":"D:\\Users\\bob\\x"}}')
assert_eq 'w|w|X|D:/Users/bob/x|0||||' "$GOT" "non-C drive NOT collapsed (old behaviour)"
end_test

start_test "parse_status_json: display_name \" (…)\" stripped; null context → CTX 0"
GOT=$(call_parse '{"session_id":"s2","model":{"display_name":"Opus 4.7 (1M context)"},"workspace":{"current_dir":"/home/u/p"},"context_window":{"used_percentage":null}}')
assert_eq 's2|s2|Opus 4.7|/home/u/p|0||||' "$GOT" "suffix stripped; null used_percentage → 0 (// 0 | floor)"
end_test

start_test "parse_status_json: absent context_window does NOT mis-grab a rate used_percentage"
GOT=$(call_parse '{"session_id":"s1","rate_limits":{"five_hour":{"used_percentage":50,"resets_at":111},"seven_day":{"used_percentage":60,"resets_at":222}}}')
assert_eq 's1|s1|||0|50|111|60|222' "$GOT" "CTX=0 via jq path, not 50 (old positional-grep bug); rates intact"
end_test

start_test "parse_status_json: fractional used_percentage floors; SANITIZED_SID maps non-alnum"
GOT=$(call_parse '{"session_id":"f","model":{"display_name":"Opus"},"workspace":{"current_dir":"/c/w/d"},"context_window":{"used_percentage":8},"rate_limits":{"five_hour":{"used_percentage":23.5,"resets_at":1738425600},"seven_day":{"used_percentage":41.2,"resets_at":1738857600}}}')
assert_eq 'f|f|Opus|/c/w/d|8|23|1738425600|41|1738857600' "$GOT" "23.5→23, 41.2→41 (floor), byte-identical to old grep [0-9]*"
GOT=$(call_parse '{"session_id":"a/b.c d","model":{"display_name":"X"},"workspace":{"current_dir":"/x"},"context_window":{"used_percentage":8}}')
assert_eq 'a/b.c d|a_b_c_d|X|/x|8||||' "$GOT" "SANITIZED_SID: non-alnum → _ (tr -c equivalent)"
end_test

# Gate-level: jq failure (malformed input) and empty session_id both collapse
# to an empty SESSION_ID → the render gate emits a single notice + exit 0,
# BEFORE any state-*.tsv write. Old grep code instead renders normally.
start_test "render gate: malformed input → jq-required notice, exit 0, no state write"
NOTICE='oh-my-claude: jq required (winget install jqlang.jq)'
rm -f "$RENDER_STATE_DIR/state-.tsv"
OUT=$(printf 'not valid json at all' | bash "$STATUSLINE" 2>/dev/null); RC=$?
assert_eq "$NOTICE" "$OUT" "malformed JSON → exactly the jq-required notice"
assert_eq "0" "$RC" "notice path exits 0"
[ ! -e "$RENDER_STATE_DIR/state-.tsv" ] \
  || { printf '    FAIL: state-.tsv written on jq-failure path\n' >&2; TEST_FAILED=1; }
end_test

start_test "render gate: empty session_id → jq-required notice, exit 0"
NOTICE='oh-my-claude: jq required (winget install jqlang.jq)'
OUT=$(echo '{"session_id":"","model":{"display_name":"X"},"workspace":{"current_dir":"/x"}}' | bash "$STATUSLINE" 2>/dev/null); RC=$?
assert_eq "$NOTICE" "$OUT" "empty session_id → notice (no broken statusline)"
assert_eq "0" "$RC" "empty-session notice path exits 0"
end_test

# --- worker grouping (spec 2026-05-19) -----------------------------------
# 1-based index of the first stripped output line containing $2 (literal),
# or 0 if absent. Used to assert relative render order.
line_index() {
  printf '%s\n' "$1" | grep -nF -- "$2" | head -1 | cut -d: -f1 | { read -r n; printf '%s' "${n:-0}"; }
}

start_test "WORKERS_MAX caps the rendered shell rows in launch order"
SID="render-test-group-max"
SF="$RENDER_STATE_DIR/state-${SID}.tsv"
NOW=$(date +%s)
sleep 60 & LP1=$!
sleep 60 & LP2=$!
sleep 60 & LP3=$!
{
  printf 'shell\ttoolu_b1\tbash_1\tshell-one\tsleep 99\t%s\t%s\n'      "$((NOW - 25))" "$LP1"
  printf 'shell\ttoolu_b2\tbash_2\tshell-two\tsleep 99\t%s\t%s\n'      "$((NOW - 15))" "$LP2"
  printf 'shell\ttoolu_b3\tbash_3\tshell-three\tsleep 99\t%s\t%s\n'    "$((NOW - 5))"  "$LP3"
} > "$SF"
OUT="$(bash -c "
  OMC_TEST_LIB_ONLY=1
  source '$STATUSLINE'
  WORKERS_STATE_FILE='$SF'
  SESSION_ID='$SID'
  WORKERS_MAX=2
  WORKERS_SHELL_ICON='S'
  emit_workers
" | strip_ansi)"
kill "$LP1" "$LP2" "$LP3" 2>/dev/null; wait "$LP1" "$LP2" "$LP3" 2>/dev/null
echo "$OUT" | grep -qF 'shell-one' && echo "$OUT" | grep -qF 'shell-two' \
  || { printf '    FAIL: cap=2 should keep the first two shells\n      got: %q\n' "$OUT" >&2; TEST_FAILED=1; }
echo "$OUT" | grep -qF 'shell-three' \
  && { printf '    FAIL: third shell rendered despite cap=2\n      got: %q\n' "$OUT" >&2; TEST_FAILED=1; }
end_test

start_test "fancy layout order: git before meters, workers last"
SID="render-test-fancy-order"
SF="$RENDER_STATE_DIR/state-${SID}.tsv"
NOW=$(date +%s)
printf 'shell\ttoolu_fa\tbash_fa\tfancyagentX\tsleep 99\t%s\n' "$((NOW - 15))" > "$SF"
FREPO="$RENDER_STATE_DIR/fancy-repo"
rm -rf "$FREPO"; mkdir -p "$FREPO"
git -C "$FREPO" init -q
git -C "$FREPO" symbolic-ref HEAD refs/heads/fancybrZ
FCONF="$RENDER_STATE_DIR/fancy.conf"
printf 'THEME="catppuccin"\nLAYOUT="fancy"\n' > "$FCONF"
OUT="$(COLUMNS=200 OMC_CONF="$FCONF" bash -c "
  cd '$FREPO' && echo '{\"session_id\":\"$SID\",\"model\":{\"display_name\":\"X\"},\"workspace\":{\"current_dir\":\"$FREPO\"}}' \
    | bash '$STATUSLINE' 2>/dev/null
" | strip_ansi)"
rm -rf "$FREPO" "$FCONF"
I_W=$(line_index "$OUT" 'fancyagentX')
I_G=$(line_index "$OUT" 'fancybrZ')
I_C=$(line_index "$OUT" 'ctx')
[ "$I_W" -gt 0 ] && [ "$I_G" -gt 0 ] && [ "$I_C" -gt 0 ] \
  || { printf '    FAIL: worker/git/ctx line missing (w=%s g=%s c=%s)\n      got: %q\n' "$I_W" "$I_G" "$I_C" "$OUT" >&2; TEST_FAILED=1; }
[ "$I_G" -lt "$I_C" ] \
  || { printf '    FAIL: git not before meters (g=%s c=%s)\n      got: %q\n' "$I_G" "$I_C" "$OUT" >&2; TEST_FAILED=1; }
[ "$I_C" -lt "$I_W" ] \
  || { printf '    FAIL: workers not after meters (c=%s w=%s)\n      got: %q\n' "$I_C" "$I_W" "$OUT" >&2; TEST_FAILED=1; }
end_test

start_test "_omc_sweep_stale_tmp removes orphaned temp files older than 30s, keeps the rest"
ST=$(mktemp -d)
NOW=$(date +%s)
# Crash-orphaned temp files (60s old) — must be swept.
printf 'x' > "$ST/state-sess.tsv.prune.111"
printf 'x' > "$ST/gitcache-somekey.tmp.222"
touch -d "@$((NOW - 60))" "$ST/state-sess.tsv.prune.111" "$ST/gitcache-somekey.tmp.222"
# Fresh temp file + real state/cache files — must all survive.
printf 'x' > "$ST/state-sess.tsv.prune.333"
printf 'x' > "$ST/state-sess.tsv"
printf 'x' > "$ST/gitcache-somekey"
bash -c "
  OMC_STATE_DIR='$ST'
  OMC_TEST_LIB_ONLY=1
  source '$STATUSLINE'
  _omc_sweep_stale_tmp
"
[ ! -f "$ST/state-sess.tsv.prune.111" ] \
  || { printf '    FAIL: stale .prune temp not swept\n' >&2; TEST_FAILED=1; }
[ ! -f "$ST/gitcache-somekey.tmp.222" ] \
  || { printf '    FAIL: stale gitcache .tmp temp not swept\n' >&2; TEST_FAILED=1; }
[ -f "$ST/state-sess.tsv.prune.333" ] \
  || { printf '    FAIL: fresh temp file wrongly swept\n' >&2; TEST_FAILED=1; }
[ -f "$ST/state-sess.tsv" ] \
  || { printf '    FAIL: real state file wrongly swept\n' >&2; TEST_FAILED=1; }
[ -f "$ST/gitcache-somekey" ] \
  || { printf '    FAIL: real gitcache file wrongly swept\n' >&2; TEST_FAILED=1; }
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
ORPHAN="$OMC_STATE_DIR/state-sweepwire.tsv.prune.99999"
printf 'x' > "$ORPHAN"
touch -d "@$((NOW - 60))" "$ORPHAN"
run_workers "render-test-sweep-wiring" 120 >/dev/null
[ ! -f "$ORPHAN" ] \
  || { printf '    FAIL: full render did not sweep the orphaned temp file\n' >&2; TEST_FAILED=1; }
rm -f "$ORPHAN"
end_test

# --- 1.2.0: agent tracking removed; prune keeps shell rows only ---
start_test "prune keeps only shell rows: drops agent (5- and 6-col) and unknown kind"
SID="render-test-t21"
SF="$RENDER_STATE_DIR/state-${SID}.tsv"
NOW=$(date +%s)
SHELL_LINE="$(printf 'shell\ttoolu_s1\t-\tkeepme\tsleep 99\t%s' "$NOW")"
{
  printf 'agent\ttoolu_a1\tgeneral-purpose\told five\t%s\n' "$NOW"
  printf '%s\n' "$SHELL_LINE"
  printf 'agent\ttoolu_a2\tExplore\told six\t%s\t-\n' "$NOW"
  printf 'bogus\tx\ty\n'
} > "$SF"
run_workers "$SID" 200 >/dev/null
assert_eq "$SHELL_LINE" "$(cat "$SF")" "state file must hold exactly the shell row"
end_test

start_test "WORKERS_SHOW_SHELLS=false: no worker lines and state file untouched (no prune)"
SID="render-test-t22"
SF="$RENDER_STATE_DIR/state-${SID}.tsv"
NOW=$(date +%s)
DEAD_LINE="$(printf 'shell\ttoolu_dead\tbash_dead\tghost shell\tsleep 99\t%s\t99999999' "$((NOW - 9999))")"
printf '%s\n' "$DEAD_LINE" > "$SF"
OUT="$(WORKERS_SHOW_SHELLS=false run_workers "$SID" 200 | strip_ansi)"
echo "$OUT" | grep -qF 'ghost shell' \
  && { printf '    FAIL: worker line rendered with WORKERS_SHOW_SHELLS=false\n      got: %q\n' "$OUT" >&2; TEST_FAILED=1; }
assert_eq "$DEAD_LINE" "$(cat "$SF")" "dead row must survive (prune must not run)"
end_test

start_test "1.1.2 mixed state file upgrades to shell rows byte-identical"
SID="render-test-t23"
SF="$RENDER_STATE_DIR/state-${SID}.tsv"
NOW=$(date +%s)
sleep 60 & LP=$!
S6="$(printf 'shell\ttoolu_p\t-\tplaceholder\tsleep 99\t%s' "$NOW")"
S7="$(printf 'shell\ttoolu_l\tbash_l\tlive one\tsleep 99\t%s\t%s' "$NOW" "$LP")"
{
  printf 'agent\ttoolu_a1\tgeneral-purpose\tfive col\t%s\n' "$NOW"
  printf '%s\n' "$S6"
  printf 'agent\ttoolu_a2\tExplore\tsix col\t%s\tagent_x\n' "$NOW"
  printf '%s\n' "$S7"
} > "$SF"
run_workers "$SID" 200 >/dev/null
kill "$LP" 2>/dev/null; wait "$LP" 2>/dev/null
assert_eq "$(printf '%s\n%s' "$S6" "$S7")" "$(cat "$SF")" "exactly the 2 shell lines, byte-identical"
end_test

start_test "no workdir-raw variable left in tests or statusline"
tok=WORKDIR; tok+=_RAW   # built at runtime so this test's own source never matches
assert_eq "" "$(grep -rn -- "$tok" "$REPO_ROOT/tests" "$REPO_ROOT/statusline.sh")" "variable removed"
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
  local out nogit; nogit=$(mktemp -d)
  out=$(cd "$nogit" && echo '{"session_id":"render-test-acc","model":{"display_name":"M"},"workspace":{"current_dir":"/tmp/d"}}' \
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
p=$(OMC_DIR="$REPO_ROOT" OMC_CONF=/dev/null bash "$REPO_ROOT/preview.sh" layouts 2>/dev/null | strip_ansi)
case "$p" in *willie*) ;; *) printf '    FAIL: preview lacks willie\n' >&2; TEST_FAILED=1;; esac
printf 'ACCOUNT_SHOW=false\n' > "$T4D/p.conf"
p=$(OMC_DIR="$REPO_ROOT" OMC_CONF="$T4D/p.conf" bash "$REPO_ROOT/preview.sh" layouts 2>/dev/null | strip_ansi)
case "$p" in *willie*) printf '    FAIL: preview shows willie when disabled\n' >&2; TEST_FAILED=1;; esac
end_test

rm -rf "$T4D"
cleanup_render_state
print_summary

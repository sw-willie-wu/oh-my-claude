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

start_test "short agent line includes type, description, and elapsed"
SID="render-test-001"
SF="$RENDER_STATE_DIR/state-${SID}.tsv"
NOW=$(date +%s)
printf 'agent\ttoolu_a1\tclaude-code-guide\tresearch feature\t%s\n' "$((NOW - 12))" > "$SF"
OUT="$(run_workers "$SID" 120 | strip_ansi)"
echo "$OUT" | grep -qF 'claude-code-guide: research feature' \
  || { printf '    FAIL: agent body missing\n      got: %q\n' "$OUT" >&2; TEST_FAILED=1; }
echo "$OUT" | grep -qE '[0-9]+s' \
  || { printf '    FAIL: elapsed (Ns) missing\n      got: %q\n' "$OUT" >&2; TEST_FAILED=1; }
end_test

start_test "long line truncates and elapsed appears exactly once"
SID="render-test-002"
SF="$RENDER_STATE_DIR/state-${SID}.tsv"
NOW=$(date +%s)
LONG_DESC="a very long description that exceeds terminal width definitely and goes on and on"
printf 'agent\ttoolu_a2\tclaude-code-guide\t%s\t%s\n' "$LONG_DESC" "$((NOW - 12))" > "$SF"
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
printf 'agent\ttoolu_a3\tgeneral-purpose\ta\\tb\\nc\t%s\n' "$((NOW - 5))" > "$SF"
OUT="$(run_workers "$SID" 120 | strip_ansi)"
TAB_PATTERN=$'a\tb'
echo "$OUT" | head -1 | grep -qF "$TAB_PATTERN" \
  || { printf '    FAIL: tab not unescaped in output\n      got: %q\n' "$OUT" >&2; TEST_FAILED=1; }
end_test

start_test "WORKERS_ENABLED=false produces zero worker lines"
SID="render-test-004"
SF="$RENDER_STATE_DIR/state-${SID}.tsv"
NOW=$(date +%s)
printf 'agent\ttoolu_a4\tgeneral-purpose\tshould not appear\t%s\n' "$((NOW - 1))" > "$SF"
OUT="$(WORKERS_ENABLED=false run_workers "$SID" 120 | strip_ansi)"
echo "$OUT" | grep -qF 'should not appear' \
  && { printf '    FAIL: worker line emitted despite WORKERS_ENABLED=false\n      got: %q\n' "$OUT" >&2; TEST_FAILED=1; }
end_test

start_test "corrupt row (missing start_unix) is skipped silently"
SID="render-test-005"
SF="$RENDER_STATE_DIR/state-${SID}.tsv"
# Row missing the trailing start_unix column.
printf 'agent\ttoolu_a5\tgeneral-purpose\tcorrupt row no timestamp\n' > "$SF"
OUT="$(run_workers "$SID" 120 | strip_ansi)"
echo "$OUT" | grep -qF 'corrupt row no timestamp' \
  && { printf '    FAIL: corrupt row should not render\n      got: %q\n' "$OUT" >&2; TEST_FAILED=1; }
end_test

start_test "WORKDIR_RAW preserves raw current_dir for is_agent_alive slug"
SID="render-test-workdir-raw"
SF="$RENDER_STATE_DIR/state-${SID}.tsv"
: > "$SF"
# Inject a debug echo via env override (we'll add WORKDIR_RAW capture in statusline).
OUT=$(echo "{\"session_id\":\"$SID\",\"model\":{\"display_name\":\"X\"},\"workspace\":{\"current_dir\":\"C:\\\\Users\\\\test\\\\proj\"}}" \
  | OMC_DEBUG_DUMP_WORKDIR_RAW=1 bash "$STATUSLINE" 2>&1)
echo "$OUT" | grep -qF 'WORKDIR_RAW=C:\Users\test\proj' \
  || { printf '    FAIL: WORKDIR_RAW not captured pre-normalization\n      got: %q\n' "$OUT" >&2; TEST_FAILED=1; }
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
  WORKDIR_RAW='/tmp'
  SESSION_ID='$SID'
  prune_state_and_emit
")
assert_line_count "$SF" 0 "dead row should be removed by prune"
end_test

start_test "prune drops shell row with dead PID, keeps alive shell + agent"
SID="render-test-prune-1"
SF="$RENDER_STATE_DIR/state-${SID}.tsv"
NOW=$(date +%s)
sleep 30 &
LIVE_PID=$!
DEAD_PID=99999999
{
  printf 'agent\ttoolu_a1\tgeneral-purpose\talive agent\t%s\n' "$NOW"
  printf 'shell\ttoolu_b_dead\tbash_dead\tdead bash\tsleep 99\t%s\t%s\n' "$NOW" "$DEAD_PID"
  printf 'shell\ttoolu_b_live\tbash_live\tlive bash\tsleep 99\t%s\t%s\n' "$NOW" "$LIVE_PID"
} > "$SF"
OUT=$(run_workers "$SID" 200 | strip_ansi)
kill "$LIVE_PID" 2>/dev/null
wait "$LIVE_PID" 2>/dev/null
echo "$OUT" | grep -qF 'alive agent' \
  || { printf '    FAIL: agent missing\n      got: %q\n' "$OUT" >&2; TEST_FAILED=1; }
echo "$OUT" | grep -qF 'live bash' \
  || { printf '    FAIL: alive shell missing\n      got: %q\n' "$OUT" >&2; TEST_FAILED=1; }
echo "$OUT" | grep -qvF 'dead bash' \
  || { printf '    FAIL: dead shell still rendered\n      got: %q\n' "$OUT" >&2; TEST_FAILED=1; }
grep -qF 'bash_dead' "$SF" \
  && { printf '    FAIL: dead row not removed from state\n' >&2; TEST_FAILED=1; }
end_test

start_test "prune preserves agent row at exactly 5 columns (N-C1 regression)"
SID="render-test-prune-2"
SF="$RENDER_STATE_DIR/state-${SID}.tsv"
NOW=$(date +%s)
printf 'agent\ttoolu_a1\tgeneral-purpose\tagent only\t%s\n' "$NOW" > "$SF"
run_workers "$SID" 200 >/dev/null
COLCOUNT=$(awk -F'\t' '{print NF}' "$SF" | head -1)
assert_eq "5" "$COLCOUNT" "agent row should remain 5 cols after prune"
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

# --- Task 4: prune writeback preserves agent col6 ---
start_test "prune preserves agent col6 (agentId) on writeback"
SID="render-test-agent-col6"
SF="$RENDER_STATE_DIR/state-${SID}.tsv"
NOW=$(date +%s)
printf 'agent\ttoolu_pre\tExplore\tdesc\t%s\t-\n' "$NOW" > "$SF"
RESULT=$(bash -c "
  OMC_TEST_LIB_ONLY=1
  source '$STATUSLINE'
  WORKERS_STATE_FILE='$SF'
  WORKDIR_RAW='/tmp'
  SESSION_ID='$SID'
  prune_state_and_emit >/dev/null
")
assert_eq "6" "$(awk -F'\t' '{print NF}' "$SF" | head -1)" "agent row must stay 6 cols after prune"
assert_eq "-" "$(awk -F'\t' '{print $6}' "$SF" | head -1)" "col6 must survive writeback"
end_test

start_test "prune still emits legacy 5-col agent row as 5 cols (back-compat)"
SID="render-test-agent-5col-bc"
SF="$RENDER_STATE_DIR/state-${SID}.tsv"
NOW=$(date +%s)
printf 'agent\ttoolu_legacy\tgeneral-purpose\tlegacy\t%s\n' "$NOW" > "$SF"
bash -c "
  OMC_TEST_LIB_ONLY=1
  source '$STATUSLINE'
  WORKERS_STATE_FILE='$SF'
  WORKDIR_RAW='/tmp'
  SESSION_ID='$SID'
  prune_state_and_emit >/dev/null
"
assert_eq "5" "$(awk -F'\t' '{print NF}' "$SF" | head -1)" "legacy 5-col agent row must not grow a column"
assert_line_count "$SF" 1 "legacy 5-col agent row must be kept"
end_test

# --- Task 5: render-side liveness check for async agent rows ---
# wd_id transform mirrors statusline.sh: every non-alnum char in
# WORKDIR_RAW -> '-' (per-char, not collapsed; Claude Code's slug rule).
# WORKDIR_RAW='/tmp' => wd_id='-tmp'.
agent_prune() {
  # $1=state file  $2=session id  $3=transcript root  $4=WORKDIR_RAW(default /tmp)
  WORKERS_AGENT_TRANSCRIPT_ROOT="$3" \
  WORKERS_PLACEHOLDER_GRACE_SEC=5 \
  WORKERS_AGENT_QUIET_SEC=5 \
  bash -c "
    OMC_TEST_LIB_ONLY=1
    source '$STATUSLINE'
    WORKERS_STATE_FILE='$1'
    WORKDIR_RAW='${4:-/tmp}'
    SESSION_ID='$2'
    prune_state_and_emit >/dev/null
  "
}
# Claude Code slugifies the cwd by replacing every non-alphanumeric char
# with '-' (NOT collapsed). '/tmp' -> '-tmp'.
wd_slug() { printf '%s' "$1" | sed 's/[^A-Za-z0-9]/-/g'; }
mk_jsonl() {
  # $1=root $2=sid $3=agentId $4=lastline_json $5=mtime_epoch(optional) $6=slug(default -tmp)
  local d="$1/${6:--tmp}/$2/subagents"
  mkdir -p "$d"
  printf '%s\n' "$4" > "$d/agent-$3.jsonl"
  [ -n "${5:-}" ] && touch -d "@$5" "$d/agent-$3.jsonl"
}
asst_line() { printf '{"type":"assistant","message":{"stop_reason":%s}}' "$1"; }
user_line='{"type":"user","message":{"content":[{"type":"tool_result"}]}}'

start_test "prune keeps agent row when JSONL mtime is fresh (alive fast-path)"
SID="render-test-agent-live-mtime"
SF="$RENDER_STATE_DIR/state-${SID}.tsv"
ROOT=$(mktemp -d)
NOW=$(date +%s)
mk_jsonl "$ROOT" "$SID" "a_live" "$(asst_line '"end_turn"')"   # fresh mtime (just created)
printf 'agent\ttoolu_lm\tExplore\tdesc\t%s\ta_live\n' "$((NOW - 9999))" > "$SF"
agent_prune "$SF" "$SID" "$ROOT"
assert_line_count "$SF" 1 "fresh-mtime agent must be kept even beyond grace"
rm -rf "$ROOT"
end_test

start_test "prune drops agent row when JSONL stale + stop_reason terminal"
SID="render-test-agent-done"
SF="$RENDER_STATE_DIR/state-${SID}.tsv"
ROOT=$(mktemp -d)
NOW=$(date +%s)
mk_jsonl "$ROOT" "$SID" "a_done" "$(asst_line '"end_turn"')" "$((NOW - 9999))"
printf 'agent\ttoolu_dn\tExplore\tdesc\t%s\ta_done\n' "$((NOW - 9999))" > "$SF"
agent_prune "$SF" "$SID" "$ROOT"
assert_line_count "$SF" 0 "stale + end_turn agent must be pruned"
rm -rf "$ROOT"
end_test

start_test "prune keeps agent row when JSONL stale but stop_reason=tool_use (mid-loop)"
SID="render-test-agent-midloop"
SF="$RENDER_STATE_DIR/state-${SID}.tsv"
ROOT=$(mktemp -d)
NOW=$(date +%s)
mk_jsonl "$ROOT" "$SID" "a_loop" "$(asst_line '"tool_use"')" "$((NOW - 9999))"
printf 'agent\ttoolu_ml\tExplore\tdesc\t%s\ta_loop\n' "$((NOW - 9999))" > "$SF"
agent_prune "$SF" "$SID" "$ROOT"
assert_line_count "$SF" 1 "stale-but-tool_use agent must be kept (still mid-loop)"
rm -rf "$ROOT"
end_test

start_test "prune drops agent row when JSONL missing and beyond grace"
SID="render-test-agent-nojsonl"
SF="$RENDER_STATE_DIR/state-${SID}.tsv"
ROOT=$(mktemp -d)
NOW=$(date +%s)
printf 'agent\ttoolu_nj\tExplore\tdesc\t%s\ta_ghost\n' "$((NOW - 9999))" > "$SF"
agent_prune "$SF" "$SID" "$ROOT"
assert_line_count "$SF" 0 "missing JSONL beyond grace must be pruned"
rm -rf "$ROOT"
end_test

start_test "prune keeps agentId row when JSONL missing but within grace (launch window)"
SID="render-test-agent-grace"
SF="$RENDER_STATE_DIR/state-${SID}.tsv"
ROOT=$(mktemp -d)
NOW=$(date +%s)
printf 'agent\ttoolu_gw\tExplore\tdesc\t%s\ta_justlaunched\n' "$NOW" > "$SF"
agent_prune "$SF" "$SID" "$ROOT"
assert_line_count "$SF" 1 "fresh agentId row within grace must survive the launch window"
rm -rf "$ROOT"
end_test

start_test "prune keeps placeholder agent row (col6=-) within grace"
SID="render-test-agent-ph-fresh"
SF="$RENDER_STATE_DIR/state-${SID}.tsv"
ROOT=$(mktemp -d)
NOW=$(date +%s)
printf 'agent\ttoolu_pf\tExplore\tdesc\t%s\t-\n' "$NOW" > "$SF"
agent_prune "$SF" "$SID" "$ROOT"
assert_line_count "$SF" 1 "fresh placeholder must survive"
rm -rf "$ROOT"
end_test

start_test "prune reaps placeholder agent row (col6=-) beyond grace"
SID="render-test-agent-ph-stale"
SF="$RENDER_STATE_DIR/state-${SID}.tsv"
ROOT=$(mktemp -d)
NOW=$(date +%s)
printf 'agent\ttoolu_ps\tExplore\tdesc\t%s\t-\n' "$((NOW - 9999))" > "$SF"
agent_prune "$SF" "$SID" "$ROOT"
assert_line_count "$SF" 0 "stale placeholder (Post never patched col6) must be reaped"
rm -rf "$ROOT"
end_test

# --- C1: wd_id slug must match Claude Code (all non-alnum -> '-') ---
start_test "is_agent_alive resolves JSONL under a cwd containing _ and ."
SID="render-test-agent-slug"
SF="$RENDER_STATE_DIR/state-${SID}.tsv"
ROOT=$(mktemp -d)
NOW=$(date +%s)
WDR='/home/a_b.c/proj'                       # real slug: -home-a-b-c-proj
mk_jsonl "$ROOT" "$SID" "a_slug" "$(asst_line '"tool_use"')" "" "$(wd_slug "$WDR")"
printf 'agent\ttoolu_sl\tExplore\tdesc\t%s\ta_slug\n' "$((NOW - 9999))" > "$SF"
agent_prune "$SF" "$SID" "$ROOT" "$WDR"
assert_line_count "$SF" 1 "agent must be found+kept when cwd slug has _/. (C1)"
rm -rf "$ROOT"
end_test

# --- I1: liveness keys off the last transcript line's type, not just stop_reason ---
start_test "prune keeps agent whose JSONL ends on a user/tool_result line (model owes a turn)"
SID="render-test-agent-toolresult"
SF="$RENDER_STATE_DIR/state-${SID}.tsv"
ROOT=$(mktemp -d)
NOW=$(date +%s)
mk_jsonl "$ROOT" "$SID" "a_tr" "$user_line" "$((NOW - 9999))"
printf 'agent\ttoolu_tr\tExplore\tdesc\t%s\ta_tr\n' "$((NOW - 9999))" > "$SF"
agent_prune "$SF" "$SID" "$ROOT"
assert_line_count "$SF" 1 "stale JSONL ending in tool_result must be kept (mid-loop)"
rm -rf "$ROOT"
end_test

start_test "prune drops agent whose last assistant line has stop_reason null (terminal text)"
SID="render-test-agent-nullsr"
SF="$RENDER_STATE_DIR/state-${SID}.tsv"
ROOT=$(mktemp -d)
NOW=$(date +%s)
mk_jsonl "$ROOT" "$SID" "a_ns" "$(asst_line null)" "$((NOW - 9999))"
printf 'agent\ttoolu_ns\tExplore\tdesc\t%s\ta_ns\n' "$((NOW - 9999))" > "$SF"
agent_prune "$SF" "$SID" "$ROOT"
assert_line_count "$SF" 0 "stale + trailing assistant text (sr=null) must be pruned"
rm -rf "$ROOT"
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

cleanup_render_state
print_summary

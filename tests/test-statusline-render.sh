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
  COLUMNS="$cols" bash -c "
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

start_test "WORKDIR_RAW preserves raw current_dir for output-file fallback path"
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

start_test "is_bash_output_present returns true when output file exists"
SID="render-test-output-fb-1"
SF="$RENDER_STATE_DIR/state-${SID}.tsv"
TMPROOT=$(mktemp -d)
WD_RAW='C:\Users\test\proj'
WD_ID='C--Users-test-proj'
mkdir -p "$TMPROOT/claude/$WD_ID/$SID/tasks"
touch "$TMPROOT/claude/$WD_ID/$SID/tasks/bash_xyz.output"
RESULT=$(TEMP="$TMPROOT" bash -c "
  OMC_TEST_LIB_ONLY=1
  source '$STATUSLINE'
  WORKDIR_RAW='$WD_RAW'
  SESSION_ID='$SID'
  is_bash_output_present bash_xyz && echo YES || echo NO
")
assert_eq "YES" "$RESULT" "output file existed but helper returned false"
rm -rf "$TMPROOT"
end_test

start_test "is_bash_output_present returns false when file missing"
SID="render-test-output-fb-2"
TMPROOT=$(mktemp -d)
WD_RAW='C:\Users\test\proj'
RESULT=$(TEMP="$TMPROOT" bash -c "
  OMC_TEST_LIB_ONLY=1
  source '$STATUSLINE'
  WORKDIR_RAW='$WD_RAW'
  SESSION_ID='$SID'
  is_bash_output_present bash_missing && echo YES || echo NO
")
assert_eq "NO" "$RESULT" "missing output file should return false"
rm -rf "$TMPROOT"
end_test

start_test "is_bash_output_present returns false when fallback disabled"
SID="render-test-output-fb-3"
TMPROOT=$(mktemp -d)
WD_RAW='C:\Users\test\proj'
WD_ID='C--Users-test-proj'
mkdir -p "$TMPROOT/claude/$WD_ID/$SID/tasks"
touch "$TMPROOT/claude/$WD_ID/$SID/tasks/bash_xyz.output"
RESULT=$(TEMP="$TMPROOT" WORKERS_OUTPUT_FALLBACK_ENABLED=false bash -c "
  OMC_TEST_LIB_ONLY=1
  source '$STATUSLINE'
  WORKDIR_RAW='$WD_RAW'
  SESSION_ID='$SID'
  is_bash_output_present bash_xyz && echo YES || echo NO
")
assert_eq "NO" "$RESULT" "disabled flag should suppress fallback"
rm -rf "$TMPROOT"
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

start_test "prune uses output-file fallback for legacy 6-col shell row"
SID="render-test-prune-3"
SF="$RENDER_STATE_DIR/state-${SID}.tsv"
NOW=$(date +%s)
TMPROOT=$(mktemp -d)
WD_ID='-tmp'
mkdir -p "$TMPROOT/claude/$WD_ID/$SID/tasks"
touch "$TMPROOT/claude/$WD_ID/$SID/tasks/bash_legacy.output"
printf 'shell\ttoolu_legacy\tbash_legacy\tlegacy\tsleep 99\t%s\n' "$NOW" > "$SF"
OUT=$(TEMP="$TMPROOT" run_workers "$SID" 200 | strip_ansi)
echo "$OUT" | grep -qF 'legacy' \
  || { printf '    FAIL: legacy row pruned despite present output file\n      got: %q\n' "$OUT" >&2; TEST_FAILED=1; }
rm -rf "$TMPROOT"
end_test

cleanup_render_state
print_summary

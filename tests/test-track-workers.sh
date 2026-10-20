#!/bin/bash
# Tests for hooks/track-workers.sh
set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"

# shellcheck source=test-helpers.sh
. "$SCRIPT_DIR/test-helpers.sh"

# Path to the dispatcher under test.
TRACK_WORKERS="$REPO_ROOT/hooks/track-workers.sh"

printf 'Running track-workers tests in: %s\n\n' "$OMC_STATE_DIR"

# (Tests will be added in subsequent tasks.)

start_test "session-start creates state directory and empty state file"
SESSION_ID="test-session-001"
echo "{\"session_id\":\"$SESSION_ID\",\"hook_event_name\":\"SessionStart\",\"source\":\"startup\"}" \
  | bash "$TRACK_WORKERS" session-start
STATE_FILE="$OMC_STATE_DIR/state-${SESSION_ID}.tsv"
[ -d "$OMC_STATE_DIR" ] || { printf '    FAIL: state dir missing\n' >&2; TEST_FAILED=1; }
[ -f "$STATE_FILE" ] || { printf '    FAIL: state file missing: %s\n' "$STATE_FILE" >&2; TEST_FAILED=1; }
assert_line_count "$STATE_FILE" 0 "fresh state file should be empty"
end_test

start_test "PreToolUse(Bash, run_in_background:true) appends shell row"
SESSION_ID="test-session-004"
SF="$OMC_STATE_DIR/state-${SESSION_ID}.tsv"
: > "$SF"
cat <<'EOF' | bash "$TRACK_WORKERS" pre
{
  "session_id": "test-session-004",
  "hook_event_name": "PreToolUse",
  "tool_name": "Bash",
  "tool_use_id": "toolu_b1",
  "tool_input": {
    "command": "npm run dev",
    "description": "run dev server",
    "run_in_background": true
  }
}
EOF
assert_line_count "$SF" 1 "expected one shell row"
assert_file_contains "$SF" "shell	toolu_b1	-	run dev server	npm run dev"
end_test

start_test "PreToolUse(Bash, run_in_background:false) is no-op"
SESSION_ID="test-session-005"
SF="$OMC_STATE_DIR/state-${SESSION_ID}.tsv"
: > "$SF"
cat <<'EOF' | bash "$TRACK_WORKERS" pre
{
  "session_id": "test-session-005",
  "hook_event_name": "PreToolUse",
  "tool_name": "Bash",
  "tool_use_id": "toolu_b2",
  "tool_input": {
    "command": "ls",
    "run_in_background": false
  }
}
EOF
assert_line_count "$SF" 0 "expected no rows"
end_test

start_test "PreToolUse(Bash, no run_in_background field) is no-op"
SESSION_ID="test-session-006"
SF="$OMC_STATE_DIR/state-${SESSION_ID}.tsv"
: > "$SF"
cat <<'EOF' | bash "$TRACK_WORKERS" pre
{
  "session_id": "test-session-006",
  "hook_event_name": "PreToolUse",
  "tool_name": "Bash",
  "tool_use_id": "toolu_b3",
  "tool_input": { "command": "ls" }
}
EOF
assert_line_count "$SF" 0 "expected no rows"
end_test

start_test "PostToolUse(Bash) patches backgroundTaskId into shell row column 3"
SESSION_ID="test-session-007"
SF="$OMC_STATE_DIR/state-${SESSION_ID}.tsv"
printf 'shell\ttoolu_b1\t-\trun dev server\tnpm run dev\t1735000000\n' > "$SF"
cat <<'EOF' | bash "$TRACK_WORKERS" post
{
  "session_id": "test-session-007",
  "hook_event_name": "PostToolUse",
  "tool_name": "Bash",
  "tool_use_id": "toolu_b1",
  "tool_input": { "command": "npm run dev", "run_in_background": true },
  "tool_response": {
    "stdout": "",
    "stderr": "",
    "interrupted": false,
    "backgroundTaskId": "bash_xyz9"
  }
}
EOF
assert_file_contains "$SF" "shell	toolu_b1	bash_xyz9	run dev server	npm run dev"
assert_file_not_contains "$SF" "shell	toolu_b1	-"
end_test

# Helper to seed a shell row before each BashOutput test.
seed_shell_row() {
  local sid="$1"
  local sf="$OMC_STATE_DIR/state-${sid}.tsv"
  printf 'shell\ttoolu_b1\tbash_xyz9\trun dev server\tnpm run dev\t1735000000\n' > "$sf"
}

for ALIAS in task_id agentId bash_id; do
  start_test "PostToolUse(BashOutput) terminal status with $ALIAS alias removes row"
  SESSION_ID="test-session-bo-$ALIAS"
  SF="$OMC_STATE_DIR/state-${SESSION_ID}.tsv"
  seed_shell_row "$SESSION_ID"
  CURR_ALIAS="$ALIAS"
  CURR_SESSION_ID="$SESSION_ID"
  cat <<EOF | bash "$TRACK_WORKERS" post
{
  "session_id": "$CURR_SESSION_ID",
  "hook_event_name": "PostToolUse",
  "tool_name": "BashOutput",
  "tool_use_id": "toolu_bo1",
  "tool_input": { "$CURR_ALIAS": "bash_xyz9" },
  "tool_response": { "status": "completed" }
}
EOF
  assert_line_count "$SF" 0 "row should be removed for $ALIAS alias"
  end_test
done

start_test "PostToolUse(BashOutput) status=running is no-op"
SESSION_ID="test-session-bo-running"
SF="$OMC_STATE_DIR/state-${SESSION_ID}.tsv"
seed_shell_row "$SESSION_ID"
cat <<'EOF' | bash "$TRACK_WORKERS" post
{
  "session_id": "test-session-bo-running",
  "hook_event_name": "PostToolUse",
  "tool_name": "BashOutput",
  "tool_use_id": "toolu_bo2",
  "tool_input": { "task_id": "bash_xyz9" },
  "tool_response": { "status": "running" }
}
EOF
assert_line_count "$SF" 1 "row should remain (status not terminal)"
end_test

start_test "PostToolUse(BashOutput) status=killed removes row"
SESSION_ID="test-session-bo-killed"
SF="$OMC_STATE_DIR/state-${SESSION_ID}.tsv"
seed_shell_row "$SESSION_ID"
cat <<'EOF' | bash "$TRACK_WORKERS" post
{
  "session_id": "test-session-bo-killed",
  "hook_event_name": "PostToolUse",
  "tool_name": "BashOutput",
  "tool_use_id": "toolu_bo3",
  "tool_input": { "task_id": "bash_xyz9" },
  "tool_response": { "status": "killed" }
}
EOF
assert_line_count "$SF" 0 "row should be removed on killed status"
end_test

for ALIAS in task_id shell_id; do
  start_test "PreToolUse(KillShell) with $ALIAS alias removes shell row"
  SESSION_ID="test-session-ks-$ALIAS"
  SF="$OMC_STATE_DIR/state-${SESSION_ID}.tsv"
  seed_shell_row "$SESSION_ID"
  cat <<EOF | bash "$TRACK_WORKERS" pre
{
  "session_id": "$SESSION_ID",
  "hook_event_name": "PreToolUse",
  "tool_name": "KillShell",
  "tool_use_id": "toolu_ks1",
  "tool_input": { "$ALIAS": "bash_xyz9" }
}
EOF
  assert_line_count "$SF" 0 "row should be removed for $ALIAS alias"
  end_test
done

start_test "session-start deletes sibling state files older than 24h"
# Create three stale files and one fresh.
OLD_FILE="$OMC_STATE_DIR/state-old-aaa.tsv"
RECENT_FILE="$OMC_STATE_DIR/state-recent-bbb.tsv"
printf 'agent\told\t-\told\t1\n' > "$OLD_FILE"
printf 'agent\trecent\t-\trecent\t1\n' > "$RECENT_FILE"
# Set OLD_FILE mtime to 25h ago (cross-platform).
if date -d '25 hours ago' '+%Y%m%d%H%M.%S' >/dev/null 2>&1; then
  touch -t "$(date -d '25 hours ago' '+%Y%m%d%H%M.%S')" "$OLD_FILE"
else
  touch -t "$(date -v-25H '+%Y%m%d%H%M.%S')" "$OLD_FILE"
fi
SESSION_ID="test-session-cleanup"
echo "{\"session_id\":\"$SESSION_ID\",\"hook_event_name\":\"SessionStart\",\"source\":\"startup\"}" \
  | bash "$TRACK_WORKERS" session-start
[ ! -f "$OLD_FILE" ] || { printf '    FAIL: stale file should have been deleted\n' >&2; TEST_FAILED=1; }
[ -f "$RECENT_FILE" ] || { printf '    FAIL: recent file unexpectedly deleted\n' >&2; TEST_FAILED=1; }
end_test

start_test "session-start deletes stale gitcache files (incl .tmp leftovers) older than 24h"
GC_OLD="$OMC_STATE_DIR/gitcache-some-dir-slug"
GC_TMP_OLD="$OMC_STATE_DIR/gitcache-some-dir-slug.tmp.9999"
GC_FRESH="$OMC_STATE_DIR/gitcache-fresh-slug"
printf 'main\t0\t0\t0\t0\t0' > "$GC_OLD"
printf 'main\t0\t0\t0\t0\t0' > "$GC_TMP_OLD"
printf 'main\t0\t0\t0\t0\t0' > "$GC_FRESH"
if date -d '25 hours ago' '+%Y%m%d%H%M.%S' >/dev/null 2>&1; then
  GC_STALE_TS=$(date -d '25 hours ago' '+%Y%m%d%H%M.%S')
else
  GC_STALE_TS=$(date -v-25H '+%Y%m%d%H%M.%S')
fi
touch -t "$GC_STALE_TS" "$GC_OLD" "$GC_TMP_OLD"
SESSION_ID="test-session-gitcache-cleanup"
echo "{\"session_id\":\"$SESSION_ID\",\"hook_event_name\":\"SessionStart\",\"source\":\"startup\"}" \
  | bash "$TRACK_WORKERS" session-start
[ ! -f "$GC_OLD" ] || { printf '    FAIL: stale gitcache file should have been deleted\n' >&2; TEST_FAILED=1; }
[ ! -f "$GC_TMP_OLD" ] || { printf '    FAIL: stale gitcache .tmp leftover should have been deleted\n' >&2; TEST_FAILED=1; }
[ -f "$GC_FRESH" ] || { printf '    FAIL: fresh gitcache file unexpectedly deleted\n' >&2; TEST_FAILED=1; }
end_test

start_test "10 concurrent PreToolUse(Bash bg) writers all land"
SESSION_ID="test-session-concurrent"
SF="$OMC_STATE_DIR/state-${SESSION_ID}.tsv"
: > "$SF"
for i in $(seq 1 10); do
  cat <<EOF | bash "$TRACK_WORKERS" pre &
{
  "session_id": "$SESSION_ID",
  "hook_event_name": "PreToolUse",
  "tool_name": "Bash",
  "tool_use_id": "toolu_c${i}",
  "tool_input": { "command": "sleep ${i}", "description": "task ${i}", "run_in_background": true }
}
EOF
done
wait
assert_line_count "$SF" 10 "expected 10 rows from concurrent writers"
end_test

start_test "stale lock (no pid file, past OMC_LOCK_STALE_SEC) is broken and writer succeeds"
SESSION_ID="test-session-stale-lock"
SF="$OMC_STATE_DIR/state-${SESSION_ID}.tsv"
: > "$SF"
mkdir "$OMC_STATE_DIR/state.lock" 2>/dev/null
# Set lock dir mtime to 30s ago.
if date -d '30 seconds ago' '+%Y%m%d%H%M.%S' >/dev/null 2>&1; then
  touch -t "$(date -d '30 seconds ago' '+%Y%m%d%H%M.%S')" "$OMC_STATE_DIR/state.lock"
else
  touch -t "$(date -v-30S '+%Y%m%d%H%M.%S')" "$OMC_STATE_DIR/state.lock"
fi
cat <<EOF | bash "$TRACK_WORKERS" pre
{
  "session_id": "$SESSION_ID",
  "hook_event_name": "PreToolUse",
  "tool_name": "Bash",
  "tool_use_id": "toolu_stale",
  "tool_input": { "command": "sleep 1", "description": "stale lock victim", "run_in_background": true }
}
EOF
# The line count IS the guarantee: a row was written ⇒ the 30s-stale lock was
# detected and broken. If stale-detection regressed, omc_with_lock spins its
# bounded 100×0.05s loop, never acquires, and track-workers exits WITHOUT
# writing → 0 lines (caught here). The old `ELAPSED <= 2s` wall-clock check was
# a fragile proxy that mostly measured bash/jq spawn overhead and false-failed
# on a loaded box; it is redundant with this assertion (a broken stale-break
# degrades to a line-count failure within ~5s — it cannot hang) so it was
# removed rather than guessing at a timing budget (condition-based-waiting).
assert_line_count "$SF" 1 "writer should have succeeded after breaking stale lock"
end_test

start_test "lock with a dead holder PID is reclaimed before the stale window"
SESSION_ID="test-session-deadpid-lock"
SF="$OMC_STATE_DIR/state-${SESSION_ID}.tsv"
: > "$SF"
mkdir "$OMC_STATE_DIR/state.lock" 2>/dev/null
# A PID too large to be live. The lock dir mtime is fresh (just created,
# well within OMC_LOCK_STALE_SEC) — so ONLY the dead-holder PID check, not
# the age backstop, can break this lock. If PID-liveness detection
# regressed, omc_with_lock spins out its bounded loop without acquiring and
# track-workers exits writing 0 lines (caught by the assertion below).
printf '%s' "2147480000" > "$OMC_STATE_DIR/state.lock/pid"  # no newline — mirror production's pid write
cat <<EOF | bash "$TRACK_WORKERS" pre
{
  "session_id": "$SESSION_ID",
  "hook_event_name": "PreToolUse",
  "tool_name": "Bash",
  "tool_use_id": "toolu_deadpid",
  "tool_input": { "command": "sleep 1", "description": "dead-holder victim", "run_in_background": true }
}
EOF
assert_line_count "$SF" 1 "writer should reclaim a lock whose holder PID is dead"
end_test

start_test "description with tab/newline/backslash round-trips through state file"
SESSION_ID="test-session-escape"
SF="$OMC_STATE_DIR/state-${SESSION_ID}.tsv"
: > "$SF"
# Description contains a literal tab, a newline, and backslashes.
cat <<'EOF' | bash "$TRACK_WORKERS" pre
{
  "session_id": "test-session-escape",
  "hook_event_name": "PreToolUse",
  "tool_name": "Bash",
  "tool_use_id": "toolu_esc",
  "tool_input": {
    "command": "sleep 1",
    "run_in_background": true,
    "description": "a\tb\nc\\d"
  }
}
EOF
# After escape, the row stays one line (no embedded raw newlines/tabs in description column).
assert_line_count "$SF" 1 "escape must keep row to single line"
# State file should NOT contain a raw embedded newline inside the description (it'd split the row).
RAW_LINES=$(awk 'END {print NR}' "$SF")
assert_eq "1" "$RAW_LINES" "row must be one TSV line after escaping"
# Shell row description is column 4; \t and \\ escapes present, round-trips.
DESC_COL=$(awk -F'\t' '{print $4}' "$SF" | tr -d '\r')
assert_eq 'a\tb\nc\\d' "$DESC_COL" "description column holds the escaped form"
assert_eq "$(printf 'a\tb\nc\\d')" "$(printf '%b' "$DESC_COL")" "unescaping round-trips"
end_test

start_test "unescape_field reverses escape_field"
INPUT='a\tb\nc\\d'
EXPECTED=$(printf 'a\tb\nc\\d')
ACTUAL=$(awk -v input="$INPUT" 'BEGIN {
  s = input
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
}')
assert_eq "$EXPECTED" "$ACTUAL" "unescape result must match"
end_test

start_test "cross-kind ID collision: agent.subagent_type matching shell.bg_task_id is not deleted by KillShell"
SESSION_ID="test-session-collision"
SF="$OMC_STATE_DIR/state-${SESSION_ID}.tsv"
# Pathological: agent has subagent_type "bash_xyz9" (column 3), shell has same value as background_task_id.
printf 'agent\ttoolu_a1\tbash_xyz9\tagent description\t1735000000\n' > "$SF"
printf 'shell\ttoolu_b1\tbash_xyz9\tshell description\tnpm run dev\t1735000005\n' >> "$SF"
cat <<EOF | bash "$TRACK_WORKERS" pre
{
  "session_id": "$SESSION_ID",
  "hook_event_name": "PreToolUse",
  "tool_name": "KillShell",
  "tool_use_id": "toolu_ks_collision",
  "tool_input": { "task_id": "bash_xyz9" }
}
EOF
# Only the shell row should be removed; agent row must survive.
assert_line_count "$SF" 1 "agent row should survive KillShell"
assert_file_contains "$SF" "agent	toolu_a1	bash_xyz9"
assert_file_not_contains "$SF" "shell	toolu_b1"
end_test

start_test "PostToolUse(Bash, bg) stores PID in col7"
SESSION_ID="test-session-pid-1"
SF="$OMC_STATE_DIR/state-${SESSION_ID}.tsv"
# Pre-state: row already added by PreToolUse, col3=- placeholder.
printf 'shell\ttoolu_b1\t-\trun forever\tsleep 9999\t1735000000\n' > "$SF"
# Spawn a real bash that matches the fingerprint.
( exec -a bash bash -c 'sleep 9999' ) &
SPAWNED_PID=$!
sleep 0.2  # let ps see it
cat <<EOF | bash "$TRACK_WORKERS" post
{
  "session_id": "$SESSION_ID",
  "hook_event_name": "PostToolUse",
  "tool_name": "Bash",
  "tool_use_id": "toolu_b1",
  "tool_input": {"command": "sleep 9999", "run_in_background": true},
  "tool_response": {"backgroundTaskId": "bash_xyz"}
}
EOF
COL7=$(awk -F'\t' '{print $7}' "$SF")
[ -n "$COL7" ] && [ "$COL7" -gt 0 ] 2>/dev/null \
  || { printf '    FAIL: col7 not a positive PID, got=%q\n' "$COL7" >&2; TEST_FAILED=1; }
kill "$SPAWNED_PID" 2>/dev/null
wait "$SPAWNED_PID" 2>/dev/null
end_test

start_test "PostToolUse(Bash, bg) captures PID when command is wrapped in 'eval'"
# Claude Code on MSYS bash wraps user commands as:
#   /bin/bash -c "source <snapshot>.sh && eval '<user_command>' && pwd ..."
# Strict prefix match on the user command never hits because cmd starts with
# `/bin/bash -c source ...`. Hook must also match the `eval '<user_command>'`
# substring.
SESSION_ID="test-session-pid-eval"
SF="$OMC_STATE_DIR/state-${SESSION_ID}.tsv"
# Use a unique-string + short sleep so the spawned tree self-terminates
# regardless of whether explicit cleanup reaches the orphaned grandchild.
EVAL_TAG="omc_evalprobe_$$"
printf 'shell\ttoolu_eval\t-\teval probe\tsleep 5 && echo %s\t1735000000\n' "$EVAL_TAG" > "$SF"
( /usr/bin/bash -c "eval 'sleep 5 && echo $EVAL_TAG' < /dev/null" ) &
SPAWNED_PID=$!
sleep 0.3
cat <<EOF | bash "$TRACK_WORKERS" post
{
  "session_id": "$SESSION_ID",
  "hook_event_name": "PostToolUse",
  "tool_name": "Bash",
  "tool_use_id": "toolu_eval",
  "tool_input": {"command": "sleep 5 && echo $EVAL_TAG", "run_in_background": true},
  "tool_response": {"backgroundTaskId": "bash_eval"}
}
EOF
COL7=$(awk -F'\t' '{print $7}' "$SF")
[ -n "$COL7" ] && [ "$COL7" -gt 0 ] 2>/dev/null \
  || { printf '    FAIL: col7 not a positive PID for eval-wrapped command, got=%q\n' "$COL7" >&2; TEST_FAILED=1; }
# Best-effort cleanup; the 5s sleep will self-terminate even if these miss.
kill "$SPAWNED_PID" 2>/dev/null
pkill -f "$EVAL_TAG" 2>/dev/null
wait "$SPAWNED_PID" 2>/dev/null
end_test

start_test "PostToolUse(Bash, bg) sets PID=0 when no process matches fingerprint"
SESSION_ID="test-session-pid-2"
SF="$OMC_STATE_DIR/state-${SESSION_ID}.tsv"
printf 'shell\ttoolu_b2\t-\tno match\toxqz_uniqueprefix_neverseen_1234567890_aaaaaaaaaaaaaaaaaaaaaaaa\t1735000000\n' > "$SF"
cat <<EOF | bash "$TRACK_WORKERS" post
{
  "session_id": "$SESSION_ID",
  "hook_event_name": "PostToolUse",
  "tool_name": "Bash",
  "tool_use_id": "toolu_b2",
  "tool_input": {"command": "oxqz_uniqueprefix_neverseen_1234567890_aaaaaaaaaaaaaaaaaaaaaaaa", "run_in_background": true},
  "tool_response": {"backgroundTaskId": "bash_xyz2"}
}
EOF
COL7=$(awk -F'\t' '{print $7}' "$SF")
assert_eq "0" "$COL7" "expected col7=0 when no fingerprint match"
end_test

# Bug A: Claude Code on Windows fires PreToolUse hooks twice for the same
# tool_use_id (verified live via instrumented hook). The dispatcher must
# absorb duplicates without emitting a second row.
start_test "PreToolUse(Bash bg) fired twice for same tool_use_id appends only one row (dedup)"
SESSION_ID="test-session-dedup-bash"
SF="$OMC_STATE_DIR/state-${SESSION_ID}.tsv"
: > "$SF"
PAYLOAD='{"session_id":"test-session-dedup-bash","hook_event_name":"PreToolUse","tool_name":"Bash","tool_use_id":"toolu_dedup2","tool_input":{"command":"sleep 1","run_in_background":true}}'
printf '%s' "$PAYLOAD" | bash "$TRACK_WORKERS" pre
printf '%s' "$PAYLOAD" | bash "$TRACK_WORKERS" pre
assert_line_count "$SF" 1 "second identical bg-Bash Pre must not append a second row"
end_test

start_test "PreToolUse(Bash bg) different tool_use_id appends both rows (regression guard)"
SESSION_ID="test-session-dedup-distinct"
SF="$OMC_STATE_DIR/state-${SESSION_ID}.tsv"
: > "$SF"
printf '%s' '{"session_id":"test-session-dedup-distinct","hook_event_name":"PreToolUse","tool_name":"Bash","tool_use_id":"toolu_d1","tool_input":{"command":"sleep 1","description":"a","run_in_background":true}}' \
  | bash "$TRACK_WORKERS" pre
printf '%s' '{"session_id":"test-session-dedup-distinct","hook_event_name":"PreToolUse","tool_name":"Bash","tool_use_id":"toolu_d2","tool_input":{"command":"sleep 2","description":"b","run_in_background":true}}' \
  | bash "$TRACK_WORKERS" pre
assert_line_count "$SF" 2 "distinct tool_use_ids must each append"
end_test

# --- 1.2.0: agent tracking removed, one jq pass, early exit when disabled ---
SHIMROOT="$(mktemp -d -t omc-shim-XXXXXX)"
SHIM="$SHIMROOT/bin"
LOG="$SHIMROOT/jq.log"
make_jq_shim "$SHIM" "$LOG"
BG_BASH_PAYLOAD='{"session_id":"t1-sess","hook_event_name":"PreToolUse","tool_name":"Bash","tool_use_id":"toolu_t1","tool_input":{"command":"sleep 5","description":"d","run_in_background":true}}'
FG_BASH_PAYLOAD='{"session_id":"t1-sess","hook_event_name":"PreToolUse","tool_name":"Bash","tool_use_id":"toolu_t1fg","tool_input":{"command":"ls","description":"d"}}'
POST_BASH_PAYLOAD='{"session_id":"t1-sess","hook_event_name":"PostToolUse","tool_name":"Bash","tool_use_id":"toolu_t1","tool_input":{"command":"sleep 5","run_in_background":true},"tool_response":{"backgroundTaskId":"bash_t1"}}'

start_test "hooks.json: no matcher token is exactly Agent or Task"
toks=$(jq -r '.hooks[][]?.matcher // empty' "$REPO_ROOT/hooks/hooks.json" | tr -d '\r' | tr '|' '\n')
assert_eq "" "$(printf '%s\n' "$toks" | grep -xE 'Agent|Task')" "agent matchers removed"
end_test

start_test "pre/post Agent payload leaves state file unchanged"
SF="$OMC_STATE_DIR/state-t1-sess.tsv"
printf 'shell\ttoolu_seed\tbash_seed\tdesc\tsleep 9\t1735000000\t0\n' > "$SF"
cp "$SF" "$OMC_STATE_DIR/seed.copy"
printf '%s' '{"session_id":"t1-sess","tool_name":"Agent","tool_use_id":"toolu_ag","tool_input":{"subagent_type":"Explore","description":"x","run_in_background":true},"tool_response":{"agentId":"a_1","status":"completed"}}' | bash "$TRACK_WORKERS" pre
printf '%s' '{"session_id":"t1-sess","tool_name":"Agent","tool_use_id":"toolu_ag","tool_input":{"subagent_type":"Explore","description":"x","run_in_background":true},"tool_response":{"agentId":"a_1","status":"completed"}}' | bash "$TRACK_WORKERS" post
cmp -s "$SF" "$OMC_STATE_DIR/seed.copy" || { printf '    FAIL: state file changed by Agent payload\n' >&2; TEST_FAILED=1; }
end_test

for FLAG in WORKERS_ENABLED WORKERS_SHOW_SHELLS; do
  start_test "$FLAG=false: pre bg-Bash writes no row, zero jq calls"
  SF="$OMC_STATE_DIR/state-t1-sess.tsv"
  conf="$OMC_STATE_DIR/c.conf"; printf '%s=false\n' "$FLAG" > "$conf"
  : > "$LOG"
  PATH="$SHIM:$PATH" OMC_CONF="$conf" bash "$TRACK_WORKERS" pre <<< "$BG_BASH_PAYLOAD"
  assert_line_count "$SF" 0 "no row written"
  assert_eq 0 "$(shim_count "$LOG")" "zero jq calls"
  end_test

  start_test "$FLAG=false: post leaves placeholder row byte-identical, zero jq calls"
  SF="$OMC_STATE_DIR/state-t1-sess.tsv"
  conf="$OMC_STATE_DIR/c.conf"; printf '%s=false\n' "$FLAG" > "$conf"
  printf 'shell\ttoolu_t1\t-\td\tsleep 5\t1735000000\t-\n' > "$SF"
  cp "$SF" "$OMC_STATE_DIR/seed.copy"
  : > "$LOG"
  PATH="$SHIM:$PATH" OMC_CONF="$conf" bash "$TRACK_WORKERS" post <<< "$POST_BASH_PAYLOAD"
  cmp -s "$SF" "$OMC_STATE_DIR/seed.copy" || { printf '    FAIL: state file changed\n' >&2; TEST_FAILED=1; }
  assert_eq 0 "$(shim_count "$LOG")" "zero jq calls"
  end_test
done

start_test "foreground pre Bash: exactly one jq call, OMC_STATE_DIR not created"
ABSENT="$(dirname "$OMC_STATE_DIR")/omc-absent-$$"
: > "$LOG"
PATH="$SHIM:$PATH" OMC_STATE_DIR="$ABSENT" bash "$TRACK_WORKERS" pre <<< "$FG_BASH_PAYLOAD"
assert_eq 1 "$(shim_count "$LOG")" "exactly one jq call"
[ ! -e "$ABSENT" ] || { printf '    FAIL: state dir was created\n' >&2; TEST_FAILED=1; }
rm -rf "$ABSENT"
end_test

start_test "conf with unset var + stdout echo: hook exits 0, empty stdout, row written"
SF="$OMC_STATE_DIR/state-t1-sess.tsv"
: > "$SF"
conf="$OMC_STATE_DIR/c.conf"; printf 'X=$UNSET_VAR_XYZ; echo noisy\n' > "$conf"
out=$(OMC_CONF="$conf" bash "$TRACK_WORKERS" pre <<< "$BG_BASH_PAYLOAD"); rc=$?
assert_eq 0 "$rc" "exit 0"
assert_eq "" "$out" "empty stdout"
assert_line_count "$SF" 1 "row written with defaults enabled"
end_test

start_test "quoted and export-form disable both short-circuit"
SF="$OMC_STATE_DIR/state-t1-sess.tsv"
conf="$OMC_STATE_DIR/c.conf"
for line in 'WORKERS_ENABLED="false"' 'export WORKERS_ENABLED=false'; do
  printf '%s\n' "$line" > "$conf"
  : > "$SF"; : > "$LOG"
  PATH="$SHIM:$PATH" OMC_CONF="$conf" bash "$TRACK_WORKERS" pre <<< "$BG_BASH_PAYLOAD"
  assert_line_count "$SF" 0 "no row for: $line"
  assert_eq 0 "$(shim_count "$LOG")" "zero jq calls for: $line"
done
end_test

start_test "empty stdin: pre/post/session-start exit 0, no stderr"
for a in pre post session-start; do
  err=$(bash "$TRACK_WORKERS" "$a" </dev/null 2>&1 >/dev/null); rc=$?
  assert_eq "" "$err" "no stderr for $a"
  assert_eq 0 "$rc" "exit 0 for $a"
done
end_test

rm -rf "$SHIMROOT"

print_summary

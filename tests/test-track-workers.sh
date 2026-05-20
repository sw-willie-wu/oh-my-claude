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

start_test "PreToolUse(Task) appends agent row"
SESSION_ID="test-session-002"
SF="$OMC_STATE_DIR/state-${SESSION_ID}.tsv"
: > "$SF"  # ensure empty start
cat <<'EOF' | OMC_STATE_DIR="$OMC_STATE_DIR" bash "$TRACK_WORKERS" pre
{
  "session_id": "test-session-002",
  "hook_event_name": "PreToolUse",
  "tool_name": "Task",
  "tool_use_id": "toolu_a1",
  "tool_input": {
    "subagent_type": "claude-code-guide",
    "description": "research statusline feature",
    "prompt": "..."
  }
}
EOF
assert_line_count "$SF" 1 "expected one agent row"
assert_file_contains "$SF" "agent	toolu_a1	claude-code-guide	research statusline feature"
end_test

start_test "PostToolUse(Task) removes agent row"
SESSION_ID="test-session-003"
SF="$OMC_STATE_DIR/state-${SESSION_ID}.tsv"
printf 'agent\ttoolu_a1\tgeneral-purpose\ttest description\t1735000000\n' > "$SF"
cat <<'EOF' | bash "$TRACK_WORKERS" post
{
  "session_id": "test-session-003",
  "hook_event_name": "PostToolUse",
  "tool_name": "Task",
  "tool_use_id": "toolu_a1",
  "tool_input": {},
  "tool_response": {}
}
EOF
assert_line_count "$SF" 0 "expected row to be removed"
end_test

start_test "PostToolUse(Task, run_in_background:true) keeps agent row (async launch)"
SESSION_ID="test-session-003-async"
SF="$OMC_STATE_DIR/state-${SESSION_ID}.tsv"
printf 'agent\ttoolu_a2\tgeneral-purpose\tasync description\t1735000000\n' > "$SF"
cat <<'EOF' | bash "$TRACK_WORKERS" post
{
  "session_id": "test-session-003-async",
  "hook_event_name": "PostToolUse",
  "tool_name": "Task",
  "tool_use_id": "toolu_a2",
  "tool_input": { "run_in_background": true },
  "tool_response": {}
}
EOF
assert_line_count "$SF" 1 "async Task post must not remove the row (subagent still running in background)"
assert_file_contains "$SF" "agent	toolu_a2	general-purpose	async description"
end_test

# Claude Code renamed the Task tool to Agent at some point after the original
# spec was written (verified live: tool_name="Agent" arrives at the hook even
# though the legacy matcher still says "Task").
start_test "PreToolUse(Agent) appends agent row (current tool_name)"
SESSION_ID="test-session-agent-pre"
SF="$OMC_STATE_DIR/state-${SESSION_ID}.tsv"
: > "$SF"
cat <<'EOF' | bash "$TRACK_WORKERS" pre
{
  "session_id": "test-session-agent-pre",
  "hook_event_name": "PreToolUse",
  "tool_name": "Agent",
  "tool_use_id": "toolu_ag1",
  "tool_input": {
    "subagent_type": "Explore",
    "description": "agent rename probe",
    "prompt": "..."
  }
}
EOF
assert_line_count "$SF" 1 "expected one agent row for tool_name=Agent"
assert_file_contains "$SF" "agent	toolu_ag1	Explore	agent rename probe"
end_test

start_test "PostToolUse(Agent) sync removes agent row"
SESSION_ID="test-session-agent-post-sync"
SF="$OMC_STATE_DIR/state-${SESSION_ID}.tsv"
printf 'agent\ttoolu_ag2\tgeneral-purpose\tsync agent\t1735000000\n' > "$SF"
cat <<'EOF' | bash "$TRACK_WORKERS" post
{
  "session_id": "test-session-agent-post-sync",
  "hook_event_name": "PostToolUse",
  "tool_name": "Agent",
  "tool_use_id": "toolu_ag2",
  "tool_input": {},
  "tool_response": {}
}
EOF
assert_line_count "$SF" 0 "sync Agent post should remove the row"
end_test

start_test "PostToolUse(Agent, run_in_background:true) keeps agent row"
SESSION_ID="test-session-agent-post-async"
SF="$OMC_STATE_DIR/state-${SESSION_ID}.tsv"
printf 'agent\ttoolu_ag3\tExplore\tasync agent\t1735000000\n' > "$SF"
cat <<'EOF' | bash "$TRACK_WORKERS" post
{
  "session_id": "test-session-agent-post-async",
  "hook_event_name": "PostToolUse",
  "tool_name": "Agent",
  "tool_use_id": "toolu_ag3",
  "tool_input": { "run_in_background": true },
  "tool_response": {}
}
EOF
assert_line_count "$SF" 1 "async Agent post must not remove the row"
assert_file_contains "$SF" "agent	toolu_ag3	Explore	async agent"
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

start_test "10 concurrent PreToolUse(Task) writers all land"
SESSION_ID="test-session-concurrent"
SF="$OMC_STATE_DIR/state-${SESSION_ID}.tsv"
: > "$SF"
for i in $(seq 1 10); do
  cat <<EOF | bash "$TRACK_WORKERS" pre &
{
  "session_id": "$SESSION_ID",
  "hook_event_name": "PreToolUse",
  "tool_name": "Task",
  "tool_use_id": "toolu_c${i}",
  "tool_input": { "subagent_type": "general-purpose", "description": "task ${i}" }
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
  "tool_name": "Task",
  "tool_use_id": "toolu_stale",
  "tool_input": { "subagent_type": "Plan", "description": "stale lock victim" }
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
echo "2147480000" > "$OMC_STATE_DIR/state.lock/pid"
cat <<EOF | bash "$TRACK_WORKERS" pre
{
  "session_id": "$SESSION_ID",
  "hook_event_name": "PreToolUse",
  "tool_name": "Task",
  "tool_use_id": "toolu_deadpid",
  "tool_input": { "subagent_type": "Plan", "description": "dead-holder victim" }
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
  "tool_name": "Task",
  "tool_use_id": "toolu_esc",
  "tool_input": {
    "subagent_type": "general-purpose",
    "description": "a\tb\nc\\d"
  }
}
EOF
# After escape, the row stays one line (no embedded raw newlines/tabs in description column).
assert_line_count "$SF" 1 "escape must keep row to single line"
# State file should NOT contain a raw embedded newline inside the description (it'd split the row).
RAW_LINES=$(awk 'END {print NR}' "$SF")
assert_eq "1" "$RAW_LINES" "row must be one TSV line after escaping"
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
start_test "PreToolUse(Agent) fired twice for same tool_use_id appends only one row (dedup)"
SESSION_ID="test-session-dedup-agent"
SF="$OMC_STATE_DIR/state-${SESSION_ID}.tsv"
: > "$SF"
PAYLOAD='{"session_id":"test-session-dedup-agent","hook_event_name":"PreToolUse","tool_name":"Agent","tool_use_id":"toolu_dedup1","tool_input":{"subagent_type":"Explore","description":"d","prompt":"x","run_in_background":true}}'
printf '%s' "$PAYLOAD" | bash "$TRACK_WORKERS" pre
printf '%s' "$PAYLOAD" | bash "$TRACK_WORKERS" pre
assert_line_count "$SF" 1 "second identical Pre must not append a second row"
end_test

start_test "PreToolUse(Bash bg) fired twice for same tool_use_id appends only one row (dedup)"
SESSION_ID="test-session-dedup-bash"
SF="$OMC_STATE_DIR/state-${SESSION_ID}.tsv"
: > "$SF"
PAYLOAD='{"session_id":"test-session-dedup-bash","hook_event_name":"PreToolUse","tool_name":"Bash","tool_use_id":"toolu_dedup2","tool_input":{"command":"sleep 1","run_in_background":true}}'
printf '%s' "$PAYLOAD" | bash "$TRACK_WORKERS" pre
printf '%s' "$PAYLOAD" | bash "$TRACK_WORKERS" pre
assert_line_count "$SF" 1 "second identical bg-Bash Pre must not append a second row"
end_test

start_test "PreToolUse(Agent) different tool_use_id appends both rows (regression guard)"
SESSION_ID="test-session-dedup-distinct"
SF="$OMC_STATE_DIR/state-${SESSION_ID}.tsv"
: > "$SF"
printf '%s' '{"session_id":"test-session-dedup-distinct","hook_event_name":"PreToolUse","tool_name":"Agent","tool_use_id":"toolu_d1","tool_input":{"subagent_type":"Explore","description":"a","prompt":"x","run_in_background":true}}' \
  | bash "$TRACK_WORKERS" pre
printf '%s' '{"session_id":"test-session-dedup-distinct","hook_event_name":"PreToolUse","tool_name":"Agent","tool_use_id":"toolu_d2","tool_input":{"subagent_type":"Explore","description":"b","prompt":"x","run_in_background":true}}' \
  | bash "$TRACK_WORKERS" pre
assert_line_count "$SF" 2 "distinct tool_use_ids must each append"
end_test

# --- Task 2: Pre Task|Agent writes a 6-col row with col6=- placeholder ---
start_test "PreToolUse(Agent) writes 6-col row with col6=- placeholder"
SESSION_ID="test-session-agent-6col"
SF="$OMC_STATE_DIR/state-${SESSION_ID}.tsv"
: > "$SF"
cat <<'EOF' | bash "$TRACK_WORKERS" pre
{
  "session_id": "test-session-agent-6col",
  "hook_event_name": "PreToolUse",
  "tool_name": "Agent",
  "tool_use_id": "toolu_6c1",
  "tool_input": {
    "subagent_type": "Explore",
    "description": "six col probe",
    "prompt": "x",
    "run_in_background": true
  }
}
EOF
COL_COUNT=$(awk -F'\t' '{print NF}' "$SF")
assert_eq "6" "$COL_COUNT" "Pre Agent row must have 6 columns"
COL6=$(awk -F'\t' '{print $6}' "$SF")
assert_eq "-" "$COL6" "col6 must be the '-' placeholder"
assert_file_contains "$SF" "agent	toolu_6c1	Explore	six col probe"
end_test

start_test "PreToolUse(Task) legacy tool_name also writes 6-col row"
SESSION_ID="test-session-task-6col"
SF="$OMC_STATE_DIR/state-${SESSION_ID}.tsv"
: > "$SF"
cat <<'EOF' | bash "$TRACK_WORKERS" pre
{
  "session_id": "test-session-task-6col",
  "hook_event_name": "PreToolUse",
  "tool_name": "Task",
  "tool_use_id": "toolu_6c2",
  "tool_input": { "subagent_type": "general-purpose", "description": "legacy probe", "prompt": "x" }
}
EOF
assert_eq "6" "$(awk -F'\t' '{print NF}' "$SF")" "Pre Task row must have 6 columns"
assert_eq "-" "$(awk -F'\t' '{print $6}' "$SF")" "col6 must be the '-' placeholder"
end_test

# --- Task 3: Post Task|Agent async patches col6 with tool_response.agentId ---
start_test "PostToolUse(Agent, run_in_background:true) patches col6 with agentId"
SESSION_ID="test-session-agent-patch"
SF="$OMC_STATE_DIR/state-${SESSION_ID}.tsv"
printf 'agent\ttoolu_p1\tExplore\tasync probe\t1735000000\t-\n' > "$SF"
cat <<'EOF' | bash "$TRACK_WORKERS" post
{
  "session_id": "test-session-agent-patch",
  "hook_event_name": "PostToolUse",
  "tool_name": "Agent",
  "tool_use_id": "toolu_p1",
  "tool_input": { "run_in_background": true },
  "tool_response": {
    "isAsync": true,
    "status": "async_launched",
    "agentId": "a_PATCH_ME",
    "outputFile": "/dev/null",
    "canReadOutputFile": true
  }
}
EOF
assert_eq "a_PATCH_ME" "$(awk -F'\t' '{print $6}' "$SF")" "col6 must be patched to the agentId"
assert_line_count "$SF" 1 "async post must keep the row"
end_test

start_test "PostToolUse(Agent) sync still removes the 6-col row"
SESSION_ID="test-session-agent-sync6"
SF="$OMC_STATE_DIR/state-${SESSION_ID}.tsv"
printf 'agent\ttoolu_s6\tExplore\tsync probe\t1735000000\t-\n' > "$SF"
cat <<'EOF' | bash "$TRACK_WORKERS" post
{
  "session_id": "test-session-agent-sync6",
  "hook_event_name": "PostToolUse",
  "tool_name": "Agent",
  "tool_use_id": "toolu_s6",
  "tool_input": {},
  "tool_response": { "status": "completed", "agentId": "a_ignored" }
}
EOF
assert_line_count "$SF" 0 "sync Agent post must still remove the row"
end_test

# --- I2: async post with no agentId keeps placeholder + logs (diagnosable) ---
start_test "PostToolUse(Agent async) without agentId leaves col6=- and logs"
SESSION_ID="test-session-agent-noid"
SF="$OMC_STATE_DIR/state-${SESSION_ID}.tsv"
LOG="$OMC_STATE_DIR/track-workers.log"
: > "$LOG"
printf 'agent\ttoolu_ni\tExplore\tno id probe\t1735000000\t-\n' > "$SF"
cat <<'EOF' | OMC_STATE_DIR="$OMC_STATE_DIR" OMC_LOG_FILE="$OMC_STATE_DIR/track-workers.log" bash "$TRACK_WORKERS" post
{
  "session_id": "test-session-agent-noid",
  "hook_event_name": "PostToolUse",
  "tool_name": "Agent",
  "tool_use_id": "toolu_ni",
  "tool_input": { "run_in_background": true },
  "tool_response": { "isAsync": true, "status": "async_launched" }
}
EOF
assert_eq "-" "$(awk -F'\t' '{print $6}' "$SF")" "col6 stays '-' when agentId absent"
assert_line_count "$SF" 1 "row must remain (reaped later by render grace)"
assert_file_contains "$LOG" "no agentId" "missing-agentId case must be logged"
end_test

print_summary

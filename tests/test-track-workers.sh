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

print_summary

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

print_summary

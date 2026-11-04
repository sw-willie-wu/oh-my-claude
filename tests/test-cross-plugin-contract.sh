#!/bin/bash
# Cross-plugin contract: oh-my-status writes ctx-<sid>; oh-my-knowledge
# hooks read ctx-<sid> and own handoff-<sid>. The two
# plugins share only these files, so this test drives the real scripts.
set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"
# shellcheck source=test-helpers.sh
. "$SCRIPT_DIR/test-helpers.sh"

STATUSLINE="$REPO_ROOT/plugins/oh-my-status/statusline.sh"
HOOKS="$REPO_ROOT/plugins/oh-my-knowledge/hooks"

for v in $(compgen -e | grep -E '^(OMK_|CLAUDE_PLUGIN_OPTION_|CLAUDE_CONFIG_DIR$)'); do unset "$v"; done
T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
export HOME="$T/home"; mkdir -p "$HOME"
export OMC_STATE_DIR="$T/state"
export OMC_CONF=/dev/null
export CLAUDE_PLUGIN_OPTION_KNOWLEDGE_DIR="$T/kb"
mkdir -p "$T/kb"; : > "$T/kb/SCHEMA.md"   # a set-up knowledge base (hooks are silent before setup)

SID='sess/contract 1'   # special chars: exercises the shared sanitisation
SAN='sess_contract_1'
strip() { sed -E 's/\x1b\[[0-9;]*[a-zA-Z]//g'; }
render() {
  jq -n --arg s "$SID" '{session_id:$s,model:{display_name:"X"},workspace:{current_dir:"/tmp"},context_window:{used_percentage:75,context_window_size:200000}}' \
    | COLUMNS=120 bash "$STATUSLINE" 2>/dev/null | strip
}
stop() {
  jq -n --arg s "$SID" '{session_id:$s,hook_event_name:"Stop",stop_hook_active:false}' \
    | CLAUDE_PLUGIN_OPTION_AUTO_HANDOFF_THRESHOLD=70 bash "$HOOKS/auto-handoff.sh" 2>/dev/null
}
compact() {
  jq -n --arg s "$SID" '{session_id:$s,hook_event_name:"SessionStart",source:"compact"}' \
    | bash "$HOOKS/session-start.sh" >/dev/null 2>&1
}
has_badge() { printf '%s' "$1" | grep -qE '✓ handoff|handoff ok'; }

start_test "render -> Stop block -> no badge -> compact clears -> Stop blocks again"
OUT="$(render)"
assert_eq "75 200000" "$(cat "$OMC_STATE_DIR/ctx-$SAN" 2>/dev/null)" "render wrote ctx file"
has_badge "$OUT" && { printf '    FAIL: badge before handoff\n' >&2; TEST_FAILED=1; }
R1="$(stop)"
case "$R1" in *'"decision":"block"'*'Context is at 75%'*) ;; *) printf '    FAIL: first Stop did not block: %q\n' "$R1" >&2; TEST_FAILED=1;; esac
[ -f "$OMC_STATE_DIR/handoff-$SAN" ] || { printf '    FAIL: marker missing\n' >&2; TEST_FAILED=1; }
has_badge "$(render)" && { printf '    FAIL: badge shown after handoff\n' >&2; TEST_FAILED=1; }
assert_eq "75 200000" "$(cat "$OMC_STATE_DIR/ctx-$SAN" 2>/dev/null)" "render still writes ctx with marker present"
assert_eq "" "$(stop)" "second Stop must be silent while marker exists"
compact
[ -f "$OMC_STATE_DIR/handoff-$SAN" ] && { printf '    FAIL: compact left marker\n' >&2; TEST_FAILED=1; }
[ -f "$OMC_STATE_DIR/ctx-$SAN" ] && { printf '    FAIL: stale ctx file survived compact\n' >&2; TEST_FAILED=1; }
assert_eq "" "$(stop)" "Stop must be silent between compact and the next render (no stale percentage)"
has_badge "$(render)" && { printf '    FAIL: badge after compact\n' >&2; TEST_FAILED=1; }
R2="$(stop)"
case "$R2" in *'"decision":"block"'*) ;; *) printf '    FAIL: Stop did not fire again after compact: %q\n' "$R2" >&2; TEST_FAILED=1;; esac
end_test

print_summary

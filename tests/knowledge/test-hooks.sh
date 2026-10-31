#!/bin/bash
# Tests for oh-my-knowledge hooks and the statusline usage file.
set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(dirname "$(dirname "$SCRIPT_DIR")")"
# shellcheck source=../test-helpers.sh
. "$REPO_ROOT/tests/test-helpers.sh"

HOOKS="$REPO_ROOT/plugins/oh-my-knowledge/hooks"
STATUSLINE="$REPO_ROOT/plugins/oh-my-status/statusline.sh"

for v in $(compgen -e | grep -E '^(OMK_|CLAUDE_PLUGIN_OPTION_|CLAUDE_CONFIG_DIR$)'); do unset "$v"; done
T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
export HOME="$T/home"; mkdir -p "$HOME"
export OMC_STATE_DIR="$T/state"
export OMC_CONF=/dev/null

contains() { # <file> <needle> <msg>
  if ! grep -qF -- "$2" "$1" 2>/dev/null; then
    printf '    FAIL: %s\n      missing: %q\n      in: %q\n' "$3" "$2" "$(cat "$1" 2>/dev/null)" >&2; TEST_FAILED=1
  fi
}
lacks() {
  if grep -qF -- "$2" "$1" 2>/dev/null; then
    printf '    FAIL: %s\n      unexpected: %q\n' "$3" "$2" >&2; TEST_FAILED=1
  fi
}
empty() { # <file> <msg>
  if [ -s "$1" ]; then printf '    FAIL: %s (expected silence)\n      got: %q\n' "$2" "$(cat "$1")" >&2; TEST_FAILED=1; fi
}

# prompt_hook <prompt> [env assignments...] -> $T/out
prompt_hook() {
  local p="$1"; shift
  MSYS2_ARG_CONV_EXCL='*' jq -n --arg p "$p" '{session_id:"s1",hook_event_name:"UserPromptSubmit",prompt:$p}' \
    | env "$@" bash "$HOOKS/lookup-reminder.sh" >"$T/out" 2>"$T/err"
}

start_test "hooks.json valid, runs scripts via bash \${CLAUDE_PLUGIN_ROOT}"
H="$HOOKS/hooks.json"
if jq -e '.hooks.UserPromptSubmit and .hooks.Stop and .hooks.SessionStart' "$H" >/dev/null 2>&1; then :; else
  printf '    FAIL: hooks.json missing/invalid\n' >&2; TEST_FAILED=1; fi
contains "$H" 'bash \"${CLAUDE_PLUGIN_ROOT}/hooks/lookup-reminder.sh\"' "reminder command"
contains "$H" 'bash \"${CLAUDE_PLUGIN_ROOT}/hooks/auto-handoff.sh\"' "handoff command"
contains "$H" 'bash \"${CLAUDE_PLUGIN_ROOT}/hooks/session-start.sh\"' "session-start command"
end_test

start_test "lookup-reminder fires on zh and en triggers"
prompt_hook '為什麼 docker 很慢'
contains "$T/out" 'oh-my-knowledge:lookup' "zh trigger"
contains "$T/out" '"hookEventName":"UserPromptSubmit"' "event name"
jq -e '.hookSpecificOutput.additionalContext' "$T/out" >/dev/null 2>&1 || { printf '    FAIL: not valid JSON\n' >&2; TEST_FAILED=1; }
prompt_hook 'why does it fail'
contains "$T/out" 'oh-my-knowledge:lookup' "en trigger"
prompt_hook 'The build TIMED OUT again'
contains "$T/out" 'oh-my-knowledge:lookup' "en trigger uppercase"
end_test

start_test "lookup-reminder silent cases"
prompt_hook '/handoff why is it slow'; empty "$T/out" "slash command"
prompt_hook '   /handoff 為什麼'; empty "$T/out" "slash command after spaces"
prompt_hook 'OK'; empty "$T/out" "OK"
prompt_hook 'please change the color'; empty "$T/out" "no trigger"
prompt_hook 'somewhat showy'; empty "$T/out" "word boundary"
prompt_hook '為什麼 docker 很慢' CLAUDE_PLUGIN_OPTION_LOOKUP_REMINDER=false; empty "$T/out" "option off"
prompt_hook 'why does it fail' OMK_JQ=/nonexistent; empty "$T/out" "jq missing"
printf 'garbage' | bash "$HOOKS/lookup-reminder.sh" >"$T/out" 2>/dev/null; assert_eq 0 $? "garbage stdin exit"; empty "$T/out" "garbage stdin"
end_test

# --- auto-handoff ---------------------------------------------------------
stop_hook() { # <json> [env...] -> $T/out, RC
  local j="$1"; shift
  printf '%s' "$j" | env "$@" bash "$HOOKS/auto-handoff.sh" >"$T/out" 2>"$T/err"; RC=$?
}
mkdir -p "$OMC_STATE_DIR"
reset_state() { rm -f "$OMC_STATE_DIR"/ctx-* "$OMC_STATE_DIR"/handoff-*; }
STOP='{"session_id":"sess-A","hook_event_name":"Stop","stop_hook_active":false}'

start_test "auto-handoff fires at default threshold 70, writes marker first"
reset_state
printf '70 200000\n' > "$OMC_STATE_DIR/ctx-sess-A"
stop_hook "$STOP"
assert_eq 0 "$RC" "exit"
contains "$T/out" '"decision":"block"' "decision"
contains "$T/out" 'Context is at 70%' "pct in reason"
contains "$T/out" 'oh-my-knowledge:handoff' "skill in reason"
[ -f "$OMC_STATE_DIR/handoff-sess-A" ] || { printf '    FAIL: marker not written\n' >&2; TEST_FAILED=1; }
stop_hook "$STOP"; empty "$T/out" "second Stop with marker"
end_test

start_test "auto-handoff silent cases"
reset_state
printf '69 200000\n' > "$OMC_STATE_DIR/ctx-sess-A"
stop_hook "$STOP"; empty "$T/out" "below threshold"
[ -f "$OMC_STATE_DIR/handoff-sess-A" ] && { printf '    FAIL: marker written below threshold\n' >&2; TEST_FAILED=1; }
printf '90 200000\n' > "$OMC_STATE_DIR/ctx-sess-A"
stop_hook '{"session_id":"sess-A","stop_hook_active":true}'; empty "$T/out" "stop_hook_active"
stop_hook '{"session_id":"sess-B"}'; empty "$T/out" "missing ctx"
printf 'garbage\n' > "$OMC_STATE_DIR/ctx-sess-B"
stop_hook '{"session_id":"sess-B"}'; empty "$T/out" "garbage ctx"
stop_hook "$STOP" CLAUDE_PLUGIN_OPTION_AUTO_HANDOFF=false; empty "$T/out" "option off"
stop_hook "$STOP" OMK_JQ=/nonexistent; empty "$T/out" "jq missing"; assert_eq 0 "$RC" "jq missing exit"
stop_hook '{"hook_event_name":"Stop"}'; empty "$T/out" "no session id"
printf ' 200000\n' > "$OMC_STATE_DIR/ctx-sess-C"
stop_hook '{"session_id":"sess-C"}'; empty "$T/out" "empty pct field"
printf '\n' > "$OMC_STATE_DIR/ctx-sess-C"
stop_hook '{"session_id":"sess-C"}'; empty "$T/out" "blank ctx line"
touch "$OMC_STATE_DIR/handoff-sess-A"
stop_hook "$STOP"; empty "$T/out" "existing marker"
end_test

start_test "auto-handoff honours threshold option and sanitises sid"
reset_state
printf '50 200000\n' > "$OMC_STATE_DIR/ctx-a_b_c"
stop_hook '{"session_id":"a/b c"}' CLAUDE_PLUGIN_OPTION_AUTO_HANDOFF_THRESHOLD=50
contains "$T/out" '"decision":"block"' "fires at 50"
[ -f "$OMC_STATE_DIR/handoff-a_b_c" ] || { printf '    FAIL: sanitised marker missing\n' >&2; TEST_FAILED=1; }
end_test

# --- session-start --------------------------------------------------------
start_hook() { # <source> [env...] -> $T/out
  local s="$1"; shift
  printf '{"session_id":"sess-A","hook_event_name":"SessionStart","source":"%s"}' "$s" \
    | env "$@" bash "$HOOKS/session-start.sh" >"$T/out" 2>"$T/err"; RC=$?
}
KB="$T/kbdir"; mkdir -p "$KB" "$HOME/knowledge"
# native form of an existing dir: C:/… on Windows (pwd -W), plain physical path elsewhere
native() { ( cd -P -- "$1" && { pwd -W 2>/dev/null || pwd -P; } ); }

start_test "session-start: default dir, startup prints only the KB line"
start_hook startup
assert_eq 0 "$RC" "exit"
jq -e '.hookSpecificOutput.hookEventName=="SessionStart"' "$T/out" >/dev/null 2>&1 || { printf '    FAIL: bad JSON: %q\n' "$(cat "$T/out")" >&2; TEST_FAILED=1; }
DEF="$(jq -r '.hookSpecificOutput.additionalContext' "$T/out" 2>/dev/null)"
case "$DEF" in "Knowledge base: "*"/knowledge. [[g:slug]]"*) ;; *) printf '    FAIL: default line: %q\n' "$DEF" >&2; TEST_FAILED=1;; esac
case "$DEF" in *"$(native "$HOME/knowledge")."*) ;; *) printf '    FAIL: ~/knowledge not resolved to native form: %q\n' "$DEF" >&2; TEST_FAILED=1;; esac
contains "$T/out" '[[g:slug]]' "link defs"
lacks "$T/out" 'MEMORY.md' "no reread on startup"
start_hook startup CLAUDE_PLUGIN_OPTION_KNOWLEDGE_DIR="$KB"
contains "$T/out" "Knowledge base: $(native "$KB")." "configured dir on startup"
lacks "$T/out" 'MEMORY.md' "no reread on startup (configured)"
start_hook resume CLAUDE_PLUGIN_OPTION_KNOWLEDGE_DIR="$KB"
contains "$T/out" "Knowledge base: $(native "$KB")." "configured dir on resume"
lacks "$T/out" 'MEMORY.md' "no reread on resume"
end_test

start_test "session-start: compact deletes marker + reread; clear keeps marker"
touch "$OMC_STATE_DIR/handoff-sess-A"
printf '80 200000\n' > "$OMC_STATE_DIR/ctx-sess-A"
start_hook clear CLAUDE_PLUGIN_OPTION_KNOWLEDGE_DIR="$KB"
[ -f "$OMC_STATE_DIR/ctx-sess-A" ] || { printf '    FAIL: clear removed ctx file\n' >&2; TEST_FAILED=1; }
contains "$T/out" 'MEMORY.md' "clear reread"
contains "$T/out" '[[k:path]]' "clear link defs"
[ -f "$OMC_STATE_DIR/handoff-sess-A" ] || { printf '    FAIL: clear removed marker\n' >&2; TEST_FAILED=1; }
start_hook compact CLAUDE_PLUGIN_OPTION_KNOWLEDGE_DIR="$KB"
contains "$T/out" 'MEMORY.md' "compact reread"
contains "$T/out" '[[k:path]]' "compact link defs"
[ -f "$OMC_STATE_DIR/handoff-sess-A" ] && { printf '    FAIL: compact kept marker\n' >&2; TEST_FAILED=1; }
[ -f "$OMC_STATE_DIR/ctx-sess-A" ] && { printf '    FAIL: compact kept stale ctx file\n' >&2; TEST_FAILED=1; }
start_hook startup OMK_JQ=/nonexistent; empty "$T/out" "jq missing"
end_test

# --- statusline usage file ------------------------------------------------
render() { # <sid>  -> stdout
  jq -n --arg s "$1" '{session_id:$s,model:{display_name:"X"},workspace:{current_dir:"/tmp"},context_window:{used_percentage:42,context_window_size:200000}}' \
    | COLUMNS=120 bash "$STATUSLINE" 2>/dev/null
}
strip() { sed -E 's/\x1b\[[0-9;]*[a-zA-Z]//g'; }

start_test "statusline writes ctx-<sid>; special chars map like SANITIZED_SID"
reset_state
render sess-R >/dev/null
assert_eq "42 200000" "$(cat "$OMC_STATE_DIR/ctx-sess-R" 2>/dev/null)" "ctx content"
render 'a/b c.d' >/dev/null
assert_eq "42 200000" "$(cat "$OMC_STATE_DIR/ctx-a_b_c_d" 2>/dev/null)" "sanitised ctx file"
end_test

start_test "statusline shows no handoff badge, even with a marker"
reset_state
touch "$OMC_STATE_DIR/handoff-sess-R"
render sess-R | strip | grep -qF 'handoff' && { printf '    FAIL: badge with marker\n' >&2; TEST_FAILED=1; }
assert_eq "42 200000" "$(cat "$OMC_STATE_DIR/ctx-sess-R" 2>/dev/null)" "ctx still written with marker present"
end_test

start_test "pure layout shows no handoff badge with a marker"
printf 'LAYOUT=pure\n' > "$T/pure.conf"
touch "$OMC_STATE_DIR/handoff-sess-R"
OUT="$(jq -n '{session_id:"sess-R",model:{display_name:"X"},workspace:{current_dir:"/tmp"}}' | OMC_CONF="$T/pure.conf" COLUMNS=120 bash "$STATUSLINE" 2>/dev/null | strip)"
case "$OUT" in *'handoff ok'*|*'✓ handoff'*) printf '    FAIL: pure badge present: %q\n' "$OUT" >&2; TEST_FAILED=1;; esac
case "$OUT" in *'ctx:'*) ;; *) printf '    FAIL: pure render empty: %q\n' "$OUT" >&2; TEST_FAILED=1;; esac
end_test

print_summary

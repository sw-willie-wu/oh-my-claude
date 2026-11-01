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
export HOME="$T/home"; mkdir -p "$HOME/knowledge"; : > "$HOME/knowledge/SCHEMA.md"
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

start_test "lookup-reminder skips harness relays (starts-with only)"
prompt_hook 'Another Claude session sent a message: why is it slow'; empty "$T/out" "peer-session relay"
prompt_hook '<agent-message from="x">why did it fail</agent-message>'; empty "$T/out" "agent-message relay"
prompt_hook '<task-notification>task failed with error</task-notification>'; empty "$T/out" "task-notification relay"
prompt_hook '[SYSTEM NOTIFICATION] build failed'; empty "$T/out" "system notification relay"
prompt_hook '   <agent-message from="x">why did it fail</agent-message>'; empty "$T/out" "relay after leading spaces"
prompt_hook "$(printf '\n\t<task-notification>why error</task-notification>')"; empty "$T/out" "relay after leading newline/tab"
prompt_hook 'what does <agent-message > mean, why does it fail'; contains "$T/out" 'oh-my-knowledge:lookup' "quoted mid-text still reminded"
prompt_hook 'Why did the Another Claude session sent a message thing fail'; contains "$T/out" 'oh-my-knowledge:lookup' "relay phrase mid-text still reminded"
prompt_hook 'why does the build fail'; contains "$T/out" 'oh-my-knowledge:lookup' "normal question still reminded"
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
printf '90\n' > "$OMC_STATE_DIR/handoff-sess-A"
printf '90 200000\n' > "$OMC_STATE_DIR/ctx-sess-A"
stop_hook "$STOP"; empty "$T/out" "existing marker at 90%"
end_test

# fire_case <label> <marker content|-> <ctx pct> <expect fire|silent> [env...]
# marker '-' = no marker file. On fire, the marker must then hold the ctx pct.
fire_case() {
  local label="$1" mk="$2" pct="$3" want="$4"; shift 4
  reset_state
  printf '%s 200000\n' "$pct" > "$OMC_STATE_DIR/ctx-sess-A"
  [ "$mk" = - ] || printf '%b' "$mk" > "$OMC_STATE_DIR/handoff-sess-A"
  stop_hook "$STOP" "$@"
  assert_eq 0 "$RC" "$label exit"
  if [ "$want" = fire ]; then
    contains "$T/out" '"decision":"block"' "$label fires"
    assert_eq "$pct" "$(head -n1 "$OMC_STATE_DIR/handoff-sess-A" 2>/dev/null)" "$label marker records pct"
  else
    empty "$T/out" "$label silent"
  fi
}

start_test "auto-handoff firing rule (thr 70, repeat 20)"
fire_case "no marker" - 70 fire
assert_eq "70" "$(cat "$OMC_STATE_DIR/handoff-sess-A")" "marker content is the pct"
fire_case "r<thr gap 4" '66\n' 70 silent
fire_case "r<thr gap 5" '65\n' 70 fire
fire_case "r<thr small r" '10\n' 70 fire
fire_case "r>=thr gap repeat-1" '70\n' 89 silent
fire_case "r>=thr gap repeat" '70\n' 90 fire
fire_case "r+repeat>100" '85\n' 100 silent
fire_case "r+repeat=100 (r=80)" '80\n' 100 fire
fire_case "below threshold, no marker" - 69 silent
end_test

start_test "auto-handoff marker validity"
fire_case "empty marker = 0" '' 70 fire
fire_case "abc marker = 0" 'abc\n' 70 fire
fire_case "150 marker = 0" '150\n' 70 fire
fire_case "20-digit marker = 0" '00000000000000000090\n' 70 fire
fire_case "CRLF marker 72 -> 72 (gap 18 silent)" '72\r\n' 90 silent
fire_case "CRLF marker 72 -> 72 (gap 20 fires)" '72\r\n' 92 fire
fire_case "first line only" '72\n10\n' 90 silent
reset_state
printf '100 200000\r\n' > "$OMC_STATE_DIR/ctx-sess-A"
stop_hook "$STOP"; contains "$T/out" 'Context is at 100%' "CRLF ctx"
reset_state
printf '75\r\n' > "$OMC_STATE_DIR/ctx-sess-A"
stop_hook "$STOP"; contains "$T/out" 'Context is at 75%' "CRLF ctx without size"
assert_eq "75" "$(cat "$OMC_STATE_DIR/handoff-sess-A" 2>/dev/null)" "CRLF ctx records 75"
reset_state
printf '0075 200000\n' > "$OMC_STATE_DIR/ctx-sess-A"
stop_hook "$STOP"; empty "$T/out" "4-digit ctx 0075 invalid"
reset_state
printf '150 200000\n' > "$OMC_STATE_DIR/ctx-sess-A"
stop_hook "$STOP"; empty "$T/out" "invalid ctx 150"
end_test

start_test "auto-handoff repeat option is clamped 10-60"
fire_case "repeat=5 acts as 10 (gap 9)" '70\n' 79 silent CLAUDE_PLUGIN_OPTION_AUTO_HANDOFF_REPEAT=5
fire_case "repeat=5 acts as 10 (gap 10)" '70\n' 80 fire CLAUDE_PLUGIN_OPTION_AUTO_HANDOFF_REPEAT=5
fire_case "repeat=99 acts as 60 (gap 59)" '30\n' 89 silent CLAUDE_PLUGIN_OPTION_AUTO_HANDOFF_REPEAT=99 CLAUDE_PLUGIN_OPTION_AUTO_HANDOFF_THRESHOLD=30
fire_case "repeat=99 acts as 60 (gap 60)" '30\n' 90 fire CLAUDE_PLUGIN_OPTION_AUTO_HANDOFF_REPEAT=99 CLAUDE_PLUGIN_OPTION_AUTO_HANDOFF_THRESHOLD=30
fire_case "env repeat=30 (gap 29)" '70\n' 99 silent OMK_AUTO_HANDOFF_REPEAT=30
fire_case "env repeat=30 (gap 30)" '70\n' 100 fire OMK_AUTO_HANDOFF_REPEAT=30
end_test

start_test "auto-handoff unwritable marker and stop_hook_active stay silent"
reset_state
printf '80 200000\n' > "$OMC_STATE_DIR/ctx-sess-A"
mkdir "$OMC_STATE_DIR/handoff-sess-A"
stop_hook "$STOP"; assert_eq 0 "$RC" "unwritable exit"; empty "$T/out" "unwritable marker (directory)"
rmdir "$OMC_STATE_DIR/handoff-sess-A"
stop_hook '{"session_id":"sess-A","stop_hook_active":true}'; empty "$T/out" "stop_hook_active true"
[ -e "$OMC_STATE_DIR/handoff-sess-A" ] && { printf '    FAIL: marker written while stop_hook_active\n' >&2; TEST_FAILED=1; }
stop_hook '{"session_id":"sess-A"}'; contains "$T/out" '"decision":"block"' "stop_hook_active absent fires"
end_test

start_test "auto-handoff: payload without session_id is silent; fields parsed with tab split"
reset_state
printf '80 200000\n' > "$OMC_STATE_DIR/ctx-sess-A"
stop_hook '{"stop_hook_active":false}'; empty "$T/out" "no session_id (active false)"
stop_hook '{"stop_hook_active":true}'; empty "$T/out" "no session_id (active true)"
stop_hook '{"session_id":"sess-A","stop_hook_active":null}'; contains "$T/out" '"decision":"block"' "null stop_hook_active"
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
KB="$T/kbdir"; mkdir -p "$KB" "$HOME/knowledge"; : > "$KB/SCHEMA.md"
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

start_test "session-start: compact and clear delete marker + ctx and ask for reread"
printf '70\n' > "$OMC_STATE_DIR/handoff-sess-A"
printf '80 200000\n' > "$OMC_STATE_DIR/ctx-sess-A"
start_hook clear CLAUDE_PLUGIN_OPTION_KNOWLEDGE_DIR="$KB"
[ -f "$OMC_STATE_DIR/ctx-sess-A" ] && { printf '    FAIL: clear kept ctx file\n' >&2; TEST_FAILED=1; }
contains "$T/out" 'MEMORY.md' "clear reread"
contains "$T/out" '[[k:path]]' "clear link defs"
[ -f "$OMC_STATE_DIR/handoff-sess-A" ] && { printf '    FAIL: clear kept marker\n' >&2; TEST_FAILED=1; }
printf '70\n' > "$OMC_STATE_DIR/handoff-sess-A"
printf '80 200000\n' > "$OMC_STATE_DIR/ctx-sess-A"
start_hook resume CLAUDE_PLUGIN_OPTION_KNOWLEDGE_DIR="$KB"
[ -f "$OMC_STATE_DIR/handoff-sess-A" ] && [ -f "$OMC_STATE_DIR/ctx-sess-A" ] || { printf '    FAIL: resume cleared marker/ctx\n' >&2; TEST_FAILED=1; }
printf '{"hook_event_name":"SessionStart","source":"compact"}' | bash "$HOOKS/session-start.sh" >"$T/out" 2>/dev/null
contains "$T/out" 'MEMORY.md' "compact without session_id still asks reread"
[ -f "$OMC_STATE_DIR/handoff-sess-A" ] || { printf '    FAIL: compact without sid removed another marker\n' >&2; TEST_FAILED=1; }
printf '{"session_id":"sess-A","hook_event_name":"SessionStart"}' | bash "$HOOKS/session-start.sh" >"$T/out" 2>/dev/null
contains "$T/out" 'Knowledge base:' "payload without source"
lacks "$T/out" 'MEMORY.md' "no reread without source"
[ -f "$OMC_STATE_DIR/handoff-sess-A" ] || { printf '    FAIL: no-source payload cleared marker\n' >&2; TEST_FAILED=1; }
start_hook compact CLAUDE_PLUGIN_OPTION_KNOWLEDGE_DIR="$KB"
contains "$T/out" 'MEMORY.md' "compact reread"
contains "$T/out" '[[k:path]]' "compact link defs"
[ -f "$OMC_STATE_DIR/handoff-sess-A" ] && { printf '    FAIL: compact kept marker\n' >&2; TEST_FAILED=1; }
[ -f "$OMC_STATE_DIR/ctx-sess-A" ] && { printf '    FAIL: compact kept stale ctx file\n' >&2; TEST_FAILED=1; }
start_hook startup OMK_JQ=/nonexistent; empty "$T/out" "jq missing"
end_test

start_test "configuration error (relative knowledge_dir): SessionStart prints it; compact/clear still clear + reread; other hooks silent"
ERRMSG='knowledge_dir must be an absolute path or start with ~/ (got: kb); run /oh-my-knowledge:setup'
for src in startup compact clear; do
  printf '70\n' > "$OMC_STATE_DIR/handoff-sess-A"; printf '80 200000\n' > "$OMC_STATE_DIR/ctx-sess-A"
  start_hook "$src" OMK_KNOWLEDGE_DIR=kb
  assert_eq 0 "$RC" "exit ($src)"
  got="$(jq -r '.hookSpecificOutput.additionalContext' "$T/out" 2>/dev/null)"
  case "$got" in *"$ERRMSG"*) ;; *) printf '    FAIL: %s: message missing: %q\n' "$src" "$got" >&2; TEST_FAILED=1 ;; esac
  case "$got" in "Knowledge base: "*) printf '    FAIL: %s: normal note not replaced: %q\n' "$src" "$got" >&2; TEST_FAILED=1 ;; esac
  case "$src" in
    startup)
      lacks "$T/out" 'MEMORY.md' "no reread on startup"
      [ -f "$OMC_STATE_DIR/handoff-sess-A" ] && [ -f "$OMC_STATE_DIR/ctx-sess-A" ] || { printf '    FAIL: startup cleared state\n' >&2; TEST_FAILED=1; } ;;
    *)
      contains "$T/out" 'MEMORY.md' "$src reread sentence"
      [ -f "$OMC_STATE_DIR/handoff-sess-A" ] && { printf '    FAIL: %s kept marker\n' "$src" >&2; TEST_FAILED=1; }
      [ -f "$OMC_STATE_DIR/ctx-sess-A" ] && { printf '    FAIL: %s kept ctx\n' "$src" >&2; TEST_FAILED=1; } ;;
  esac
done
# lookup reminder: silent with the error, fires with a valid dir (same prompt)
prompt_hook '為什麼 docker 很慢' OMK_KNOWLEDGE_DIR=kb; empty "$T/out" "reminder silent on config error"
prompt_hook '為什麼 docker 很慢' OMK_KNOWLEDGE_DIR="$KB"; contains "$T/out" 'oh-my-knowledge:lookup' "reminder fires with a valid dir"
# auto-handoff: silent with the error (no marker written), blocks with a valid dir
reset_state; printf '90 200000\n' > "$OMC_STATE_DIR/ctx-sess-A"
stop_hook "$STOP" OMK_KNOWLEDGE_DIR=kb; empty "$T/out" "auto-handoff silent on config error"
[ -f "$OMC_STATE_DIR/handoff-sess-A" ] && { printf '    FAIL: marker written despite config error\n' >&2; TEST_FAILED=1; }
stop_hook "$STOP" OMK_KNOWLEDGE_DIR="$KB"; contains "$T/out" '"decision":"block"' "auto-handoff blocks with a valid dir"
reset_state
end_test

start_test "not set up (no SCHEMA.md): SessionStart prints the note; reminder and auto-handoff silent; each paired with a set-up KB"
NOKB="$T/nokb"; mkdir -p "$NOKB"
NOMSG="oh-my-knowledge: knowledge base not set up yet ($(native "$NOKB")) — run /oh-my-knowledge:setup"
for src in startup compact clear; do
  printf '70\n' > "$OMC_STATE_DIR/handoff-sess-A"; printf '80 200000\n' > "$OMC_STATE_DIR/ctx-sess-A"
  start_hook "$src" OMK_KNOWLEDGE_DIR="$NOKB"
  assert_eq 0 "$RC" "not set up exit ($src)"
  got="$(jq -r '.hookSpecificOutput.additionalContext' "$T/out" 2>/dev/null)"
  case "$got" in *"$NOMSG"*) ;; *) printf '    FAIL: %s: not-set-up note missing: %q\n' "$src" "$got" >&2; TEST_FAILED=1 ;; esac
  case "$got" in *"[[g:slug]]"*) printf '    FAIL: %s: link definitions not replaced: %q\n' "$src" "$got" >&2; TEST_FAILED=1 ;; esac
  case "$src" in
    startup)
      lacks "$T/out" 'MEMORY.md' "not set up: no reread on startup"
      [ -f "$OMC_STATE_DIR/handoff-sess-A" ] && [ -f "$OMC_STATE_DIR/ctx-sess-A" ] || { printf '    FAIL: not set up: startup cleared state\n' >&2; TEST_FAILED=1; } ;;
    *)
      contains "$T/out" 'MEMORY.md' "not set up: $src reread sentence"
      [ -f "$OMC_STATE_DIR/handoff-sess-A" ] && { printf '    FAIL: not set up: %s kept marker\n' "$src" >&2; TEST_FAILED=1; }
      [ -f "$OMC_STATE_DIR/ctx-sess-A" ] && { printf '    FAIL: not set up: %s kept ctx\n' "$src" >&2; TEST_FAILED=1; } ;;
  esac
done
start_hook startup OMK_KNOWLEDGE_DIR="$KB"; contains "$T/out" 'Knowledge base:' "paired: set-up KB prints the normal note"
lacks "$T/out" 'not set up yet' "paired: set-up KB has no not-set-up note"
# a directory named SCHEMA.md is not a set-up KB
mkdir -p "$T/dirschema/SCHEMA.md"
start_hook startup OMK_KNOWLEDGE_DIR="$T/dirschema"; contains "$T/out" 'not set up yet' "SCHEMA.md as a directory is not set up"
prompt_hook '為什麼 docker 很慢' OMK_KNOWLEDGE_DIR="$NOKB"; empty "$T/out" "reminder silent before setup"
prompt_hook '為什麼 docker 很慢' OMK_KNOWLEDGE_DIR="$KB"; contains "$T/out" 'oh-my-knowledge:lookup' "paired: reminder fires with SCHEMA.md"
reset_state; printf '90 200000\n' > "$OMC_STATE_DIR/ctx-sess-A"
stop_hook "$STOP" OMK_KNOWLEDGE_DIR="$NOKB"; empty "$T/out" "auto-handoff silent before setup"
[ -f "$OMC_STATE_DIR/handoff-sess-A" ] && { printf '    FAIL: marker written before setup\n' >&2; TEST_FAILED=1; }
reset_state; printf '90 200000\n' > "$OMC_STATE_DIR/ctx-sess-A"
stop_hook "$STOP" OMK_KNOWLEDGE_DIR="$KB"; contains "$T/out" '"decision":"block"' "paired: auto-handoff blocks with SCHEMA.md"
reset_state
# configuration error wins over not set up (relative dir has no SCHEMA.md either)
start_hook startup OMK_KNOWLEDGE_DIR=kb
contains "$T/out" 'knowledge_dir must be an absolute path' "config error shown"
lacks "$T/out" 'not set up yet' "config error wins over not set up"
end_test

# --- session-start: project always-on injection (spec G2) -----------------
AO_CC="$T/aocc"; AO_KB="$T/kbao"; AO_W="$T/aowork/proj"
mkdir -p "$AO_CC/projects" "$AO_KB/projects/demo" "$AO_W"; : > "$AO_KB/SCHEMA.md"
git -C "$AO_W" init -q . >/dev/null 2>&1
AO_ENC="$(bash -c '. "$1"; omk_encode_path "$2"' _ "$HOOKS/../scripts/lib/common.sh" "$AO_W" | tr -d '\r')"
AO_MEM="$AO_CC/projects/$AO_ENC/memory"; mkdir -p "$AO_MEM"
AO_PAGE="$AO_KB/projects/demo/always-on.md"
ao_marker() { printf -- '- Knowledge base project: [[k:projects/%s/index]] (omk-project)\n' "$1"; }
ao_marker demo > "$AO_MEM/MEMORY.md"
# ao_hook <source> <cwd|-> [env...] -> $T/out ; cwd "-" omits the field
ao_hook() {
  local s="$1" c="$2"; shift 2
  if [ "$c" = "-" ]; then
    printf '{"session_id":"sess-A","hook_event_name":"SessionStart","source":"%s"}' "$s"
  else
    MSYS2_ARG_CONV_EXCL='*' jq -nc --arg s "$s" --arg c "$c" '{session_id:"sess-A",hook_event_name:"SessionStart",source:$s,cwd:$c}'
  fi | env CLAUDE_CONFIG_DIR="$AO_CC" OMK_KNOWLEDGE_DIR="$AO_KB" "$@" bash "$HOOKS/session-start.sh" >"$T/out" 2>"$T/err"; RC=$?
}
# Windows jq writes CRLF in text mode; the hook output itself is checked for a real CR separately.
ao_msg() { jq -r '.hookSpecificOutput.additionalContext' "$T/out" 2>/dev/null | tr -d '\r'; }
AO_NOTE="Knowledge base: $(native "$AO_KB"). [[g:slug]] = $(native "$AO_KB")/global/<slug>.md; [[k:path]] = $(native "$AO_KB")/<path>.md."
AO_HEAD='Always-on directives for this project (demo) — follow them in every reply:'
AO_REREAD="Before continuing, re-read the current-status section of this project's auto-memory MEMORY.md."
ao_expect() { # <msg> <expected> <label>
  [ "$1" = "$2" ] || { printf '    FAIL: %s\n      want: %q\n      got:  %q\n' "$3" "$2" "$1" >&2; TEST_FAILED=1; }
}
printf -- '---\nname: ao\ndescription: d\ntags:\n- yaml-list-item\n---\n# Title\n- Reply in 繁體中文\n  - indented is not a directive\nprose line\n```\n- inside fence\n```\n<!-- single-line comment -->\n<!--\n- inside comment\n-->\n- say "hi" and C:\\path\\x\n-not a directive\n- last <!-- inline kept -->\n' > "$AO_PAGE"
AO_BODY="$(printf -- '- Reply in 繁體中文\n- say "hi" and C:\\path\\x\n- last <!-- inline kept -->')"

start_test "session-start always-on: heading and exactly the '- ' lines after the note; frontmatter, fences and comments excluded"
ao_hook startup "$AO_W"
assert_eq 0 "$RC" "exit"
jq -e '.hookSpecificOutput.hookEventName=="SessionStart"' "$T/out" >/dev/null 2>&1 || { printf '    FAIL: bad JSON: %q\n' "$(cat "$T/out")" >&2; TEST_FAILED=1; }
ao_expect "$(ao_msg)" "$AO_NOTE"$'\n\n'"$AO_HEAD"$'\n'"$AO_BODY" "startup message"
ao_hook resume "$AO_W"
ao_expect "$(ao_msg)" "$AO_NOTE"$'\n\n'"$AO_HEAD"$'\n'"$AO_BODY" "resume repeats the injection"
(cd "$AO_W" && printf '{"session_id":"sess-A","source":"startup"}' | env CLAUDE_CONFIG_DIR="$AO_CC" OMK_KNOWLEDGE_DIR="$AO_KB" bash "$HOOKS/session-start.sh" >"$T/out" 2>/dev/null)
ao_expect "$(ao_msg)" "$AO_NOTE"$'\n\n'"$AO_HEAD"$'\n'"$AO_BODY" "no cwd field falls back to \$PWD"
(cd "$AO_W" && printf '{"session_id":"sess-A","source":"startup","cwd":""}' | env CLAUDE_CONFIG_DIR="$AO_CC" OMK_KNOWLEDGE_DIR="$AO_KB" bash "$HOOKS/session-start.sh" >"$T/out" 2>/dev/null)
ao_expect "$(ao_msg)" "$AO_NOTE"$'\n\n'"$AO_HEAD"$'\n'"$AO_BODY" "empty cwd falls back to \$PWD"
end_test

start_test "session-start always-on: a trailing CR on cwd, source and session_id is stripped"
# A jq that writes CRLF (Windows builds) already appends one CR to every field, so the
# source/session_id strip is covered by the compact/clear tests there (msys tolerates a CR
# on cwd); the explicit payload-CR case, which covers cwd, runs only with an LF jq.
if [ "$(jq -n '"a"' | od -An -c | tr -d ' ')" = '"a"\n' ]; then
  printf '{"session_id":"sess-A\\r","hook_event_name":"SessionStart","source":"compact\\r","cwd":"%s\\r"}' "$AO_W" \
    | env CLAUDE_CONFIG_DIR="$AO_CC" OMK_KNOWLEDGE_DIR="$AO_KB" bash "$HOOKS/session-start.sh" >"$T/out" 2>/dev/null
  ao_expect "$(ao_msg)" "$AO_NOTE $AO_REREAD"$'\n\n'"$AO_HEAD"$'\n'"$AO_BODY" "payload fields ending in CR"
else
  echo "    (jq writes CRLF here: CR strip is exercised by every injection case; explicit case skipped)"
fi
end_test

start_test "session-start always-on: compact and clear append after the re-read sentence"
for src in compact clear; do
  ao_hook "$src" "$AO_W"
  ao_expect "$(ao_msg)" "$AO_NOTE $AO_REREAD"$'\n\n'"$AO_HEAD"$'\n'"$AO_BODY" "$src message"
done
end_test

start_test "session-start always-on: CRLF page"
printf -- '---\r\nname: ao\r\ntags:\r\n- yaml-list-item\r\n---\r\n- one\r\n- two\r\n' > "$AO_PAGE"
ao_hook startup "$AO_W"
ao_expect "$(ao_msg)" "$AO_NOTE"$'\n\n'"$AO_HEAD"$'\n- one\n- two' "CRLF page"
assert_eq false "$(jq -r '.hookSpecificOutput.additionalContext | contains("\r")' "$T/out" | tr -d '\r')" "no CR in the message"
end_test

start_test "session-start always-on: backslash cwd in the payload (Windows form)"
case "${OSTYPE:-}" in
  msys*|cygwin*)
    printf -- '- one\n' > "$AO_PAGE"
    WB="$(cd "$AO_W" && pwd -W)"; WB="${WB//\//\\}"
    ao_hook startup "$WB"
    ao_expect "$(ao_msg)" "$AO_NOTE"$'\n\n'"$AO_HEAD"$'\n- one' "backslash cwd ($WB)" ;;
  *) echo "    (not msys: backslash-cwd case skipped)" ;;
esac
end_test

start_test "session-start always-on: anything unmapped leaves the note unchanged"
printf -- '- one\n' > "$AO_PAGE"
ao_hook startup "$AO_W"; ao_expect "$(ao_msg)" "$AO_NOTE"$'\n\n'"$AO_HEAD"$'\n- one' "baseline injects"
ao_hook startup "$T/aowork"; ao_expect "$(ao_msg)" "$AO_NOTE" "not migrated (cwd without marker)"
ao_marker demo > "$AO_MEM/MEMORY.md"; ao_marker other >> "$AO_MEM/MEMORY.md"; mkdir -p "$AO_KB/projects/other"
ao_hook startup "$AO_W"; ao_expect "$(ao_msg)" "$AO_NOTE" "multiple projects"
ao_marker nosuch > "$AO_MEM/MEMORY.md"
ao_hook startup "$AO_W"; ao_expect "$(ao_msg)" "$AO_NOTE" "marker names a missing project"
ao_marker demo > "$AO_MEM/MEMORY.md"
mv "$AO_PAGE" "$AO_PAGE.off"
ao_hook startup "$AO_W"; ao_expect "$(ao_msg)" "$AO_NOTE" "no page"
printf -- '---\nname: ao\n---\nno directives here\n  - indented\n' > "$AO_PAGE"
ao_hook startup "$AO_W"; ao_expect "$(ao_msg)" "$AO_NOTE" "page without '- ' lines"
printf -- '> Moved: [[k:rules/x]]\n' > "$AO_PAGE"
ao_hook startup "$AO_W"; ao_expect "$(ao_msg)" "$AO_NOTE" "stub page"
printf -- '```\n- never closed fence\n' > "$AO_PAGE"
ao_hook startup "$AO_W"; ao_expect "$(ao_msg)" "$AO_NOTE" "only an unclosed fence"
rm -f "$AO_PAGE"; mv "$AO_PAGE.off" "$AO_PAGE"
ao_hook startup "$AO_W" OMK_KNOWLEDGE_DIR=kb
case "$(ao_msg)" in *"Always-on directives"*) printf '    FAIL: injected despite config error\n' >&2; TEST_FAILED=1;; esac
NOKB2="$T/nokb2"; mkdir -p "$NOKB2/projects/demo"; cp "$AO_PAGE" "$NOKB2/projects/demo/always-on.md"
ao_hook startup "$AO_W" OMK_KNOWLEDGE_DIR="$NOKB2"
case "$(ao_msg)" in *"Always-on directives"*) printf '    FAIL: injected despite not set up\n' >&2; TEST_FAILED=1;; esac
contains "$T/out" 'not set up yet' "not-set-up note kept"
end_test

start_test "session-start always-on: cap of 4000 bytes at a line boundary, then the (more in ...) line"
: > "$AO_PAGE"
i=0; while [ "$i" -lt 100 ]; do i=$((i+1)); printf -- '- line-%03d %s\n' "$i" "xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx" >> "$AO_PAGE"; done
ao_hook startup "$AO_W"
M="$(ao_msg)"
BLOCK="${M#*"$AO_HEAD"$'\n'}"
case "$BLOCK" in *$'\n(more in [[k:projects/demo/always-on]])') ;; *) printf '    FAIL: no (more in) line: %q\n' "${BLOCK: -80}" >&2; TEST_FAILED=1;; esac
LINES_ONLY="${BLOCK%$'\n(more in [[k:projects/demo/always-on]])'}"
assert_eq 1 "$([ "$(printf '%s' "$LINES_ONLY" | LC_ALL=C wc -c | tr -d ' ')" -le 4000 ] && echo 1 || echo 0)" "directive lines <= 4000 bytes"
NL="$(printf '%s\n' "$LINES_ONLY" | grep -c '^- line-[0-9]* x\{52\}$')"
assert_eq "$(printf '%s\n' "$LINES_ONLY" | wc -l | tr -d ' ')" "$NL" "every injected line is complete"
assert_eq 1 "$([ "$NL" -ge 50 ] && [ "$NL" -lt 100 ] && echo 1 || echo 0)" "truncated but not tiny (got $NL lines)"
jq -e . "$T/out" >/dev/null 2>&1 || { printf '    FAIL: invalid JSON when truncated\n' >&2; TEST_FAILED=1; }
# CJK is counted in bytes (LC_ALL=C): 3 bytes per char
: > "$AO_PAGE"
i=0; while [ "$i" -lt 60 ]; do i=$((i+1)); printf -- '- 行%02d 規則規則規則規則規則規則規則規則規則規則規則規則規則規則規則規則規則規則規則規則規則規則規則規則規則規則\n' "$i" >> "$AO_PAGE"; done
ao_hook startup "$AO_W"
M="$(ao_msg)"; BLOCK="${M#*"$AO_HEAD"$'\n'}"
case "$BLOCK" in *$'\n(more in [[k:projects/demo/always-on]])') ;; *) printf '    FAIL: CJK page not truncated\n' >&2; TEST_FAILED=1;; esac
LINES_ONLY="${BLOCK%$'\n(more in [[k:projects/demo/always-on]])'}"
assert_eq 1 "$([ "$(printf '%s' "$LINES_ONLY" | LC_ALL=C wc -c | tr -d ' ')" -le 4000 ] && echo 1 || echo 0)" "CJK lines <= 4000 bytes"
# a first line over the cap: heading kept, no directive line, the (more in) line
printf -- '- %s\n- short\n' "$(printf 'y%.0s' $(seq 1 4100))" > "$AO_PAGE"
ao_hook startup "$AO_W"
ao_expect "$(ao_msg)" "$AO_NOTE"$'\n\n'"$AO_HEAD"$'\n(more in [[k:projects/demo/always-on]])' "oversized first line"
# a page of exactly-fitting size is not truncated
printf -- '- a\n- b\n' > "$AO_PAGE"
ao_hook startup "$AO_W"; lacks "$T/out" '(more in' "short page: no more-line"
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

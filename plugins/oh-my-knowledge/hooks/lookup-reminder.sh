#!/bin/bash
# UserPromptSubmit hook: remind Claude to consult the knowledge base before
# answering a problem/diagnostic-style question. Never breaks the session:
# any internal error or missing jq -> exit 0 silently. bash 3.2 compatible.
case "${BASH_SOURCE[0]}" in */*) HOOK_DIR="${BASH_SOURCE[0]%/*}" ;; *) HOOK_DIR=. ;; esac
# shellcheck source=../scripts/lib/common.sh
. "$HOOK_DIR/../scripts/lib/common.sh" 2>/dev/null || exit 0
omk_config 2>/dev/null || exit 0
[ -z "${OMK_CONFIG_ERROR:-}" ] || exit 0
[ "$OMK_LOOKUP_REMINDER" = true ] || exit 0

prompt="$("$OMK_JQ" -r '.prompt // ""' 2>/dev/null)" || exit 0
[ -n "$prompt" ] || exit 0

# Slash commands are not questions.
trimmed="${prompt#"${prompt%%[![:space:]]*}"}"
case "$trimmed" in /*) exit 0 ;; esac

zh='為什麼|為何|怎麼|怎樣|如何|怎辦|是不是|會不會|要不要|慢|錯|壞|失敗|卡住|卡在|不行|不能|沒反應|跑不|掛了|爆了|異常|問題|影響'
en='why|how come|error|errors|fail(s|ed|ing|ure)?|slow|broken|crash(es|ed)?|hang(s|ing)?|stuck|timeout|timed out|flaky|not working'
hit=0
if [[ "$prompt" =~ $zh ]]; then
  hit=1
else
  en_re="(^|[^a-z])($en)([^a-z]|\$)"
  shopt -s nocasematch
  [[ "$prompt" =~ $en_re ]] && hit=1
  shopt -u nocasematch
fi
[ "$hit" = 1 ] || exit 0

ctx='[oh-my-knowledge hook] This message looks like a problem/diagnostic question (這則訊息像問題／診斷型提問). Before replying, run oh-my-knowledge:lookup first with 3-6 keywords (error fragments, tool names, symptoms, zh/en synonyms), read the 1-2 best-matching topic files in full, then answer and say in one sentence what the lookup found (or that the knowledge base has nothing). If the message is merely a command or a confirmation, skip it.'
"$OMK_JQ" -cn --arg c "$ctx" '{hookSpecificOutput:{hookEventName:"UserPromptSubmit",additionalContext:$c}}' 2>/dev/null
exit 0

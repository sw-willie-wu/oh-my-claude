#!/bin/bash
# SessionStart hook (every source): tell Claude where the knowledge base is and
# what [[g:slug]] / [[k:path]] mean. On compact and clear the handoff marker and
# usage file are dropped so the next window can trigger again, and Claude is told
# to re-read the current-status section of the project auto-memory. bash 3.2.
case "${BASH_SOURCE[0]}" in */*) HOOK_DIR="${BASH_SOURCE[0]%/*}" ;; *) HOOK_DIR=. ;; esac
# shellcheck source=../scripts/lib/common.sh
. "$HOOK_DIR/../scripts/lib/common.sh" 2>/dev/null || exit 0
omk_config 2>/dev/null || exit 0

l="$("$OMK_JQ" -r '[(.source // ""), (.session_id // "")] | @tsv' 2>/dev/null)" || exit 0
source_="${l%%$'\t'*}"
sid="${l#*$'\t'}"
source_="${source_%$'\r'}"; sid="${sid%$'\r'}"

# Native form (C:/… on Windows) so the Read tool gets a path it can open.
kb="$(omk_native_path "$OMK_KNOWLEDGE_DIR")"
msg="Knowledge base: ${kb}. [[g:slug]] = ${kb}/global/<slug>.md; [[k:path]] = ${kb}/<path>.md."
# Precedence: configuration error > not set up > normal note (clearing and the
# re-read sentence stay in every case).
[ -f "$OMK_KNOWLEDGE_DIR/SCHEMA.md" ] || msg="oh-my-knowledge: knowledge base not set up yet (${kb}) — run /oh-my-knowledge:setup"
[ -z "${OMK_CONFIG_ERROR:-}" ] || msg="oh-my-knowledge: $OMK_CONFIG_ERROR"

case "$source_" in
  compact|clear)
    if [ -n "$sid" ]; then
      san="${sid//[^A-Za-z0-9_-]/_}"
      # New window: drop the handoff marker and the now-stale usage reading.
      rm -f "$OMC_STATE_DIR/handoff-$san" "$OMC_STATE_DIR/ctx-$san" 2>/dev/null
    fi ;;
esac
case "$source_" in
  compact|clear) msg="$msg Before continuing, re-read the current-status section of this project's auto-memory MEMORY.md." ;;
esac

"$OMK_JQ" -cn --arg c "$msg" '{hookSpecificOutput:{hookEventName:"SessionStart",additionalContext:$c}}' 2>/dev/null
exit 0

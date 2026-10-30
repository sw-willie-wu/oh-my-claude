#!/bin/bash
# Stop hook: when the context usage written by oh-my-status (ctx-<sid>) reaches
# the threshold and no handoff has been requested in this compact window, write
# handoff-<sid> and block the stop so Claude runs oh-my-knowledge:handoff.
# Never breaks the session: any problem -> exit 0 silently. bash 3.2 compatible.
case "${BASH_SOURCE[0]}" in */*) HOOK_DIR="${BASH_SOURCE[0]%/*}" ;; *) HOOK_DIR=. ;; esac
# shellcheck source=../scripts/lib/common.sh
. "$HOOK_DIR/../scripts/lib/common.sh" 2>/dev/null || exit 0
omk_config 2>/dev/null || exit 0
[ "$OMK_AUTO_HANDOFF" = true ] || exit 0

fields="$("$OMK_JQ" -r '(.stop_hook_active // false | tostring), (.session_id // "")' 2>/dev/null)" || exit 0
active="${fields%%$'\n'*}"
sid="${fields#*$'\n'}"
sid="${sid%$'\r'}"; active="${active%$'\r'}"
[ "$active" = false ] || exit 0
[ -n "$sid" ] || exit 0
san="${sid//[^A-Za-z0-9_-]/_}"

ctx_file="$OMC_STATE_DIR/ctx-$san"
marker="$OMC_STATE_DIR/handoff-$san"
[ -f "$ctx_file" ] || exit 0
[ -e "$marker" ] && exit 0

line=""
IFS= read -r line < "$ctx_file" 2>/dev/null
pct="${line%% *}"
case "$pct" in ''|*[!0-9]*) exit 0 ;; esac
pct=$((10#$pct))

thr="$OMK_AUTO_HANDOFF_THRESHOLD"
[ "$thr" -lt 30 ] && thr=30
[ "$thr" -gt 90 ] && thr=90
[ "$pct" -ge "$thr" ] || exit 0

# Marker first, then block: if the marker cannot be written, stay silent so we
# never block twice for the same window.
: > "$marker" 2>/dev/null || exit 0
"$OMK_JQ" -cn --arg r "Context is at ${pct}%. Run oh-my-knowledge:handoff now, then tell the user they can /clear or /compact." \
  '{decision:"block",reason:$r}' 2>/dev/null
exit 0

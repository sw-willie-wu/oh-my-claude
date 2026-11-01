#!/bin/bash
# Stop hook: when the context usage written by oh-my-status (ctx-<sid>) reaches
# the threshold, write the usage into handoff-<sid> and block the stop so Claude
# runs oh-my-knowledge:handoff. The marker holds the highest usage % at which a
# handoff was requested or completed in this window; it fires again once usage
# grows by auto_handoff_repeat points past a marker that is at/above the
# threshold (or by 5 points past a lower one, e.g. an early manual handoff).
# Never breaks the session: any problem -> exit 0 silently. bash 3.2 compatible.
case "${BASH_SOURCE[0]}" in */*) HOOK_DIR="${BASH_SOURCE[0]%/*}" ;; *) HOOK_DIR=. ;; esac
# shellcheck source=../scripts/lib/common.sh
. "$HOOK_DIR/../scripts/lib/common.sh" 2>/dev/null || exit 0
omk_config 2>/dev/null || exit 0
[ -z "${OMK_CONFIG_ERROR:-}" ] || exit 0
[ "$OMK_AUTO_HANDOFF" = true ] || exit 0
# Not set up yet (no SCHEMA.md in the knowledge base): stay silent.
[ -f "$OMK_KNOWLEDGE_DIR/SCHEMA.md" ] || exit 0

# One jq call; split on the tab with parameter expansion (read would collapse an
# empty first field) and strip the CR a Windows jq adds.
l="$("$OMK_JQ" -r '[(.stop_hook_active // false | tostring), (.session_id // "")] | @tsv' 2>/dev/null)" || exit 0
active="${l%%$'\t'*}"
sid="${l#*$'\t'}"
sid="${sid%$'\r'}"; active="${active%$'\r'}"
[ "$active" = false ] || exit 0
[ -n "$sid" ] || exit 0
san="${sid//[^A-Za-z0-9_-]/_}"

ctx_file="$OMC_STATE_DIR/ctx-$san"
marker="$OMC_STATE_DIR/handoff-$san"
[ -f "$ctx_file" ] || exit 0

# Valid = first line (CR stripped), 1-3 digits, value <= 100.
line=""
IFS= read -r line 2>/dev/null < "$ctx_file"
line="${line%$'\r'}"
pct="${line%% *}"
case "$pct" in ''|*[!0-9]*|????*) exit 0 ;; esac
pct=$((10#$pct))
[ "$pct" -le 100 ] || exit 0

r=0
m=""
IFS= read -r m 2>/dev/null < "$marker"
m="${m%$'\r'}"
case "$m" in ''|*[!0-9]*|????*) ;; *) r=$((10#$m)); [ "$r" -le 100 ] || r=0 ;; esac

thr="$OMK_AUTO_HANDOFF_THRESHOLD"
[ "$thr" -lt 30 ] && thr=30
[ "$thr" -gt 90 ] && thr=90
rep="$OMK_AUTO_HANDOFF_REPEAT"
[ "$rep" -lt 10 ] && rep=10
[ "$rep" -gt 60 ] && rep=60
[ "$pct" -ge "$thr" ] || exit 0
if [ "$r" -lt "$thr" ]; then
  [ $((pct - r)) -ge 5 ] || exit 0
else
  [ $((pct - r)) -ge "$rep" ] || exit 0
fi

# Marker first, then block: if the marker cannot be written, stay silent so we
# never block without a marker.
printf '%s\n' "$pct" 2>/dev/null > "$marker" || exit 0
"$OMK_JQ" -cn --arg r "Context is at ${pct}%. Run oh-my-knowledge:handoff now, then tell the user they can /clear or /compact." \
  '{decision:"block",reason:$r}' 2>/dev/null
exit 0

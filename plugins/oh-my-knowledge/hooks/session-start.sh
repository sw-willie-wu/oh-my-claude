#!/bin/bash
# SessionStart hook (every source): tell Claude where the knowledge base is and
# what [[g:slug]] / [[k:path]] mean. On compact and clear the handoff marker and
# usage file are dropped so the next window can trigger again, and Claude is told
# to re-read the current-status section of the project auto-memory. When the
# project is migrated and has projects/<p>/always-on.md, its "- " lines are
# appended as always-on directives. bash 3.2.
case "${BASH_SOURCE[0]}" in */*) HOOK_DIR="${BASH_SOURCE[0]%/*}" ;; *) HOOK_DIR=. ;; esac
# shellcheck source=../scripts/lib/common.sh
. "$HOOK_DIR/../scripts/lib/common.sh" 2>/dev/null || exit 0
omk_config 2>/dev/null || exit 0

# One jq call, one value per line (not @tsv: it would double a backslash in cwd).
l="$("$OMK_JQ" -r '(.source // ""), (.session_id // ""), (.cwd // "")' 2>/dev/null)" || exit 0
source_=""; sid=""; cwd=""
{ IFS= read -r source_; IFS= read -r sid; IFS= read -r cwd; } <<< "$l"
source_="${source_%$'\r'}"; sid="${sid%$'\r'}"; cwd="${cwd%$'\r'}"
[ -n "$cwd" ] || cwd="$PWD"

# Native form (C:/… on Windows) so the Read tool gets a path it can open.
kb="$(omk_native_path "$OMK_KNOWLEDGE_DIR")"
msg="Knowledge base: ${kb}. [[g:slug]] = ${kb}/global/<slug>.md; [[k:path]] = ${kb}/<path>.md."
normal=1
# Precedence: configuration error > not set up > normal note (clearing and the
# re-read sentence stay in every case).
if [ ! -f "$OMK_KNOWLEDGE_DIR/SCHEMA.md" ]; then
  normal=0
  msg="oh-my-knowledge: knowledge base not set up yet (${kb}) — run /oh-my-knowledge:setup"
fi
if [ -n "${OMK_CONFIG_ERROR:-}" ]; then
  normal=0
  msg="oh-my-knowledge: $OMK_CONFIG_ERROR"
fi

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

# _omk_always_on_block <outvar> <project> <page>: assigns the directives block
# (heading + "- " lines, at most 4000 bytes counted under LC_ALL=C, cut at a line
# boundary) or "" when there is nothing to inject.
_omk_always_on_block() {
  local LC_ALL=C
  local _p="$2" _page="$3" _line _t _first=1 _infm=0 _fence=0 _cmt=0 _body="" _more=0 _total=0 _bom=$'\xef\xbb\xbf' _out=""
  printf -v "$1" '%s' ""
  [ -f "$_page" ] || return 0
  while IFS= read -r _line || [ -n "$_line" ]; do
    _line="${_line%$'\r'}"
    if [ "$_first" = 1 ]; then
      _first=0; _line="${_line#"$_bom"}"
      if [ "$_line" = "---" ]; then _infm=1; continue; fi
    fi
    if [ "$_infm" = 1 ]; then
      if [ "$_line" = "---" ]; then _infm=0; fi
      continue
    fi
    _t="${_line#"${_line%%[![:space:]]*}"}"
    if [ "$_cmt" = 1 ]; then
      case "$_line" in *'-->'*) _cmt=0 ;; esac
      continue
    fi
    if [ "$_fence" = 1 ]; then
      case "$_t" in '```'*|'~~~'*) _fence=0 ;; esac
      continue
    fi
    case "$_t" in
      '```'*|'~~~'*) _fence=1; continue ;;
      '<!--'*) case "$_t" in *'-->'*) ;; *) _cmt=1 ;; esac; continue ;;
    esac
    case "$_line" in
      '- '*)
        if [ $((_total + ${#_line} + 1)) -gt 4000 ]; then _more=1; break; fi
        _total=$((_total + ${#_line} + 1))
        _body="${_body:+$_body$'\n'}$_line" ;;
    esac
  done < "$_page"
  [ -n "$_body" ] || [ "$_more" = 1 ] || return 0
  _out="Always-on directives for this project (${_p}) — follow them in every reply:"
  [ -z "$_body" ] || _out="$_out"$'\n'"$_body"
  if [ "$_more" = 1 ]; then _out="$_out"$'\n'"(more in [[k:projects/${_p}/always-on]])"; fi
  printf -v "$1" '%s' "$_out"
}

if [ "$normal" = 1 ]; then
  proj=""; block=""
  if . "$HOOK_DIR/../scripts/lib/project.sh" 2>/dev/null; then
    _omk_project_into proj "$cwd" 2>/dev/null
    if [ -n "$proj" ]; then
      _omk_always_on_block block "$proj" "$OMK_KNOWLEDGE_DIR/projects/$proj/always-on.md" 2>/dev/null
      [ -z "$block" ] || msg="$msg"$'\n\n'"$block"
    fi
  fi
fi

"$OMK_JQ" -cn --arg c "$msg" '{hookSpecificOutput:{hookEventName:"SessionStart",additionalContext:$c}}' 2>/dev/null
exit 0

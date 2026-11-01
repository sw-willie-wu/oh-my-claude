#!/bin/bash
# oh-my-knowledge shared helpers: path normalisation and configuration.
# Source this file; it defines functions only. Requirements: bash, gawk, GNU date, jq.

_OMK_UP=ABCDEFGHIJKLMNOPQRSTUVWXYZ
_OMK_LO=abcdefghijklmnopqrstuvwxyz

# _omk_resolve_into <outvar> <path>: fork-free core of omk_resolve_dir.
_omk_resolve_into() {
  local _p="$2" _q _pre _dl _old _hadold _oo
  _p="${_p//\\//}"
  case "$_p" in
    "~") _p="$HOME" ;;
    "~/"*) _p="$HOME/${_p#\~/}" ;;
  esac
  if [[ "$_p" =~ ^([A-Za-z]):(/.*)?$ ]]; then
    _dl="${BASH_REMATCH[1]}"
    _q="${BASH_REMATCH[2]}"
    _pre="${_OMK_UP%%"$_dl"*}"
    if [ "${#_pre}" -lt 26 ]; then _dl="${_OMK_LO:${#_pre}:1}"; fi
    _p="/$_dl$_q"
  fi
  while [ "${#_p}" -gt 1 ] && [ "${_p%/}" != "$_p" ]; do _p="${_p%/}"; done
  if [ -d "$_p" ]; then
    _old="$PWD"
    if [ -d "$_old" ]; then
      # Fork-free canonicalisation; caller's PWD and OLDPWD are restored.
      _hadold="${OLDPWD+set}"; _oo="${OLDPWD-}"
      if CDPATH= cd -P -- "$_p" 2>/dev/null; then
        _p="$PWD"
        cd -- "$_old" 2>/dev/null
      fi
      if [ "$_hadold" = set ]; then OLDPWD="$_oo"; else unset OLDPWD; fi
    else
      # Caller's cwd is gone (cd back impossible): canonicalise in a subshell.
      _q="$(CDPATH= cd -P -- "$_p" 2>/dev/null && pwd -P)" && _p="$_q"
    fi
  fi
  printf -v "$1" '%s' "$_p"
}

# omk_resolve_dir <path>
# Canonical absolute POSIX path used for every comparison. Expands a leading
# ~/, turns C:\a\b / C:/a/b / c:/a/b into /c/a/b, strips trailing slashes, and
# (when the directory exists) canonicalises it with cd -P so /tmp/x, 8.3 short
# names and symlinks all map to the same string as the long path.
omk_resolve_dir() {
  local _r
  _omk_resolve_into _r "$1"
  printf '%s' "$_r"
}

# omk_native_path <path>
# The canonical path in the form Claude Code encodes for auto-memory dir names:
# Windows -> C:/… with long names (pwd -W; never cygpath -m, which may return
# 8.3 names); elsewhere pwd -P. Non-existent paths: best-effort conversion.
omk_native_path() {
  local p q r
  _omk_resolve_into p "$1"
  case "${OSTYPE:-}" in
    msys*|cygwin*)
      if [ -d "$p" ] && q="$(CDPATH= cd -P -- "$p" 2>/dev/null && pwd -W)"; then
        printf '%s' "$q"
        return 0
      fi
      if [[ "$p" =~ ^/([a-z])(/.*)?$ ]]; then
        r="${BASH_REMATCH[1]}"
        _omk_upper_into r "$r"
        printf "%s:%s" "$r" "${BASH_REMATCH[2]:-/}"
      else
        printf '%s' "$p"
      fi
      ;;
    *)
      printf '%s' "$p"
      ;;
  esac
}

# omk_repo_root <dir>
# Project root: inside git, the parent of the common git dir (so linked
# worktrees map to the main repo); otherwise <dir>. Submodules are out of scope
# (their common dir lives under the parent's .git/modules/; use OMK_AUTO_MEMORY_DIR).
omk_repo_root() {
  local d g
  d="$(omk_resolve_dir "$1")"
  if g="$(git -C "$d" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)" && [ -n "$g" ]; then
    g="${g%$'\r'}"
    # Anything but one absolute line (old git ignoring --path-format, noise) = not in git.
    case "$g" in
      *$'\n'*) printf '%s' "$d"; return 0 ;;
      /*|[A-Za-z]:|[A-Za-z]:[/\\]*) ;;
      *) printf '%s' "$d"; return 0 ;;
    esac
    g="$(omk_resolve_dir "$g")"
    omk_resolve_dir "$(dirname "$g")"
  else
    printf '%s' "$d"
  fi
}

# omk_encode_name <native string>
# Every character outside [A-Za-z0-9] becomes '-', one '-' per character (CJK too).
omk_encode_name() {
  local s="$1"
  local LC_ALL=C.UTF-8
  printf "%s" "${s//[^A-Za-z0-9]/-}"
}

# omk_encode_path <path>: the only way to derive an auto-memory dir name.
omk_encode_path() {
  omk_encode_name "$(omk_native_path "$1")"
}

# _omk_unset <value>: true when empty or still a literal ${user_config.…}.
_omk_unset() {
  case "$1" in
    "" | *'${user_config.'*) return 0 ;;
  esac
  return 1
}

# _omk_upper_into <outvar> <string>: ASCII upper-case without forking.
_omk_upper_into() {
  local _s="$2" _r="" _c _i _pre
  for ((_i = 0; _i < ${#_s}; _i++)); do
    _c="${_s:_i:1}"
    case "$_c" in
      [abcdefghijklmnopqrstuvwxyz]) _pre="${_OMK_LO%%"$_c"*}"; _c="${_OMK_UP:${#_pre}:1}" ;;
    esac
    _r+="$_c"
  done
  printf -v "$1" '%s' "$_r"
}

# _omk_pick <outvar> <ENV_VAR> <option_key> <default>:
# env > CLAUDE_PLUGIN_OPTION_<UPPER key> > CLAUDE_PLUGIN_OPTION_<key as given> > default.
# Both option lookups derive from the one key argument.
_omk_pick() {
  local _var="$2" _key="$3" _def="$4" _v _o _up
  _v="${!_var:-}"
  if _omk_unset "$_v"; then
    _omk_upper_into _up "$_key"
    _o="CLAUDE_PLUGIN_OPTION_$_up"; _v="${!_o:-}"
    if _omk_unset "$_v"; then
      _o="CLAUDE_PLUGIN_OPTION_${_key}"; _v="${!_o:-}"
    fi
  fi
  if _omk_unset "$_v"; then _v="$_def"; fi
  printf -v "$1" '%s' "$_v"
}

_omk_bool() { # <outvar> <value> <default>
  case "$2" in
    [Tt][Rr][Uu][Ee]|1|[Yy][Ee][Ss]|[Oo][Nn]|[Yy]) printf -v "$1" true ;;
    [Ff][Aa][Ll][Ss][Ee]|0|[Nn][Oo]|[Oo][Ff][Ff]|[Nn]) printf -v "$1" false ;;
    *) printf -v "$1" '%s' "$3" ;;
  esac
}

_omk_int() { # <outvar> <value> <default>
  case "$2" in
    ''|*[!0-9]*) printf -v "$1" '%s' "$3" ;;
    *) printf -v "$1" '%s' "$((10#$2))" ;;
  esac
}

# omk_today: set OMK_TODAY (env OMK_TODAY wins) and export it. Not part of
# omk_config (it forks `date`); call it from scripts that need the date (lint).
omk_today() {
  OMK_TODAY="${OMK_TODAY:-}"
  _omk_unset "$OMK_TODAY" && OMK_TODAY="$(date +%F)"
  export OMK_TODAY
}

# omk_config: set and export every OMK_* setting (plus OMC_STATE_DIR).
# Precedence: env var (if non-empty and not a literal ${user_config.…}) >
# CLAUDE_PLUGIN_OPTION_<KEY> > spec default. The platform never applies
# userConfig defaults, so the default branch is the normal path for unset options.
# Fork-free (hooks run it on every event); OMK_TODAY is lazy, see omk_today.
omk_config() {
  local cc="${CLAUDE_CONFIG_DIR:-$HOME/.claude}" t _v
  _omk_pick t OMK_KNOWLEDGE_DIR knowledge_dir '~/knowledge'
  # Validate the picked raw value (backslashes as slashes) before resolving:
  # absolute = /…, X:/…, X:, or ~ / ~/…. Always assigned; omk_config still returns 0.
  OMK_CONFIG_ERROR=""
  _v="${t//\\//}"
  case "$_v" in
    /*|"~"|"~/"*|[A-Za-z]:|[A-Za-z]:/*) ;;
    *) OMK_CONFIG_ERROR="knowledge_dir must be an absolute path or start with ~/ (got: $t); run /oh-my-knowledge:setup" ;;
  esac
  _omk_resolve_into OMK_KNOWLEDGE_DIR "$t"
  _omk_pick t OMK_LOOKUP_REMINDER lookup_reminder true; _omk_bool OMK_LOOKUP_REMINDER "$t" true
  _omk_pick t OMK_AUTO_HANDOFF auto_handoff true; _omk_bool OMK_AUTO_HANDOFF "$t" true
  _omk_pick t OMK_AUTO_HANDOFF_THRESHOLD auto_handoff_threshold 70; _omk_int OMK_AUTO_HANDOFF_THRESHOLD "$t" 70
  _omk_pick t OMK_AUTO_HANDOFF_REPEAT auto_handoff_repeat 20; _omk_int OMK_AUTO_HANDOFF_REPEAT "$t" 20
  _omk_pick t OMK_LINT_STALE_DAYS lint_stale_days 90; _omk_int OMK_LINT_STALE_DAYS "$t" 90
  _omk_pick t OMK_LINT_FLAG_DAYS lint_flag_days 14; _omk_int OMK_LINT_FLAG_DAYS "$t" 14
  _omk_pick t OMK_LINT_REMIND_AFTER_DISTILLS lint_remind_after_distills 10; _omk_int OMK_LINT_REMIND_AFTER_DISTILLS "$t" 10
  _omk_pick t OMK_MAX_FILE_KB max_file_kb 8; _omk_int OMK_MAX_FILE_KB "$t" 8
  _omk_pick t OMK_MAX_INDEX_LINE_CHARS max_index_line_chars 200; _omk_int OMK_MAX_INDEX_LINE_CHARS "$t" 200
  OMK_AUTO_MEMORY_DIR="${OMK_AUTO_MEMORY_DIR:-}"
  _omk_unset "$OMK_AUTO_MEMORY_DIR" && OMK_AUTO_MEMORY_DIR=""
  OMK_AUTO_MEMORY_GLOB="${OMK_AUTO_MEMORY_GLOB:-}"
  _omk_unset "$OMK_AUTO_MEMORY_GLOB" && OMK_AUTO_MEMORY_GLOB="$cc/projects/*/memory"
  OMK_CLAUDE_MD="${OMK_CLAUDE_MD:-}"
  _omk_unset "$OMK_CLAUDE_MD" && OMK_CLAUDE_MD="$cc/CLAUDE.md"
  OMC_STATE_DIR="${OMC_STATE_DIR:-}"
  _omk_unset "$OMC_STATE_DIR" && OMC_STATE_DIR="$HOME/.claude/oh-my-claude/state"
  OMK_TODAY="${OMK_TODAY:-}"
  _omk_unset "$OMK_TODAY" && OMK_TODAY=""
  OMK_JQ="${OMK_JQ:-}"
  _omk_unset "$OMK_JQ" && OMK_JQ="jq"
  export OMK_KNOWLEDGE_DIR OMK_LOOKUP_REMINDER OMK_AUTO_HANDOFF OMK_AUTO_HANDOFF_THRESHOLD \
    OMK_AUTO_HANDOFF_REPEAT OMK_LINT_STALE_DAYS OMK_LINT_FLAG_DAYS OMK_LINT_REMIND_AFTER_DISTILLS OMK_MAX_FILE_KB \
    OMK_MAX_INDEX_LINE_CHARS OMK_AUTO_MEMORY_DIR OMK_AUTO_MEMORY_GLOB OMK_CLAUDE_MD \
    OMC_STATE_DIR OMK_TODAY OMK_JQ OMK_CONFIG_ERROR
}

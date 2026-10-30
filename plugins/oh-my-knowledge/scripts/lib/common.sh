#!/bin/bash
# oh-my-knowledge shared helpers: path normalisation and configuration.
# Source this file; it defines functions only. Requirements: bash, gawk, GNU date, jq.

# omk_resolve_dir <path>
# Canonical absolute POSIX path used for every comparison. Expands a leading
# ~/, turns C:\a\b / C:/a/b / c:/a/b into /c/a/b, strips trailing slashes, and
# (when the directory exists) canonicalises it with pwd -P so /tmp/x, 8.3 short
# names and symlinks all map to the same string as the long path.
omk_resolve_dir() {
  local p="$1" q
  case "$p" in
    "~") p="$HOME" ;;
    "~/"*) p="$HOME/${p#\~/}" ;;
  esac
  p="${p//\\//}"
  if [[ "$p" =~ ^([A-Za-z]):(/.*)?$ ]]; then
    local dl="${BASH_REMATCH[1]}"
    dl="$(printf %s "$dl" | tr A-Z a-z)"
    p="/$dl${BASH_REMATCH[2]}"
  fi
  while [ "${#p}" -gt 1 ] && [ "${p%/}" != "$p" ]; do p="${p%/}"; done
  if [ -d "$p" ]; then
    if q="$(CDPATH= cd -P -- "$p" 2>/dev/null && pwd -P)"; then p="$q"; fi
  fi
  printf '%s' "$p"
}

# omk_native_path <path>
# The canonical path in the form Claude Code encodes for auto-memory dir names:
# Windows -> C:/… with long names (pwd -W; never cygpath -m, which may return
# 8.3 names); elsewhere pwd -P. Non-existent paths: best-effort conversion.
omk_native_path() {
  local p q r
  p="$(omk_resolve_dir "$1")"
  case "${OSTYPE:-}" in
    msys*|cygwin*)
      if [ -d "$p" ] && q="$(CDPATH= cd -P -- "$p" 2>/dev/null && pwd -W)"; then
        printf '%s' "$q"
        return 0
      fi
      if [[ "$p" =~ ^/([a-z])(/.*)?$ ]]; then
        r="${BASH_REMATCH[1]}"
        r="$(printf %s "$r" | tr a-z A-Z)"
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

# _omk_unset_literal <value>: true when empty or still a literal ${user_config.…}.
_omk_unset() {
  case "$1" in
    "" | *'${user_config.'*) return 0 ;;
  esac
  return 1
}

# _omk_pick <ENV_VAR> <option_key> <default>: env > CLAUDE_PLUGIN_OPTION_<KEY> > default.
_omk_pick() {
  local var="$1" key="$2" def="$3" v o
  v="${!var:-}"
  if _omk_unset "$v"; then
    o="CLAUDE_PLUGIN_OPTION_$(printf %s "$key" | tr a-z A-Z)"; v="${!o:-}"
    if _omk_unset "$v"; then
      o="CLAUDE_PLUGIN_OPTION_${key}"; v="${!o:-}"
    fi
  fi
  if _omk_unset "$v"; then v="$def"; fi
  printf '%s' "$v"
}

_omk_bool() { # <value> <default>
  case "$(printf %s "$1" | tr A-Z a-z)" in
    true|1|yes|on|y) printf true ;;
    false|0|no|off|n) printf false ;;
    *) printf '%s' "$2" ;;
  esac
}

_omk_int() { # <value> <default>
  case "$1" in
    ''|*[!0-9]*) printf '%s' "$2" ;;
    *) printf '%s' "$((10#$1))" ;;
  esac
}

# omk_config: set and export every OMK_* setting (plus OMC_STATE_DIR).
# Precedence: env var (if non-empty and not a literal ${user_config.…}) >
# CLAUDE_PLUGIN_OPTION_<KEY> > spec default. The platform never applies
# userConfig defaults, so the default branch is the normal path for unset options.
omk_config() {
  local cc="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
  OMK_KNOWLEDGE_DIR="$(omk_resolve_dir "$(_omk_pick OMK_KNOWLEDGE_DIR knowledge_dir '~/knowledge')")"
  OMK_LOOKUP_REMINDER="$(_omk_bool "$(_omk_pick OMK_LOOKUP_REMINDER lookup_reminder true)" true)"
  OMK_AUTO_HANDOFF="$(_omk_bool "$(_omk_pick OMK_AUTO_HANDOFF auto_handoff true)" true)"
  OMK_AUTO_HANDOFF_THRESHOLD="$(_omk_int "$(_omk_pick OMK_AUTO_HANDOFF_THRESHOLD auto_handoff_threshold 70)" 70)"
  OMK_LINT_STALE_DAYS="$(_omk_int "$(_omk_pick OMK_LINT_STALE_DAYS lint_stale_days 90)" 90)"
  OMK_LINT_FLAG_DAYS="$(_omk_int "$(_omk_pick OMK_LINT_FLAG_DAYS lint_flag_days 14)" 14)"
  OMK_LINT_REMIND_AFTER_DISTILLS="$(_omk_int "$(_omk_pick OMK_LINT_REMIND_AFTER_DISTILLS lint_remind_after_distills 10)" 10)"
  OMK_MAX_FILE_KB="$(_omk_int "$(_omk_pick OMK_MAX_FILE_KB max_file_kb 8)" 8)"
  OMK_MAX_INDEX_LINE_CHARS="$(_omk_int "$(_omk_pick OMK_MAX_INDEX_LINE_CHARS max_index_line_chars 200)" 200)"
  OMK_AUTO_MEMORY_DIR="${OMK_AUTO_MEMORY_DIR:-}"
  _omk_unset "$OMK_AUTO_MEMORY_DIR" && OMK_AUTO_MEMORY_DIR=""
  OMK_AUTO_MEMORY_GLOB="${OMK_AUTO_MEMORY_GLOB:-}"
  _omk_unset "$OMK_AUTO_MEMORY_GLOB" && OMK_AUTO_MEMORY_GLOB="$cc/projects/*/memory"
  OMK_CLAUDE_MD="${OMK_CLAUDE_MD:-}"
  _omk_unset "$OMK_CLAUDE_MD" && OMK_CLAUDE_MD="$cc/CLAUDE.md"
  OMC_STATE_DIR="${OMC_STATE_DIR:-}"
  _omk_unset "$OMC_STATE_DIR" && OMC_STATE_DIR="$HOME/.claude/oh-my-claude/state"
  OMK_TODAY="${OMK_TODAY:-}"
  _omk_unset "$OMK_TODAY" && OMK_TODAY="$(date +%F)"
  OMK_JQ="${OMK_JQ:-}"
  _omk_unset "$OMK_JQ" && OMK_JQ="jq"
  export OMK_KNOWLEDGE_DIR OMK_LOOKUP_REMINDER OMK_AUTO_HANDOFF OMK_AUTO_HANDOFF_THRESHOLD \
    OMK_LINT_STALE_DAYS OMK_LINT_FLAG_DAYS OMK_LINT_REMIND_AFTER_DISTILLS OMK_MAX_FILE_KB \
    OMK_MAX_INDEX_LINE_CHARS OMK_AUTO_MEMORY_DIR OMK_AUTO_MEMORY_GLOB OMK_CLAUDE_MD \
    OMC_STATE_DIR OMK_TODAY OMK_JQ
}

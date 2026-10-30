#!/bin/bash
# oh-my-knowledge project mapping: marker parser and auto-memory discovery.
# Source after lib/common.sh and after calling omk_config. Functions only.
# bash-3.2 compatible (no bash4-only constructs).

# omk_project_marker_status <auto-memory dir>
# The single parser for the project marker line in <dir>/MEMORY.md:
#   - Knowledge base project: [[k:projects/<p>/index]] (omk-project)
# (whole-line match anywhere in the file, CRLF tolerated; prose is not a marker).
# Prints exactly one of:
#   none                  no marker (or no MEMORY.md / empty dir argument)
#   ok <p>                exactly one distinct project and <kb>/projects/<p>/ exists
#   invalid multiple      two or more distinct projects named
#   invalid missing <p>   one project named but <kb>/projects/<p>/ does not exist
omk_project_marker_status() {
  local dir="${1:-}" f names n p
  if [ -z "$dir" ] || [ ! -f "$dir/MEMORY.md" ]; then printf 'none'; return 0; fi
  f="$dir/MEMORY.md"
  names="$(LC_ALL=C awk '
    { sub(/\r$/, "") }
    NR == 1 { sub(/^\357\273\277/, "") }
    match($0, /^- Knowledge base project: \[\[k:projects\/[^\/\]]+\/index\]\] \(omk-project\)$/) {
      s = $0
      sub(/^- Knowledge base project: \[\[k:projects\//, "", s)
      sub(/\/index\]\] \(omk-project\)$/, "", s)
      if (!(s in seen)) { seen[s] = 1; print s }
    }
  ' "$f")"
  if [ -z "$names" ]; then printf 'none'; return 0; fi
  n="$(printf '%s\n' "$names" | wc -l | tr -d ' ')"
  if [ "$n" -gt 1 ]; then printf 'invalid multiple'; return 0; fi
  p="${names%$'\r'}"
  case "$p" in
    "." | "..") printf 'invalid missing %s' "$p"; return 0 ;;
  esac
  if [ -d "${OMK_KNOWLEDGE_DIR:-}/projects/$p" ]; then printf 'ok %s' "$p"; else printf 'invalid missing %s' "$p"; fi
  return 0
}

# omk_project_marker <auto-memory dir>: <p> when the status is "ok <p>", else nothing.
omk_project_marker() {
  local st
  st="$(omk_project_marker_status "${1:-}")"
  case "$st" in "ok "*) printf '%s' "${st#ok }" ;; esac
  return 0
}

# omk_auto_memory_for_cwd <cwd>
# OMK_AUTO_MEMORY_DIR if set and existing (normalised); else the dir under the
# OMK_AUTO_MEMORY_GLOB parent whose name equals omk_encode_path(omk_repo_root cwd),
# compared case-insensitively (Claude Code may write the drive letter in lower case).
omk_auto_memory_for_cwd() {
  local cwd="${1:-.}" glob pre suf want lc_want names idx name d
  if [ -n "${OMK_AUTO_MEMORY_DIR:-}" ]; then
    d="$(omk_resolve_dir "$OMK_AUTO_MEMORY_DIR")"
    if [ -d "$d" ]; then printf '%s' "$d"; return 0; fi
  fi
  glob="${OMK_AUTO_MEMORY_GLOB:-}"
  case "$glob" in *'*'*) ;; *) return 0 ;; esac
  pre="${glob%%\**}"
  suf="${glob#*\*}"
  suf="${suf//\\//}"
  pre="$(omk_resolve_dir "$pre")"
  [ -d "$pre" ] || return 0
  want="$(omk_encode_path "$(omk_repo_root "$cwd")")"
  lc_want="$(printf %s "$want" | LC_ALL=C tr 'A-Z' 'a-z')"
  names="$(ls -1 "$pre" 2>/dev/null | tr -d '\r')"
  idx="$(printf '%s\n' "$names" | LC_ALL=C tr 'A-Z' 'a-z' | grep -nxF -- "$lc_want" | head -n 1 | cut -d: -f1)"
  [ -n "$idx" ] || return 0
  name="$(printf '%s\n' "$names" | sed -n "${idx}p")"
  if [ -d "$pre/$name$suf" ]; then printf '%s' "$(omk_resolve_dir "$pre/$name$suf")"; fi
  return 0
}

# omk_project_for_cwd <cwd>
omk_project_for_cwd() {
  omk_project_marker "$(omk_auto_memory_for_cwd "$1")"
}

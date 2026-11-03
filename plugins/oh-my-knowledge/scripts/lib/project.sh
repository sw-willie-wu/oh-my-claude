#!/bin/bash
# oh-my-knowledge project mapping: marker parser and auto-memory discovery.
# Source after lib/common.sh and after calling omk_config. Functions only.
# bash-3.2 compatible (no bash4-only constructs). Fork-lean on purpose: the
# SessionStart hook runs this on every session start (builtins only; no
# awk/wc/grep/sed/cut/head pipelines). Each public function is a thin printing
# wrapper over an _omk_*_into function that assigns by name, so a hook can call
# the _into form without a command substitution. An _into outvar name must never
# match a local of the callee (printf -v would write the callee's local, e.g.
# _omk_resolve_into declares _p _q _pre _dl _old _hadold _oo).

# _omk_marker_status_into <outvar> <auto-memory dir>
# The single parser for the project marker line in <dir>/MEMORY.md:
#   - Knowledge base project: [[k:projects/<p>/index]] (omk-project)
# (whole-line match anywhere in the file; CRLF, a BOM on the first line and a
# last line without a trailing newline are tolerated; prose is not a marker).
# Assigns exactly one of:
#   none                  no marker (or no MEMORY.md / empty dir argument)
#   ok <p>                exactly one distinct project and <kb>/projects/<p>/ exists
#   invalid multiple      two or more distinct projects named
#   invalid missing <p>   one project named but <kb>/projects/<p>/ does not exist
_omk_marker_status_into() {
  local LC_ALL=C
  local _dir="${2:-}" _line _p="" _first=1 _re _bom=$'\xef\xbb\xbf' _res
  if [ -z "$_dir" ] || [ ! -f "$_dir/MEMORY.md" ]; then printf -v "$1" '%s' none; return 0; fi
  _re='^- Knowledge base project: \[\[k:projects/([^]/]+)/index\]\] \(omk-project\)$'
  while IFS= read -r _line || [ -n "$_line" ]; do
    _line="${_line%$'\r'}"
    if [ "$_first" = 1 ]; then _first=0; _line="${_line#"$_bom"}"; fi
    if [[ "$_line" =~ $_re ]]; then
      if [ -z "$_p" ]; then
        _p="${BASH_REMATCH[1]}"
      elif [ "${BASH_REMATCH[1]}" != "$_p" ]; then
        printf -v "$1" '%s' 'invalid multiple'; return 0
      fi
    fi
  done < "$_dir/MEMORY.md"
  if [ -z "$_p" ]; then printf -v "$1" '%s' none; return 0; fi
  case "$_p" in
    "." | "..") printf -v "$1" '%s' "invalid missing $_p"; return 0 ;;
  esac
  if [ -d "${OMK_KNOWLEDGE_DIR:-}/projects/$_p" ]; then _res="ok $_p"; else _res="invalid missing $_p"; fi
  printf -v "$1" '%s' "$_res"
  return 0
}

omk_project_marker_status() {
  local _st
  _omk_marker_status_into _st "${1:-}"
  printf '%s' "$_st"
  return 0
}

# omk_project_marker <auto-memory dir>: <p> when the status is "ok <p>", else nothing.
omk_project_marker() {
  local _st
  _omk_marker_status_into _st "${1:-}"
  case "$_st" in "ok "*) printf '%s' "${_st#ok }" ;; esac
  return 0
}

# _omk_auto_memory_into <outvar> <cwd>: see omk_auto_memory_for_cwd; assigns "" when none.
_omk_auto_memory_into() {
  local _cwd="${2:-.}" _glob _gpre _suf _want _root _nat _ent _name _found="" _d _fold _nc _out=""
  printf -v "$1" '%s' ""
  if [ -n "${OMK_AUTO_MEMORY_DIR:-}" ]; then
    _omk_resolve_into _d "$OMK_AUTO_MEMORY_DIR"
    if [ -d "$_d" ]; then printf -v "$1" '%s' "$_d"; return 0; fi
  fi
  _glob="${OMK_AUTO_MEMORY_GLOB:-}"
  case "$_glob" in *'*'*) ;; *) return 0 ;; esac
  _gpre="${_glob%%\**}"
  _suf="${_glob#*\*}"
  _suf="${_suf//\\//}"
  _omk_resolve_into _gpre "$_gpre"
  [ -d "$_gpre" ] || return 0
  _root="$(omk_repo_root "$_cwd")"
  _nat="$(omk_native_path "$_root")"
  _want="$(omk_encode_name "$_nat")"
  # Exact on-disk name first. Never a bare [ -d ] as the match: it is
  # case-insensitive on Windows and macOS. The glob lists directories only.
  for _ent in "$_gpre"/*/; do
    _name="${_ent%/}"; _name="${_name##*/}"
    if [ "$_name" = "$_want" ]; then _found="$_name"; break; fi
  done
  if [ -z "$_found" ]; then
    # Case-insensitive fallback for Windows only (Claude Code may write the
    # drive letter in lower case). OMK_TEST_CASE_FOLD=0|1 overrides the OS
    # default; test-only seam.
    _fold=0
    case "${OSTYPE:-}" in msys*|cygwin*) _fold=1 ;; esac
    case "${OMK_TEST_CASE_FOLD:-}" in 0) _fold=0 ;; 1) _fold=1 ;; esac
    [ "$_fold" = 1 ] || return 0
    if shopt -q nocasematch; then _nc=1; else _nc=0; fi
    shopt -s nocasematch
    for _ent in "$_gpre"/*/; do
      _name="${_ent%/}"; _name="${_name##*/}"
      # shellcheck disable=SC2053
      if [[ "$_name" == "$_want" ]]; then _found="$_name"; break; fi
    done
    [ "$_nc" = 1 ] || shopt -u nocasematch
  fi
  [ -n "$_found" ] || return 0
  if [ -d "$_gpre/$_found$_suf" ]; then
    _omk_resolve_into _out "$_gpre/$_found$_suf"
    printf -v "$1" '%s' "$_out"
  fi
  return 0
}

# omk_auto_memory_for_cwd <cwd>
# OMK_AUTO_MEMORY_DIR if set and existing (normalised); else the dir under the
# OMK_AUTO_MEMORY_GLOB parent whose name equals omk_encode_path(omk_repo_root cwd);
# exact match first, then (Windows only) case-insensitive.
omk_auto_memory_for_cwd() {
  local _am
  _omk_auto_memory_into _am "${1:-.}"
  printf '%s' "$_am"
  return 0
}

# _omk_project_into <outvar> <cwd>: <p> when the cwd maps to "ok <p>", else "".
_omk_project_into() {
  local _am _st
  _omk_auto_memory_into _am "${2:-}"
  _omk_marker_status_into _st "$_am"
  case "$_st" in "ok "*) printf -v "$1" '%s' "${_st#ok }" ;; *) printf -v "$1" '%s' "" ;; esac
  return 0
}

# omk_project_for_cwd <cwd>
omk_project_for_cwd() {
  local _p
  _omk_project_into _p "${1:-}"
  printf '%s' "$_p"
  return 0
}

#!/bin/bash
# lint.sh [--checks structure|content|all]   (oh-my-knowledge health check, script stage)
# Prints one JSON document on stdout:
#   {"version":1,"generated":"YYYY-MM-DD","knowledge_dir":"...","findings":[{check,severity,file,line,detail}],
#    "groups":[{"name":"index:<slug>|project:<p>|family:<prefix>","pages":[rel paths]}]}
# Scope: rules/, global/, projects/, index.md (skips .git/, lint/, _retired/). Paths are KB-relative; line 0 = whole file.
# Symlinked files are skipped (find -type f). long_index_line looks at bullet lines of index.md / index_*.md files. Groups come only from the structure pass
# (--checks content returns none). Content/reference checks (lib/lint-content.awk) cover KB pages, auto memory
# (OMK_AUTO_MEMORY_GLOB) and OMK_CLAUDE_MD in one gawk pass. Any failing find/gawk is fatal (exit 1).
# Exit: 0 | 1 a pass failed | 2 usage error, KB, gawk or jq missing.
set -u
set -o pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
. "$HERE/lib/common.sh"
omk_config

USAGE="usage: lint.sh [--checks structure|content|all]"
CHECKS=all
while [ "$#" -gt 0 ]; do
  case "$1" in
    --checks) [ "$#" -ge 2 ] || { echo "$USAGE" >&2; exit 2; }; CHECKS="$2"; shift 2 ;;
    *) echo "$USAGE" >&2; exit 2 ;;
  esac
done
case "$CHECKS" in structure|content|all) ;; *) echo "$USAGE" >&2; exit 2 ;; esac
command -v gawk >/dev/null 2>&1 || { echo "lint.sh: gawk is required but was not found on PATH" >&2; exit 2; }
command -v "$OMK_JQ" >/dev/null 2>&1 || { echo "lint.sh: jq is required but was not found ($OMK_JQ)" >&2; exit 2; }
KB="$OMK_KNOWLEDGE_DIR"
[ -d "$KB" ] || { echo "lint.sh: knowledge base not found: $KB" >&2; exit 2; }

RAW="$(mktemp)" || exit 2
trap 'rm -f "$RAW"' EXIT
: > "$RAW"
if [ "$CHECKS" != content ]; then
  {
    find "$KB" -maxdepth 1 -type f -name '*.md' -printf '%s\0%p\0' || exit 1
    if [ -d "$KB/rules" ]; then find "$KB/rules" -name .git -prune -o -type f -printf '%s\0%p\0' || exit 1; fi
    for d in global projects; do
      if [ -d "$KB/$d" ]; then find "$KB/$d" \( -name .git -o -name _retired \) -prune -o -type f -name '*.md' -printf '%s\0%p\0' || exit 1; fi
    done
    for d in _retired lint; do   # existence only (link targets); no check runs on these pages
      if [ -d "$KB/$d" ]; then find "$KB/$d" -name .git -prune -o -type f -name '*.md' -printf '%s\0%p\0' || exit 1; fi
    done
  } | LC_ALL=C.UTF-8 OMK_LINT_ROOT="$KB" OMK_MAX_FILE_KB="$OMK_MAX_FILE_KB" OMK_MAX_INDEX_LINE_CHARS="$OMK_MAX_INDEX_LINE_CHARS" \
    gawk -f "$HERE/lib/lint-structure.awk" > "$RAW" || { echo "lint.sh: structural pass failed" >&2; exit 1; }
fi

if [ "$CHECKS" != structure ]; then
  QFILE="$(mktemp)" || exit 2
  trap 'rm -f "$RAW" "$QFILE"' EXIT
  : > "$QFILE"
  # auto-memory dirs from OMK_AUTO_MEMORY_GLOB: one '*' path component (same rule as omk_auto_memory_for_cwd)
  AMDIRS=()
  case "$OMK_AUTO_MEMORY_GLOB" in
    *'*'*)
      amg="$OMK_AUTO_MEMORY_GLOB"; ampre="${amg%%\**}"; amsuf="${amg#*\*}"; amsuf="${amsuf//\\//}"
      ampre="$(omk_resolve_dir "$ampre")"
      if [ -d "$ampre" ]; then
        for e in "$ampre"/*/; do
          [ -d "${e%/}$amsuf" ] && AMDIRS[${#AMDIRS[@]}]="${e%/}$amsuf"
        done
      fi ;;
    "") ;;
    *) [ -d "$OMK_AUTO_MEMORY_GLOB" ] && AMDIRS[0]="$(omk_resolve_dir "$OMK_AUTO_MEMORY_GLOB")" ;;
  esac
  CLAUDE_MD="$(omk_resolve_dir "$OMK_CLAUDE_MD")"
  CLAUDE_MD="$(omk_resolve_dir "${CLAUDE_MD%/*}")/${CLAUDE_MD##*/}"
  WINP=0
  case "${OSTYPE:-}" in msys*|cygwin*) WINP=1 ;; esac
  # case-insensitive file system? (Windows, default macOS): probe the KB dir itself; OMK_LINT_ICASE=0|1 overrides
  ICASE="${OMK_LINT_ICASE:-}"
  case "$ICASE" in 0|1) ;; *)
    ICASE=0
    kb_b="${KB##*/}"; kb_u="$(printf %s "$kb_b" | tr 'a-z' 'A-Z')"
    [ "$kb_u" = "$kb_b" ] && kb_u="$(printf %s "$kb_b" | tr 'A-Z' 'a-z')"
    if [ "$kb_u" != "$kb_b" ] && [ -d "${KB%/*}/$kb_u" ] && [ "${KB%/*}/$kb_u" -ef "$KB" ]; then ICASE=1; fi ;;
  esac
  {
    find "$KB" -maxdepth 1 -type f -name '*.md' -printf 'K\0%p\0' || exit 1
    for d in rules global projects; do
      if [ -d "$KB/$d" ]; then find "$KB/$d" \( -name .git -o -name _retired \) -prune -o -type f -name '*.md' -printf 'K\0%p\0' || exit 1; fi
    done
    for d in _retired lint; do   # existence only (link targets); no check runs on these pages
      if [ -d "$KB/$d" ]; then find "$KB/$d" -name .git -prune -o -type f -name '*.md' -printf 'X\0%p\0' || exit 1; fi
    done
    if [ -d "$KB/projects" ]; then find "$KB/projects" -mindepth 1 -maxdepth 1 -xtype d -printf 'D\0%f\0' || exit 1; fi
    if [ "${#AMDIRS[@]}" -gt 0 ]; then find "${AMDIRS[@]}" -maxdepth 1 -type f -name '*.md' -printf 'A\0%p\0' || exit 1; fi
    if [ -f "$CLAUDE_MD" ]; then printf 'C\0%s\0' "$CLAUDE_MD"; fi
  } | LC_ALL=C.UTF-8 OMK_LINT_ROOT="$KB" OMK_LINT_QFILE="$QFILE" OMK_LINT_WINPATHS="$WINP" OMK_LINT_ICASE="$ICASE" OMK_TODAY="$OMK_TODAY" \
    OMK_LINT_STALE_DAYS="$OMK_LINT_STALE_DAYS" OMK_LINT_FLAG_DAYS="$OMK_LINT_FLAG_DAYS" \
    gawk -f "$HERE/lib/lint-content.awk" >> "$RAW" || { echo "lint.sh: content pass failed" >&2; exit 1; }
  # missing_path: candidate ~/ paths are tested here with the [ -e ] builtin (no forks)
  while IFS=$'\t' read -r qf ql qp; do
    case "$qp" in "~/"*) ;; *) continue ;; esac
    [ -e "$HOME/${qp#\~/}" ] || printf 'F\tmissing_path\tblue\t%s\t%s\t%s does not exist\n' "$qf" "$ql" "$qp" >> "$RAW"
  done < "$QFILE"
fi

"$OMK_JQ" -Rn --arg gen "$OMK_TODAY" --arg kb "$(omk_native_path "$KB")" '
  [inputs | rtrimstr("\r") | split("\t")] as $r
  | {version: 1, generated: $gen, knowledge_dir: $kb,
     findings: [$r[] | select(.[0] == "F") | {check: .[1], severity: .[2], file: .[3], line: (.[4] | tonumber), detail: .[5]}],
     groups: [$r[] | select(.[0] == "G") | {name: .[1], pages: .[2:]}]}' < "$RAW" | tr -d '\r' || { echo "lint.sh: JSON shaping failed" >&2; exit 1; }
exit 0

#!/bin/bash
# lint.sh [--checks structure|content|all]   (oh-my-knowledge health check, script stage)
# Prints one JSON document on stdout:
#   {"version":1,"generated":"YYYY-MM-DD","knowledge_dir":"...","findings":[{check,severity,file,line,detail}],
#    "groups":[{"name":"index:<slug>|project:<p>|family:<prefix>","pages":[rel paths]}]}
# Scope: rules/, global/, projects/, index.md (skips .git/, lint/, _retired/). Paths are KB-relative; line 0 = whole file.
# long_index_line looks at bullet lines of index.md / index_*.md files. Groups come only from the structure pass
# (--checks content returns none); Task 5 adds content checks and merges them here. Any failing find/gawk is fatal (exit 1).
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
  } | LC_ALL=C.UTF-8 OMK_LINT_ROOT="$KB" OMK_MAX_FILE_KB="$OMK_MAX_FILE_KB" OMK_MAX_INDEX_LINE_CHARS="$OMK_MAX_INDEX_LINE_CHARS" \
    gawk -f "$HERE/lib/lint-structure.awk" > "$RAW" || { echo "lint.sh: structural pass failed" >&2; exit 1; }
fi

"$OMK_JQ" -Rn --arg gen "$OMK_TODAY" --arg kb "$(omk_native_path "$KB")" '
  [inputs | rtrimstr("\r") | split("\t")] as $r
  | {version: 1, generated: $gen, knowledge_dir: $kb,
     findings: [$r[] | select(.[0] == "F") | {check: .[1], severity: .[2], file: .[3], line: (.[4] | tonumber), detail: .[5]}],
     groups: [$r[] | select(.[0] == "G") | {name: .[1], pages: .[2:]}]}' < "$RAW" | tr -d '\r' || { echo "lint.sh: JSON shaping failed" >&2; exit 1; }
exit 0

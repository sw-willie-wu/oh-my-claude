#!/bin/bash
# search.sh <keyword>...   (oh-my-knowledge lookup engine)
# Fixed-string, any-keyword match over: global/, projects/<p>/ (when the current
# repo is migrated: valid marker) and the current auto-memory dir. ASCII keywords
# are also tried in lower and upper case (no grep -i: UTF-8 safe). Frontmatter is
# searched too (descriptions carry trigger keywords). Never searches rules/,
# _retired/, lint/. Stub files (body only "> Moved: [[target]], ..." lines) are skipped.
#
# Output (directories shown in native form):
#   == knowledge base: <dir>
#   == index hits                 global index files (index.md, index_*.md): rel:line:text
#   == topic hits (file:count)    other global files: rel:count, most hits first
#   == project: <name> | (not migrated)   then, when migrated, projects/<p>/ hits
#   == auto memory: <dir> | (none)        then hits (MEMORY.md counts as an index file)
#   no hits                       last line when nothing matched anywhere
# Index-type lines are `rel:line:text`, other files `rel:count`. Caps: 40 index
# lines and 15 topic files per section, lines cut to 260 characters; a capped
# sub-list ends with `… N more index lines` or `… N more files`.
# Exit: 0 (also for "no hits") | 1 a search tool failed | 2 usage error, KB or gawk missing.
set -u
set -o pipefail
if ! command -v gawk >/dev/null 2>&1; then
  echo "search.sh: gawk is required but was not found on PATH" >&2
  exit 2
fi
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
. "$HERE/lib/common.sh"
# shellcheck source=lib/project.sh
. "$HERE/lib/project.sh"
omk_config

if [ "$#" -lt 1 ]; then
  echo "usage: search.sh <keyword>..." >&2
  exit 2
fi
KB="$OMK_KNOWLEDGE_DIR"
[ -d "$KB" ] || { echo "search.sh: knowledge base not found: $KB" >&2; exit 2; }

# Pattern list: each keyword plus its ASCII lower/upper variants, newline-separated.
PATS=""
for kw in "$@"; do
  [ -n "$kw" ] || continue
  lo="$(printf %s "$kw" | LC_ALL=C tr 'A-Z' 'a-z')"
  up="$(printf %s "$kw" | LC_ALL=C tr 'a-z' 'A-Z')"
  PATS="$PATS$kw"$'\n'"$lo"$'\n'"$up"$'\n'
done
if [ -z "$PATS" ]; then
  echo "usage: search.sh <keyword>..." >&2
  exit 2
fi
export OMK_SEARCH_PATS="$PATS"

# scan <root> <output prefix>: one gawk pass over every *.md below root
# (rules/_retired/lint pruned below the root only). Emits "I<TAB>pfx+rel:line:text" for index-type files
# (index.md, index_*.md, MEMORY.md) and "T<TAB>pfx+rel:count" for the rest.
# Stub files emit nothing. Root and prefix travel via ENVIRON (no -v escape processing).
scan() {
  local root="$1"
  while [ "${#root}" -gt 1 ] && [ "${root%/}" != "$root" ]; do root="${root%/}"; done
  find "$root" -mindepth 1 \( -name rules -o -name _retired -o -name lint \) -prune -o -type f -name '*.md' -print0 \
    | LC_ALL=C.UTF-8 OMK_SCAN_ROOT="$root" OMK_SCAN_PFX="$2" xargs -0 gawk '
      BEGIN {
        n = split(ENVIRON["OMK_SEARCH_PATS"], raw, "\n")
        for (i = 1; i <= n; i++) if (raw[i] != "") pats[++np] = raw[i]
        root = ENVIRON["OMK_SCAN_ROOT"]; pfx = ENVIRON["OMK_SCAN_PFX"]
        rl = length(root)
      }
      BEGINFILE { fm = 0; ln = 0; body = 0; moved = 0; cnt = 0; nh = 0 }
      {
        ln++
        line = $0; sub(/\r$/, "", line)
        infm = 0
        if (ln == 1 && line == "---") { fm = 1; infm = 1 }
        else if (fm) { infm = 1; if (line == "---") fm = 0 }
        if (!infm && line !~ /^[ \t]*$/) {
          body++
          if (line ~ /^> Moved: \[\[[^]]+\]\](, *\[\[[^]]+\]\])* *$/) moved++
        }
        for (i = 1; i <= np; i++) if (index(line, pats[i]) > 0) { cnt++; hit[++nh] = ln ":" line; break }
      }
      ENDFILE {
        skip = (cnt == 0 || (body > 0 && moved == body))
        if (!skip) {
          rel = pfx substr(FILENAME, rl + 2)
          b = rel; sub(/.*\//, "", b)
          if (b == "index.md" || b == "MEMORY.md" || b ~ /^index_.*\.md$/) {
            for (i = 1; i <= nh; i++) print "I\t" substr(rel ":" hit[i], 1, 260)
          } else print "T\t" rel ":" cnt
        }
      }
    ' \
    | LC_ALL=C sort -s -t: -k1,1
}

# sel <tag> <scan output>: payload of lines with that tag
sel() { printf '%s\n' "$2" | sed -n "s/^$1	//p"; }

# put <cap> <label> <text>: print the first <cap> lines of text, then "… N more <label>" if capped
put() {
  local n
  [ -n "$3" ] || return 0
  n="$(printf '%s\n' "$3" | wc -l | tr -d ' ')"
  printf '%s\n' "$3" | head -n "$1"
  if [ "$n" -gt "$1" ]; then printf '… %s more %s\n' "$((n - $1))" "$2"; fi
  return 0
}
ranked() { printf '%s\n' "$1" | sed '/^$/d' | LC_ALL=C sort -t: -k2,2nr -k1,1; }

GLOBAL_OUT=""
if [ -d "$KB/global" ]; then GLOBAL_OUT="$(scan "$KB/global" "global/")" || { echo "search.sh: search failed" >&2; exit 1; }; fi
AM="$(omk_auto_memory_for_cwd "$PWD")"
PROJ="$(omk_project_marker "$AM")"
PROJ_OUT=""
if [ -n "$PROJ" ]; then PROJ_OUT="$(scan "$KB/projects/$PROJ" "projects/$PROJ/")" || { echo "search.sh: search failed" >&2; exit 1; }; fi
AM_OUT=""
if [ -n "$AM" ]; then AM_OUT="$(scan "$AM" "")" || { echo "search.sh: search failed" >&2; exit 1; }; fi

echo "== knowledge base: $(omk_native_path "$KB")"
echo "== index hits"
put 40 "index lines" "$(sel I "$GLOBAL_OUT")"
echo "== topic hits (file:count)"
put 15 "files" "$(ranked "$(sel T "$GLOBAL_OUT")")"
if [ -n "$PROJ" ]; then echo "== project: $PROJ"; else echo "== project: (not migrated)"; fi
put 40 "index lines" "$(sel I "$PROJ_OUT")"; put 15 "files" "$(ranked "$(sel T "$PROJ_OUT")")"
if [ -n "$AM" ]; then echo "== auto memory: $(omk_native_path "$AM")"; else echo "== auto memory: (none)"; fi
put 40 "index lines" "$(sel I "$AM_OUT")"; put 15 "files" "$(ranked "$(sel T "$AM_OUT")")"
if [ -z "$GLOBAL_OUT$PROJ_OUT$AM_OUT" ]; then echo "no hits"; fi
exit 0

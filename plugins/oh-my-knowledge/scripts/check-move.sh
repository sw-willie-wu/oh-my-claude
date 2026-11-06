#!/bin/bash
# check-move.sh [--spans-only] <original> <target>...     (oh-my-knowledge: did the literal [[ in code survive a move?)
#
# After a harvest moves text from an auto-memory file (the backup copy is <original>) into knowledge-base
# page(s) <target>..., this checks that every inline code span and every fenced line holding "[[" in the
# original body arrived in the targets unchanged. Needs no knowledge base; reads files only.
#   - CR and a leading BOM are stripped from every file; frontmatter of the original and of the targets
#     is ignored (only bodies count, for presence and for size).
#   - From the original body: (i) every inline code span containing "[[", delimiters included (a run of
#     N backticks closes at the next run of exactly N; an unmatched run is literal); (ii) every line inside
#     a ``` / ~~~ fence that contains "[[", compared whitespace-trimmed.
#   - Present = the span is a substring of the targets' bodies together; the fence line equals some
#     trimmed target body line. Missing items are printed as "missing <original line>: <item>".
#   - Size (skipped with --spans-only): the targets' bodies (bytes, LC_ALL=C) under 50% of the original
#     body -> "small: <target bytes>/<original bytes>".
#   - An original with an empty body has nothing to check: exit 0.
# Exit: 0 ok | 1 missing items | 3 only "small" (3 is NOT success: read both files) | 2 usage, an unreadable
#       file, gawk missing, or a file whose frontmatter is never closed (line 1 is "---" and no later "---";
#       the file is named on stderr).
# Limits: inline code spans that continue across lines and 4-space-indented code blocks are not covered
# (lint's suspect_link_rewrite and reading are the backstop). Presence is a substring test without counting:
# if the original holds the same span twice and only one copy arrives intact, it passes.
set -u
if ! command -v gawk >/dev/null 2>&1; then
  echo "check-move.sh: gawk is required but was not found on PATH" >&2
  exit 2
fi
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
USAGE="usage: check-move.sh [--spans-only] <original> <target>..."
SIZES=1
if [ "${1:-}" = "--spans-only" ]; then SIZES=0; shift; fi
[ "$#" -ge 2 ] || { echo "$USAGE" >&2; exit 2; }
for f in "$@"; do
  [ -f "$f" ] && [ -r "$f" ] || { echo "check-move.sh: cannot read: $f" >&2; exit 2; }
done
orig="$1"; shift
LC_ALL=C gawk -v sizes="$SIZES" -f "$HERE/lib/md-spans.awk" -f "$HERE/lib/check-move.awk" "$orig" "$@"
rc=$?
case "$rc" in 0|1|3) exit "$rc" ;; *) exit 2 ;; esac

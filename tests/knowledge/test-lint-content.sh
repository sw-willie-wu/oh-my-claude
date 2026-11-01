#!/bin/bash
# Tests for oh-my-knowledge scripts/lint.sh content/reference checks and lib/lint-content.awk.
set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(dirname "$(dirname "$SCRIPT_DIR")")"
# shellcheck source=../test-helpers.sh
. "$REPO_ROOT/tests/test-helpers.sh"

PLUGIN="$REPO_ROOT/plugins/oh-my-knowledge"
LINT="$PLUGIN/scripts/lint.sh"
AWKF="$PLUGIN/scripts/lib/lint-content.awk"
FIXKB="$SCRIPT_DIR/fixtures/kb-content"
FIXAM="$SCRIPT_DIR/fixtures/auto-memory"

for v in $(compgen -e | grep -E '^(OMK_|CLAUDE_PLUGIN_OPTION_|CLAUDE_CONFIG_DIR$)'); do unset "$v"; done
T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
export HOME="$T/home"; mkdir -p "$HOME"
export GIT_CONFIG_GLOBAL="$T/gitconfig-empty"; : > "$GIT_CONFIG_GLOBAL"
export GIT_CONFIG_NOSYSTEM=1
export OMC_STATE_DIR="$T/state"
export CLAUDE_CONFIG_DIR="$T/cc"; mkdir -p "$CLAUDE_CONFIG_DIR"
export OMK_TODAY="2026-10-30"
JQ="${REAL_JQ:-jq}"

KB="$T/kb"; cp -r "$FIXKB" "$KB"
AM="$T/am"; cp -r "$FIXAM" "$AM"
export OMK_AUTO_MEMORY_GLOB="$AM/*/memory"
export OMK_CLAUDE_MD="$AM/CLAUDE.md"
mkdir -p "$HOME/omk-fixture-present"; : > "$HOME/omk-fixture-present/y.txt"

# run <kb> [args...]: lint.sh output in $T/out (CR stripped), RC
run() { local k="$1"; shift; OMK_KNOWLEDGE_DIR="$k" bash "$LINT" "$@" >"$T/out" 2>"$T/err"; RC=$?; tr -d '\r' < "$T/out" > "$T/o2"; mv "$T/o2" "$T/out"; }
q() { "$JQ" -r "$1" "$T/out" | tr -d '\r'; }
# finding <check> <file>: "severity:line" of the single matching finding, or "none"/"many"
finding() {
  local n
  n="$("$JQ" -r --arg c "$1" --arg f "$2" '[.findings[] | select(.check == $c and .file == $f)] | length' "$T/out" | tr -d '\r')"
  case "$n" in 0) echo none ;; 1) "$JQ" -r --arg c "$1" --arg f "$2" '.findings[] | select(.check == $c and .file == $f) | "\(.severity):\(.line)"' "$T/out" | tr -d '\r' ;; *) echo many ;; esac
}
detail() { "$JQ" -r --arg c "$1" --arg f "$2" '[.findings[] | select(.check == $c and .file == $f) | .detail] | join(" | ")' "$T/out" | tr -d '\r'; }
lines_of() { "$JQ" -r --arg c "$1" --arg f "$2" '[.findings[] | select(.check == $c and .file == $f) | .line] | sort | map(tostring) | join(",")' "$T/out" | tr -d '\r'; }
files_of() { "$JQ" -r --arg c "$1" '[.findings[] | select(.check == $c) | .file] | sort | join(" ")' "$T/out" | tr -d '\r'; }
count_check() { "$JQ" -r --arg c "$1" '[.findings[] | select(.check == $c)] | length' "$T/out" | tr -d '\r'; }
RES() { bash -c '. "$1"; omk_native_path "$2"' _ "$PLUGIN/scripts/lib/common.sh" "$1" | tr -d '\r'; }
has() { case "$1" in *"$2"*) return 0 ;; esac; echo "    FAIL: $3 (missing: $2 in: $1)" >&2; TEST_FAILED=1; return 1; }
hasnt() { case "$1" in *"$2"*) echo "    FAIL: $3 (unexpected: $2 in: $1)" >&2; TEST_FAILED=1; return 1 ;; esac; return 0; }
# fresh <dir>: minimal KB skeleton
fresh() { rm -rf "$1"; mkdir -p "$1/rules" "$1/global" "$1/projects/a" "$1/projects/b"; printf '# KB\n' > "$1/index.md"; }
page() { printf -- '---\nname: %s\ndescription: d\nmetadata:\n  type: reference\n  verified: 2026-10-20\n  evidence: tested\n---\n%s\n' "$2" "${3:-body}" > "$1"; }
# runc <kb> <am-glob-parent> [args]: run with a custom auto-memory tree and no CLAUDE.md
runc() { local k="$1" g="$2"; shift 2; OMK_AUTO_MEMORY_GLOB="$g/*/memory" OMK_CLAUDE_MD="$T/no-claude.md" run "$k" "$@"; }

start_test "lint-content.awk exists; bash-3.2 guard on lint.sh"
[ -f "$AWKF" ] || { echo "    FAIL: missing lint-content.awk" >&2; TEST_FAILED=1; }
if grep -nE '\$\{[A-Za-z_]+(\^\^|,,)|declare +-A|\bmapfile\b|\breadarray\b' "$LINT" >/dev/null 2>&1; then
  echo "    FAIL: bash4-only construct in lint.sh" >&2; TEST_FAILED=1
fi
end_test

run "$KB" --checks content
assert_eq 0 "$RC" "fixture content run exit"

start_test "progress_leak: reported lines, not URLs/code/headings/#N alone"
assert_eq "10,11,12,13" "$(lines_of progress_leak global/leaks.md)" "LEAK1..4 only"
assert_eq "yellow" "$(q '[.findings[] | select(.check=="progress_leak")][0].severity')" "severity yellow"
assert_eq 4 "$(count_check progress_leak)" "no other progress_leak in the fixture"
end_test

start_test "stale: verified old + version words; fresh / plain / no-version are not stale"
assert_eq "blue:9" "$(finding stale global/stale-old.md)" "uses v1.2 is stale (first matching line)"
assert_eq "blue:9" "$(finding stale global/stale-words.md)" "目前 is a staleness word"
assert_eq none "$(finding stale global/stale-fresh.md)" "fresh verified"
assert_eq none "$(finding stale global/stale-plain.md)" "1.5 秒 is not a version"
assert_eq 2 "$(count_check stale)" "exactly two stale"
end_test

start_test "unverified_overdue: older than OMK_LINT_FLAG_DAYS only"
assert_eq "9" "$(lines_of unverified_overdue global/flags.md)" "old flag only"
assert_eq "yellow:9" "$(finding unverified_overdue global/flags.md)" "yellow"
OMK_LINT_FLAG_DAYS=3 run "$KB" --checks content
assert_eq "9,10" "$(lines_of unverified_overdue global/flags.md)" "threshold from env"
run "$KB" --checks content
end_test

start_test "missing_path: absent ~/ path reported; present, placeholder and non-path skipped"
assert_eq "blue:9" "$(finding missing_path global/paths.md)" "one missing path"
has "$(detail missing_path global/paths.md)" "~/omk-fixture-missing/x.txt" "detail names the path" || true
assert_eq 1 "$(count_check missing_path)" "only one"
end_test

start_test "stub_unreferenced: unreferenced stubs only; KB, auto-memory and CLAUDE.md references count"
assert_eq "global/stub-orphan.md projects/b/stub-b.md" "$(files_of stub_unreferenced)" "orphan stubs"
assert_eq "blue:0" "$(finding stub_unreferenced global/stub-orphan.md)" "blue"
end_test

start_test "ext_link_missing: [[g:]] and [[k:]] from auto memory and CLAUDE.md"
CLMD="$(RES "$AM")/CLAUDE.md"
assert_eq "red:2" "$(finding ext_link_missing "$CLMD")" "CLAUDE.md [[g:no-such-global]]"
EXT1="$(RES "$AM/one/memory")"
assert_eq "red:7" "$(finding ext_link_missing "$EXT1/MEMORY.md")" "auto memory [[k:global/no-such-ext]] (only the missing one)"
has "$(detail ext_link_missing "$EXT1/MEMORY.md")" "k:global/no-such-ext" "detail" || true
assert_eq 5 "$(count_check ext_link_missing)" "claude(1) + one(1) + two(3)"
end_test

start_test "auto_memory_link_broken: [[x]] and (x.md) inside the memory dir; stubs and existing files fine"
assert_eq "4,5" "$(lines_of auto_memory_link_broken "$EXT1/MEMORY.md")" "gone-note and missing-file.md"
assert_eq 2 "$(count_check auto_memory_link_broken)" "nothing else"
end_test

start_test "unharvested_auto_memory: per dir; mapped vs unmapped text; stubs/project/unlisted handled"
assert_eq "blue:0" "$(finding unharvested_auto_memory "$EXT1")" "mapped dir finding"
assert_eq "to harvest: 3 new entries" "$(detail unharvested_auto_memory "$EXT1")" "fb1 + ref1 (metadata.type) + user1 (not listed); not project/mixed/blank-line stub; not omk: always-on (top level ao-top, under metadata: ao-meta) nor always-on-declined (ao-declined)"
EXT2="$(RES "$AM/two/memory")"
assert_eq "not migrated: 2 knowledge entries" "$(detail unharvested_auto_memory "$EXT2")" "unmapped dir (stub excluded)"
assert_eq 2 "$(count_check unharvested_auto_memory)" "one finding per dir"
end_test

start_test "project_marker_missing: harvested lines / Moved stubs to projects/<p>/; plain cross-refs do not count"
assert_eq "yellow:0" "$(finding project_marker_missing "$EXT2")" "dir two"
assert_eq "a, b" "$(detail project_marker_missing "$EXT2")" "both inferred projects listed"
assert_eq 1 "$(count_check project_marker_missing)" "valid-marker dir not reported"
assert_eq 0 "$(count_check project_marker_invalid)" "no invalid in fixture"
assert_eq 0 "$(count_check project_marker_misplaced)" "no misplaced in fixture"
end_test

start_test "promote_candidate: cross-project [[k:projects/a/...]] from a non-stub page only"
assert_eq "projects/a/page-a.md" "$(files_of promote_candidate)" "only page-a"
assert_eq "blue:0" "$(finding promote_candidate projects/a/page-a.md)" "blue"
has "$(detail promote_candidate projects/a/page-a.md)" "b" "names linking project" || true
end_test

start_test "no structural checks or groups from --checks content; --checks structure has no content checks"
assert_eq "[]" "$("$JQ" -c .groups "$T/out" | tr -d '\r')" "content-only: groups empty"
assert_eq 0 "$(q '[.findings[] | select(.check == "orphan" or .check == "broken_link" or .check == "not_indexed")] | length')" "no structural finding"
run "$KB" --checks structure
assert_eq 0 "$(q '[.findings[] | select(.check == "stale" or .check == "progress_leak" or .check == "stub_unreferenced" or .check == "ext_link_missing")] | length')" "structure-only has no content checks"
run "$KB" --checks all
assert_eq 1 "$(q '[.findings[] | select(.check == "orphan")] | length > 0 | if . then 1 else 0 end')" "all includes structure"
assert_eq 2 "$(count_check stale)" "all includes content"
end_test

start_test "project marker regex: gawk pass agrees with omk_project_marker_status on every variant"
M="$T/markers"; rm -rf "$M"; mkdir -p "$M"
fresh "$T/kbm"
MK='- Knowledge base project: [[k:projects/%s/index]] (omk-project)'
mkmem() { mkdir -p "$M/$1/memory"; printf -- '---\nname: fb\ndescription: d\ntype: feedback\n---\nx\n' > "$M/$1/memory/fb.md"; }
mkmem m-ok;      printf "# M\n$MK\n" a > "$M/m-ok/memory/MEMORY.md"
mkmem m-none;    printf '# M\n- nothing\n' > "$M/m-none/memory/MEMORY.md"
mkmem m-multi;   printf -- "$MK\n$MK\n" a b > "$M/m-multi/memory/MEMORY.md"
mkmem m-missing; printf -- "$MK\n" zzz > "$M/m-missing/memory/MEMORY.md"
mkmem m-crlf;    printf "# M\r\n$MK\r\n" a > "$M/m-crlf/memory/MEMORY.md"
mkmem m-prose;   printf 'Use the line "- Knowledge base project: [[k:projects/a/index]] (omk-project)" to map.\n' > "$M/m-prose/memory/MEMORY.md"
mkmem m-trail;   printf -- "$MK \n" a > "$M/m-trail/memory/MEMORY.md"
mkmem m-indent;  printf -- " $MK\n" a > "$M/m-indent/memory/MEMORY.md"
mkmem m-dup;     printf -- "$MK\n$MK\n" a a > "$M/m-dup/memory/MEMORY.md"
mkmem m-dotdot;  printf -- '- Knowledge base project: [[k:projects/../index]] (omk-project)\n' > "$M/m-dotdot/memory/MEMORY.md"
mkmem m-nomem
mkmem m-subpath; printf -- '- Knowledge base project: [[k:projects/a/b/index]] (omk-project)\n' > "$M/m-subpath/memory/MEMORY.md"
mkmem m-wrongtail; printf -- '- Knowledge base project: [[k:projects/a/index]] (omk-projects)\n' > "$M/m-wrongtail/memory/MEMORY.md"
mkmem m-bomless; printf -- "$MK\n- Knowledge base project: [[k:projects/b/index]] (omk-project) extra\n" a > "$M/m-bomless/memory/MEMORY.md"
mkmem m-bom-ok;   printf '\xef\xbb\xbf'"$MK"'\n' a > "$M/m-bom-ok/memory/MEMORY.md"
mkmem m-bom-none; printf '\xef\xbb\xbf# M\n- nothing\n' > "$M/m-bom-none/memory/MEMORY.md"
mkmem m-bom-l2;   printf '# M\n\xef\xbb\xbf'"$MK"'\n' a > "$M/m-bom-l2/memory/MEMORY.md"
mkmem m-case;     printf -- "$MK\n" A > "$M/m-case/memory/MEMORY.md"
runc "$T/kbm" "$M"
for d in m-ok m-none m-multi m-missing m-crlf m-prose m-trail m-indent m-dup m-dotdot m-nomem m-subpath m-wrongtail m-bomless m-bom-ok m-bom-none m-bom-l2 m-case; do
  dp="$(RES "$M/$d/memory")"
  ST="$(OMK_KNOWLEDGE_DIR="$T/kbm" bash -c '. "$1"; . "$2"; omk_project_marker_status "$3"' _ "$PLUGIN/scripts/lib/common.sh" "$PLUGIN/scripts/lib/project.sh" "$dp" | tr -d '\r')"
  case "$ST" in
    "ok "*) EXP_U="to harvest: 1 new entries"; EXP_I="none" ;;
    "invalid multiple") EXP_U="not migrated: 1 knowledge entries"; EXP_I="more than one project" ;;
    "invalid missing "*) EXP_U="not migrated: 1 knowledge entries"; EXP_I="does not exist" ;;
    *) EXP_U="not migrated: 1 knowledge entries"; EXP_I="none" ;;
  esac
  assert_eq "$EXP_U" "$(detail unharvested_auto_memory "$dp")" "$d ($ST): mapped state"
  GOT_I="$(detail project_marker_invalid "$dp/MEMORY.md")"
  if [ "$EXP_I" = none ]; then assert_eq "" "$GOT_I" "$d ($ST): no invalid finding"; else has "$GOT_I" "$EXP_I" "$d ($ST): invalid finding" || true; fi
done
end_test

start_test "project_marker_invalid: two distinct projects; project that does not exist"
D1="$(RES "$M/m-multi/memory")"
D2="$(RES "$M/m-missing/memory")"
assert_eq "yellow:1" "$(finding project_marker_invalid "$D1/MEMORY.md")" "multiple (line of the first marker)"
has "$(detail project_marker_invalid "$D1/MEMORY.md")" "a, b" "lists both" || true
has "$(detail project_marker_invalid "$D2/MEMORY.md")" "projects/zzz/" "names missing project" || true
assert_eq 0 "$(count_check project_marker_missing)" "no distill links: nothing inferred"
assert_eq none "$(finding ext_link_missing "$D2/MEMORY.md")" "the marker line itself is not an ext_link_missing"
printf -- '- when X -> [[k:projects/a/deploy]] (omk-harvested)\n' >> "$M/m-missing/memory/MEMORY.md"
runc "$T/kbm" "$M"
assert_eq "a" "$(detail project_marker_missing "$D2")" "invalid marker + harvested links is also 'missing' (R10)"
has "$(detail project_marker_invalid "$D2/MEMORY.md")" "projects/zzz/" "and still invalid" || true
end_test

start_test "project_marker_missing: only a Moved stub, two inferred projects, cross-ref only, harvested line without link target"
rm -rf "$M"; mkdir -p "$M/s1/memory" "$M/s2/memory" "$M/s3/memory" "$M/s4/memory"
printf -- '---\nname: x\ndescription: d\ntype: feedback\n---\n> Moved: [[k:projects/a/gone]], [[k:projects/b/gone2]]\n' > "$M/s1/memory/x.md"
printf -- '# M\n- see [[k:projects/a/y]] for background\n' > "$M/s2/memory/MEMORY.md"
printf -- '# M\n- thing -> [[g:glob]] (omk-harvested)\n' > "$M/s3/memory/MEMORY.md"
printf -- '---\nname: x\ndescription: d\ntype: feedback\n---\n> Moved: [[g:glob]]\n' > "$M/s4/memory/x.md"
runc "$T/kbm" "$M"
S1="$(RES "$M/s1/memory")"
assert_eq "a, b" "$(detail project_marker_missing "$S1")" "Moved stub with two projects (no MEMORY.md at all)"
assert_eq 1 "$(count_check project_marker_missing)" "cross-ref, [[g:]] harvested and [[g:]] stub are not inferred"
end_test

start_test "project_marker_misplaced: marker on line 201 (blue), line 200 is fine"
rm -rf "$M"; mkdir -p "$M/p1/memory" "$M/p2/memory"
{ for i in $(seq 1 200); do echo "- filler $i"; done; printf -- '- Knowledge base project: [[k:projects/a/index]] (omk-project)\n'; } > "$M/p1/memory/MEMORY.md"
{ for i in $(seq 1 199); do echo "- filler $i"; done; printf -- '- Knowledge base project: [[k:projects/a/index]] (omk-project)\n'; } > "$M/p2/memory/MEMORY.md"
runc "$T/kbm" "$M"
P1="$(RES "$M/p1/memory")"
P2="$(RES "$M/p2/memory")"
assert_eq "blue:201" "$(finding project_marker_misplaced "$P1/MEMORY.md")" "line 201"
assert_eq none "$(finding project_marker_misplaced "$P2/MEMORY.md")" "line 200"
end_test

start_test "CRLF stubs/pages: stub with CRLF counts as stub; links and progress still seen"
fresh "$T/kbc"; rm -rf "$M"; mkdir -p "$M/c1/memory"
printf -- '---\r\nname: s\r\ndescription: d\r\n---\r\n\r\n> Moved: [[k:global/t]]\r\n' > "$T/kbc/global/s.md"
page "$T/kbc/global/t.md" t "待審 here"
printf -- '---\r\nname: u\r\ndescription: d\r\ntype: feedback\r\n---\r\n\r\n> Moved: [[k:global/t]]\r\n' > "$M/c1/memory/u.md"
runc "$T/kbc" "$M"
assert_eq "global/s.md" "$(files_of stub_unreferenced)" "CRLF KB stub recognised"
assert_eq 0 "$(count_check unharvested_auto_memory)" "CRLF auto-memory stub is not counted"
assert_eq "yellow:9" "$(finding progress_leak global/t.md)" "progress in body"
end_test

start_test "stale boundary: exactly OMK_LINT_STALE_DAYS old is not stale; one more day is"
fresh "$T/kbs"
printf -- '---\nname: s1\ndescription: d\nmetadata:\n  type: reference\n  verified: 2026-08-01\n  evidence: tested\n---\nv2.0 here\n' > "$T/kbs/global/s1.md"   # 90 days
printf -- '---\nname: s2\ndescription: d\nmetadata:\n  type: reference\n  verified: 2026-07-31\n  evidence: tested\n---\nv2.0 here\n' > "$T/kbs/global/s2.md"   # 91 days
printf -- '---\nname: s3\ndescription: d\ntype: reference\nverified: 2026-01-01\nevidence: tested\n---\nAs Of now, 3.4.5 is used\n' > "$T/kbs/global/s3.md"
runc "$T/kbs" "$T/none"
assert_eq none "$(finding stale global/s1.md)" "90 days"
assert_eq "blue:9" "$(finding stale global/s2.md)" "91 days"
assert_eq "blue:8" "$(finding stale global/s3.md)" "top-level verified + 3-part version"
end_test

start_test "a stub referenced from an unrelated project dir or by [[slug]] is referenced; self-link is not"
fresh "$T/kbr"
printf -- '---\nname: s\ndescription: d\n---\n> Moved: [[s]]\n' > "$T/kbr/global/s.md"
runc "$T/kbr" "$T/none"
assert_eq "blue:0" "$(finding stub_unreferenced global/s.md)" "self-reference is not an inbound reference"
printf -- 'See [[s]]\n' > "$T/kbr/global/index_x.md"
runc "$T/kbr" "$T/none"
assert_eq none "$(finding stub_unreferenced global/s.md)" "[[slug]] from the KB"
end_test

start_test "failures are fatal: failing find or gawk exits 1 with no JSON"
mkdir -p "$T/failbin"
printf '#!/bin/bash\nexit 1\n' > "$T/failbin/find"; chmod +x "$T/failbin/find"
(PATH="$T/failbin:$PATH" OMK_KNOWLEDGE_DIR="$KB" bash "$LINT" --checks content >"$T/fout" 2>"$T/ferr"); FRC=$?
assert_eq 1 "$FRC" "failing find"
assert_eq 0 "$(grep -c findings "$T/fout")" "no JSON (find)"
rm -f "$T/failbin/find"
printf '#!/bin/bash\ncat >/dev/null\nexit 1\n' > "$T/failbin/gawk"; chmod +x "$T/failbin/gawk"
(PATH="$T/failbin:$PATH" OMK_KNOWLEDGE_DIR="$KB" bash "$LINT" --checks content >"$T/fout" 2>"$T/ferr"); FRC=$?
assert_eq 1 "$FRC" "failing gawk"
assert_eq 0 "$(grep -c findings "$T/fout")" "no JSON (gawk)"
end_test

start_test "performance: 1000 topics + ~100 auto-memory files, --checks all"
P="$T/perf"; fresh "$P"
mkdir -p "$P/projects/p1"
gawk -v root="$P" 'BEGIN {
  for (i = 1; i <= 1000; i++) {
    g = (i % 2 == 0) ? "global" : "projects/p1"
    s = sprintf("t%04d", i)
    f = root "/" g "/" s ".md"
    j = (i % 1000) + 1; j = (j % 1000) + 1
    printf "---\nname: %s\ndescription: topic %d about widgets\nmetadata:\n  type: reference\n  verified: 2026-10-01\n  evidence: tested\n---\nBody of %s. See [[t%04d]] (same folder) and [[k:%s/t%04d]].\n", s, i, s, j, g, j > f
    close(f)
    ix = root "/" g "/index_perf_" int((i - 1) / 100) ".md"
    printf "- [[%s]] — trigger %d -> conclusion -> link\n", s, i >> ix
  }
for (b = 0; b < 10; b++) { printf "- [[g:index_perf_%d]] — shard\n- [[k:projects/p1/index_perf_%d]] — shard\n", b, b >> (root "/index.md") }
}'
PA="$T/perfam"; mkdir -p "$PA"
gawk -v root="$PA" 'BEGIN {
  for (d = 1; d <= 10; d++) {
    dir = root "/proj" d "/memory"; system("mkdir -p \"" dir "\"")
    f = dir "/MEMORY.md"
    printf "# M\n- Knowledge base project: [[k:projects/p1/index]] (omk-project)\n" > f
    for (k = 1; k <= 9; k++) {
      printf "- [[n%d]] note %d (n%d.md)\n", k, k, k >> f
      g = dir "/n" k ".md"
      printf "---\nname: n%d\ndescription: d\ntype: %s\n---\nnote body [[k:global/t%04d]]\n", k, (k % 3 == 0 ? "feedback" : "project"), 2 * k > g
      close(g)
    }
    close(f)
  }
}'
printf -- '# P\n' > "$P/projects/p1/index.md"
START=$SECONDS
OMK_AUTO_MEMORY_GLOB="$PA/*/memory" OMK_CLAUDE_MD="$T/no-claude.md" run "$P" --checks all
ELAPSED=$((SECONDS - START))
echo "    timing: ${ELAPSED}s --checks all for $(find "$P" -name '*.md' | wc -l | tr -d ' ') KB md files + $(find "$PA" -name '*.md' | wc -l | tr -d ' ') auto-memory files" >&2
assert_eq 0 "$RC" "exit"
if [ "$ELAPSED" -ge 60 ]; then echo "    FAIL: ${ELAPSED}s >= 60s" >&2; TEST_FAILED=1; fi
assert_eq 10 "$(count_check unharvested_auto_memory)" "10 dirs with knowledge entries (mapped)"
assert_eq 0 "$(count_check ext_link_missing)" "no false ext_link_missing"
assert_eq 0 "$(count_check auto_memory_link_broken)" "no false auto_memory_link_broken"
end_test

start_test "_retired/ and lint/ pages exist as link targets (no false ext_link_missing); nothing else runs on them"
fresh "$T/kbx"; mkdir -p "$T/kbx/_retired/2026-10-30/harvested/enc" "$T/kbx/lint"
printf -- '待審 old note\n' > "$T/kbx/_retired/2026-10-30/harvested/enc/x.md"
printf -- '待審 report\n' > "$T/kbx/lint/lint-2026-10-30.md"
rm -rf "$T/amx"; mkdir -p "$T/amx/p/memory"
printf -- '---\nname: x\ndescription: d\ntype: feedback\n---\n> Moved: [[k:_retired/2026-10-30/harvested/enc/x]]\n' > "$T/amx/p/memory/x.md"
printf -- 'See [[k:lint/lint-2026-10-30]] and [[k:_retired/2026-10-30/nope]]\n' > "$T/amx/p/memory/MEMORY.md"
runc "$T/kbx" "$T/amx"
AX="$(RES "$T/amx/p/memory")"
assert_eq 1 "$(count_check ext_link_missing)" "only the really missing retired target"
has "$(detail ext_link_missing "$AX/MEMORY.md")" "_retired/2026-10-30/nope" "names the missing one" || true
assert_eq 0 "$(count_check progress_leak)" "no check runs on _retired/ or lint/"
end_test

start_test "stale words are whole words; a.b.c.d is not a version; versions and 3-part still are"
fresh "$T/kbw"
sp() { printf -- '---\nname: %s\ndescription: d\nmetadata:\n  type: reference\n  verified: %s\n  evidence: tested\n---\n%s\n' "$1" "$2" "$3" > "$T/kbw/global/$1.md"; }
sp w-offline 2026-01-01 "the server was offline"
sp w-conc 2026-01-01 "ran concurrently"
sp w-ip 2026-01-01 "host 10.0.0.1 answers"
sp w-ver3 2026-01-01 "released as 1.2.3."
sp w-cur 2026-01-01 "Current setting is x"
sp w-asof 2026-01-01 "valid as of May"
sp w-v4 2026-01-01 "tool v10.0.0.1 here"
runc "$T/kbw" "$T/none"
for n in w-offline w-conc w-ip; do assert_eq none "$(finding stale global/$n.md)" "$n not stale"; done
for n in w-ver3 w-cur w-asof w-v4; do assert_eq "blue:9" "$(finding stale global/$n.md)" "$n stale"; done
end_test

start_test "dates: invalid verified is old; trailing comment stripped; invalid / unpadded UNVERIFIED date is overdue"
fresh "$T/kbd"
sd() { printf -- '---\nname: %s\ndescription: d\nmetadata:\n  type: reference\n  verified: %s\n  evidence: tested\n---\n%s\n' "$1" "$2" "$3" > "$T/kbd/global/$1.md"; }
sd d-1345 "2026-13-45" "latest"
sd d-0230 "2026-02-30" "latest"
sd d-junk "soon" "latest"
sd d-cmt-fresh "2026-10-20  # checked" "latest"
sd d-cmt-old "2026-01-01  # checked" "latest"
sd d-flag1 "2026-10-20" "> ⚠ UNVERIFIED (2025-1-5): x; evidence: y"
sd d-flag2 "2026-10-20" "> ⚠ UNVERIFIED (2026-02-30): x; evidence: y"
sd d-flag3 "2026-10-20" "> ⚠ UNVERIFIED (2026-10-25): x; evidence: y"
runc "$T/kbd" "$T/none"
for n in d-1345 d-0230 d-junk d-cmt-old; do assert_eq "blue:9" "$(finding stale global/$n.md)" "$n stale"; done
assert_eq none "$(finding stale global/d-cmt-fresh.md)" "comment stripped, fresh date"
has "$(detail stale global/d-1345.md)" "not a valid date" "message" || true
assert_eq "yellow:9" "$(finding unverified_overdue global/d-flag1.md)" "unpadded"
assert_eq "yellow:9" "$(finding unverified_overdue global/d-flag2.md)" "impossible date"
assert_eq none "$(finding unverified_overdue global/d-flag3.md)" "valid recent"
end_test

start_test "fences: a 4-backtick block is not closed by a 3-backtick line; ~~~ does not close backticks"
fresh "$T/kbf"
{ printf -- '---\nname: f\ndescription: d\nmetadata:\n  type: reference\n  verified: 2026-10-20\n  evidence: tested\n---\n'
  printf '%s\n' '````' '待審 a' '```' '待審 b' '~~~' '待審 c' '````' '待審 outside' '```' '待審 d' '~~~' '待審 e' '```' '待審 outside2'
} > "$T/kbf/global/f.md"
runc "$T/kbf" "$T/none"
assert_eq "16,22" "$(lines_of progress_leak global/f.md)" "only the lines outside both fences"
end_test

start_test "references from inbox.md and log.md count toward stub_unreferenced"
fresh "$T/kbi"
printf -- '---\nname: s1\ndescription: d\n---\n> Moved: [[k:global/s2]]\n' > "$T/kbi/global/s1.md"
printf -- '---\nname: s2\ndescription: d\n---\n> Moved: [[k:global/s1]]\n' > "$T/kbi/global/s2.md"
printf -- '---\nname: s3\ndescription: d\n---\n> Moved: [[k:global/s1]]\n' > "$T/kbi/global/s3.md"
printf -- '- [[s3]] seen\n' > "$T/kbi/inbox.md"
printf -- '## [2026-10-30] x | [[k:global/s2]]\n' > "$T/kbi/log.md"
runc "$T/kbi" "$T/none"
assert_eq 0 "$(count_check stub_unreferenced)" "s3 via inbox.md, s2 via log.md, s1 via the others"
printf -- '待審 here\n' >> "$T/kbi/log.md"
runc "$T/kbi" "$T/none"
assert_eq 0 "$(count_check progress_leak)" "inbox/log content is not otherwise checked"
end_test

start_test "auto_memory_link_broken is case-insensitive on Windows (msys/cygwin) only"
rm -rf "$T/amc"; mkdir -p "$T/amc/p/memory"; fresh "$T/kbc2"
printf -- '- [[Note]] x\n' > "$T/amc/p/memory/MEMORY.md"; printf -- 'body\n' > "$T/amc/p/memory/note.md"
runc "$T/kbc2" "$T/amc"
case "${OSTYPE:-}" in
  msys*|cygwin*) assert_eq 0 "$(count_check auto_memory_link_broken)" "Note == note on Windows" ;;
  *) assert_eq 1 "$(count_check auto_memory_link_broken)" "Note != note elsewhere" ;;
esac
end_test

start_test "stale detail quotes only the version text; UNVERIFIED without a date is overdue"
fresh "$T/kbq"
printf -- '---\nname: q1\ndescription: d\nmetadata:\n  type: reference\n  verified: 2026-01-01\n  evidence: tested\n---\nruns node 18.2.1, fine\n' > "$T/kbq/global/q1.md"
printf -- '---\nname: q2\ndescription: d\nmetadata:\n  type: reference\n  verified: 2026-10-20\n  evidence: tested\n---\n> ⚠ UNVERIFIED: maybe; evidence: none\n> ⚠ UNVERIFIEDX not a flag\n' > "$T/kbq/global/q2.md"
runc "$T/kbq" "$T/none"
has "$(detail stale global/q1.md)" "mentions '18.2.1'" "clean version text" || true
assert_eq "yellow:9" "$(finding unverified_overdue global/q2.md)" "undated flag (and not the UNVERIFIEDX line)"
has "$(detail unverified_overdue global/q2.md)" "no date" "detail" || true
end_test

start_test "OMK_LINT_ICASE override: marker projects/A/ vs folder a is mapped only when case-insensitive"
rm -rf "$T/kbi2" "$T/ami"; fresh "$T/kbi2"; mkdir -p "$T/ami/p/memory"
printf -- '- Knowledge base project: [[k:projects/A/index]] (omk-project)\n' > "$T/ami/p/memory/MEMORY.md"
printf -- '---\nname: fb\ndescription: d\ntype: feedback\n---\nx\n' > "$T/ami/p/memory/fb.md"
DI="$(RES "$T/ami/p/memory")"
OMK_LINT_ICASE=1 runc "$T/kbi2" "$T/ami"; assert_eq "to harvest: 1 new entries" "$(detail unharvested_auto_memory "$DI")" "icase=1"
OMK_LINT_ICASE=0 runc "$T/kbi2" "$T/ami"; assert_eq "not migrated: 1 knowledge entries" "$(detail unharvested_auto_memory "$DI")" "icase=0"
end_test

print_summary

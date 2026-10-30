#!/bin/bash
# Tests for oh-my-knowledge scripts/lint.sh (structure checks) and lib/lint-structure.awk.
set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(dirname "$(dirname "$SCRIPT_DIR")")"
# shellcheck source=../test-helpers.sh
. "$REPO_ROOT/tests/test-helpers.sh"

PLUGIN="$REPO_ROOT/plugins/oh-my-knowledge"
LINT="$PLUGIN/scripts/lint.sh"
AWKF="$PLUGIN/scripts/lib/lint-structure.awk"
TPL="$PLUGIN/templates"
FIX="$SCRIPT_DIR/fixtures/kb-lint"

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

KB="$T/kb"; cp -r "$FIX" "$KB"

# run <kb> [args...]: lint.sh output in $T/out (CR stripped), RC
run() { local k="$1"; shift; OMK_KNOWLEDGE_DIR="$k" bash "$LINT" "$@" >"$T/out" 2>"$T/err"; RC=$?; tr -d '\r' < "$T/out" > "$T/o2"; mv "$T/o2" "$T/out"; }
# q <jq filter>: filter applied to $T/out
q() { "$JQ" -r "$1" "$T/out" | tr -d '\r'; }
# finding <check> <file>: "severity:line" of the single matching finding, or "none"/"many"
finding() {
  local n
  n="$("$JQ" -r --arg c "$1" --arg f "$2" '[.findings[] | select(.check == $c and .file == $f)] | length' "$T/out" | tr -d '\r')"
  case "$n" in 0) echo none ;; 1) "$JQ" -r --arg c "$1" --arg f "$2" '.findings[] | select(.check == $c and .file == $f) | "\(.severity):\(.line)"' "$T/out" | tr -d '\r' ;; *) echo many ;; esac
}
detail() { "$JQ" -r --arg c "$1" --arg f "$2" '[.findings[] | select(.check == $c and .file == $f) | .detail] | join(" | ")' "$T/out" | tr -d '\r'; }
count_check() { "$JQ" -r --arg c "$1" '[.findings[] | select(.check == $c)] | length' "$T/out" | tr -d '\r'; }
nfind() { q '.findings | length'; }
qc() { "$JQ" -c "$1" "$T/out" | tr -d '\r'; }
has() { case "$1" in *"$2"*) return 0 ;; esac; echo "    FAIL: $3 (missing: $2 in: $1)" >&2; TEST_FAILED=1; return 1; }
# fresh <dir>: minimal clean KB skeleton (meta files only)
fresh() { rm -rf "$1"; mkdir -p "$1/rules" "$1/global" "$1/projects"; cp "$TPL/index.md" "$1/index.md"; cp "$TPL/rules-INDEX.md" "$1/rules/INDEX.md"; }
# page <file> <name> [extra body]: valid page
page() { printf -- '---\nname: %s\ndescription: d\nmetadata:\n  type: reference\n  verified: 2026-10-01\n  evidence: tested\n---\n%s\n' "$2" "${3:-body}" > "$1"; }

start_test "lint.sh and lint-structure.awk exist; bash-3.2 guard"
[ -f "$LINT" ] && [ -f "$AWKF" ] || { echo "    FAIL: missing lint.sh/lint-structure.awk" >&2; TEST_FAILED=1; }
if [ -f "$LINT" ] && grep -nE '\$\{[A-Za-z_]+(\^\^|,,)|declare +-A|\bmapfile\b|\breadarray\b' "$LINT" >/dev/null 2>&1; then
  echo "    FAIL: bash4-only construct in lint.sh" >&2; TEST_FAILED=1
fi
end_test

start_test "usage errors and missing KB exit 2"
run "$KB" --bogus; assert_eq 2 "$RC" "unknown flag"
run "$KB" --checks nope; assert_eq 2 "$RC" "bad --checks value"
run "$KB" --checks; assert_eq 2 "$RC" "--checks without value"
run "$T/nokb"; assert_eq 2 "$RC" "missing KB"
end_test

run "$KB"
assert_eq 0 "$RC" "fixture run exit"

start_test "JSON header: version, generated, knowledge_dir"
assert_eq 1 "$(q .version)" "version"
assert_eq 2026-10-30 "$(q .generated)" "generated = OMK_TODAY"
assert_eq "string" "$(q '.knowledge_dir | type')" "knowledge_dir string"
assert_eq "$(bash -c '. "$1"; omk_native_path "$2"' _ "$PLUGIN/scripts/lib/common.sh" "$KB" | tr -d '\r')" "$(q .knowledge_dir)" "knowledge_dir is the exact native KB path"
assert_eq "[\"check\",\"detail\",\"file\",\"line\",\"severity\"]" "$(qc '[.findings[0] | keys[]]')" "finding object keys"
assert_eq "array" "$(q '.findings | type')" "findings array"
assert_eq "array" "$(q '.groups | type')" "groups array"
end_test

start_test "broken_link red with file and line"
assert_eq "red:9" "$(finding broken_link global/broken_link.md)" "broken_link"
has "$(detail broken_link global/broken_link.md)" "no_such_page" "detail names target" || true
end_test

start_test "broken_link: every target of a multi-target > Moved: line is checked"
assert_eq "red:9" "$(finding broken_link global/broken_link_stub.md)" "second target missing"
has "$(detail broken_link global/broken_link_stub.md)" "stub_missing_target" "detail" || true
assert_eq none "$(finding broken_link global/moved-multi.md)" "valid multi-target stub"
assert_eq none "$(finding broken_link global/moved-single.md)" "valid single-target stub"
end_test

start_test "link resolution: same folder then global/, g:, k:; code spans, fences, comments ignored"
assert_eq none "$(finding broken_link global/tool-c.md)" "code span, fence and comment links ignored"
assert_eq none "$(finding broken_link projects/alpha/deploy.md)" "[[g:ops-deploy]]"
assert_eq none "$(finding broken_link projects/beta/setup.md)" "[[g:tool-b]]"
assert_eq none "$(finding broken_link global/ops-deploy.md)" "[[k:projects/beta/setup]]"
assert_eq none "$(finding broken_link global/tool-a.md)" "same-folder [[tool-b]]"
printf '%s\n' '---' 'name: x1' 'description: d' 'metadata:' '  type: project' '  verified: 2026-10-01' '  evidence: tested' '---' 'global fallback [[tool-a]] and own [[x2]]' > "$KB/projects/beta/x1.md"
page "$KB/projects/beta/x2.md" x2
run "$KB"
assert_eq none "$(finding broken_link projects/beta/x1.md)" "project page resolves own folder then global/"
rm -f "$KB/projects/beta/x1.md" "$KB/projects/beta/x2.md"
end_test

start_test "missing_page blue replaces broken_links (>=3 links)"
assert_eq "blue:9" "$(finding missing_page global/missing_page.md)" "missing_page at first link"
assert_eq none "$(finding broken_link global/missing_page.md)" "its broken_links are replaced"
has "$(detail missing_page global/missing_page.md)" "ghost_page" "detail" || true
end_test

start_test "duplicate_name red (same folder only)"
assert_eq "red:0" "$(finding duplicate_name projects/alpha/duplicate_name_2.md)" "second file flagged"
assert_eq none "$(finding duplicate_name projects/alpha/duplicate_name.md)" "first file not flagged"
assert_eq "red:0" "$(finding name_mismatch projects/alpha/duplicate_name_2.md)" "also a mismatch"
assert_eq 1 "$(count_check duplicate_name)" "only one duplicate_name finding"
end_test

start_test "name_mismatch red"
assert_eq "red:0" "$(finding name_mismatch global/name_mismatch.md)" "name_mismatch"
has "$(detail name_mismatch global/name_mismatch.md)" "something_else" "detail" || true
end_test

start_test "orphan and not_indexed yellow; rules/, stubs and meta exempt"
assert_eq "yellow:0" "$(finding orphan global/orphan.md)" "orphan"
assert_eq none "$(finding orphan global/not_indexed.md)" "linked from a page: not orphan"
assert_eq "yellow:0" "$(finding not_indexed global/not_indexed.md)" "not_indexed"
assert_eq "yellow:0" "$(finding not_indexed global/orphan.md)" "orphan also not indexed"
assert_eq none "$(finding orphan global/moved-multi.md)" "stub exempt (orphan)"
assert_eq none "$(finding not_indexed global/moved-single.md)" "stub exempt (not_indexed)"
assert_eq none "$(finding orphan rules/rule-two.md)" "rules exempt (orphan)"
assert_eq none "$(finding not_indexed rules/rule-two.md)" "rules exempt (not_indexed)"
assert_eq none "$(finding orphan global/index_ops.md)" "index file exempt"
assert_eq none "$(finding orphan index.md)" "root index exempt"
end_test

start_test "rules_not_in_index yellow, rules_import_missing red"
assert_eq "yellow:0" "$(finding rules_not_in_index rules/rules_not_in_index.md)" "rules_not_in_index"
assert_eq none "$(finding rules_not_in_index rules/rule-one.md)" "imported rule"
assert_eq 1 "$(count_check rules_not_in_index)" "only one rule missing from INDEX"
assert_eq "red:9" "$(finding rules_import_missing rules/INDEX.md)" "import of a nonexistent file"
has "$(detail rules_import_missing rules/INDEX.md)" "rules_import_missing.md" "detail" || true
end_test

start_test "rules/INDEX.md: real template example (@my-rule.md in a code span) is not an import"
fresh "$T/kb2"
run "$T/kb2"
assert_eq "[]" "$(qc .findings)" "template INDEX alone reports nothing"
page "$T/kb2/rules/my-rule.md" my-rule
run "$T/kb2"
assert_eq "yellow:0" "$(finding rules_not_in_index rules/my-rule.md)" "my-rule really is missing from INDEX"
assert_eq 0 "$(count_check rules_import_missing)" "example not reported as missing import"
printf '@my-rule.md\n' >> "$T/kb2/rules/INDEX.md"
run "$T/kb2"
assert_eq "[]" "$(qc .findings)" "import line added: clean"
end_test

start_test "rules/INDEX.md: absolute imports reported; fenced and inline imports ignored; nested relative path"
fresh "$T/kb3"
mkdir -p "$T/kb3/rules/sub"
page "$T/kb3/rules/sub/deep.md" deep
{ printf '@sub/deep.md\n@~/knowledge/rules/x.md\n@/etc/x.md\n'; printf '```\n@in-fence.md\n```\n'; printf 'text @inline.md more\n@./sub/../sub/deep.md\n'; } >> "$T/kb3/rules/INDEX.md"
run "$T/kb3"
assert_eq 2 "$(count_check rules_import_missing)" "two absolute imports"
has "$(q '[.findings[] | select(.check == "rules_import_missing") | .detail] | join("|")')" "absolute" "absolute wording" || true
assert_eq 0 "$(count_check rules_not_in_index)" "nested rule found via relative import"
end_test

start_test "missing_frontmatter yellow; metadata.type and top-level type both accepted"
run "$KB"
assert_eq "yellow:0" "$(finding missing_frontmatter global/missing_frontmatter.md)" "no frontmatter"
assert_eq none "$(finding missing_frontmatter global/moved-multi.md)" "stub exempt"
assert_eq none "$(finding missing_frontmatter global/index_tools.md)" "meta exempt"
assert_eq none "$(finding missing_frontmatter rules/INDEX.md)" "rules/INDEX.md exempt"
fresh "$T/kb4"
printf -- '---\nname: top-type\ndescription: d\ntype: feedback\nverified: 2026-10-01\nevidence: tested\n---\nbody\n' > "$T/kb4/global/top-type.md"
printf -- '---\nname: no-type\ndescription: d\nmetadata:\n  verified: 2026-10-01\n  evidence: tested\n---\nbody\n' > "$T/kb4/global/no-type.md"
printf -- '---\nname: no-ev\ndescription: d\nmetadata:\n  type: user\n---\nbody\n' > "$T/kb4/global/no-ev.md"
run "$T/kb4"
assert_eq none "$(finding missing_frontmatter global/top-type.md)" "top-level type"
assert_eq "yellow:0" "$(finding missing_frontmatter global/no-type.md)" "no type anywhere"
has "$(detail missing_frontmatter global/no-type.md)" "type" "detail names type" || true
has "$(detail missing_frontmatter global/no-ev.md)" "verified evidence" "detail names verified and evidence" || true
end_test

start_test "oversize yellow (> OMK_MAX_FILE_KB)"
run "$KB"
assert_eq "yellow:0" "$(finding oversize global/oversize.md)" "oversize"
assert_eq 1 "$(count_check oversize)" "only the big page"
OMK_MAX_FILE_KB=20 run "$KB"
assert_eq 0 "$(count_check oversize)" "limit raised"
end_test

start_test "long_index_line blue: characters, not bytes"
run "$KB"
assert_eq "blue:3" "$(finding long_index_line global/index_long_index_line.md)" "long ascii index line"
fresh "$T/kb5"
assert_eq 1 "$(count_check long_index_line)" "other index lines fine"
{ printf '# Idx\n\n- '; i=0; while [ $i -lt 148 ]; do printf '中'; i=$((i+1)); done; printf '\n'; } > "$T/kb5/global/index_cjk.md"
run "$T/kb5"
assert_eq 0 "$(count_check long_index_line)" "150 CJK characters (450 bytes) not flagged"
end_test

start_test "long_index_line boundary: 200 chars ok, 201 flagged (CJK)"
fresh "$T/kb5"
{ printf '# Idx\n\n- '; i=0; while [ $i -lt 197 ]; do printf '中'; i=$((i+1)); done; printf 'a\n'; } > "$T/kb5/global/index_a.md"
{ printf '# Idx\n\n- '; i=0; while [ $i -lt 198 ]; do printf '中'; i=$((i+1)); done; printf 'a\n'; } > "$T/kb5/global/index_b.md"
run "$T/kb5"
assert_eq none "$(finding long_index_line global/index_a.md)" "200 characters"
assert_eq "blue:3" "$(finding long_index_line global/index_b.md)" "201 characters"
end_test

start_test "slug_shadows_global blue"
run "$KB"
assert_eq "blue:0" "$(finding slug_shadows_global projects/beta/slug_shadows_global.md)" "project slug equals global slug"
assert_eq none "$(finding slug_shadows_global global/slug_shadows_global.md)" "global side not flagged"
end_test

start_test "exempt areas: log/inbox/SCHEMA, _retired, lint never reported"
run "$KB"
assert_eq 0 "$(q '[.findings[] | select(.file | test("^(log|inbox|SCHEMA)\\.md$|^_retired/|^lint/"))] | length')" "no findings from exempt files"
end_test

start_test "missing_page needs >=3 links; two links stay broken_link"
fresh "$T/kb6"
page "$T/kb6/global/a.md" a "[[ghost]] and [[ghost]]"
page "$T/kb6/global/b.md" b "just [[ghost2]]"
run "$T/kb6"
assert_eq 2 "$("$JQ" -r '[.findings[] | select(.check == "broken_link" and .file == "global/a.md")] | length' "$T/out" | tr -d "\r")" "both links stay broken_link"
assert_eq 0 "$(count_check missing_page)" "no missing_page"
end_test

start_test "clean control: fixture minus violation files reports nothing"
fresh "$T/kb7"
rm -rf "$T/kb7"; cp -r "$FIX" "$T/kb7"
for f in global/broken_link global/broken_link_stub global/missing_page projects/alpha/duplicate_name projects/alpha/duplicate_name_2 \
  global/name_mismatch global/orphan global/not_indexed global/missing_frontmatter global/oversize global/index_long_index_line \
  global/slug_shadows_global projects/beta/slug_shadows_global rules/rules_not_in_index; do rm -f "$T/kb7/$f.md"; done
grep -v 'rules_import_missing' "$T/kb7/rules/INDEX.md" > "$T/idx" && cp "$T/idx" "$T/kb7/rules/INDEX.md"
run "$T/kb7"
assert_eq "[]" "$(qc .findings)" "findings == []"
end_test

start_test "groups: index, project and family"
run "$KB"
assert_eq "global/tool-a.md global/tool-b.md global/tool-c.md" "$(q '.groups[] | select(.name == "index:index_tools") | .pages | join(" ")')" "index group pages"
assert_eq "projects/alpha/deploy.md projects/alpha/duplicate_name.md projects/alpha/duplicate_name_2.md projects/alpha/notes.md" "$(q '.groups[] | select(.name == "project:alpha") | .pages | sort | join(" ")')" "project group"
assert_eq "global/tool-a.md global/tool-b.md global/tool-c.md" "$(q '.groups[] | select(.name == "family:tool") | .pages | sort | join(" ")')" "family group (>=3)"
assert_eq 0 "$(q '[.groups[] | select(.name == "family:ops" or .name == "family:rule" or .name == "family:moved")] | length')" "families below 3 or stubs/rules absent"
end_test

start_test "empty skeleton and CRLF input"
fresh "$T/kb8"
run "$T/kb8"
assert_eq "[]" "$(qc .findings)" "skeleton: []"
assert_eq "[]" "$(qc .groups)" "skeleton: no groups"
rm -rf "$T/kb8"; mkdir -p "$T/kb8"
run "$T/kb8"
assert_eq 0 "$RC" "totally empty KB dir"
assert_eq "[]" "$(qc .findings)" "empty dir: []"
fresh "$T/kb8"
printf -- '---\r\nname: crlf\r\ndescription: d\r\nmetadata:\r\n  type: user\r\n  verified: 2026-10-01\r\n  evidence: tested\r\n---\r\nbody\r\n' > "$T/kb8/global/crlf.md"
printf -- '- [[crlf]] x\r\n' >> "$T/kb8/index.md"
run "$T/kb8"
assert_eq "[]" "$(qc .findings)" "CRLF page clean"
end_test

start_test "--checks structure|content|all"
run "$KB" --checks structure; S1="$(q '.findings | length')"
run "$KB" --checks all; S2="$(q '.findings | length')"
assert_eq "$S1" "$S2" "all includes structure"
run "$KB" --checks content; assert_eq 0 "$RC" "content exit"; assert_eq 0 "$(q '.findings | length')" "content-only: no structural findings yet"
assert_eq 1 "$(q .version)" "content-only keeps shape"
end_test

start_test "performance: 1000 topics + indexes, structure checks < 60 s, 0 findings"
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
n = 0
for (b = 0; b < 10; b++) { printf "- [[g:index_perf_%d]] — shard\n- [[k:projects/p1/index_perf_%d]] — shard\n", b, b >> (root "/index.md") }
}'
START=$SECONDS
run "$P" --checks structure
ELAPSED=$((SECONDS - START))
echo "    timing: ${ELAPSED}s for $(find "$P" -name '*.md' | wc -l | tr -d ' ') md files" >&2
assert_eq 0 "$RC" "exit"
if [ "$ELAPSED" -ge 60 ]; then echo "    FAIL: ${ELAPSED}s >= 60s" >&2; TEST_FAILED=1; fi
assert_eq 0 "$(nfind)" "0 findings"
if [ "$(nfind)" != 0 ]; then qc ".findings[:3]" >&2; fi
end_test

start_test "find failure is fatal: exit 1 and no JSON"
mkdir -p "$T/failbin"
printf '#!/bin/bash\nexit 1\n' > "$T/failbin/find"; chmod +x "$T/failbin/find"
(PATH="$T/failbin:$PATH" OMK_KNOWLEDGE_DIR="$KB" bash "$LINT" >"$T/fout" 2>"$T/ferr"); FRC=$?
assert_eq 1 "$FRC" "exit code with failing find"
assert_eq 0 "$(grep -c findings "$T/fout")" "no JSON on stdout"
end_test

start_test "not_indexed applies to index files (not root index.md); R8: meta index = index.md / index_*.md only"
fresh "$T/kb9"
mkdir -p "$T/kb9/projects/p"
page "$T/kb9/global/topic.md" topic
printf -- '- [[topic]] — t\n' > "$T/kb9/global/index_x.md"
printf -- '- [[topic]] — t\n' > "$T/kb9/projects/p/index.md"
page "$T/kb9/global/indexing-tips.md" indexing-tips
run "$T/kb9"
assert_eq "yellow:0" "$(finding not_indexed global/index_x.md)" "sub-index not linked from root"
assert_eq "yellow:0" "$(finding not_indexed projects/p/index.md)" "project index not linked"
assert_eq none "$(finding not_indexed index.md)" "root index exempt"
assert_eq none "$(finding not_indexed rules/INDEX.md)" "rules/INDEX.md exempt"
assert_eq "yellow:0" "$(finding orphan global/indexing-tips.md)" "indexing-tips is a normal page (orphan)"
assert_eq "yellow:0" "$(finding not_indexed global/indexing-tips.md)" "indexing-tips is a normal page (not indexed)"
printf -- '- [[g:index_x]] — x\n- [[k:projects/p/index]] — p\n' >> "$T/kb9/index.md"
printf -- '- [[indexing-tips]] — i\n' >> "$T/kb9/global/index_x.md"
run "$T/kb9"
assert_eq "[]" "$(qc .findings)" "linked from root: clean"
end_test

start_test "fences: ~~~ inside a backtick fence does not close it; later links still seen"
fresh "$T/kb10"
printf -- '---\nname: f1\ndescription: d\nmetadata:\n  type: user\n  verified: 2026-10-01\n  evidence: tested\n---\n```\n~~~\n[[hidden1]]\n```\nvisible [[broken1]]\n~~~\n[[hidden2]]\n~~~\n[[broken2]]\n' > "$T/kb10/global/f1.md"
run "$T/kb10"
assert_eq "[[broken1]] [[broken2]]" "$(q '[.findings[] | select(.check == "broken_link") | .detail | split(" ")[0]] | join(" ")')" "only the links outside fences are reported"
end_test

start_test "UTF-8 BOM before frontmatter"
fresh "$T/kb11"
printf '\xef\xbb\xbf---\nname: bom\ndescription: d\nmetadata:\n  type: user\n  verified: 2026-10-01\n  evidence: tested\n---\nbody\n' > "$T/kb11/global/bom.md"
printf -- '- [[bom]] x\n' > "$T/kb11/global/index_b.md"; printf -- '- [[g:index_b]] x\n' >> "$T/kb11/index.md"
run "$T/kb11"
assert_eq "[]" "$(qc .findings)" "BOM page has frontmatter"
end_test

start_test "missing_page key is the resolved path ([[ghost]] and [[g:ghost]] together)"
fresh "$T/kb12"
page "$T/kb12/global/m1.md" m1 "[[ghost]] and [[g:ghost]] and [[g:ghost]]"
run "$T/kb12"
assert_eq 1 "$(count_check missing_page)" "one missing_page"
assert_eq 0 "$(count_check broken_link)" "broken_links replaced"
end_test

start_test "rules/ stub is not reported as rules_not_in_index"
fresh "$T/kb13"
page "$T/kb13/global/real.md" real
printf -- '> Moved: [[g:real]]\n' > "$T/kb13/rules/old-rule.md"
run "$T/kb13"
assert_eq 0 "$(count_check rules_not_in_index)" "stub in rules/"
end_test

start_test "empty frontmatter values count as missing"
fresh "$T/kb14"
printf -- '---\nname: e1\ndescription: ""\nmetadata:\n  type: user\n  verified: 2026-10-01\n  evidence: tested\n---\nb\n' > "$T/kb14/global/e1.md"
printf -- '---\nname: e2\ndescription:\nmetadata:\n  type: user\n  verified: 2026-10-01\n  evidence: tested\n---\nb\n' > "$T/kb14/global/e2.md"
printf -- '---\nname: e3\ndescription: >\n  folded text\nmetadata:\n  type: user\n  verified: 2026-10-01\n  evidence: tested\n---\nb\n' > "$T/kb14/global/e3.md"
printf -- '---\nname: e4\ndescription:\n  continued plain\nmetadata:\n  type: user\n  verified: 2026-10-01\n  evidence: tested\n---\nb\n' > "$T/kb14/global/e4.md"
run "$T/kb14"
assert_eq "yellow:0" "$(finding missing_frontmatter global/e1.md)" "description: \"\""
assert_eq "yellow:0" "$(finding missing_frontmatter global/e2.md)" "description:"
assert_eq none "$(finding missing_frontmatter global/e3.md)" "folded scalar"
assert_eq none "$(finding missing_frontmatter global/e4.md)" "indented continuation"
end_test

start_test "group pages are sorted"
run "$KB"
assert_eq 0 "$(q '[.groups[] | select(.pages != (.pages | sort))] | length')" "every group sorted"
end_test

start_test "index files must be reachable from root index.md (cycles do not count); stub index exempt"
fresh "$T/kb15"
mkdir -p "$T/kb15/projects/p1"
page "$T/kb15/global/topic.md" topic
printf -- '- [[index_cb]] x\n- [[topic]] t\n' > "$T/kb15/global/index_ca.md"
printf -- '- [[index_ca]] x\n' > "$T/kb15/global/index_cb.md"
printf -- '- [[topic]] t\n- [[index_ops]] o\n' > "$T/kb15/projects/p1/index.md"
printf -- '- [[index]] back\n' > "$T/kb15/projects/p1/index_ops.md"
printf -- '> Moved: [[index_ca]]\n' > "$T/kb15/global/index_old.md"
run "$T/kb15"
assert_eq "yellow:0" "$(finding not_indexed global/index_ca.md)" "cycle member a"
assert_eq "yellow:0" "$(finding not_indexed global/index_cb.md)" "cycle member b"
assert_eq "yellow:0" "$(finding not_indexed projects/p1/index.md)" "project index only back-linked"
assert_eq "yellow:0" "$(finding not_indexed projects/p1/index_ops.md)" "its sub-index too"
assert_eq none "$(finding not_indexed global/index_old.md)" "stub index exempt"
printf -- '- [[g:index_ca]] x\n- [[k:projects/p1/index]] p\n' >> "$T/kb15/index.md"
run "$T/kb15"
assert_eq 0 "$(count_check not_indexed)" "reachable from root: clean"
end_test

print_summary

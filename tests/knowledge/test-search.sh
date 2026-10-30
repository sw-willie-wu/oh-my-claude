#!/bin/bash
# Tests for oh-my-knowledge lib/project.sh and scripts/search.sh.
set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(dirname "$(dirname "$SCRIPT_DIR")")"
# shellcheck source=../test-helpers.sh
. "$REPO_ROOT/tests/test-helpers.sh"

PLUGIN="$REPO_ROOT/plugins/oh-my-knowledge"
COMMON="$PLUGIN/scripts/lib/common.sh"
PROJECT="$PLUGIN/scripts/lib/project.sh"
SEARCH="$PLUGIN/scripts/search.sh"
FIX="$SCRIPT_DIR/fixtures/kb-basic"

for v in $(compgen -e | grep -E '^(OMK_|CLAUDE_PLUGIN_OPTION_|CLAUDE_CONFIG_DIR$)'); do unset "$v"; done
T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
export HOME="$T/home"; mkdir -p "$HOME"
export GIT_CONFIG_GLOBAL="$T/gitconfig-empty"; : > "$GIT_CONFIG_GLOBAL"
export GIT_CONFIG_NOSYSTEM=1
export OMC_STATE_DIR="$T/state"
export CLAUDE_CONFIG_DIR="$T/cc"; mkdir -p "$CLAUDE_CONFIG_DIR/projects"

IS_WIN=0
case "${OSTYPE:-}" in msys*|cygwin*) IS_WIN=1;; esac

assert_has() { grep -qF -- "$2" "$1" 2>/dev/null || { echo "    FAIL: $3 (missing in $1: $2)" >&2; sed 's/^/      | /' "$1" >&2; TEST_FAILED=1; }; }
assert_lacks() { ! grep -qF -- "$2" "$1" 2>/dev/null || { echo "    FAIL: $3 (unexpected in $1: $2)" >&2; TEST_FAILED=1; }; }

KB="$T/kb"; cp -r "$FIX" "$KB"
CWD="$T/work/proj one"; mkdir -p "$CWD"
# enc <path>: encoded auto-memory dir name via common.sh
enc() { bash -c '. "$1"; omk_encode_path "$2"' _ "$COMMON" "$1" | tr -d '\r'; }
nat() { bash -c '. "$1"; omk_native_path "$2"' _ "$COMMON" "$1" | tr -d '\r'; }
res() { bash -c '. "$1"; omk_resolve_dir "$2"' _ "$COMMON" "$1" | tr -d '\r'; }
# mkmem <cwd> [name]: create auto-memory dir for cwd under CLAUDE_CONFIG_DIR; sets AM
mkmem() { AM="$CLAUDE_CONFIG_DIR/projects/${2:-$(enc "$1")}/memory"; rm -rf "$AM"; mkdir -p "$AM"; }
# run <cwd> kw...: search.sh with cwd; output in $T/out, RC
run() { local c="$1"; shift; (cd "$c" && OMK_KNOWLEDGE_DIR="${KBENV:-$KB}" bash "$SEARCH" "$@") >"$T/out" 2>"$T/err"; RC=$?; tr -d '\r' < "$T/out" > "$T/out2"; mv "$T/out2" "$T/out"; }
marker() { printf -- '- Knowledge base project: [[k:projects/%s/index]] (omk-project)\n' "$1"; }
pcall() { (cd "${PCWD:-$CWD}" && OMK_KNOWLEDGE_DIR="$KB" bash -c '. "$1"; . "$2"; omk_config; shift 2; "$@"' _ "$COMMON" "$PROJECT" "$@") | tr -d '\r'; }

start_test "project.sh and search.sh exist"
[ -f "$PROJECT" ] && [ -f "$SEARCH" ] || { echo "    FAIL: missing project.sh/search.sh" >&2; TEST_FAILED=1; }
end_test

start_test "bash-3.2 compatibility guard (no bash4-only constructs)"
if [ -f "$PROJECT" ] && [ -f "$SEARCH" ] && ! grep -nE '\$\{[A-Za-z_]+(\^\^|,,)|declare +-A|\bmapfile\b|\breadarray\b' "$PROJECT" "$SEARCH" >/dev/null 2>&1; then
  :
else
  echo "    FAIL: bash4-only construct or files missing" >&2; TEST_FAILED=1
fi
end_test

start_test "usage / missing KB exit 2"
run "$CWD"; assert_eq 2 "$RC" "no args"
assert_has "$T/err" "usage" "usage text"
KBENV="$T/nokb" run "$CWD" widget; assert_eq 2 "$RC" "missing KB"
end_test

mkmem "$CWD"   # empty auto-memory for CWD

start_test "english hit: index lines and topic counts"
run "$CWD" frobnicator; assert_eq 0 "$RC" rc
assert_has "$T/out" "== index hits" h1
assert_has "$T/out" "== topic hits (file:count)" h2
assert_has "$T/out" "global/index_tools.md:" "index line file"
assert_has "$T/out" "Widget frobnicator crashes" "index line text"
assert_has "$T/out" "global/widget_pitfall.md:1" "topic count"
assert_lacks "$T/out" "no hits" "not empty"
end_test

start_test "chinese hit"
run "$CWD" 設定檔; assert_eq 0 "$RC" rc
assert_has "$T/out" "global/zhongwen_note.md:1" "zh topic"
assert_has "$T/out" "global/index_tools.md:" "zh index"
end_test

start_test "case variants: lower/upper without grep -i"
run "$CWD" WIDGET; assert_has "$T/out" "global/widget_pitfall.md:" "upper kw finds Widget? (via lower/upper variants)"
run "$CWD" widget; assert_has "$T/out" "global/widget_pitfall.md:" "lower kw"
run "$CWD" CACHE; assert_has "$T/out" "global/cache_design.md:" "upper kw finds lower text"
run "$CWD" cache; assert_has "$T/out" "global/cache_design.md:" "lower kw finds lower text"
end_test

start_test "multiple keywords: any matches"
run "$CWD" frobnicator Invalidate; assert_has "$T/out" "global/widget_pitfall.md" a; assert_has "$T/out" "global/cache_design.md" b
end_test

start_test "regex metacharacters are literal"
run "$CWD" 'a.b*'; assert_has "$T/out" "no hits" "fixed-string"
end_test

start_test "no marker -> not migrated, project pages not searched"
run "$CWD" Gizmo
assert_has "$T/out" "== project: (not migrated)" hdr
assert_lacks "$T/out" "projects/demo" "no project hits"
assert_has "$T/out" "no hits" "none"
assert_has "$T/out" "== auto memory: $(nat "$AM")" "am hdr"
end_test

start_test "marker -> project included"
{ echo "# Memory"; marker demo; } > "$AM/MEMORY.md"
run "$CWD" Gizmo
assert_has "$T/out" "== project: demo" hdr
assert_has "$T/out" "projects/demo/gizmo_flow.md:2" "topic"
assert_has "$T/out" "projects/demo/index.md:" "index line"
end_test

start_test "marker after a status section / CRLF / twice"
printf '## status\n- done: x\n\n# Memory index\n- [a](a.md) - a\n%s\n' "$(marker demo)" > "$AM/MEMORY.md"
run "$CWD" Gizmo; assert_has "$T/out" "== project: demo" after-status
{ marker demo | sed 's/$/\r/'; } > "$AM/MEMORY.md"
run "$CWD" Gizmo; assert_has "$T/out" "== project: demo" crlf
{ marker demo; echo x; marker demo; } > "$AM/MEMORY.md"
run "$CWD" Gizmo; assert_has "$T/out" "== project: demo" twice-same
end_test

start_test "prose mentioning (omk-project) is not a marker; two distinct markers / missing dir -> not migrated"
printf 'Note: lines tagged (omk-project) mark migration.\n- see Knowledge base project: [[k:projects/demo/index]] (omk-project)\n' > "$AM/MEMORY.md"
run "$CWD" Gizmo; assert_has "$T/out" "== project: (not migrated)" prose
{ marker demo; marker other; } > "$AM/MEMORY.md"
mkdir -p "$KB/projects/other"
run "$CWD" Gizmo; assert_has "$T/out" "== project: (not migrated)" two-distinct
marker nosuch > "$AM/MEMORY.md"
run "$CWD" Gizmo; assert_has "$T/out" "== project: (not migrated)" missing-dir
rmdir "$KB/projects/other"
end_test

start_test "project.sh functions"
{ marker demo; } > "$AM/MEMORY.md"
assert_eq demo "$(pcall omk_project_marker "$AM")" marker
assert_eq "" "$(pcall omk_project_marker "$T/nonexistent")" "no dir"
assert_eq "$(res "$AM")" "$(pcall omk_auto_memory_for_cwd "$CWD")" "am for cwd"
assert_eq demo "$(pcall omk_project_for_cwd "$CWD")" "project for cwd"
assert_eq "" "$(pcall omk_auto_memory_for_cwd "$T/work")" "unmapped"
end_test

start_test "C:\\ vs /c/ cwd find the same auto-memory dir"
if [ "$IS_WIN" = 1 ]; then
  W="$(cd "$CWD" && pwd -W)"
  assert_eq "$(res "$AM")" "$(pcall omk_auto_memory_for_cwd "$W")" "C:/ form"
  assert_eq "$(res "$AM")" "$(pcall omk_auto_memory_for_cwd "$(printf %s "$W" | tr / '\\')")" "backslash form"
fi
end_test

start_test "OMK_AUTO_MEMORY_DIR overrides derivation; unmapped cwd with matching dir"
OTHER="$T/work/other"; mkdir -p "$OTHER"
assert_eq "" "$(PCWD="$OTHER" pcall omk_auto_memory_for_cwd "$OTHER")" "no dir for other"
mkmem "$OTHER"; echo "Quuxword here" > "$AM/note.md"
run "$OTHER" Quuxword; assert_has "$T/out" "note.md:1" "unmapped cwd auto-memory hits"
OVR="$T/override-am"; mkdir -p "$OVR"; echo "Overrideword" > "$OVR/x.md"
(cd "$OTHER" && OMK_AUTO_MEMORY_DIR="$OVR" OMK_KNOWLEDGE_DIR="$KB" bash "$SEARCH" Overrideword) > "$T/out" 2>&1
assert_has "$T/out" "== auto memory: $(nat "$OVR")" "override hdr"; assert_has "$T/out" "x.md:1" "override hit"
end_test

start_test "lowercase drive-prefix auto-memory dir still found"
if [ "$IS_WIN" = 1 ]; then
  LC="$T/work/lcdrive"; mkdir -p "$LC"
  e="$(enc "$LC")"; lc="$(printf %s "${e:0:1}" | tr A-Z a-z)${e:1}"
  mkmem "$LC" "$lc"; echo "Lowerdrive" > "$AM/n.md"
  run "$LC" Lowerdrive; assert_has "$T/out" "n.md:1" "found via lowercase"
fi
end_test

start_test "stubs skipped, mixed files searched, project auto memory searched"
PM="$T/work/migrated"; mkdir -p "$PM"; mkmem "$PM"
{ marker demo; } > "$AM/MEMORY.md"
printf -- '---\nname: s\n---\n> Moved: [[g:widget_pitfall]], [[k:projects/demo/gizmo_flow]]\n\n> Moved: [[slug]]\n' > "$AM/stub.md"
printf -- '---\nname: m\n---\nProgress: Zebraword done\n→ [[k:projects/demo/gizmo_flow]]\n' > "$AM/mixed.md"
printf 'Zebraword plain\n' > "$AM/plain.md"
run "$PM" Zebraword
assert_has "$T/out" "mixed.md:1" mixed; assert_has "$T/out" "plain.md:1" plain
assert_has "$T/out" "== project: demo" "project too"
printf -- '> Moved: [[g:a]]\nZebraword2 text\n' > "$AM/halfstub.md"
printf -- '---\nx: y\n---\n> Moved: [[g:Zebraword3]]\n' > "$AM/stub2.md"
run "$PM" Zebraword3; assert_lacks "$T/out" "stub2.md" "stub skipped"
run "$PM" Zebraword2; assert_has "$T/out" "halfstub.md:1" "non-stub with moved-line + text"
end_test

start_test "MEMORY.md index lines in auto memory"
echo "- [x](x.md) - Yakword entry" >> "$AM/MEMORY.md"
run "$PM" Yakword; assert_has "$T/out" "MEMORY.md:" "memory index line"; assert_has "$T/out" "Yakword entry" text
end_test

start_test "excluded dirs never appear"
run "$CWD" Secretrule Retiredword Lintword; assert_has "$T/out" "no hits" "excluded"
assert_lacks "$T/out" "rules/" r; assert_lacks "$T/out" "_retired" t; assert_lacks "$T/out" "lint/" l
end_test

start_test "empty skeleton -> no hits, exit 0"
E="$T/empty"; OMK_KNOWLEDGE_DIR="$E" bash "$PLUGIN/scripts/init.sh" >/dev/null 2>&1
KBENV="$E" run "$CWD" anything; assert_eq 0 "$RC" rc; assert_has "$T/out" "no hits" nohits
end_test

start_test "OMK_KNOWLEDGE_DIR=~/... works"
rm -rf "$HOME/kbh"; cp -r "$FIX" "$HOME/kbh"
KBENV='~/kbh' run "$CWD" frobnicator; assert_eq 0 "$RC" rc; assert_has "$T/out" "global/widget_pitfall.md:1" "tilde kb"
end_test

start_test "linked worktree of /tmp-form repo -> same auto-memory dir"
R="$(mktemp -d "$T/wtR.XXXXXX")"; WT="$(mktemp -d "$T/wtW.XXXXXX")"; rmdir "$WT"
git -C "$R" init -q . >/dev/null 2>&1
git -C "$R" -c user.name=t -c user.email=t@x commit -q --allow-empty -m init >/dev/null 2>&1
git -C "$R" worktree add -q "$WT" -b wt >/dev/null 2>&1
mkmem "$R"; marker demo > "$AM/MEMORY.md"
assert_eq "$(res "$AM")" "$(PCWD="$R" pcall omk_auto_memory_for_cwd "$R")" "main"
assert_eq "$(res "$AM")" "$(PCWD="$WT" pcall omk_auto_memory_for_cwd "$WT")" "worktree"
assert_eq demo "$(PCWD="$WT" pcall omk_project_for_cwd "$WT")" "worktree project"
git -C "$R" worktree remove --force "$WT" >/dev/null 2>&1; rm -rf "$R" "$WT"
end_test

start_test "encoding: space, underscore, dot, CJK"
P="$T/work/we ird_na.me 測試"; mkdir -p "$P"
N="$(bash -c '. "$1"; omk_native_path "$2"' _ "$COMMON" "$P" | tr -d '\r')"
exp="$(printf %s "$N" | LC_ALL=C.UTF-8 sed 's/[^A-Za-z0-9]/-/g')"
assert_eq "$exp" "$(enc "$P")" "one dash per char"
mkmem "$P"; echo Cjkdir > "$AM/z.md"
run "$P" Cjkdir; assert_has "$T/out" "z.md:1" "cjk dir mapped"
end_test

start_test "knowledge base header in native form"
run "$CWD" frobnicator
assert_eq "== knowledge base: $(nat "$KB")" "$(head -n 1 "$T/out")" "first line"
end_test

start_test "override / glob normalisation (trailing slash, C:\\ form, ~/ form, backslash config dir)"
NM="$T/work/norm"; mkdir -p "$NM"; mkmem "$NM"
printf -- '- [a](a.md) - Normword index\n' > "$AM/MEMORY.md"; echo "Normword alpha" > "$AM/alpha.md"
chk() { # <label>
  assert_has "$T/out" "MEMORY.md:1:- [a](a.md) - Normword index" "$1 MEMORY.md index line"
  assert_has "$T/out" "alpha.md:1" "$1 alpha"
  assert_has "$T/out" "== auto memory: $(nat "$AM")" "$1 header"
}
(cd "$NM" && OMK_AUTO_MEMORY_DIR="$AM/" OMK_KNOWLEDGE_DIR="$KB" bash "$SEARCH" Normword) > "$T/out" 2>&1; chk "trailing slash"
if [ "$IS_WIN" = 1 ]; then
  WA="$(nat "$AM" | tr / '\\')\\"
  (cd "$NM" && OMK_AUTO_MEMORY_DIR="$WA" OMK_KNOWLEDGE_DIR="$KB" bash "$SEARCH" Normword) > "$T/out" 2>&1; chk "C:\\ form"
  WC="$(nat "$CLAUDE_CONFIG_DIR" | tr / '\\')"
  (cd "$NM" && CLAUDE_CONFIG_DIR="$WC" OMK_KNOWLEDGE_DIR="$KB" bash "$SEARCH" Normword) > "$T/out" 2>&1; chk "backslash CLAUDE_CONFIG_DIR"
  (cd "$NM" && OMK_AUTO_MEMORY_GLOB="$WC\\projects\\*\\memory" OMK_KNOWLEDGE_DIR="$KB" bash "$SEARCH" Normword) > "$T/out" 2>&1; chk "backslash glob"
fi
(cd "$NM" && OMK_AUTO_MEMORY_GLOB="$CLAUDE_CONFIG_DIR/projects/*/memory/" OMK_KNOWLEDGE_DIR="$KB" bash "$SEARCH" Normword) > "$T/out" 2>&1; chk "glob trailing slash"
if [ "$IS_WIN" = 1 ]; then
  (cd "$NM" && OMK_AUTO_MEMORY_GLOB="$WC\projects\*\memory\\" OMK_KNOWLEDGE_DIR="$KB" bash "$SEARCH" Normword) > "$T/out" 2>&1; chk "glob trailing backslash"
fi
rm -rf "$HOME/amh"; cp -r "$AM" "$HOME/amh"
(cd "$NM" && OMK_AUTO_MEMORY_DIR="~/amh" OMK_KNOWLEDGE_DIR="$KB" bash "$SEARCH" Normword) > "$T/out" 2>&1
assert_has "$T/out" "alpha.md:1" "~/ form"; assert_lacks "$T/out" "auto memory: (none)" "~/ not none"
end_test

start_test "OMK_AUTO_MEMORY_DIR set but missing -> derivation fallback"
(cd "$NM" && OMK_AUTO_MEMORY_DIR="$T/does-not-exist" OMK_KNOWLEDGE_DIR="$KB" bash "$SEARCH" Normword) > "$T/out" 2>&1
assert_has "$T/out" "alpha.md:1" "fell back"
assert_eq "$(res "$AM")" "$(OMK_AUTO_MEMORY_DIR="$T/does-not-exist" PCWD="$NM" pcall omk_auto_memory_for_cwd "$NM")" "func fallback"
end_test

start_test "frontmatter description is searched"
mkdir -p "$KB/global"
printf -- '---\nname: fm_page\ndescription: use when Trigglyword happens\n---\nBody text.\n' > "$KB/global/fm_page.md"
run "$CWD" Trigglyword; assert_has "$T/out" "global/fm_page.md:1" "frontmatter hit"
end_test

start_test "missing gawk -> exit 2 with message (PATH without gawk)"
NOG="$T/nogawk"; mkdir -p "$NOG"
(cd "$CWD" && PATH="$NOG" OMK_KNOWLEDGE_DIR="$KB" "$BASH" "$SEARCH" widget) > "$T/out" 2> "$T/err"; RC=$?
assert_eq 2 "$RC" "rc"; assert_has "$T/err" "gawk" "message"
end_test

start_test "stub shape: prose Moved line is not a stub; multi-target, blank-line and CRLF stubs are"
SM="$T/work/stubs"; mkdir -p "$SM"; mkmem "$SM"
printf -- '---\nname: s\n---\n> Moved: [[g:Stubword]], [[k:projects/demo/Stubword]]\n\n> Moved: [[Stubword2]]\n' > "$AM/s1.md"
printf -- '> Moved: [[g:Stubword]],[[slug]]\r\n\r\n> Moved: [[Stubword]]\r\n' > "$AM/s2.md"
printf -- '> Moved: see the Stubword notes\n' > "$AM/prose.md"
run "$SM" Stubword
assert_lacks "$T/out" "s1.md" "multi-target stub skipped"; assert_lacks "$T/out" "s2.md" "CRLF stub skipped"
assert_has "$T/out" "prose.md:1" "prose Moved line is searched"
end_test

start_test "excluded dirs (also nested) never appear"
for d in rules _retired lint; do
  mkdir -p "$KB/global/$d" "$KB/projects/demo/$d"
  echo "Exclword top" > "$KB/$d/x.md"; echo "Exclword g" > "$KB/global/$d/x.md"; echo "Exclword p" > "$KB/projects/demo/$d/x.md"
done
echo "Exclword ok" > "$KB/global/kept.md"
mkmem "$CWD"; marker demo > "$AM/MEMORY.md"
run "$CWD" Exclword
assert_has "$T/out" "global/kept.md:1" "control hit"
for d in rules _retired lint; do assert_lacks "$T/out" "$d/" "$d excluded"; done
end_test

start_test "ranking, caps and long-line cut"
CK="$T/capkb"; mkdir -p "$CK/global"
i=1; while [ $i -le 20 ]; do
  n=$i; : > "$CK/global/t$(printf %02d $i).md"; while [ $n -gt 0 ]; do echo "Capword line" >> "$CK/global/t$(printf %02d $i).md"; n=$((n-1)); done; i=$((i+1))
done
{ i=1; while [ $i -le 45 ]; do echo "- Capword entry $i"; i=$((i+1)); done; } > "$CK/global/index_big.md"
LONG="$(printf 'Capword'; i=0; while [ $i -lt 30 ]; do printf '測試測試測試測試測試'; i=$((i+1)); done)"
echo "- $LONG" >> "$CK/global/index_big.md"
KBENV="$CK" run "$CWD" Capword
first="$(sed -n '/^== topic hits/,/^== project/p' "$T/out" | sed -n 2p)"
assert_eq "global/t20.md:20" "$first" "highest count first"
assert_eq 15 "$(sed -n '/^== topic hits/,/^== project/p' "$T/out" | grep -c '^global/t')" "15 topics"
assert_has "$T/out" "… 5 more files" "topic overflow line"
assert_eq 40 "$(sed -n '/^== index hits/,/^== topic/p' "$T/out" | grep -c '^global/index_big.md:')" "40 index lines"
assert_has "$T/out" "… 6 more index lines" "index overflow line"
cutline="$(grep -F "global/index_big.md:46:" "$T/out" | head -n 1)"
assert_eq "" "$cutline" "46th line is beyond the cap"
printf -- '- %s\n' "$LONG" > "$CK/global/index_one.md"; rm "$CK/global/index_big.md"
KBENV="$CK" run "$CWD" Capword
L="$(grep -F "global/index_one.md:1:" "$T/out" | head -n 1)"
assert_eq 260 "$(LC_ALL=C.UTF-8 bash -c 'printf %s "${#1}"' _ "$L")" "line cut to 260 chars"
end_test

start_test "omk_project_marker_status: none / ok / invalid multiple / invalid missing"
SD="$T/statusd"; mkdir -p "$SD"
assert_eq none "$(pcall omk_project_marker_status "$SD")" "no MEMORY.md"
echo "# nothing" > "$SD/MEMORY.md"; assert_eq none "$(pcall omk_project_marker_status "$SD")" "no marker"
marker demo > "$SD/MEMORY.md"; assert_eq "ok demo" "$(pcall omk_project_marker_status "$SD")" ok
{ marker demo; marker demo; } > "$SD/MEMORY.md"; assert_eq "ok demo" "$(pcall omk_project_marker_status "$SD")" "same twice"
mkdir -p "$KB/projects/other"; { marker demo; marker other; } > "$SD/MEMORY.md"
assert_eq "invalid multiple" "$(pcall omk_project_marker_status "$SD")" multiple
assert_eq "" "$(pcall omk_project_marker "$SD")" "wrapper empty on invalid"
rmdir "$KB/projects/other"
marker nosuch > "$SD/MEMORY.md"; assert_eq "invalid missing nosuch" "$(pcall omk_project_marker_status "$SD")" missing
printf 'prose (omk-project) only\n' > "$SD/MEMORY.md"; assert_eq none "$(pcall omk_project_marker_status "$SD")" prose
end_test

print_summary

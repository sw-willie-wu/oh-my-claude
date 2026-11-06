#!/bin/bash
# Tests for oh-my-knowledge scripts/harvest-copy.sh (harvest backup: short folder names, copy and verify).
set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(dirname "$(dirname "$SCRIPT_DIR")")"
# shellcheck source=../test-helpers.sh
. "$REPO_ROOT/tests/test-helpers.sh"

PLUGIN="$REPO_ROOT/plugins/oh-my-knowledge"
INIT="$PLUGIN/scripts/init.sh"
COMMIT="$PLUGIN/scripts/commit.sh"
HC="$PLUGIN/scripts/harvest-copy.sh"

for v in $(compgen -e | grep -E '^(OMK_|CLAUDE_PLUGIN_OPTION_|CLAUDE_CONFIG_DIR$)'); do unset "$v"; done
T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
export HOME="$T/home"; mkdir -p "$HOME"
export GIT_CONFIG_GLOBAL="$T/gitconfig-empty"; : > "$GIT_CONFIG_GLOBAL"
export GIT_CONFIG_NOSYSTEM=1
export OMC_STATE_DIR="$T/state"
export OMK_COMMIT_RETRY_DELAY=0.2

IS_WIN=0
case "${OSTYPE:-}" in msys*|cygwin*) IS_WIN=1;; esac

# fresh KB with an initial commit; sets KB
newkb() {
  KB="$T/kb-$1"
  OMK_KNOWLEDGE_DIR="$KB" bash "$INIT" >/dev/null 2>&1
  OMK_KNOWLEDGE_DIR="$KB" bash "$COMMIT" 'init' SCHEMA.md index.md log.md inbox.md rules/INDEX.md .gitattributes >/dev/null 2>&1
}
nlog() { git -C "$KB" log --oneline 2>/dev/null | wc -l | tr -d ' '; }
dn() { bash "$HC" --dir-name "$1"; }
# rep <char> <count>
rep() { local i s=""; for ((i = 0; i < $2; i++)); do s="$s$1"; done; printf '%s' "$s"; }
# expect <name>: the documented rule, computed independently of the script
expect() {
  local e="$1" t c
  if [ "${#e}" -le 60 ]; then printf '%s' "$e"; return; fi
  t="${e: -51}"; while [ "${t#-}" != "$t" ]; do t="${t#-}"; done
  c="$(printf %s "$e" | cksum | cut -d' ' -f1)"
  printf '%s-%08x' "$t" "$c"
}
# hc <files...> against $KB, today 2026-11-06: stdout in $T/out, stderr in $T/err, RC
hc() { OMK_KNOWLEDGE_DIR="${KBENV:-$KB}" OMK_TODAY=2026-11-06 bash "$HC" "$@" >"$T/out" 2>"$T/err"; RC=$?; }

start_test "harvest-copy.sh exists"
[ -f "$HC" ] || { printf '    FAIL: missing %s\n' "$HC" >&2; TEST_FAILED=1; }
end_test

start_test "--dir-name: at most 60 chars unchanged; longer = last 51 chars + cksum hash"
n60="$(rep a 60)"; n61="$(rep b 61)"
assert_eq "$n60" "$(dn "$n60")" "60 chars unchanged"
r61="$(dn "$n61")"
assert_eq 60 "${#r61}" "61 chars -> 60"
assert_eq "$(expect "$n61")" "$r61" "61 chars: tail + hash"
assert_eq "$(rep b 51)-e526d3c5" "$r61" "61 x b: known answer (not derived from the script rule)"
assert_eq 930766865 "$(printf %s 123456789 | cksum | cut -d" " -f1)" "POSIX cksum check value"
tail51="22-46ca-aa9d-4374ea29dfe7-scratch-2026-10-28-ec534f"
assert_eq 51 "${#tail51}" "fixture tail is 51 chars"
e184="$(rep h 133)$tail51"
assert_eq 184 "${#e184}" "fixture name is 184 chars"
r184="$(dn "$e184")"
assert_eq "$(expect "$e184")" "$r184" "184 chars: tail + hash"
case "$r184" in "$tail51"-????????) ;; *) echo "    FAIL: 184-char result shape: $r184" >&2; TEST_FAILED=1 ;; esac
assert_eq 60 "${#r184}" "184 chars -> 60"
ed="$(rep x 40)---$(rep y 48)"
rd="$(dn "$ed")"
case "$rd" in -*) echo "    FAIL: leading dash kept: $rd" >&2; TEST_FAILED=1 ;; esac
assert_eq "$(expect "$ed")" "$rd" "leading dashes of the tail stripped"
a1="$(rep p 69)$tail51"; a2="$(rep q 69)$tail51"
assert_eq 120 "${#a1}" "fixture 120"
[ "$(dn "$a1")" != "$(dn "$a2")" ] || { echo "    FAIL: same tail, same folder" >&2; TEST_FAILED=1; }
assert_eq "$(dn "$a1")" "$(dn "$a1")" "deterministic"
end_test

start_test "copy: byte-identical, mtime kept, same day re-run reuses, changes get .2/.3, never overwrites"
newkb c1
AMD="$T/am/C--src-demo/memory"; mkdir -p "$AMD"
src="$AMD/x.md"
printf '\xef\xbb\xbfline one\r\nline two\r\n' > "$src"; touch -d '2020-01-02 03:04:05' "$src"
hc "$src"
assert_eq 0 "$RC" "exit"
assert_eq "_retired/harvested/2026-11-06/C--src-demo/x.md" "$(tr -d '\r' < "$T/out")" "printed path"
dst="$KB/_retired/harvested/2026-11-06/C--src-demo/x.md"
cmp -s "$src" "$dst" || { echo "    FAIL: copy differs" >&2; TEST_FAILED=1; }
{ [ ! "$src" -nt "$dst" ] && [ ! "$dst" -nt "$src" ]; } || { echo "    FAIL: mtime not kept" >&2; TEST_FAILED=1; }
hc "$src"
assert_eq 0 "$RC" "re-run exit"
assert_eq "_retired/harvested/2026-11-06/C--src-demo/x.md" "$(tr -d '\r' < "$T/out")" "identical backup reused"
cp -p "$dst" "$T/x1.saved"
printf 'changed\n' > "$src"
hc "$src"
assert_eq "_retired/harvested/2026-11-06/C--src-demo/x.2.md" "$(tr -d '\r' < "$T/out")" "changed -> .2"
cmp -s "$T/x1.saved" "$dst" || { echo "    FAIL: first backup touched" >&2; TEST_FAILED=1; }
cp "$src" "$T/x2.saved"
printf 'changed again\n' > "$src"
hc "$src"
assert_eq "_retired/harvested/2026-11-06/C--src-demo/x.3.md" "$(tr -d '\r' < "$T/out")" "changed again -> .3"
cp "$T/x2.saved" "$src"
hc "$src"
assert_eq "_retired/harvested/2026-11-06/C--src-demo/x.2.md" "$(tr -d '\r' < "$T/out")" "identical to .2 -> .2 reused"
end_test

start_test "args: validated first (exit 2, nothing created); backslashes accepted; usage and setup errors"
newkb c2
AMD="$T/am2/C--src-demo/memory"; mkdir -p "$AMD/z.md" "$T/am2/C--src-demo/notmemory"
printf 'a\n' > "$AMD/good.md"; printf 'b\n' > "$T/am2/C--src-demo/notmemory/y.md"
hc "$AMD/good.md" "$T/am2/C--src-demo/notmemory/y.md"
assert_eq 2 "$RC" "bad arg among good ones"
[ ! -e "$KB/_retired/harvested" ] || { echo "    FAIL: something was created before validation" >&2; TEST_FAILED=1; }
hc "$AMD/z.md"
assert_eq 2 "$RC" "directory named z.md"
hc "$AMD/missing.md"
assert_eq 2 "$RC" "missing file"
good="$AMD/good.md"
hc "${good//\//\\}"
assert_eq 0 "$RC" "backslash form accepted"
assert_eq "_retired/harvested/2026-11-06/C--src-demo/good.md" "$(tr -d '\r' < "$T/out")" "backslash form path"
hc
assert_eq 2 "$RC" "no args"
mkdir -p "$T/nokb"
KBENV="$T/nokb" hc "$good"
assert_eq 2 "$RC" "KB without SCHEMA.md"
end_test

start_test "a file that cannot be copied -> exit 1, stderr names it, the others are still copied"
newkb c3
AM1="$T/am3/C--src-demo/memory"; AM2="$T/am3/C--src-other/memory"; mkdir -p "$AM1" "$AM2"
printf 'a\n' > "$AM1/a.md"; printf 'o\n' > "$AM2/o.md"
mkdir -p "$KB/_retired/harvested/2026-11-06"; printf 'blocker\n' > "$KB/_retired/harvested/2026-11-06/C--src-demo"
hc "$AM1/a.md" "$AM2/o.md"
assert_eq 1 "$RC" "exit"
grep -qF "a.md" "$T/err" || { echo "    FAIL: stderr does not name the file" >&2; TEST_FAILED=1; }
assert_eq "_retired/harvested/2026-11-06/C--src-other/o.md" "$(tr -d '\r' < "$T/out")" "other file printed"
[ -f "$KB/_retired/harvested/2026-11-06/C--src-other/o.md" ] || { echo "    FAIL: other file not copied" >&2; TEST_FAILED=1; }
end_test

start_test "Windows: 184-char encoded dir under a 100-char KB root commits with core.longpaths=false"
if [ "$IS_WIN" = 1 ]; then
  Tm="$(cygpath -m "$T")"; pad=$((100 - ${#Tm} - 1))
  KB="$T/$(rep k "$pad")"
  OMK_KNOWLEDGE_DIR="$KB" bash "$INIT" >/dev/null 2>&1
  OMK_KNOWLEDGE_DIR="$KB" bash "$COMMIT" 'init' SCHEMA.md index.md log.md inbox.md rules/INDEX.md .gitattributes >/dev/null 2>&1
  bd="$(dn "$e184")"
  d="$KB/_retired/harvested/2026-11-06/$bd"
  if mkdir -p "$d" 2>/dev/null && printf 'x\n' > "$d/project_ttlauth_release_frontend_reconcile_2026-07-08.md" 2>/dev/null; then
    n0="$(nlog)"
    OMK_KNOWLEDGE_DIR="$KB" GIT_CONFIG_PARAMETERS="'core.longpaths=false'" bash "$COMMIT" 'long' _retired >"$T/out" 2>&1; RC=$?
    assert_eq 0 "$RC" "commit exit"
    assert_eq "$((n0 + 1))" "$(nlog)" "one new commit"
  else
    echo "    (cannot create the long path here; skipped)"
  fi
else
  echo "    (not Windows; skipped)"
fi
end_test

print_summary

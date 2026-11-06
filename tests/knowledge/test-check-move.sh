#!/bin/bash
# Tests for oh-my-knowledge scripts/check-move.sh (literal [[ inside code must survive a move).
set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(dirname "$(dirname "$SCRIPT_DIR")")"
# shellcheck source=../test-helpers.sh
. "$REPO_ROOT/tests/test-helpers.sh"

PLUGIN="$REPO_ROOT/plugins/oh-my-knowledge"
CM="$PLUGIN/scripts/check-move.sh"
FIX="$SCRIPT_DIR/fixtures/move"

for v in $(compgen -e | grep -E '^(OMK_|CLAUDE_PLUGIN_OPTION_|CLAUDE_CONFIG_DIR$)'); do unset "$v"; done
T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
export HOME="$T/home"; mkdir -p "$HOME"
export GIT_CONFIG_GLOBAL="$T/gitconfig-empty"; : > "$GIT_CONFIG_GLOBAL"
export GIT_CONFIG_NOSYSTEM=1
export OMC_STATE_DIR="$T/state"

mkdir -p "$T/f"; cp "$FIX"/*.md "$T/f/"
F="$T/f"
# cm <args...>: stdout in $T/out, stderr in $T/err, RC
cm() { bash "$CM" "$@" >"$T/out" 2>"$T/err"; RC=$?; tr -d '\r' < "$T/out" > "$T/o2"; mv "$T/o2" "$T/out"; }
has() { grep -qF -- "$2" "$1" 2>/dev/null; }

start_test "check-move.sh exists"
[ -f "$CM" ] || { printf '    FAIL: missing %s\n' "$CM" >&2; TEST_FAILED=1; }
end_test

start_test "intact move (links rewritten, fence re-indented, other frontmatter) -> 0, no output"
cm "$F/original.md" "$F/ok.md"
assert_eq 0 "$RC" "exit"
assert_eq 0 "$(wc -c < "$T/out" | tr -d ' ')" "no output"
end_test

start_test "stripped span -> 1 naming it; truncated -> 1; span only in target frontmatter -> 1"
cm "$F/original.md" "$F/stripped.md"
assert_eq 1 "$RC" "stripped exit"
has "$T/out" 'missing' || { echo "    FAIL: no 'missing' line" >&2; TEST_FAILED=1; }
has "$T/out" '`[[a]]`' || { echo "    FAIL: span not named" >&2; TEST_FAILED=1; }
cm "$F/original.md" "$F/truncated.md"
assert_eq 1 "$RC" "truncated exit"
cm "$F/original.md" "$F/fmonly.md"
assert_eq 1 "$RC" "target frontmatter does not count"
end_test

start_test "size: small target -> 3 with 'small:'; --spans-only -> 0; split across two targets -> 0"
cm "$F/original.md" "$F/small.md"
assert_eq 3 "$RC" "small exit"
has "$T/out" 'small:' || { echo "    FAIL: no 'small:' line" >&2; TEST_FAILED=1; }
cm --spans-only "$F/original.md" "$F/small.md"
assert_eq 0 "$RC" "spans-only exit"
cm "$F/original.md" "$F/part1.md" "$F/part2.md"
assert_eq 0 "$RC" "two targets"
end_test

start_test "CRLF + BOM original is stripped; empty-body original -> 0"
{ printf '\xef\xbb\xbf'; sed 's/$/\r/' "$F/original.md"; } > "$T/crlf.md"
cm "$T/crlf.md" "$F/ok.md"
assert_eq 0 "$RC" "CRLF+BOM original"
{ printf '\xef\xbb\xbf'; sed 's/$/\r/' "$F/ok.md"; } > "$T/crlf-ok.md"
cm "$F/original.md" "$T/crlf-ok.md"
assert_eq 0 "$RC" "CRLF+BOM target"
cm "$F/empty.md" "$F/ok.md"
assert_eq 0 "$RC" "empty original body"
end_test

start_test "unterminated frontmatter (original or target) -> 2 naming the file, never a silent 0"
printf -- '---\nname: broken\nbody with `[[a]]` that the parser would swallow\n' > "$T/unterminated.md"
cm "$T/unterminated.md" "$F/ok.md"
assert_eq 2 "$RC" "unterminated original"
has "$T/err" 'unterminated.md' || { echo "    FAIL: original not named on stderr" >&2; TEST_FAILED=1; }
cm "$F/original.md" "$T/unterminated.md"
assert_eq 2 "$RC" "unterminated target"
has "$T/err" 'unterminated.md' || { echo "    FAIL: target not named on stderr" >&2; TEST_FAILED=1; }
end_test

start_test "usage errors -> 2; PATH without gawk -> 2 naming gawk"
cm "$F/original.md" "$T/does-not-exist.md"
assert_eq 2 "$RC" "missing target"
cm "$F/original.md"
assert_eq 2 "$RC" "one argument"
cm
assert_eq 2 "$RC" "no arguments"
NOG="$T/nogawk"; mkdir -p "$NOG"
PATH="$NOG" "$BASH" "$CM" "$F/original.md" "$F/ok.md" >"$T/out" 2>"$T/err"; RC=$?
assert_eq 2 "$RC" "no gawk"
has "$T/err" 'gawk' || { echo "    FAIL: message does not name gawk" >&2; TEST_FAILED=1; }
end_test

print_summary

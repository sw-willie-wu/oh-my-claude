#!/bin/bash
# Tests for oh-my-knowledge scripts/commit.sh (storage seam).
set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(dirname "$(dirname "$SCRIPT_DIR")")"
# shellcheck source=../test-helpers.sh
. "$REPO_ROOT/tests/test-helpers.sh"

PLUGIN="$REPO_ROOT/plugins/oh-my-knowledge"
INIT="$PLUGIN/scripts/init.sh"
COMMIT="$PLUGIN/scripts/commit.sh"

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
# run <msg> <paths...> against $KB (or $KBENV); sets RC
run() { OMK_KNOWLEDGE_DIR="${KBENV:-$KB}" bash "$COMMIT" "$@" >"$T/out" 2>&1; RC=$?; }
nlog() { git -C "$KB" log --oneline 2>/dev/null | wc -l | tr -d ' '; }

start_test "commit.sh exists"
[ -f "$COMMIT" ] || { printf '    FAIL: missing %s\n' "$COMMIT" >&2; TEST_FAILED=1; }
end_test

start_test "commits only the listed paths; works for new files"
newkb a
before="$(nlog)"
echo one > "$KB/global/new.md"; echo changed >> "$KB/index.md"
run 'add new' global/new.md
assert_eq "0" "$RC" "exit"
assert_eq "$((before+1))" "$(nlog)" "one new commit"
assert_eq "global/new.md" "$(git -C "$KB" show --name-only --format= HEAD | tr -d '\r')" "only listed file"
assert_eq " M index.md" "$(git -C "$KB" status --porcelain | tr -d '\r')" "other modified file stays uncommitted"
assert_eq "add new" "$(git -C "$KB" log -1 --format=%s | tr -d '\r')" "subject"
end_test

start_test "exit 3 when nothing to commit"
run 'again' global/new.md
assert_eq "3" "$RC" "exit"
end_test

start_test "exit 2 on usage errors and out-of-KB paths"
before="$(nlog)"
run
assert_eq "2" "$RC" "no args"
run 'msg'
assert_eq "2" "$RC" "no paths"
run '' index.md
assert_eq "2" "$RC" "empty message"
echo x > "$T/outside.md"
run 'msg' "$T/outside.md"
assert_eq "2" "$RC" "absolute outside KB"
run 'msg' ../outside.md
assert_eq "2" "$RC" "dotdot escape"
assert_eq "$before" "$(nlog)" "nothing committed"
end_test

start_test "move (old + new path) commits the deletion"
mkdir -p "$KB/projects/p1"
echo m > "$KB/global/mv.md"
run 'add mv' global/mv.md
assert_eq "0" "$RC" "setup exit"
mv "$KB/global/mv.md" "$KB/projects/p1/mv.md"
run 'move' global/mv.md projects/p1/mv.md
assert_eq "0" "$RC" "exit"
assert_eq "" "$(git -C "$KB" ls-files global/mv.md | tr -d '\r')" "old gone from index"
assert_eq "projects/p1/mv.md" "$(git -C "$KB" ls-files projects/p1/mv.md | tr -d '\r')" "new tracked"
assert_eq "" "$(git -C "$KB" status --porcelain -- global/mv.md projects/p1/mv.md | tr -d '\r')" "clean"
end_test

start_test "absolute in-KB paths: posix, C:/, C:\\ and ~/ forms accepted"
LONG="$(cd "$KB" && pwd -P)"
echo a1 > "$KB/global/abs1.md"
run 'abs posix' "$LONG/global/abs1.md"
assert_eq "0" "$RC" "posix abs"
echo a2 > "$KB/global/abs2.md"
run 'abs as created' "$KB/global/abs2.md"
assert_eq "0" "$RC" "as given by mktemp"
if [ "$IS_WIN" = 1 ]; then
  W="$(cd "$KB" && pwd -W)"
  echo a3 > "$KB/global/abs3.md"
  run 'abs C:/' "$W/global/abs3.md"
  assert_eq "0" "$RC" "C:/ form"
  echo a4 > "$KB/global/abs4.md"
  WB="${W//\//\\}"
  run 'abs C:\' "$WB\\global\\abs4.md"
  assert_eq "0" "$RC" "C:\\ form"
fi
KBH="$HOME/kbhome"
OMK_KNOWLEDGE_DIR="$KBH" bash "$INIT" >/dev/null 2>&1
echo h > "$KBH/global/h.md"
OMK_KNOWLEDGE_DIR="$KBH" bash "$COMMIT" 'tilde' '~/kbhome/global/h.md' >"$T/out" 2>&1; RC=$?
assert_eq "0" "$RC" "~/ form"
end_test

start_test "lock held: exit 4 after retries, nothing committed; released lock then succeeds"
newkb lock
echo l > "$KB/global/l.md"
before="$(nlog)"
: > "$KB/.git/index.lock"
run 'locked' global/l.md
assert_eq "4" "$RC" "index.lock exit"
hint="$(grep -F 'if no git process is running, remove it (docs/knowledge.md: Troubleshooting)' "$T/out")"
[ -n "$hint" ] || { printf '    FAIL: exit-4 hint line missing\n' >&2; TEST_FAILED=1; }
case "$hint" in *index.lock*) ;; *) printf '    FAIL: hint does not name the lock path: %s\n' "$hint" >&2; TEST_FAILED=1 ;; esac
assert_eq "1" "$(grep -cF 'if no git process is running' "$T/out")" "exactly one hint line"
rm -f "$KB/.git/index.lock"
assert_eq "$before" "$(nlog)" "nothing committed"
run 'now' global/l.md
assert_eq "0" "$RC" "after release"
echo l2 > "$KB/global/l2.md"
: > "$KB/.git/HEAD.lock"
run 'head locked' global/l2.md
assert_eq "4" "$RC" "HEAD.lock exit"
rm -f "$KB/.git/HEAD.lock"
assert_eq "" "$(git -C "$KB" diff --cached --name-only | tr -d '\r')" "nothing left staged"
end_test

start_test "lock released during retries -> success"
echo l3 > "$KB/global/l3.md"
: > "$KB/.git/index.lock"
( sleep 0.3; rm -f "$KB/.git/index.lock" ) &
OMK_COMMIT_RETRY_DELAY=0.5 run 'late' global/l3.md
wait
assert_eq "0" "$RC" "exit"
end_test

start_test "KB without .git exits 1, commits nothing"
NG="$T/nogit"; mkdir -p "$NG"; echo z > "$NG/z.md"; : > "$NG/SCHEMA.md"
KBENV="$NG" run 'msg' z.md
assert_eq "1" "$RC" "exit"
grep -qF "is not a git repository" "$T/out" || { printf '    FAIL: .git guard message missing\n' >&2; TEST_FAILED=1; }
[ ! -e "$NG/.git" ] || { printf '    FAIL: .git created\n' >&2; TEST_FAILED=1; }
end_test

start_test "nonexistent path named *.lock.md is not mistaken for a lock (exit 2, no retry)"
newkb lk2
s=$SECONDS
OMK_COMMIT_RETRY_DELAY=2 run 'msg' global/x.lock.md
# nothing exists and nothing tracked -> every path ignored -> exit 2 (never 4, no retry delay), warning printed
assert_eq "2" "$RC" "x.lock.md exit"
grep -qF "commit.sh: ignored global/x.lock.md (not found and not tracked)" "$T/out" || { echo "    FAIL: missing ignored warning" >&2; TEST_FAILED=1; }
[ $((SECONDS - s)) -lt 4 ] || { printf '    FAIL: retried\n' >&2; TEST_FAILED=1; }
end_test

start_test "typo path alone exits 2 with the ignored line"
echo t > "$KB/global/real.md"
run 'typo' global/reel.md
assert_eq "2" "$RC" "exit"
grep -qF "commit.sh: ignored global/reel.md (not found and not tracked)" "$T/out" || { echo "    FAIL: missing ignored line" >&2; TEST_FAILED=1; }
assert_eq "" "$(git -C "$KB" ls-files global/real.md | tr -d '\r')" "real.md not committed"
end_test

start_test "move whose old path was never committed succeeds"
echo n > "$KB/global/never.md"
mv "$KB/global/never.md" "$KB/global/moved.md"
run 'move uncommitted' global/never.md global/moved.md
assert_eq "0" "$RC" "exit"
assert_eq "global/moved.md" "$(git -C "$KB" ls-files global/moved.md | tr -d '\r')" "new tracked"
grep -qF "ignored global/never.md (not found and not tracked)" "$T/out" || { echo "    FAIL: missing warning for never-committed old path" >&2; TEST_FAILED=1; }
end_test

start_test "glob characters are literal, cannot widen the commit"
echo 1 > "$KB/global/g1.md"; echo 2 > "$KB/global/g2.md"
run 'glob' 'global/g*.md'
assert_eq "2" "$RC" "no literal match -> no committable path"
assert_eq "" "$(git -C "$KB" ls-files global/g1.md global/g2.md | tr -d '\r')" "nothing added"
echo 3 > "$KB/global/br[a].md"; echo 4 > "$KB/global/bra.md"
run 'literal bracket' 'global/br[a].md'
assert_eq "0" "$RC" "literal bracket file committed"
assert_eq "global/br[a].md" "$(git -C "$KB" show --name-only --format= HEAD | tr -d '\r')" "only literal file"
end_test

start_test "paths inside .git rejected with exit 2"
before="$(nlog)"
run 'msg' .git/config
assert_eq "2" "$RC" ".git/config"
run 'msg' ./.git/HEAD
assert_eq "2" "$RC" "./.git/HEAD"
assert_eq "$before" "$(nlog)" "nothing committed"
end_test

start_test "Windows: upper-case drive / differently-cased KB prefix commits under the right name"
if [ "$IS_WIN" = 1 ]; then
  UP="$(cd "$KB" && pwd -P)"
  echo c > "$KB/global/case.md"
  run 'drive upper' "/C${UP#/c}/global/case.md"
  assert_eq "0" "$RC" "upper-case drive letter"
  assert_eq "global/case.md" "$(git -C "$KB" show --name-only --format= HEAD | tr -d '\r')" "name under correct relative path"
  echo c2 > "$KB/global/case2.md"
  run 'prefix upper' "$(printf %s "$UP" | tr a-z A-Z)/global/case2.md"
  assert_eq "0" "$RC" "upper-cased KB prefix"
  assert_eq "global/case2.md" "$(git -C "$KB" show --name-only --format= HEAD | tr -d '\r')" "name under correct relative path (prefix)"
fi
end_test

start_test "missing KB exits 1"
KBENV="$T/does-not-exist" run 'msg' z.md
assert_eq "1" "$RC" "missing KB"
grep -qF "knowledge base not found or not set up" "$T/out" || { printf '    FAIL: missing-KB message\n' >&2; TEST_FAILED=1; }
end_test

start_test "tracked CJK-named files: move and delete commit cleanly"
mkdir -p "$KB/projects/p1" "$KB/rules"
echo a > "$KB/projects/p1/測試.md"; echo b > "$KB/rules/舊.md"
run 'add cjk' projects/p1/測試.md rules/舊.md
assert_eq "0" "$RC" "setup"
mv "$KB/projects/p1/測試.md" "$KB/projects/p1/renamed.md"
run 'move cjk' projects/p1/測試.md projects/p1/renamed.md
assert_eq "0" "$RC" "move exit"
assert_eq "" "$(git -C "$KB" status --porcelain -- projects/p1 | tr -d '\r')" "move: status clean"
assert_eq "projects/p1/renamed.md" "$(git -C "$KB" ls-files projects/p1 | tr -d '\r')" "move: only new tracked"
rm "$KB/rules/舊.md"
run 'delete cjk' rules/舊.md
assert_eq "0" "$RC" "delete exit"
assert_eq "" "$(git -C "$KB" -c core.quotepath=false ls-files rules/舊.md | tr -d '\r')" "delete: untracked now"
assert_eq "" "$(git -C "$KB" status --porcelain -- rules | tr -d '\r')" "delete: status clean"
end_test

start_test "dir-prefix lookalike: missing untracked 'a' is dropped when x/a/z is tracked"
mkdir -p "$KB/x/a"; echo z > "$KB/x/a/z"
run 'setup x/a/z' x/a/z
assert_eq "0" "$RC" "setup"
echo z2 >> "$KB/x/a/z"
run 'm' x/a/z a
assert_eq "0" "$RC" "exit"
grep -qF "ignored a (not found and not tracked)" "$T/out" || { echo "    FAIL: no ignored line for a" >&2; TEST_FAILED=1; }
assert_eq "x/a/z" "$(git -C "$KB" show --name-only --format= HEAD | tr -d '\r')" "x/a/z committed"
end_test

start_test "empty directory among listed paths is dropped; others committed"
newkb empty
mkdir -p "$KB/projects" "$KB/global/sub"
echo e > "$KB/global/e1.md"
n0=$(nlog)
run 'existing pages' rules global projects index.md
assert_eq "0" "$RC" "exit"
grep -qF "commit.sh: ignored projects (empty directory)" "$T/out" || { echo "    FAIL: no ignored line for empty projects/" >&2; cat "$T/out" >&2; TEST_FAILED=1; }
assert_eq "global/e1.md" "$(git -C "$KB" show --name-only --format= HEAD | tr -d '\r')" "global/e1.md committed"
assert_eq "$((n0 + 1))" "$(nlog)" "one new commit"
end_test

start_test "only an empty directory -> exit 2"
mkdir -p "$KB/lint/empty"
run 'only empty' lint/empty
assert_eq "2" "$RC" "exit"
grep -qF "commit.sh: ignored lint/empty (empty directory)" "$T/out" || { echo "    FAIL: no ignored line" >&2; TEST_FAILED=1; }
end_test

start_test "deleted tracked directory (now empty) still commits the deletion"
mkdir -p "$KB/global/gone"; echo g > "$KB/global/gone/a.md"
run 'add gone' global/gone
assert_eq "0" "$RC" "add"
rm -f "$KB/global/gone/a.md"
run 'rm gone' global/gone
assert_eq "0" "$RC" "deletion exit"
assert_eq "" "$(git -C "$KB" ls-files global/gone | tr -d '\r')" "deletion committed"
end_test

start_test "directory holding only a symlink is not empty; symlinked dir path is kept"
newkb sym
mkdir -p "$KB/global/links" "$KB/projects/real"; echo r > "$KB/projects/real/r.md"
if MSYS=winsymlinks:nativestrict ln -s ../../projects/real/r.md "$KB/global/links/r-link.md" 2>/dev/null && [ -L "$KB/global/links/r-link.md" ]; then
  run 'only symlink' global/links
  assert_eq "0" "$RC" "dir with only a symlink"
  assert_eq "global/links/r-link.md" "$(git -C "$KB" show --name-only --format= HEAD | tr -d '\r')" "symlink committed"
  if MSYS=winsymlinks:nativestrict ln -s real "$KB/projects/real-link" 2>/dev/null && [ -L "$KB/projects/real-link" ]; then
    run 'dir symlink' projects/real-link
    assert_eq "0" "$RC" "symlink to a directory"
    grep -qF 'empty directory' "$T/out" && { echo "    FAIL: symlink to dir dropped as empty" >&2; TEST_FAILED=1; }
  fi
else
  echo "    (symlinks cannot be created here; skipped)"
fi
end_test

start_test "Windows: path too long for git add -> exit 1, nothing committed"
if [ "$IS_WIN" = 1 ]; then
  newkb longp
  seg="dddddddddddddddddddddddddddddddddddddddddddddddddd"   # 50 chars
  rel="_retired/harvested/$seg/$seg/$seg/$seg/$seg/$seg"
  if mkdir -p "$KB/$rel" 2>/dev/null && echo l > "$KB/$rel/long.md" 2>/dev/null; then
    n0=$(nlog)
    OMK_KNOWLEDGE_DIR="$KB" GIT_CONFIG_PARAMETERS="'core.longpaths=false'" bash "$COMMIT" 'long' _retired >"$T/out" 2>&1; RC=$?
    if grep -qF 'Filename too long' "$T/out" || [ "$RC" != 0 ]; then
      assert_eq "1" "$RC" "exit"
      grep -qF 'commit.sh:' "$T/out" || { echo "    FAIL: no commit.sh message" >&2; TEST_FAILED=1; }
      assert_eq "$n0" "$(nlog)" "nothing committed"
    else
      echo "    (git handled the long path here; nothing to assert)"
    fi
  else
    echo "    (cannot create the long path here; skipped)"
  fi
else
  echo "    (not Windows; skipped)"
fi
end_test

start_test "common.sh stays bash-3.2 compatible"
hits="$(grep -nE '\^\^|,,\}|declare -A|mapfile|readarray' "$PLUGIN/scripts/lib/common.sh")"
assert_eq "" "$hits" "bash4-only constructs in common.sh"
end_test

start_test "KB without SCHEMA.md is not set up (exit 1, nothing committed)"
newkb noschema
before="$(nlog)"
echo more >> "$KB/index.md"
rm -f "$KB/SCHEMA.md"
run 'x' index.md
assert_eq "1" "$RC" "exit"
grep -qF "knowledge base not found or not set up" "$T/out" || { echo "    FAIL: message missing" >&2; TEST_FAILED=1; }
assert_eq "$before" "$(nlog)" "no new commit"
git -C "$KB" diff --quiet -- index.md; assert_eq "1" "$?" "index.md still modified"
end_test

print_summary

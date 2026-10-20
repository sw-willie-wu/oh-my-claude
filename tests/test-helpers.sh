#!/bin/bash
# Minimal bash test framework — assertions + setup/teardown helpers.

TEST_FAILED=0
TEST_NAME=""
TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0

# Override state dir during tests so we never touch real ~/.claude state.
export OMC_STATE_DIR="${OMC_STATE_DIR:-$(mktemp -d -t omc-test-XXXXXX)}"
export OMC_LOG_FILE="${OMC_LOG_FILE:-${OMC_STATE_DIR}/track-workers.log}"

# Isolation: never read the real ~/.claude/oh-my-claude.conf or ~/.claude.json.
# [ -f /dev/null ] is false, so conf defaults apply. Tests override as needed.
export OMC_CONF="${OMC_CONF:-/dev/null}"
export OMC_ACCOUNT_FILE="${OMC_ACCOUNT_FILE:-$OMC_STATE_DIR/no-such.json}"

# Real jq, resolved before any test prepends a shim dir to PATH.
REAL_JQ="$(command -v jq 2>/dev/null || true)"

# make_jq_shim <dir> <log> [fail]: write an executable <dir>/jq that logs one
# 'CALL <%q argv>' line per invocation, then execs the real jq (or exits 1).
make_jq_shim() {
  local dir="$1" log="$2" mode="${3:-}"
  mkdir -p "$dir"
  {
    printf '#!/bin/bash\n'
    printf '{ printf CALL; printf " %%q" "$@"; printf "\\n"; } >> %q\n' "$log"
    if [ "$mode" = fail ]; then
      printf 'exit 1\n'
    else
      printf 'exec %q "$@"\n' "$REAL_JQ"
    fi
  } > "$dir/jq"
  chmod +x "$dir/jq"
}

# shim_count <log> [fixed-string]: number of logged calls (or of calls whose
# line contains the %q-escaped fixed string). 0 when the log is missing/empty.
shim_count() {
  local log="$1" needle="${2:-}" n
  [ -s "$log" ] || { echo 0; return 0; }
  if [ -n "$needle" ]; then
    n=$(grep -cF -- "$(printf '%q' "$needle")" "$log" || true)
  else
    n=$(grep -c '^CALL' "$log" || true)
  fi
  echo "${n:-0}"
}

start_test() {
  TEST_NAME="$1"
  TEST_FAILED=0
  TESTS_RUN=$((TESTS_RUN + 1))
  rm -rf "$OMC_STATE_DIR"
  mkdir -p "$OMC_STATE_DIR"
}

end_test() {
  if [ "$TEST_FAILED" -eq 0 ]; then
    TESTS_PASSED=$((TESTS_PASSED + 1))
    printf '  ✓ %s\n' "$TEST_NAME"
  else
    TESTS_FAILED=$((TESTS_FAILED + 1))
    printf '  ✗ %s\n' "$TEST_NAME"
  fi
}

assert_eq() {
  local expected="$1" actual="$2" msg="${3:-values differ}"
  if [ "$expected" != "$actual" ]; then
    printf '    FAIL: %s\n      expected: %q\n      actual:   %q\n' "$msg" "$expected" "$actual" >&2
    TEST_FAILED=1
  fi
}

assert_file_contains() {
  local file="$1" pattern="$2" msg="${3:-pattern not found}"
  if ! grep -qF "$pattern" "$file" 2>/dev/null; then
    if [ ! -f "$file" ]; then
      printf '    FAIL: %s\n      file does not exist: %s\n' "$msg" "$file" >&2
    else
      printf '    FAIL: %s\n      file: %s\n      pattern: %q\n' "$msg" "$file" "$pattern" >&2
    fi
    [ -f "$file" ] && printf '      contents:\n%s\n' "$(sed 's/^/        /' "$file")" >&2
    TEST_FAILED=1
  fi
}

assert_file_not_contains() {
  local file="$1" pattern="$2" msg="${3:-pattern unexpectedly found}"
  if [ -f "$file" ] && grep -qF "$pattern" "$file" 2>/dev/null; then
    printf '    FAIL: %s\n      file: %s\n      pattern: %q\n' "$msg" "$file" "$pattern" >&2
    TEST_FAILED=1
  fi
}

assert_line_count() {
  local file="$1" expected="$2" msg="${3:-line count mismatch}"
  local actual=0
  [ -f "$file" ] && actual=$(wc -l < "$file" | tr -d ' ')
  if [ "$actual" != "$expected" ]; then
    printf '    FAIL: %s\n      expected: %s\n      actual: %s\n      file: %s\n' "$msg" "$expected" "$actual" "$file" >&2
    [ -f "$file" ] && printf '      contents:\n%s\n' "$(sed 's/^/        /' "$file")" >&2
    TEST_FAILED=1
  fi
}

print_summary() {
  printf '\n%d run, %d passed, %d failed\n' "$TESTS_RUN" "$TESTS_PASSED" "$TESTS_FAILED"
  [ "$TESTS_FAILED" -eq 0 ]
}

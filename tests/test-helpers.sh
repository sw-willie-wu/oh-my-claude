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
    printf '    FAIL: %s\n      file: %s\n      pattern: %q\n' "$msg" "$file" "$pattern" >&2
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
  local actual
  actual=$(wc -l < "$file" 2>/dev/null | tr -d ' ' || echo 0)
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

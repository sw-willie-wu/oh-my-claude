#!/bin/bash
# Run all tests.
set -e
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"
FAIL=0
echo "=== track-workers tests ==="
bash "$REPO_ROOT/tests/test-track-workers.sh" || FAIL=1
if [ -f "$REPO_ROOT/tests/test-statusline-render.sh" ]; then
  echo
  echo "=== statusline render tests ==="
  bash "$REPO_ROOT/tests/test-statusline-render.sh" || FAIL=1
fi
if [ -f "$REPO_ROOT/tests/test-conf-backfill.sh" ]; then
  echo
  echo "=== conf-backfill tests ==="
  bash "$REPO_ROOT/tests/test-conf-backfill.sh" || FAIL=1
fi
echo
echo "=== marketplace tests ==="
bash "$REPO_ROOT/tests/test-marketplace.sh" || FAIL=1
echo
echo "=== knowledge init tests ==="
bash "$REPO_ROOT/tests/knowledge/test-init.sh" || FAIL=1
echo
echo "=== knowledge commit tests ==="
bash "$REPO_ROOT/tests/knowledge/test-commit.sh" || FAIL=1
echo
echo "=== knowledge search tests ==="
bash "$REPO_ROOT/tests/knowledge/test-search.sh" || FAIL=1
echo
echo "=== knowledge lint (structure) tests ==="
bash "$REPO_ROOT/tests/knowledge/test-lint-structure.sh" || FAIL=1
echo
echo "=== knowledge config tests ==="
bash "$REPO_ROOT/tests/knowledge/test-config.sh" || FAIL=1
echo
echo "=== knowledge hooks tests ==="
bash "$REPO_ROOT/tests/knowledge/test-hooks.sh" || FAIL=1
echo
echo "=== cross-plugin contract tests ==="
bash "$REPO_ROOT/tests/test-cross-plugin-contract.sh" || FAIL=1
echo
echo "=== knowledge lint (content) tests ==="
bash "$REPO_ROOT/tests/knowledge/test-lint-content.sh" || FAIL=1
echo
echo "=== knowledge harvest-copy tests ==="
bash "$REPO_ROOT/tests/knowledge/test-harvest-copy.sh" || FAIL=1
echo
echo "=== knowledge skills tests ==="
bash "$REPO_ROOT/tests/knowledge/test-skills.sh" || FAIL=1
exit "$FAIL"

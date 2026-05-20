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
exit "$FAIL"

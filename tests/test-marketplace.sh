#!/bin/bash
# Tests for the marketplace layout: plugins/ split, manifests, rename, sweep.
set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"

# shellcheck source=test-helpers.sh
. "$SCRIPT_DIR/test-helpers.sh"

MKT="$REPO_ROOT/.claude-plugin/marketplace.json"
STATUS_DIR="$REPO_ROOT/plugins/oh-my-status"

start_test "marketplace lists exactly oh-my-knowledge and oh-my-status"
assert_eq "oh-my-knowledge,oh-my-status" \
  "$(jq -r '[.plugins[].name] | sort | join(",")' "$MKT" 2>/dev/null | tr -d '\r')" "plugin names"
end_test

start_test "each plugin source dir exists and plugin.json name matches"
for n in oh-my-knowledge oh-my-status; do
  src=$(jq -r --arg n "$n" '.plugins[] | select(.name==$n) | .source' "$MKT" 2>/dev/null | tr -d '\r')
  assert_eq "./plugins/$n" "$src" "source of $n"
  pj="$REPO_ROOT/${src#./}/.claude-plugin/plugin.json"
  if [ ! -f "$pj" ]; then
    printf '    FAIL: missing %s\n' "$pj" >&2; TEST_FAILED=1
  else
    assert_eq "$n" "$(jq -r '.name' "$pj" | tr -d '\r')" "plugin.json name of $n"
  fi
done
end_test

start_test "no version key in any manifest or marketplace entry"
n=$(jq '[.plugins[] | has("version")] | map(select(.)) | length' "$MKT" 2>/dev/null | tr -d '\r')
assert_eq "0" "$n" "marketplace entries with version"
assert_eq "false" "$(jq 'has("version")' "$MKT" 2>/dev/null | tr -d '\r')" "marketplace top-level version"
for pj in "$REPO_ROOT"/plugins/*/.claude-plugin/plugin.json; do
  assert_eq "false" "$(jq 'has("version")' "$pj" 2>/dev/null | tr -d '\r')" "version in $pj"
done
[ -f "$STATUS_DIR/.claude-plugin/plugin.json" ] || { printf '    FAIL: oh-my-status plugin.json missing\n' >&2; TEST_FAILED=1; }
end_test

start_test "marketplace renames oh-my-claude -> oh-my-status"
assert_eq "oh-my-status" "$(jq -r '.renames["oh-my-claude"]' "$MKT" 2>/dev/null | tr -d '\r')" "renames"
end_test

start_test "no old command prefix in commands, setup.sh, install.sh, README.md"
old='/oh-my-claude'; old+=':'   # built at runtime so this file never matches itself
for p in "$STATUS_DIR/commands" "$STATUS_DIR/setup.sh" "$REPO_ROOT/install.sh" "$REPO_ROOT/README.md"; do
  if [ ! -e "$p" ]; then
    printf '    FAIL: path missing: %s\n' "$p" >&2; TEST_FAILED=1
  elif [ -n "$(grep -rnF -- "$old" "$p" 2>/dev/null)" ]; then
    printf '    FAIL: old prefix found in %s\n' "$p" >&2; TEST_FAILED=1
  fi
done
end_test

start_test "session-start sweep removes 25h-old ctx-*/handoff-* and keeps fresh ones"
TW="$STATUS_DIR/hooks/track-workers.sh"
if [ ! -f "$TW" ]; then
  printf '    FAIL: missing %s\n' "$TW" >&2; TEST_FAILED=1
else
  for k in ctx handoff; do
    printf x > "$OMC_STATE_DIR/$k-old"; printf x > "$OMC_STATE_DIR/$k-fresh"
  done
  if date -d '25 hours ago' '+%Y%m%d%H%M.%S' >/dev/null 2>&1; then
    TS=$(date -d '25 hours ago' '+%Y%m%d%H%M.%S')
  else
    TS=$(date -v-25H '+%Y%m%d%H%M.%S')
  fi
  touch -t "$TS" "$OMC_STATE_DIR/ctx-old" "$OMC_STATE_DIR/handoff-old"
  echo '{"session_id":"mkt-sweep","hook_event_name":"SessionStart","source":"startup"}' \
    | bash "$TW" session-start
  for k in ctx handoff; do
    [ ! -f "$OMC_STATE_DIR/$k-old" ] || { printf '    FAIL: stale %s-old not removed\n' "$k" >&2; TEST_FAILED=1; }
    [ -f "$OMC_STATE_DIR/$k-fresh" ] || { printf '    FAIL: fresh %s-fresh removed\n' "$k" >&2; TEST_FAILED=1; }
  done
fi
end_test

print_summary

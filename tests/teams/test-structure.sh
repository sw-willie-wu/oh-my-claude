#!/bin/bash
# Structural tests for the oh-my-teams plugin (agents, lead skill, config, docs).
set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(dirname "$(dirname "$SCRIPT_DIR")")"
# shellcheck source=../test-helpers.sh
. "$REPO_ROOT/tests/test-helpers.sh"

PLUGIN="$REPO_ROOT/plugins/oh-my-teams"
MKT="$REPO_ROOT/.claude-plugin/marketplace.json"

fail() { printf '    FAIL: %s\n' "$1" >&2; TEST_FAILED=1; }

# body <file> -> stdout: everything after the closing frontmatter fence
body() { awk 'f>=2{print; next} /^---[[:space:]]*$/{f++; next} f<2 && NR==1 && !/^---/{f=2; print}' "$1"; }
# fm_value <file> <key> -> value of a top-level frontmatter key
fm_value() {
  awk -v k="$2" 'NR==1 && !/^---/{exit} /^---[[:space:]]*$/{n++; if(n==2) exit; next}
    n==1 && index($0, k ":")==1 { v=substr($0, length(k)+2); sub(/^[[:space:]]+/, "", v); sub(/\r$/, "", v); print v; exit }' "$1"
}
# fm_list <file> <key> -> comma-separated value, one trimmed item per line
fm_list() { fm_value "$1" "$2" | tr ',' '\n' | sed 's/^[[:space:]]*//; s/[[:space:]]*$//' | sed '/^$/d'; }
has() { grep -qF -- "$2" "$1" 2>/dev/null; }
need() { has "$1" "$2" || fail "$3: missing $(printf %q "$2")"; }

start_test "scaffold: plugin.json name, no version, no hooks dir"
PJ="$PLUGIN/.claude-plugin/plugin.json"
if [ ! -f "$PJ" ]; then
  fail "missing $PJ"
else
  assert_eq "oh-my-teams" "$(jq -r '.name' "$PJ" 2>/dev/null | tr -d '\r')" "plugin.json name"
  assert_eq "false" "$(jq 'has("version")' "$PJ" 2>/dev/null | tr -d '\r')" "plugin.json version key"
fi
[ ! -e "$PLUGIN/hooks" ] || fail "hooks dir exists"
d=$(jq -r '.plugins[] | select(.name=="oh-my-teams") | .description' "$MKT" 2>/dev/null | tr -d '\r')
[ -n "$d" ] || fail "marketplace entry for oh-my-teams missing or has no description"
end_test

print_summary

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

AG="$PLUGIN/agents"
ROLES="spec implementer reviewer qa"

start_test "agents: four files, name = file name, model and tools as fixed"
exp_model() { case "$1" in spec|reviewer) echo opus;; *) echo sonnet;; esac; }
exp_tools() {
  case "$1" in
    spec) echo "Read, Grep, Glob, Write, Edit, Bash, PowerShell, Skill, WebFetch, WebSearch";;
    reviewer) echo "Read, Grep, Glob, Bash, PowerShell, Skill, WebFetch, WebSearch";;
    qa) echo "Read, Grep, Glob, Bash, PowerShell, Skill";;
    *) echo "";;
  esac
}
for r in $ROLES; do
  f="$AG/$r.md"
  if [ ! -f "$f" ]; then fail "missing $f"; continue; fi
  assert_eq "$r" "$(fm_value "$f" name | tr -d '\r')" "$r name"
  assert_eq "$(exp_model "$r")" "$(fm_value "$f" model | tr -d '\r')" "$r model"
  [ -n "$(fm_value "$f" description)" ] || fail "$r: empty description"
  has "$f" "oh-my-teams:lead" || fail "$r: description/body does not name oh-my-teams:lead"
  if [ "$r" = implementer ]; then
    [ -z "$(fm_value "$f" tools)" ] || fail "implementer must not set tools"
  else
    assert_eq "$(exp_tools "$r")" "$(fm_list "$f" tools | paste -sd, - | sed 's/,/, /g' | tr -d '\r')" "$r tools"
  fi
done
end_test

start_test "agents: no hooks/mcpServers/permissionMode/skills keys"
for r in $ROLES; do
  f="$AG/$r.md"; [ -f "$f" ] || { fail "missing $f"; continue; }
  for k in hooks mcpServers permissionMode skills; do
    awk -v k="$k" 'NR==1&&!/^---/{exit} /^---[[:space:]]*$/{n++; if(n==2) exit; next} n==1 && index($0,k":")==1{found=1} END{exit !found}' "$f" && fail "$r: frontmatter has $k"
  done
done
end_test

start_test "agents: read-only roles have no edit tools"
for r in reviewer qa; do
  f="$AG/$r.md"; [ -f "$f" ] || { fail "missing $f"; continue; }
  t=$(fm_list "$f" tools)
  for bad in Edit Write NotebookEdit; do
    printf '%s\n' "$t" | grep -qx "$bad" && fail "$r: has $bad"
  done
  printf '%s\n' "$t" | grep -qx Skill || fail "$r: lacks Skill"
done
end_test

start_test "agents: every role report starts with ## Knowledge lookup and ends with ## Lessons"
for r in $ROLES; do
  f="$AG/$r.md"; [ -f "$f" ] || { fail "missing $f"; continue; }
  need "$f" "## Knowledge lookup" "$r"
  need "$f" "## Lessons" "$r"
  need "$f" "oh-my-knowledge:lookup" "$r"
  need "$f" "no knowledge base installed" "$r"
  a=$(grep -n -m1 -F '## Knowledge lookup' "$f" | cut -d: -f1)
  b=$(grep -n -F '## Lessons' "$f" | tail -1 | cut -d: -f1)
  [ -n "$a" ] && [ -n "$b" ] && [ "$a" -lt "$b" ] || fail "$r: heading order"
done
end_test

start_test "reviewer: bar obligations present"
f="$AG/reviewer.md"
for s in 'Level:' 'blocked: no level' 'normal-use' 'constructed-input' 'pre-existing' 'from-fix' '## Below the bar' '## Verdict' 'fix needed'; do
  need "$f" "$s" reviewer
done
end_test

start_test "reviewer: plan-stage notes heading"
need "$AG/reviewer.md" "## Plan-stage notes" reviewer
end_test

start_test "spec: spec-level obligations present"
f="$AG/spec.md"
for s in 'file names' 'function names' 'step order' 'test lists' '## Optional suggestions' '## Questions for the user'; do
  need "$f" "$s" spec
done
end_test

start_test "spec: names every brief heading"
for h in '### Goal' '### User decisions' '### Constraints' '### Out of scope' '### Open points' '### Target file'; do
  need "$AG/spec.md" "$h" spec
done
end_test

start_test "agents: Contracts verdict values and finding line"
for r in reviewer qa; do
  f="$AG/$r.md"
  for s in 'pass' 'fix needed' 'blocked:' '- [<severity>; <reach>; <origin>]'; do
    need "$f" "$s" "$r"
  done
done
end_test

start_test "qa: throwaway copy rule present"
for s in '## Can the tests fail' 'temp' 'working tree'; do
  need "$AG/qa.md" "$s" qa
done
end_test

start_test "agents: no commit"
for r in $ROLES; do
  f="$AG/$r.md"; [ -f "$f" ] || { fail "missing $f"; continue; }
  grep -qi 'never commit' "$f" || fail "$r: no 'never commit'"
done
end_test

start_test "agents: remaining headings, dispatch strings and severity words"
for s in '## Verdict' '## Findings' '## Below the bar' '## Questions for the user'; do need "$AG/qa.md" "$s" qa; done
for s in '## Findings' '## Questions for the user' 'Previous findings:' 'critical' 'important' 'minor'; do need "$AG/reviewer.md" "$s" reviewer; done
for s in 'critical' 'important' 'minor'; do need "$AG/qa.md" "$s" qa; done
need "$AG/spec.md" 'Plan-stage notes:' spec
end_test

print_summary

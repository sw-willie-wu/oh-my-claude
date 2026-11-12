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

LEAD="$PLUGIN/skills/lead/SKILL.md"
LEAD_REF="$PLUGIN/skills/lead/reference.md"
# sect <file> <heading> -> the lines of that ## section (heading excluded)
sect() { awk -v h="$2" '/^## /{on = ($0 == "## " h); next} on' "$1" 2>/dev/null; }
# in_sect <file> <heading> <fixed string> <test name>
in_sect() { local s; s=$(sect "$1" "$2"); printf '%s\n' "$s" | grep -qF -- "$3" || fail "$4: '## $2' lacks $(printf %q "$3")"; }

start_test "lead: frontmatter and size"
if [ ! -f "$LEAD" ]; then fail "missing $LEAD"; else
  assert_eq "lead" "$(fm_value "$LEAD" name | tr -d '\r')" "lead name"
  d=$(fm_value "$LEAD" description)
  printf '%s' "$d" | grep -q '[A-Za-z]' || fail "lead: description has no ASCII word"
  printf '%s' "$d" | LC_ALL=C grep -q '[^ -~]' || fail "lead: description has no CJK trigger phrase"
  [ "$(fm_value "$LEAD" disable-model-invocation)" != "true" ] || fail "lead: disable-model-invocation is true"
  sz=$(wc -c < "$LEAD" | tr -d ' ')
  [ "$sz" -le 8192 ] || fail "lead: SKILL.md is $sz bytes (max 8192)"
fi
end_test

start_test "lead: required headings"
for h in 'When this applies' 'Review level' 'Dispatching' 'Review loop' 'Knowledge' 'Commits' 'Settings'; do
  grep -qx "## $h" "$LEAD" 2>/dev/null || fail "lead: missing heading '## $h'"
done
end_test

start_test "lead: level table has four rows with the fixed cells"
rows=$(sect "$LEAD" 'Review level' | grep -E '^\| [0-3] (none|light|standard|strict) \|')
assert_eq "4" "$(printf '%s\n' "$rows" | sed '/^$/d' | wc -l | tr -d ' ')" "level rows"
row() { printf '%s\n' "$rows" | grep -E "^\| $1 "; }
for n in 0 1; do row $n | grep -qF 'Main session writes' || fail "lead: row $n lacks 'Main session writes'"; done
for n in 2 3; do row $n | grep -qF 'Spec agent writes' || fail "lead: row $n lacks 'Spec agent writes'"; done
row 0 | grep -qF 'No reviewer' || fail "lead: row 0 lacks 'No reviewer'"
row 0 | grep -qF 'None' || fail "lead: row 0 lacks 'None'"
row 1 | grep -qF 'One round' || fail "lead: row 1 lacks 'One round'"
row 1 | grep -qF 'None' || fail "lead: row 1 lacks 'None'"
row 2 | grep -qF 'Once' || fail "lead: row 2 lacks 'Once'"
row 3 | grep -qF 'Per task' || fail "lead: row 3 lacks 'Per task'"
end_test

start_test "lead: no spec agent at levels 0–1"
grep -v '^|' "$LEAD" 2>/dev/null | grep -i 'never dispatch the spec agent' | grep -qE '0–1|0-1' \
  || fail "lead: no line forbidding the spec agent at levels 0–1"
end_test

start_test "lead: names all four agents and the brief headings"
for s in 'oh-my-teams:spec' 'oh-my-teams:implementer' 'oh-my-teams:reviewer' 'oh-my-teams:qa' \
  '### Goal' '### User decisions' '### Constraints' '### Out of scope' '### Open points' '### Target file'; do
  has "$LEAD" "$s" || has "$LEAD_REF" "$s" || fail "lead: missing $(printf %q "$s") in SKILL.md and reference.md"
done
end_test

start_test "lead: loop rules present"
for s in 'fresh reviewer' 'until a round has none' 'pre-existing' 'from-fix' 'two consecutive rounds' 'lower the level' 'Below the bar' 'Plan-stage notes' 'Previous findings:'; do
  in_sect "$LEAD" 'Review loop' "$s" "lead loop"
done
end_test

start_test "lead: missing lookup is noted"
in_sect "$LEAD" 'Knowledge' '## Knowledge lookup' "lead knowledge"
in_sect "$LEAD" 'Knowledge' 'not re-dispatched' "lead knowledge"
end_test

start_test "lead: knowledge intake through lookup only"
for s in 'oh-my-knowledge:lookup' 'inbox' 'situation' 'conclusion' 'evidence'; do
  in_sect "$LEAD" 'Knowledge' "$s" "lead intake"
done
for bad in 'oh-my-knowledge:distill' 'oh-my-knowledge:handoff' 'oh-my-knowledge:setup' 'oh-my-knowledge:lint' 'scripts/' 'knowledge_dir' 'CLAUDE_PLUGIN_OPTION'; do
  has "$LEAD" "$bad" && fail "lead: mentions $bad"
done
end_test

start_test "lead: commit policy"
for s in 'default branch' 'feature/' 'once per plan task' 'never push'; do
  in_sect "$LEAD" 'Commits' "$s" "lead commits"
done
for bad in 'git push' 'git merge' 'git tag'; do
  has "$LEAD" "$bad" && fail "lead: spells out '$bad'"
done
end_test

start_test "lead: user interruptions and no-document path"
for s in 'level question' 'plan summary' 'goes straight to'; do
  has "$LEAD" "$s" || fail "lead: missing $(printf %q "$s")"
done
end_test

start_test "config: userConfig has exactly the seven keys, each with type/title/description"
PJ="$PLUGIN/.claude-plugin/plugin.json"
CFG_KEYS="default_level spec_model implementer_model reviewer_model qa_model spec_dir plan_dir"
assert_eq "$(printf '%s\n' $CFG_KEYS | sort | paste -sd, -)" "$(jq -r '.userConfig // {} | keys[]' "$PJ" 2>/dev/null | tr -d '\r' | sort | paste -sd, -)" "userConfig keys"
for k in $CFG_KEYS; do
  assert_eq "string" "$(jq -r --arg k "$k" '.userConfig[$k].type // empty' "$PJ" 2>/dev/null | tr -d '\r')" "$k type"
  for f in title description; do
    [ -n "$(jq -r --arg k "$k" --arg f "$f" '.userConfig[$k][$f] // empty' "$PJ" 2>/dev/null | tr -d '\r')" ] || fail "$k: no $f"
  done
  assert_eq "false" "$(jq --arg k "$k" '.userConfig[$k] | (has("options") or has("sensitive"))' "$PJ" 2>/dev/null | tr -d '\r')" "$k options/sensitive"
done
assert_eq "docs/specs" "$(jq -r '.userConfig.spec_dir.default // empty' "$PJ" 2>/dev/null | tr -d '\r')" "spec_dir default"
assert_eq "docs/plans" "$(jq -r '.userConfig.plan_dir.default // empty' "$PJ" 2>/dev/null | tr -d '\r')" "plan_dir default"
end_test

start_test "config: lead reads every key single-quoted"
for k in $CFG_KEYS; do need "$LEAD" "'\${user_config.$k}'" "lead config"; done
all=$(grep -oF '${user_config.' "$LEAD" | wc -l | tr -d ' ')
quoted=$(grep -oE "'\\$\{user_config\.[a-z_]+\}'" "$LEAD" | wc -l | tr -d ' ')
[ "$all" = "$quoted" ] || fail "lead: $all \${user_config. occurrences, only $quoted single-quoted"
end_test

start_test "config: unset and validation rules"
for s in 'is unset if it is empty' 'dollar sign and a brace' '${user_config.' 'sonnet' 'opus' 'haiku' 'fable' 'model' 'docs/specs' 'docs/plans'; do in_sect "$LEAD" Settings "$s" "lead settings"; done
sect "$LEAD" Settings | grep -qE '0–3|0-3' || fail "lead settings: no 0–3 range rule"
end_test

start_test "lead: blocked verdict, QA fixes, takeover, fix diff, stop examples, answers, lookup mismatch"
blk=$(sect "$LEAD" 'Review loop' | grep -F 'A `blocked:` verdict')
printf '%s' "$blk" | grep -qF 'reviewer or QA, at any level' || fail "lead blocked: general rule must name reviewer, QA and any level"
printf '%s' "$blk" | grep -qE '^[0-9]+\.|^ ' && fail "lead blocked: rule sits inside a numbered list"
for s in 'is not a pass' 'dispatch the same round again' 'ask the user' 'Commit nothing while a verdict is blocked'; do
  printf '%s' "$blk" | grep -qF "$s" || fail "lead blocked: rule lacks $(printf %q "$s")"
done
in_sect "$LEAD" 'Dispatching' 'a blocked verdict only the user can resolve' "lead blocked ask-list"
in_sect "$LEAD" 'Commits' 'stage that task'"'"'s files again so the fix is included' "lead staging"
in_sect "$LEAD" 'Review loop' 'the reviewed change is staged and uncommitted' "lead staging"
in_sect "$LEAD" 'Dispatching' 'QA must-fix findings (levels 2 and 3): the implementer fixes them, the fix goes through the review loop, then commit' "lead QA fixes"
in_sect "$LEAD" 'When this applies' 'you take over' "lead takeover"
in_sect "$LEAD" 'When this applies' 'replace that workflow' "lead takeover"
in_sect "$LEAD" 'Review loop' '`git add` the reviewed change (staging only, no commit)' "lead fix diff"
in_sect "$LEAD" 'Review loop' 'copy of the reviewed version in a temp directory' "lead fix diff"
in_sect "$LEAD" 'Review loop' 'the fix diff as the review target' "lead fix diff"
in_sect "$LEAD" 'Review loop' '3→3→3 stops after round 3; 3→2→2 continues to round 4' "lead stop examples"
in_sect "$LEAD" 'Review loop' 'Two comparisons in a row without a decrease' "lead stop examples"
in_sect "$LEAD" 'Dispatching' 'If a plan is called for' "lead plan condition"
in_sect "$LEAD" 'Dispatching' 'added under `### User decisions`' "lead answers"
in_sect "$LEAD" 'Knowledge' 'no knowledge base installed` while `oh-my-knowledge:lookup` is in your skill list' "lead lookup mismatch"
end_test

start_test "config: agents carry no user_config"
for r in $ROLES; do has "$AG/$r.md" '${user_config.' && fail "$r: carries user_config"; done
end_test

print_summary

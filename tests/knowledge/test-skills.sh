#!/bin/bash
# Structural tests for the five oh-my-knowledge skills (SKILL.md text contracts).
set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(dirname "$(dirname "$SCRIPT_DIR")")"
# shellcheck source=../test-helpers.sh
. "$REPO_ROOT/tests/test-helpers.sh"

PLUGIN="$REPO_ROOT/plugins/oh-my-knowledge"
SKILLS="$PLUGIN/skills"
COMMON="$PLUGIN/scripts/lib/common.sh"
NAMES="setup lookup distill lint handoff"

T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT

fail() { printf '    FAIL: %s\n' "$1" >&2; TEST_FAILED=1; }

# Commands the skills must never spell out (storage seam: scripts own git).
GIT_RE='(^|[^.[:alnum:]-])git +(add|commit|status|diff|mv|rm|log|stash|reset|checkout|push|pull|fetch|init|rev-parse|config|restore|switch|clean|show|ls-files|branch|tag|merge|worktree|rebase|blame|-C|-c)([^[:alnum:]-]|$)'

# dq_user_config <file>: lines where a ${user_config. sits inside an open double quote
# (odd number of " before it on that line), even when it is also single-quoted.
dq_user_config() {
  awk '{ s = $0; pre = ""
         while ((i = index(s, "${user_config.")) > 0) {
           pre = pre substr(s, 1, i - 1); n = gsub(/"/, "\"", pre)
           if (n % 2 == 1) { print FILENAME ":" FNR ": " $0; break }
           pre = pre "${user_config."; s = substr(s, i + 14) } }' "$1"
}

# body <file> -> stdout: everything after the closing frontmatter fence
body() { awk 'f>=2{print; next} /^---[[:space:]]*$/{f++; next} f<2 && NR==1 && !/^---/{f=2; print}' "$1"; }
# fm_value <file> <key> -> value of a top-level frontmatter key
fm_value() {
  awk -v k="$2" 'NR==1 && !/^---/{exit} /^---[[:space:]]*$/{n++; if(n==2) exit; next}
    n==1 && index($0, k ":")==1 { v=substr($0, length(k)+2); sub(/^[[:space:]]+/, "", v); sub(/\r$/, "", v); print v; exit }' "$1"
}
has() { grep -qF -- "$2" "$1" 2>/dev/null; }
need() { has "$1" "$2" || fail "$3: missing $(printf %q "$2")"; }

start_test "git-command pattern self-check"
printf '%s\n' 'run `git add x` now' > "$T/p1"
printf '%s\n' 'then git -C kb log' > "$T/p2"
printf '%s\n' 'a stale .git/index.lock' > "$T/p3"
grep -qE "$GIT_RE" "$T/p1" || fail "pattern misses \`git add x\`"
grep -qE "$GIT_RE" "$T/p2" || fail "pattern misses git -C kb log"
grep -qE "$GIT_RE" "$T/p3" && fail "pattern matches .git/index.lock"
printf '%s\n' 'then git ls-files and git worktree list' > "$T/p4"
grep -qE "$GIT_RE" "$T/p4" || fail "pattern misses git ls-files / git worktree"
printf '%s\n' 'see the git line and gitattributes' > "$T/p5"
grep -qE "$GIT_RE" "$T/p5" && fail "pattern matches prose 'git line'"
end_test

start_test "double-quoted user_config detector self-check"
printf '%s\n' "X=\"a'\${user_config.k}'b\" bash x" > "$T/q1"
printf '%s\n' "X='\${user_config.k}' bash \"\${CLAUDE_PLUGIN_ROOT}/x\"" > "$T/q2"
[ -n "$(dq_user_config "$T/q1")" ] || fail "detector misses nested double quotes"
[ -z "$(dq_user_config "$T/q2")" ] || fail "detector flags a correct single-quoted call"
end_test

for n in $NAMES; do
  f="$SKILLS/$n/SKILL.md"
  start_test "$n: SKILL.md exists with name = folder and bilingual description"
  if [ ! -f "$f" ]; then
    fail "missing $f"
  else
    assert_eq "$n" "$(fm_value "$f" name)" "frontmatter name"
    d="$(fm_value "$f" description)"
    printf '%s' "$d" | grep -qE '[A-Za-z]{3,}' || fail "description has no ASCII word"
    printf '%s' "$d" | LC_ALL=C grep -q "$(printf '[\343-\351]')" || fail "description has no CJK character"
    sz=$(wc -c < "$f" | tr -d ' ')
    [ "$sz" -le 8192 ] || fail "SKILL.md is $sz bytes (> 8192; move detail to reference.md)"
    need "$f" "SCHEMA.md" "$n points to SCHEMA.md"
  fi
  end_test
done

start_test "all skill files: scripts exist, OMK_* exist, quoting, no git commands, no stale paths"
found=0
for f in "$SKILLS"/*/*.md; do
  [ -f "$f" ] || continue
  found=1
  rel="${f#"$SKILLS"/}"
  body "$f" > "$T/body"
  for s in $(grep -oE '\$\{CLAUDE_PLUGIN_ROOT\}/scripts/[A-Za-z0-9_./-]+\.sh' "$f" | sort -u); do
    p="$PLUGIN/${s#\$\{CLAUDE_PLUGIN_ROOT\}/}"
    [ -f "$p" ] || fail "$rel mentions missing script $s"
  done
  for v in $(grep -oE 'OMK_[A-Z][A-Z_]*[A-Z]' "$f" | sort -u); do
    grep -qE "(^|[^A-Z_])$v([^A-Z_]|$)" "$COMMON" || fail "$rel uses $v, not defined in common.sh"
  done
  all=$(grep -oF '${user_config.' "$f" | wc -l | tr -d ' ')
  quoted=$(grep -oE "'\\\$\{user_config\.[a-z_]+\}'" "$f" | wc -l | tr -d ' ')
  [ "$all" = "$quoted" ] || fail "$rel: $all \${user_config. occurrences, only $quoted single-quoted"
  dq="$(dq_user_config "$f")"; [ -z "$dq" ] || fail "$rel: \${user_config. inside double quotes: $dq"
  has "$f" '--time-style' && fail "$rel uses GNU-only ls --time-style"
  if grep -nE "$GIT_RE" "$T/body" > "$T/hits"; then fail "$rel spells out git commands: $(head -3 "$T/hits")"; fi
  if grep -nE '\$[0-9]|\$ARGUMENTS' "$T/body" > "$T/hits"; then fail "$rel has argument placeholders: $(head -3 "$T/hits")"; fi
  for bad in '~/.claude/skills/' 'kb.sh' '~/knowledge/'; do
    has "$T/body" "$bad" && fail "$rel mentions $bad"
  done
done
[ "$found" = 1 ] || fail "no skill files found"
end_test

start_test "lookup, distill, lint commit through commit.sh"
for n in lookup distill lint; do need "$SKILLS/$n/SKILL.md" 'scripts/commit.sh' "$n"; done
end_test

start_test "setup: configure --json / --values-stdin, explicit new knowledge_dir for init.sh"
f="$SKILLS/setup/SKILL.md"
need "$f" '--values-stdin' setup
need "$f" '--json' setup
need "$f" 'claude plugin list' setup
need "$f" 'scripts/init.sh' setup
need "$f" 'scripts/commit.sh' setup
grep -qE "OMK_KNOWLEDGE_DIR='[^\$'][^']*'.*scripts/init\.sh" "$f" 2>/dev/null \
  || fail "setup has no init.sh call with an explicit (non-\${user_config}) OMK_KNOWLEDGE_DIR"
grep -qE "OMK_KNOWLEDGE_DIR='\\\$\{user_config\.knowledge_dir\}'.*scripts/init\.sh" "$f" 2>/dev/null \
  || fail "setup has no init.sh call for the unchanged knowledge_dir"
need "$f" 'CLAUDE.md' setup
need "$f" 'rules/INDEX.md' setup
for p in 'sort -u' 'unconfigured' 'inputs.knowledge_dir' '${CLAUDE_CONFIG_DIR:-~/.claude}/CLAUDE.md' 'already initialized' \
  'case "$d" in '"'~/'" '"$d/SCHEMA.md"' '"$d/.git"' 'no-history' 'rules global projects index.md _retired lint'; do
  need "$f" "$p" setup
done
# run setup's relocation check with ~/ paths: ok / no-history / missing
snip="$(awk '/^d=.<new knowledge_dir>.; case/{p=1} p{print} p && /^if \[/{exit}' "$f")"
if [ -z "$snip" ]; then fail "setup relocation check snippet not found"; else
  H="$T/home"; mkdir -p "$H/kb1/.git" "$H/kb2"; : > "$H/kb1/SCHEMA.md"; : > "$H/kb2/SCHEMA.md"
  for c in 'kb1 ok' 'kb2 no-history' 'kb3 missing'; do
    rep="~/${c%% *}"
    got="$(HOME="$H" bash -c "${snip//<new knowledge_dir>/$rep}" 2>&1)"
    assert_eq "${c#* }" "$got" "relocation check for $rep"
  done
  rep='~\kb1'
  got="$(HOME="$H" bash -c "${snip//<new knowledge_dir>/$rep}" 2>&1)"
  assert_eq "ok" "$got" 'relocation check for ~\kb1'
fi
end_test

start_test "setup: step 2 validates the stored knowledge_dir; step 3 normalises backslashes and rejects non-absolute"
f="$SKILLS/setup/SKILL.md"
s2="$(awk '/^## 2\./{p=1; next} /^## 3\./{exit} p' "$f")"
s3="$(awk '/^## 3\./{p=1; next} /^## 4\./{exit} p' "$f")"
case "$s2" in *'`~/`'*'go straight to step 3'*) ;; *) fail "setup step 2: stored value validation / go to step 3 missing" ;; esac
case "$s2" in *'`\` into `/`'*) ;; *) fail "setup step 2: backslash normalisation missing" ;; esac
case "$s3" in *'Turn every `\` of a `knowledge_dir` into `/`'*'reject it unless it is absolute'*'`kb` or `./kb`'*) ;; *) fail "setup step 3: normalise / reject non-absolute missing" ;; esac
need "$f" "'~/'*|'~\\'*" setup
end_test

start_test "lookup, lint, handoff, distill: exit 2 naming knowledge_dir routes to setup"
for n in lookup handoff distill; do
  grep -F 'Exit 2 naming `knowledge_dir` or "knowledge base not found"' "$SKILLS/$n/SKILL.md" | grep -qF 'oh-my-knowledge:setup' \
    || fail "$n: exit-2 routing to /oh-my-knowledge:setup missing"
done
grep -F 'naming `knowledge_dir` or "knowledge base not found"' "$SKILLS/lint/SKILL.md" | grep -qF 'oh-my-knowledge:setup' || fail "lint: exit-2 routing missing"
grep -F 'exit 2 bad path' "$SKILLS/distill/SKILL.md" | grep -qF 'fix' || fail "distill: commit-time 'exit 2 bad path -> fix' must stay"
sz="$(wc -c < "$SKILLS/distill/SKILL.md" | tr -d ' ')"
[ "$sz" -le 8192 ] || fail "distill SKILL.md is $sz bytes (> 8192)"
end_test

start_test "lookup: search sections, four write-backs, inbox-only for auto memory"
f="$SKILLS/lookup/SKILL.md"
need "$f" 'scripts/search.sh' lookup
need "$f" '== auto memory:' lookup
for p in "'verify: " "'fix: " "'flag: " "'inbox: "; do need "$f" "$p" lookup; done
need "$f" '> ⚠ UNVERIFIED (YYYY-MM-DD):' lookup
need "$f" 'OMK_AUTO_MEMORY_DIR' lookup
need "$f" '(omk-project)' lookup
need "$f" 'metadata.verified' lookup
end_test

start_test "distill: harvest literals, modes, promote timing, close precondition"
f="$SKILLS/distill/SKILL.md"
for p in '(omk-harvested)' '(omk-project)' '[[k:' '_retired/harvested/' 'OMK_AUTO_MEMORY_DIR' \
  '- Knowledge base project: [[k:projects/<p>/index]] (omk-project)' '> Moved: [[k:' \
  'second project' 'migrate this project' 'attach' 'close this project' '## Projects' \
  '## [YYYY-MM-DD] harvest |' 'lint_remind_after_distills' "'distill: "; do
  need "$f" "$p" distill
done
grep -iE 'precondition' "$f" 2>/dev/null | grep -F 'migrate this project' | grep -qF 'full harvest' \
  || fail "distill: close-mode precondition (migrate if unmapped, full harvest if mapped) not on one line"
grep -E 'exit 3' "$f" 2>/dev/null | grep -qiE 'success' || fail "distill: commit.sh exit 3 = success missing"
r="$SKILLS/distill/reference.md"
for p in 'cp -p' 'cmp' 'date -r' 'metadata.modified' 'inferred value'; do need "$f" "$p" distill; need "$r" "$p" distill/reference.md; done
grep -F 'already exists' "$f" 2>/dev/null | grep -qF 'attach <p>' || fail "distill: migrate rule 'projects/<p>/ already exists -> attach <p>' missing"
grep -F 'already exists' "$r" 2>/dev/null | grep -qF 'attach <p>' || fail "reference: migrate rule 'already exists -> attach <p>' missing"
grep -F 'invalid marker' "$r" 2>/dev/null | grep -qF 'never add a second marker' || fail "reference: attach with invalid marker replaces it"
need "$r" 'demo-old' distill/reference.md
end_test

start_test "distill: always-on directive outcomes (spec C rule path, spec G project always-on)"
f="$SKILLS/distill/SKILL.md"; r="$SKILLS/distill/reference.md"
need "$f" 'always-on directive' distill
grep -F 'always-on directive' "$f" 2>/dev/null | grep -F 'duplicate' | grep -qF 'all knowledge' || fail "distill: always-on row must state precedence over duplicate/all knowledge"
grep -F '<n> always-on' "$f" 2>/dev/null | grep -qF '<n> retired' || fail "distill: harvest log line lacks <n> always-on"
need "$f" 'copy-and-verify' distill
need "$f" '- always-on rule → [[k:rules/<slug>]] (omk-harvested)' distill
need "$f" '> Moved: [[k:rules/<slug>]]' distill
# G: no tags anywhere
if grep -rnE 'omk: always-on|always-on-declined' "$PLUGIN/skills" "$PLUGIN/templates" "$PLUGIN/scripts/lib/lint-content.awk" >/dev/null 2>&1; then
  fail "an omk: always-on / always-on-declined tag is still mentioned in skills, SCHEMA template or lint awk"
fi
# G1: project always-on row (SKILL.md) and steps (reference.md)
grep -F 'always-on directive' "$f" 2>/dev/null | grep -qF 'projects/<p>/always-on.md' || fail "distill: always-on row lacks projects/<p>/always-on.md"
need "$f" '- always-on (this project) → [[k:projects/<p>/always-on]] (omk-harvested)' distill
need "$f" '> Moved: [[k:projects/<p>/always-on]]' distill
need "$f" 'make X a global rule' distill
need "$f" '改成全域規則' distill
grep -E '^description:' "$f" | grep -qF 'make X a global rule' || fail "distill: description lacks the 'make X a global rule' trigger"
grep -E '^description:' "$f" | grep -qF '改成全域規則' || fail "distill: description lacks 改成全域規則"
for p in 'CLAUDE_CONFIG_DIR' 'rules/INDEX.md' 'setup step 6' '@<slug>.md' \
  '- always-on rule → [[k:rules/<slug>]] (omk-harvested)' '> Moved: [[k:rules/<slug>]]' 'case-insensitive' 'reuse' \
  'projects/<p>/always-on.md' '- always-on (this project) → [[k:projects/<p>/always-on]] (omk-harvested)' \
  '> Moved: [[k:projects/<p>/always-on]]' 'same directive' 'dedupe' 'stub' 'projects/<p>/index.md' \
  'no line' 'exact pointer line' 'make X a global rule' 'Never delete' 'last line' 'log.md' \
  'rules/INDEX.md' 'verified' 'user declines' 'change X' 'drop X' 'Closed'; do
  need "$r" "$p" distill/reference.md
done
grep -F 'rules/<slug>.md' "$r" 2>/dev/null | grep -F 'verified' | grep -qF 'ask the user' || fail "reference: always-on rule proposal must carry verified frontmatter and ask the user"
for o in 'all knowledge' 'mixed' 'duplicate' 'obsolete' 'always-on rule' 'project always-on'; do
  grep -F 'Copy-and-verify' "$r" 2>/dev/null | grep -qF "$o" || fail "reference: copy-and-verify must cover $o"
done
grep -F 'Copy-and-verify' "$r" 2>/dev/null | grep -qF 'six' || fail "reference: copy-and-verify must say six outcomes"
grep -F '<n> always-on' "$r" 2>/dev/null | grep -qF 'project always-on' || fail "reference: <n> always-on counting must include project always-on outcomes"
grep -E 'say .make X a global rule' "$r" 2>/dev/null | grep -qiE 'report' || fail "reference: report must carry the promote hint"
grep -F 'make X a global rule' "$r" 2>/dev/null | grep -qF 'rules-import check' || fail "reference: promote must run the rules-import check"
grep -F 'Never delete' "$r" 2>/dev/null | grep -qF 'page' || fail "reference: never-delete line must name the page"
grep -F 'commit' "$r" 2>/dev/null | grep -F 'projects/<p>/always-on.md' | grep -qF 'rules/INDEX.md' || fail "reference: promote commit list (rule, INDEX, always-on page, log) missing"
grep -F 'last line' "$r" 2>/dev/null | grep -qF '> Moved: [[k:rules/<slug>]]' || fail "reference: stub on last promote missing"
grep -F 'tub page' "$r" 2>/dev/null | grep -qF 'restore' || fail "reference: appending to a stub page must restore it and its index line"
need "$f" 'carry no conclusion' distill
# review pins (M1, M3, M4, M5)
grep -F 'user declines the import offer' "$r" 2>/dev/null | grep -qF 'project always-on' || fail "reference: a declined import offer must lead to project always-on"
grep -F 'user declines the rule' "$r" 2>/dev/null | grep -qF 'project always-on' || fail "reference: a declined rule must lead to project always-on"
grep -F 'exact pointer line' "$r" 2>/dev/null | grep -qF 'remove this file' || fail "reference: pointer-line dedupe must remove this file's line"
grep -F 'the user declines → stop' "$r" 2>/dev/null | grep -qF 'nothing changes' || fail "reference: promote with a declined import must stop, nothing changes"
need "$r" 'does not change `verified`' distill/reference.md
grep -F 'Page missing' "$r" 2>/dev/null | grep -qF 'index line' || fail "reference: page creation must add the index line"
grep -F 'delete the page' "$r" 2>/dev/null | grep -qF 'Never delete the page' || fail "reference: never-delete wording missing"
[ -z "$(grep -F 'delete the page' "$r" 2>/dev/null | grep -vF 'Never delete the page')" ] || fail "reference: a line allows deleting the always-on page"
grep -F 'index line stays' "$r" 2>/dev/null | grep -qF 'repoint' || fail "reference: promoted page keeps its index line"
grep -F 'only if it was removed or repointed' "$r" 2>/dev/null | grep -qF 'Stub page' || fail "reference: stub restore only when the index line was removed or repointed"
grep -F 'reuse that rule' "$r" 2>/dev/null | grep -qF 'existing rule' || fail "reference: promote reuses an existing rule"
grep -F 'detail link' "$r" 2>/dev/null | grep -qF 'global/' || fail "reference: promote must drop or replace [[k:projects/…]] detail links"
f="$SKILLS/distill/SKILL.md"
need "$f" 'ask first' distill
need "$f" 'make X a global rule / change X / drop X' distill
need "$f" 'After **every** `MEMORY.md` write, re-check the marker line' distill
grep -E '^Report:' "$f" | grep -qF 'always-on promote hint' || fail "distill: report line lacks the always-on promote hint"
end_test

start_test "templates/SCHEMA.md and lint skill carry the always-on.md convention (spec G4)"
S="$PLUGIN/templates/SCHEMA.md"; f="$SKILLS/lint/SKILL.md"
need "$S" 'always-on.md' SCHEMA
grep -F 'always-on.md' "$S" | grep -qF 'reserved' || fail "SCHEMA: always-on.md must be a reserved slug"
grep -F 'always-on.md' "$S" | grep -qF 'session start' || fail "SCHEMA: always-on.md loaded at session start"
need "$f" 'always-on.md' lint
grep -F 'always-on.md' "$f" | grep -qiE 'informational|not a finding' || fail "lint: always-on counts must be informational"
grep -F 'stub_unreferenced' "$f" | grep -qF 'never offer it for retirement' || fail "lint: stub_unreferenced must exclude always-on.md"
grep -F 'Never retire' "$f" | grep -qF 'always-on.md' || fail "lint: retire section must exclude always-on.md"
end_test

start_test "lint: script stage, subagent groups, report, retire, harvested marker"
f="$SKILLS/lint/SKILL.md"
for p in 'scripts/lint.sh' '(omk-harvested)' '(omk-project)' 'lint/lint-YYYY-MM-DD.md' 'sonnet' '_retired/YYYY-MM-DD/' \
  'REPORT.md' "'\${user_config.lint_stale_days}'" "'lint: "; do
  need "$f" "$p" lint
done
need "$f" 'missing_path' lint
need "$f" 'absolute native path' lint
need "$f" 'batches' lint
need "$f" 'lower recall' lint
grep -F '`missing_path`' "$f" | grep -qF 'report only' || fail "lint: missing_path row must be report only"
grep -F '`broken_link`' "$f" | grep -qF 'backticks or a fence' || fail "lint: broken_link row must mention backticks or a fence"
awk '/^## 3\. Mechanical fixes/{m=NR} /^## 4\. Report/{r=NR} END{exit !(m && r && m < r)}' "$f" || fail "lint: report must come after the mechanical fixes"
end_test

start_test "handoff: status section only, marker, distill, handoff-<sid>, clear/compact"
f="$SKILLS/handoff/SKILL.md"
for p in '## ⚡ 現況' '(omk-project)' 'distill' 'handoff-' '${CLAUDE_SESSION_ID}' 'OMC_STATE_DIR' '/clear' '/compact'; do
  need "$f" "$p" handoff
done
need "$f" 'never the knowledge base' handoff
need "$f" 'If step 1 found a marker line' handoff
need "$f" 'auto_handoff_repeat' handoff
end_test

start_test "handoff step 4: marker gets max(r, c); 0 only when both invalid"
f="$SKILLS/handoff/SKILL.md"
snip="$(awk '/^## 4\./{s=1; next} s && /^```bash/{p=1; next} p && /^```/{exit} p{print}' "$f")"
if [ -z "$snip" ]; then fail "handoff step 4 snippet not found"; else
  pat='${CLAUDE_SESSION_ID}'
  # run_h <marker|-> <ctx|-> -> prints stdout line, then the marker file content
  run_h() {
    local sd="$T/h-state"; rm -rf "$sd"; mkdir -p "$sd"
    [ "$1" = - ] || printf '%b' "$1" > "$sd/handoff-s_1"
    [ "$2" = - ] || printf '%b' "$2" > "$sd/ctx-s_1"
    OMC_STATE_DIR="$sd" bash -c "${snip//"$pat"/s/1}" >"$T/h-out" 2>&1
    printf '%s|%s' "$(tr -d '\r' < "$T/h-out")" "$(cat "$sd/handoff-s_1" 2>/dev/null | tr -d '\r')"
  }
  assert_eq "marker written: 80|80" "$(run_h '80\n' '60 200000\n')" "r > c"
  assert_eq "marker written: 75|75" "$(run_h '20\n' '75 200000\n')" "c > r"
  assert_eq "marker written: 0|0" "$(run_h 'abc\n' 'xyz 1\n')" "both invalid"
  assert_eq "marker written: 0|0" "$(run_h '150\n' '1000 200000\n')" "both out of range"
  assert_eq "marker written: 0|0" "$(run_h '' '')" "both empty"
  assert_eq "marker written: 0|0" "$(run_h - -)" "neither file"
  assert_eq "marker written: 75|75" "$(run_h '' '75 200000\r\n')" "empty marker, CRLF ctx"
  assert_eq "marker written: 72|72" "$(run_h '72\r\n' '10 200000\n')" "CRLF marker"
  assert_eq "marker written: 40|40" "$(run_h '00000000000000000090\n' '40 200000\n')" "20-digit marker invalid"
  assert_eq "marker written: 40|40" "$(run_h '30\n' '040 200000\n')" "leading zero ctx parsed base 10"
  assert_eq "marker written: 55|55" "$(run_h '55\n' ' 200000\n')" "ctx with empty first token"
  out="$(OMC_STATE_DIR="$T/h-state2" bash -c "$snip" 2>&1)"
  assert_eq "no session id; marker skipped" "$out" "unsubstituted sid skipped"
  [ -e "$T/h-state2" ] && fail "unsubstituted sid created state dir"
fi
end_test

print_summary

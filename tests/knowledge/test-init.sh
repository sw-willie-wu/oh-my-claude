#!/bin/bash
# Tests for oh-my-knowledge: common.sh helpers, omk_config, plugin.json userConfig, templates, init.sh.
set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(dirname "$(dirname "$SCRIPT_DIR")")"
# shellcheck source=../test-helpers.sh
. "$REPO_ROOT/tests/test-helpers.sh"

PLUGIN="$REPO_ROOT/plugins/oh-my-knowledge"
COMMON="$PLUGIN/scripts/lib/common.sh"
INIT="$PLUGIN/scripts/init.sh"
PJ="$PLUGIN/.claude-plugin/plugin.json"

# Isolation: temp HOME, temp git config, no inherited OMK_*/plugin options.
for v in $(compgen -e | grep -E '^(OMK_|CLAUDE_PLUGIN_OPTION_|CLAUDE_CONFIG_DIR$)'); do unset "$v"; done
T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
export HOME="$T/home"; mkdir -p "$HOME"
export GIT_CONFIG_GLOBAL="$T/gitconfig-empty"; : > "$GIT_CONFIG_GLOBAL"
export GIT_CONFIG_NOSYSTEM=1
export OMC_STATE_DIR="$T/state"

IS_WIN=0
case "${OSTYPE:-}" in msys*|cygwin*) IS_WIN=1;; esac

# call <fn> args...: run a common.sh function in a fresh bash.
call() { bash -c '. "$1"; shift; "$@"' _ "$COMMON" "$@" | tr -d '\r'; }

start_test "common.sh exists"
[ -f "$COMMON" ] || { printf '    FAIL: missing %s\n' "$COMMON" >&2; TEST_FAILED=1; }
end_test

start_test "omk_resolve_dir table"
assert_eq "$HOME/a" "$(call omk_resolve_dir '~/a')" "~/a"
assert_eq "/c/x/y" "$(call omk_resolve_dir 'C:\x\y')" "C:\\x\\y"
assert_eq "/c/x/y" "$(call omk_resolve_dir 'C:/x/y/')" "C:/x/y/"
assert_eq "/c/x" "$(call omk_resolve_dir 'c:/x')" "c:/x"
assert_eq "/c/x" "$(call omk_resolve_dir '/c/x')" "/c/x"
assert_eq "/c/中文 dir" "$(call omk_resolve_dir '/c/中文 dir')" "CJK+space"
assert_eq "/c/a b/c" "$(call omk_resolve_dir 'C:\a b\c\')" "space backslash"
end_test

start_test "omk_resolve_dir canonicalises existing dirs (/tmp vs long form)"
D="$(mktemp -d)"
LONGD="$(cd "$D" && pwd -P)"
assert_eq "$LONGD" "$(call omk_resolve_dir "$D")" "short/tmp form"
assert_eq "$LONGD" "$(call omk_resolve_dir "$LONGD/")" "long form with slash"
if [ "$IS_WIN" = 1 ]; then
  W="$(cd "$D" && pwd -W)"
  assert_eq "$LONGD" "$(call omk_resolve_dir "$W")" "C:/ form of existing dir"
fi
mkdir -p "$D/sp ace/中文"
assert_eq "$LONGD/sp ace/中文" "$(call omk_resolve_dir "$D/sp ace/中文")" "spaces+CJK existing"
end_test

start_test "omk_encode_name table (platform independent)"
assert_eq 'C--Users-jane-doe-Repos-P0001-----' "$(call omk_encode_name 'C:/Users/jane_doe/Repos/P0001_測試專案')" "jane_doe"
assert_eq 'a-b' "$(call omk_encode_name 'a b')" "space"
assert_eq 'a-b' "$(call omk_encode_name 'a.b')" "dot"
assert_eq 'a-b-' "$(call omk_encode_name 'a(b)')" "paren"
assert_eq 'a-b' "$(call omk_encode_name 'a@b')" "at"
assert_eq 'abcXYZ019' "$(call omk_encode_name 'abcXYZ019')" "alnum kept"
end_test

start_test "omk_encode_path == omk_encode_name of omk_native_path"
N="$(call omk_native_path "$D")"
assert_eq "$(call omk_encode_name "$N")" "$(call omk_encode_path "$D")" "encode_path"
if [ "$IS_WIN" = 1 ]; then
  case "$N" in [A-Za-z]:/*) ;; *) printf '    FAIL: native path not C:/ form: %s\n' "$N" >&2; TEST_FAILED=1;; esac
fi
end_test

start_test "omk_repo_root: main repo, subdir, linked worktree"
R="$(mktemp -d)"; WT="$(mktemp -d)"; rmdir "$WT"
git -C "$R" init -q . >/dev/null 2>&1
git -C "$R" -c user.name=t -c user.email=t@x commit -q --allow-empty -m init >/dev/null 2>&1
mkdir -p "$R/sub/deep"
git -C "$R" worktree add -q "$WT" -b wt >/dev/null 2>&1
mkdir -p "$WT/inner"
RR="$(call omk_resolve_dir "$R")"
[ -n "$RR" ] || { echo "    FAIL: empty repo root" >&2; TEST_FAILED=1; }
assert_eq "$RR" "$(call omk_repo_root "$R")" "main root"
assert_eq "$RR" "$(call omk_repo_root "$R/sub/deep")" "subdir"
assert_eq "$RR" "$(call omk_repo_root "$WT")" "linked worktree"
assert_eq "$RR" "$(call omk_repo_root "$WT/inner")" "worktree subdir"
NG="$(mktemp -d)"
assert_eq "$(call omk_resolve_dir "$NG")" "$(call omk_repo_root "$NG")" "non-git dir"
rm -rf "$R" "$WT" "$NG"
end_test

start_test "omk_config defaults"
out="$(bash -c '. "$1"; omk_config; for k in OMK_KNOWLEDGE_DIR OMK_LOOKUP_REMINDER OMK_AUTO_HANDOFF OMK_AUTO_HANDOFF_THRESHOLD OMK_LINT_STALE_DAYS OMK_LINT_FLAG_DAYS OMK_LINT_REMIND_AFTER_DISTILLS OMK_MAX_FILE_KB OMK_MAX_INDEX_LINE_CHARS OMK_AUTO_MEMORY_DIR OMK_AUTO_MEMORY_GLOB OMK_CLAUDE_MD OMC_STATE_DIR OMK_JQ; do echo "$k=${!k}"; done' _ "$COMMON" | tr -d '\r')"
for kv in "OMK_KNOWLEDGE_DIR=$HOME/knowledge" OMK_LOOKUP_REMINDER=true OMK_AUTO_HANDOFF=true OMK_AUTO_HANDOFF_THRESHOLD=70 \
  OMK_LINT_STALE_DAYS=90 OMK_LINT_FLAG_DAYS=14 OMK_LINT_REMIND_AFTER_DISTILLS=10 OMK_MAX_FILE_KB=8 OMK_MAX_INDEX_LINE_CHARS=200 \
  OMK_AUTO_MEMORY_DIR= "OMK_AUTO_MEMORY_GLOB=$HOME/.claude/projects/*/memory" "OMK_CLAUDE_MD=$HOME/.claude/CLAUDE.md" \
  "OMC_STATE_DIR=$T/state" OMK_JQ=jq; do
  grep -qxF -- "$kv" <<<"$out" || { printf '    FAIL: default missing: %s\n' "$kv" >&2; TEST_FAILED=1; }
done
v="$(env -u OMC_STATE_DIR bash -c '. "$1"; omk_config; echo "$OMC_STATE_DIR"' _ "$COMMON" | tr -d '\r')"
assert_eq "$HOME/.claude/oh-my-claude/state" "$v" "OMC_STATE_DIR default"
end_test

start_test "omk_config precedence env > CLAUDE_PLUGIN_OPTION_ > default; booleans normalised"
cfg() { bash -c '. "$1"; omk_config; echo "${!2}"' _ "$COMMON" "$1" | tr -d '\r'; }
assert_eq "55" "$(OMK_AUTO_HANDOFF_THRESHOLD=55 CLAUDE_PLUGIN_OPTION_AUTO_HANDOFF_THRESHOLD=44 cfg OMK_AUTO_HANDOFF_THRESHOLD)" "env wins"
assert_eq "44" "$(CLAUDE_PLUGIN_OPTION_AUTO_HANDOFF_THRESHOLD=44 cfg OMK_AUTO_HANDOFF_THRESHOLD)" "plugin option"
assert_eq "70" "$(cfg OMK_AUTO_HANDOFF_THRESHOLD)" "default"
assert_eq "false" "$(OMK_AUTO_HANDOFF=False cfg OMK_AUTO_HANDOFF)" "False->false"
assert_eq "false" "$(OMK_AUTO_HANDOFF=0 cfg OMK_AUTO_HANDOFF)" "0->false"
assert_eq "true" "$(OMK_AUTO_HANDOFF=1 cfg OMK_AUTO_HANDOFF)" "1->true"
assert_eq "true" "$(CLAUDE_PLUGIN_OPTION_LOOKUP_REMINDER=TRUE cfg OMK_LOOKUP_REMINDER)" "TRUE->true"
assert_eq "false" "$(CLAUDE_PLUGIN_OPTION_LOOKUP_REMINDER=false cfg OMK_LOOKUP_REMINDER)" "option false"
assert_eq "7" "$(CLAUDE_PLUGIN_OPTION_MAX_FILE_KB=7 cfg OMK_MAX_FILE_KB)" "max_file_kb option"
assert_eq "2026-01-02" "$(OMK_TODAY=2026-01-02 cfg OMK_TODAY)" "OMK_TODAY"
assert_eq "/x/y" "$(OMK_AUTO_MEMORY_DIR=/x/y cfg OMK_AUTO_MEMORY_DIR)" "auto memory dir passthrough"
assert_eq "/p/projects/*/memory" "$(CLAUDE_CONFIG_DIR=/p cfg OMK_AUTO_MEMORY_GLOB)" "CLAUDE_CONFIG_DIR glob"
assert_eq "/p/CLAUDE.md" "$(CLAUDE_CONFIG_DIR=/p cfg OMK_CLAUDE_MD)" "CLAUDE_CONFIG_DIR claude.md"
end_test

start_test "omk_config unset-literal cases"
assert_eq "$HOME/knowledge" "$(OMK_KNOWLEDGE_DIR='${user_config.knowledge_dir}' cfg OMK_KNOWLEDGE_DIR)" "(a) literal kb dir"
assert_eq "70" "$(OMK_AUTO_HANDOFF_THRESHOLD='${user_config.auto_handoff_threshold}' cfg OMK_AUTO_HANDOFF_THRESHOLD)" "(b) literal threshold"
assert_eq "60" "$(OMK_AUTO_HANDOFF_THRESHOLD='${user_config.auto_handoff_threshold}' CLAUDE_PLUGIN_OPTION_AUTO_HANDOFF_THRESHOLD=60 cfg OMK_AUTO_HANDOFF_THRESHOLD)" "(c) literal + option"
assert_eq "true" "$(OMK_AUTO_HANDOFF='${user_config.auto_handoff}' cfg OMK_AUTO_HANDOFF)" "literal boolean"
KB1="$(mktemp -d)"
assert_eq "$(call omk_resolve_dir "$KB1")" "$(CLAUDE_PLUGIN_OPTION_KNOWLEDGE_DIR="$KB1" OMK_KNOWLEDGE_DIR='${user_config.knowledge_dir}' cfg OMK_KNOWLEDGE_DIR)" "literal + option kb dir"
rm -rf "$KB1"
end_test

start_test "plugin.json userConfig: nine keys, ranges, defaults == omk_config defaults"
KEYS="auto_handoff,auto_handoff_threshold,knowledge_dir,lint_flag_days,lint_remind_after_distills,lint_stale_days,lookup_reminder,max_file_kb,max_index_line_chars"
assert_eq "$KEYS" "$(jq -r '.userConfig | keys | join(",")' "$PJ" | tr -d '\r')" "keys"
assert_eq "false" "$(jq 'has("version")' "$PJ" | tr -d '\r')" "no version"
assert_eq "knowledge_dir" "$(jq -r '[.userConfig | to_entries[] | select(.value.required==true) | .key] | join(",")' "$PJ" | tr -d '\r')" "required only knowledge_dir"
assert_eq "" "$(jq -r '[.userConfig | to_entries[] | select((.value.type==null) or (.value.title==null) or (.value.description==null) or (.value.default==null)) | .key] | join(",")' "$PJ" | tr -d '\r')" "all have type/title/description/default"
assert_eq "directory,boolean,boolean,number" "$(jq -r '[.userConfig.knowledge_dir.type,.userConfig.lookup_reminder.type,.userConfig.auto_handoff.type,.userConfig.max_file_kb.type]|join(",")' "$PJ" | tr -d '\r')" "types"
rng() { jq -r --arg k "$1" '.userConfig[$k] | "\(.min)-\(.max)"' "$PJ" | tr -d '\r'; }
assert_eq "30-90" "$(rng auto_handoff_threshold)" "threshold range"
assert_eq "1-3650" "$(rng lint_stale_days)" "stale range"
assert_eq "1-3650" "$(rng lint_flag_days)" "flag range"
assert_eq "1-1000" "$(rng lint_remind_after_distills)" "distills range"
assert_eq "1-64" "$(rng max_file_kb)" "kb range"
assert_eq "80-1000" "$(rng max_index_line_chars)" "chars range"
declare -A MAP=([knowledge_dir]=OMK_KNOWLEDGE_DIR [lookup_reminder]=OMK_LOOKUP_REMINDER [auto_handoff]=OMK_AUTO_HANDOFF \
  [auto_handoff_threshold]=OMK_AUTO_HANDOFF_THRESHOLD [lint_stale_days]=OMK_LINT_STALE_DAYS [lint_flag_days]=OMK_LINT_FLAG_DAYS \
  [lint_remind_after_distills]=OMK_LINT_REMIND_AFTER_DISTILLS [max_file_kb]=OMK_MAX_FILE_KB [max_index_line_chars]=OMK_MAX_INDEX_LINE_CHARS)
for k in "${!MAP[@]}"; do
  jd="$(jq -r --arg k "$k" '.userConfig[$k].default' "$PJ" | tr -d '\r')"
  [ "$k" = knowledge_dir ] && jd="$(call omk_resolve_dir "$jd")"
  assert_eq "$jd" "$(cfg "${MAP[$k]}")" "default of $k"
done
end_test

assert_has() { grep -qF -- "$2" "$1" 2>/dev/null || { echo "    FAIL: $3 (missing in $1: $2)" >&2; TEST_FAILED=1; }; }
start_test "templates present and carry the fixed literals"
TP="$PLUGIN/templates"
for f in SCHEMA.md index.md log.md inbox.md rules-INDEX.md; do
  [ -s "$TP/$f" ] || { printf '    FAIL: missing template %s\n' "$f" >&2; TEST_FAILED=1; }
done
assert_has "$TP/SCHEMA.md" '(omk-harvested)' "harvested marker"
assert_has "$TP/SCHEMA.md" '- Knowledge base project: [[k:projects/<p>/index]] (omk-project)' "project marker"
assert_has "$TP/SCHEMA.md" '> ⚠ UNVERIFIED (YYYY-MM-DD):' "unverified marker"
assert_has "$TP/SCHEMA.md" '> Moved: ' "stub marker"
assert_has "$TP/SCHEMA.md" '## [YYYY-MM-DD] <action> | <title>' "log heading"
assert_has "$TP/SCHEMA.md" '[[g:slug]]' "g link"
assert_has "$TP/SCHEMA.md" '[[k:<relpath>]]' "k link"
assert_has "$TP/SCHEMA.md" 'metadata.type' "type rule"
assert_has "$TP/index.md" '## Sub-indexes' "index sub-indexes"
assert_has "$TP/index.md" '## Projects' "index projects"
assert_has "$TP/index.md" '- [[k:projects/<p>/index]] — <description>' "index project line"
assert_has "$TP/index.md" '## Maintenance status' "index maintenance"
first="$(head -n1 "$TP/rules-INDEX.md" 2>/dev/null)"
case "$first" in *'[[g:'*'[[k:'*) ;; *) printf '    FAIL: rules-INDEX line 1 lacks link definition: %s\n' "$first" >&2; TEST_FAILED=1;; esac
assert_has "$TP/rules-INDEX.md" '@' "import format explained"
assert_has "$TP/SCHEMA.md" 'global/index_architecture.md' "architecture sub-index rule"
assert_has "$TP/SCHEMA.md" 'status section' "status section definition"
assert_has "$TP/SCHEMA.md" 'handoff later creates the status section above it' "no-status-section rule"
# log.md template: the example heading must be inside a code fence (no real entry)
real="$(awk '/^```/{f=!f; next} !f && /^## \[/{print}' "$TP/log.md")"
assert_eq "" "$real" "log.md has no unfenced entry heading"
assert_has "$TP/log.md" '## [YYYY-MM-DD] <action> | <title>' "log example present"
sz=$(wc -c < "$TP/SCHEMA.md" 2>/dev/null || echo 0)
[ "$sz" -le 8192 ] || { printf '    FAIL: SCHEMA.md %s bytes > 8 KB\n' "$sz" >&2; TEST_FAILED=1; }
end_test

# --- init.sh ---
runinit() { OMK_KNOWLEDGE_DIR="$1" bash "$INIT" 2>&1 | tr -d '\r'; }

start_test "init.sh creates skeleton"
KB="$T/kb1"
out="$(runinit "$KB")"
assert_eq "initialized $(call omk_resolve_dir "$KB")" "$out" "message"
for d in rules global projects lint _retired .git; do [ -d "$KB/$d" ] || { printf '    FAIL: missing dir %s\n' "$d" >&2; TEST_FAILED=1; }; done
for f in SCHEMA.md index.md log.md inbox.md rules/INDEX.md; do [ -s "$KB/$f" ] || { printf '    FAIL: missing file %s\n' "$f" >&2; TEST_FAILED=1; }; done
assert_eq "oh-my-knowledge@localhost" "$(git -C "$KB" config user.email)" "local identity set"
assert_eq "oh-my-knowledge" "$(git -C "$KB" config user.name)" "local name"
assert_eq "" "$(cat "$GIT_CONFIG_GLOBAL")" "global git config untouched"
assert_eq "* text=auto eol=lf" "$(cat "$KB/.gitattributes" | tr -d '\r')" ".gitattributes content"
assert_eq "1" "$(wc -l < "$KB/.gitattributes" | tr -d ' ')" ".gitattributes is exactly one line"
assert_eq "19" "$(wc -c < "$KB/.gitattributes" | tr -d ' ')" ".gitattributes bytes (LF only)"
end_test

start_test "init.sh idempotent and keeps edited SCHEMA.md"
echo "custom schema 自訂" > "$KB/SCHEMA.md"
echo "x" >> "$KB/log.md"
before="$(cat "$KB/log.md")"
out="$(runinit "$KB")"
assert_eq "already initialized $(call omk_resolve_dir "$KB")" "$out" "message"
assert_eq "custom schema 自訂" "$(cat "$KB/SCHEMA.md")" "SCHEMA kept"
assert_eq "$before" "$(cat "$KB/log.md")" "log kept"
end_test

start_test "init.sh with spaced path in all three forms"
SP="$T/sp ace 中文/kb"
mkdir -p "$T/sp ace 中文"
out="$(runinit "$SP")"
assert_eq "initialized $(call omk_resolve_dir "$SP")" "$out" "posix form"
[ -d "$SP/rules" ] || { printf '    FAIL: skeleton missing\n' >&2; TEST_FAILED=1; }
out="$(runinit "$SP/")"
case "$out" in "already initialized "*) ;; *) printf '    FAIL: trailing-slash form: %s\n' "$out" >&2; TEST_FAILED=1;; esac
if [ "$IS_WIN" = 1 ]; then
  W="$(cd "$SP" && pwd -W)"
  out="$(runinit "$W")"
  case "$out" in "already initialized "*) ;; *) printf '    FAIL: C:/ form: %s\n' "$out" >&2; TEST_FAILED=1;; esac
  WB="${W//\//\\}"
  out="$(runinit "$WB")"
  case "$out" in "already initialized "*) ;; *) printf '    FAIL: C:\\ form: %s\n' "$out" >&2; TEST_FAILED=1;; esac
fi
mkdir -p "$HOME/kbhome"
out="$(runinit '~/kbhome')"
assert_eq "initialized $(call omk_resolve_dir "$HOME/kbhome")" "$out" "~ form"
end_test

start_test "init.sh sets identity only when none resolvable"
printf '[user]\n\temail = jane_doe@example.com\n\tname = Jane Doe\n' > "$T/gitconfig-id"
KB2="$T/kb2"
GIT_CONFIG_GLOBAL="$T/gitconfig-id" runinit "$KB2" >/dev/null
assert_eq "" "$(git -C "$KB2" config --local user.email)" "no local identity when global has one"
assert_eq "oh-my-knowledge@localhost" "$(git -C "$T/kb1" config --local user.email)" "local identity when none"
assert_eq "$(printf '[user]\n\temail = jane_doe@example.com\n\tname = Jane Doe')" "$(cat "$T/gitconfig-id")" "global id file untouched"
end_test

start_test "init.sh with unset-literal knowledge_dir creates nothing named \${"
mkdir -p "$T/cwd"
( cd "$T/cwd" && OMK_KNOWLEDGE_DIR='${user_config.knowledge_dir}' bash "$INIT" >/dev/null 2>&1 )
assert_eq "" "$(find "$T/cwd" -name '*$*' 2>/dev/null)" "no \${ dirs in cwd"
assert_eq "" "$(find "$HOME" -name '*{*' 2>/dev/null)" "no \${ dirs in HOME"
[ -f "$HOME/knowledge/SCHEMA.md" ] || { printf '    FAIL: default ~/knowledge not created\n' >&2; TEST_FAILED=1; }
end_test

start_test "init.sh on an existing KB from elsewhere adds only missing skeleton parts (dirs, rules/INDEX.md, .gitattributes)"
EX="$T/existing"
mkdir -p "$EX/global" "$EX/projects/p1"
git -C "$EX" init -q . >/dev/null 2>&1
printf '# 我的 SCHEMA\n' > "$EX/SCHEMA.md"
printf '# 索引\n' > "$EX/index.md"
printf '# log\n' > "$EX/log.md"
printf '# inbox\n' > "$EX/inbox.md"
printf '頁面\n' > "$EX/global/page.md"
printf 'p\n' > "$EX/projects/p1/index.md"
snap() { (cd "$EX" && find . -path ./.git -prune -o -type f -print0 | sort -z | xargs -0 md5sum); }
b="$(snap)"; cfgb="$(cat "$EX/.git/config")"
out="$(GIT_CONFIG_GLOBAL="$T/gitconfig-id" runinit "$EX")"
assert_eq "already initialized $(call omk_resolve_dir "$EX")" "$out" "message"
a="$(snap | grep -vE 'rules/INDEX.md|.gitattributes')"
assert_eq "$b" "$a" "existing files byte-identical"
for d in rules lint _retired; do [ -d "$EX/$d" ] || { printf '    FAIL: dir %s not added\n' "$d" >&2; TEST_FAILED=1; }; done
assert_eq "* text=auto eol=lf" "$(tr -d '\r' < "$EX/.gitattributes")" ".gitattributes added to copied KB"
assert_eq "$cfgb" "$(cat "$EX/.git/config")" ".git/config unchanged when identity resolvable"
end_test

start_test "init.sh keeps an existing .gitattributes byte-identical"
EX2="$T/existing2"; mkdir -p "$EX2"; git -C "$EX2" init -q . >/dev/null 2>&1
printf '*.md -text
# 自訂
' > "$EX2/.gitattributes"; b2="$(md5sum < "$EX2/.gitattributes")"
runinit "$EX2" >/dev/null
assert_eq "$b2" "$(md5sum < "$EX2/.gitattributes")" ".gitattributes kept"
end_test

print_summary

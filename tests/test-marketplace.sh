#!/bin/bash
# Tests for the marketplace layout: plugins/ split, manifests, rename, sweep.
set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"

# shellcheck source=test-helpers.sh
. "$SCRIPT_DIR/test-helpers.sh"

MKT="$REPO_ROOT/.claude-plugin/marketplace.json"
STATUS_DIR="$REPO_ROOT/plugins/oh-my-status"

start_test "marketplace lists exactly oh-my-knowledge, oh-my-status and oh-my-teams"
assert_eq "oh-my-knowledge,oh-my-status,oh-my-teams" \
  "$(jq -r '[.plugins[].name] | sort | join(",")' "$MKT" 2>/dev/null | tr -d '\r')" "plugin names"
end_test

start_test "each plugin source dir exists and plugin.json name matches"
for n in oh-my-knowledge oh-my-status oh-my-teams; do
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

start_test "no old command prefix in commands, setup.sh, install.sh, README*.md, docs"
old='/oh-my-claude'; old+=':'   # built at runtime so this file never matches itself
for p in "$STATUS_DIR/commands" "$STATUS_DIR/setup.sh" "$REPO_ROOT/install.sh" "$REPO_ROOT/README.md" "$REPO_ROOT/README.zh-TW.md" "$REPO_ROOT/docs"; do
  if [ ! -e "$p" ]; then
    printf '    FAIL: path missing: %s\n' "$p" >&2; TEST_FAILED=1
  elif [ -n "$(grep -rnF -- "$old" "$p" 2>/dev/null)" ]; then
    printf '    FAIL: old prefix found in %s\n' "$p" >&2; TEST_FAILED=1
  fi
done
end_test

# --- setup.sh: sweep relocation + Workers-leftover cleanup ----------
run_setup() {  # $1=sandbox ; runs setup.sh fully sandboxed, returns its rc
  mkdir -p "$1/home"
  HOME="$1/home" OMC_DIR="$1/omc" OMC_CONF="$1/c.conf" OMC_STATE_DIR="$1/state" \
    OMC_CONF_TEMPLATE="$STATUS_DIR/oh-my-claude.conf" \
    bash "$STATUS_DIR/setup.sh" </dev/null >/dev/null 2>&1
}
old_ts() {  # echoes a touch -t timestamp 25 hours ago
  if date -d '25 hours ago' '+%Y%m%d%H%M.%S' >/dev/null 2>&1; then
    date -d '25 hours ago' '+%Y%m%d%H%M.%S'
  else
    date -v-25H '+%Y%m%d%H%M.%S'
  fi
}

start_test "setup sweep removes 25h-old ctx-*/handoff-*/gitcache-*/account-* and keeps fresh ones"
sbox=$(mktemp -d); mkdir -p "$sbox/state"; st="$sbox/state"
for k in ctx handoff gitcache account; do
  printf x > "$st/$k-old"; printf x > "$st/$k-fresh"
done
TS=$(old_ts)
touch -t "$TS" "$st/ctx-old" "$st/handoff-old" "$st/gitcache-old" "$st/account-old"
# old marker + fresh ctx (kept); old marker + no ctx (removed)
printf x > "$st/handoff-live"; printf x > "$st/ctx-live"
printf x > "$st/handoff-orphan"
touch -t "$TS" "$st/handoff-live" "$st/handoff-orphan"
run_setup "$sbox"; rc=$?
assert_eq "0" "$rc" "setup.sh exit code"
for k in ctx handoff gitcache account; do
  [ ! -f "$st/$k-old" ] || { printf '    FAIL: stale %s-old not removed\n' "$k" >&2; TEST_FAILED=1; }
  [ -f "$st/$k-fresh" ] || { printf '    FAIL: fresh %s-fresh removed\n' "$k" >&2; TEST_FAILED=1; }
done
[ -f "$st/handoff-live" ] || { printf '    FAIL: old marker with fresh ctx removed\n' >&2; TEST_FAILED=1; }
[ -f "$st/ctx-live" ] || { printf '    FAIL: fresh ctx removed\n' >&2; TEST_FAILED=1; }
[ ! -f "$st/handoff-orphan" ] || { printf '    FAIL: old marker without ctx not removed\n' >&2; TEST_FAILED=1; }
rm -rf "$sbox"
end_test

start_test "setup exits 0 when the last marker the sweep loop handles is kept"
sbox=$(mktemp -d); mkdir -p "$sbox/state"; st="$sbox/state"
printf x > "$st/handoff-live"; printf x > "$st/ctx-live"
touch -t "$(old_ts)" "$st/handoff-live"
run_setup "$sbox"; rc=$?
assert_eq "0" "$rc" "setup.sh exit code (R2-I2)"
[ -f "$st/handoff-live" ] || { printf '    FAIL: handoff-live removed\n' >&2; TEST_FAILED=1; }
[ -f "$st/ctx-live" ] || { printf '    FAIL: ctx-live removed\n' >&2; TEST_FAILED=1; }
rm -rf "$sbox"
end_test

start_test "setup exits 0 when OMC_STATE_DIR is absent"
sbox=$(mktemp -d)
run_setup "$sbox"; rc=$?
assert_eq "0" "$rc" "setup.sh exit code"
rm -rf "$sbox"
end_test

start_test "setup cleanup removes Workers leftovers only"
sbox=$(mktemp -d); st="$sbox/state"; od="$sbox/omc"
mkdir -p "$st/state.lock" "$od/hooks" "$od/lib"
printf x > "$st/state-a.tsv"; printf x > "$st/state-a.tsv.prune.1"
printf 1 > "$st/state.lock/pid"; printf x > "$st/track-workers.log"
printf x > "$od/hooks/track-workers.sh"; printf x > "$od/hooks/my-hook.sh"
printf x > "$od/lib/state-lock.sh"; printf x > "$od/lib/conf-keys.sh"; printf x > "$od/lib/x.sh"
printf x > "$od/statusline.sh.bak-x"
printf x > "$st/ctx-s"; printf x > "$st/gitcache-k"; printf x > "$st/account-k"
run_setup "$sbox"; rc=$?
assert_eq "0" "$rc" "setup.sh exit code"
for p in "$st/state-a.tsv" "$st/state-a.tsv.prune.1" "$st/state.lock" "$st/track-workers.log" \
         "$od/hooks/track-workers.sh" "$od/lib/state-lock.sh" "$od/lib/conf-keys.sh"; do
  [ ! -e "$p" ] || { printf '    FAIL: leftover not removed: %s\n' "$p" >&2; TEST_FAILED=1; }
done
for p in "$od/hooks/my-hook.sh" "$od/lib/x.sh" "$od/hooks" "$od/lib" "$od/statusline.sh.bak-x" \
         "$st/ctx-s" "$st/gitcache-k" "$st/account-k"; do
  [ -e "$p" ] || { printf '    FAIL: user/other file removed: %s\n' "$p" >&2; TEST_FAILED=1; }
done
rm -rf "$sbox"
end_test

start_test "setup cleanup rmdirs hooks/ and lib/ when only named files were there"
sbox=$(mktemp -d); od="$sbox/omc"
mkdir -p "$od/hooks" "$od/lib"
printf x > "$od/hooks/track-workers.sh"
printf x > "$od/lib/state-lock.sh"; printf x > "$od/lib/conf-keys.sh"
run_setup "$sbox"; rc=$?
assert_eq "0" "$rc" "setup.sh exit code"
[ ! -e "$od/hooks" ] || { printf '    FAIL: empty hooks/ not removed\n' >&2; TEST_FAILED=1; }
[ ! -e "$od/lib" ] || { printf '    FAIL: empty lib/ not removed\n' >&2; TEST_FAILED=1; }
[ -f "$od/statusline.sh" ] || { printf '    FAIL: statusline.sh not installed\n' >&2; TEST_FAILED=1; }
rm -rf "$sbox"
end_test

start_test "setup cleanup is spawn-free when nothing is left to clean (no rm call)"
sbox=$(mktemp -d); st="$sbox/state"; od="$sbox/omc"
mkdir -p "$st/state.lock" "$od/hooks" "$od/lib"
printf x > "$st/state-a.tsv"; printf 1 > "$st/state.lock/pid"; printf x > "$st/track-workers.log"
printf x > "$od/hooks/track-workers.sh"; printf x > "$od/lib/state-lock.sh"; printf x > "$od/lib/conf-keys.sh"
run_setup "$sbox"        # first run: cleans the seeded leftovers
cat > "$sbox/run.sh" <<EOS
#!/bin/bash
export HOME="$sbox/home" OMC_DIR="$od" OMC_CONF="$sbox/c.conf" OMC_STATE_DIR="$st" \
  OMC_CONF_TEMPLATE="$STATUS_DIR/oh-my-claude.conf"
"$BASH" "$STATUS_DIR/setup.sh"
EOS
count_spawns "$sbox/cnt" /dev/null "$sbox/run.sh"
assert_eq "0" "$SPAWN_MISSING" "un-shimmed externals in setup.sh"
assert_eq "0" "$(grep -c '^EXEC rm ' "$sbox/cnt/log" || true)" "rm calls on the second (clean) run"
[ "$SPAWN_EXECS" -gt 0 ] || { printf '    FAIL: harness saw no setup.sh externals (vacuous)\n' >&2; TEST_FAILED=1; }
rm -rf "$sbox"
end_test

start_test "setup does not copy lib/ any more"
sbox=$(mktemp -d)
run_setup "$sbox"; rc=$?
assert_eq "0" "$rc" "setup.sh exit code"
[ ! -e "$sbox/omc/lib" ] || { printf '    FAIL: %s/omc/lib exists\n' "$sbox" >&2; TEST_FAILED=1; }
rm -rf "$sbox"
end_test

start_test "hooks.json has exactly one hook: SessionStart -> setup.sh"
HJ="$STATUS_DIR/hooks/hooks.json"
assert_eq "SessionStart" "$(jq -r '.hooks | keys | join(",")' "$HJ" 2>/dev/null | tr -d '\r')" "hook events"
assert_eq "1" "$(jq '[.hooks.SessionStart[].hooks[]] | length' "$HJ" 2>/dev/null | tr -d '\r')" "hook count"
case "$(jq -r '.hooks.SessionStart[0].hooks[0].command' "$HJ" 2>/dev/null | tr -d '\r')" in
  */setup.sh) ;;
  *) printf '    FAIL: hook command does not end in /setup.sh\n' >&2; TEST_FAILED=1 ;;
esac
end_test

start_test "knowledge doc documents settings, state files, markers, requirements, moving"
KR="$REPO_ROOT/docs/knowledge.md"
if [ ! -f "$KR" ]; then
  printf '    FAIL: missing %s\n' "$KR" >&2; TEST_FAILED=1
else
  for k in $(jq -r '.userConfig | keys[]' "$REPO_ROOT/plugins/oh-my-knowledge/.claude-plugin/plugin.json" | tr -d '\r'); do
    grep -qF -- "\`$k\`" "$KR" || { printf '    FAIL: knowledge doc lacks setting %s\n' "$k" >&2; TEST_FAILED=1; }
  done
  for s in 'ctx-<' 'handoff-<' '(omk-harvested)' '(omk-project)' 'always-on.md' 'OMK_AUTO_MEMORY_GLOB' 'Moving to another machine'; do
    grep -qF -- "$s" "$KR" || { printf '    FAIL: knowledge doc lacks %s\n' "$s" >&2; TEST_FAILED=1; }
  done
  req=$(awk '/^## Requirements/{f=1;next} /^## /{f=0} f' "$KR")
  for s in jq gawk; do
    printf "%s" "$req" | grep -qF -- "$s" || { printf '    FAIL: Requirements section lacks %s\n' "$s" >&2; TEST_FAILED=1; }
  done
fi
end_test

start_test "upgrade notes tell disabled users to uninstall, reinstall and disable"
grep -qF -- '/plugin uninstall oh-my-claude@oh-my-claude' "$REPO_ROOT/docs/upgrading.md" \
  || { printf '    FAIL: upgrading doc lacks uninstall note\n' >&2; TEST_FAILED=1; }
grep -qF -- '/plugin disable oh-my-status@oh-my-claude' "$REPO_ROOT/docs/upgrading.md" \
  || { printf '    FAIL: upgrading doc lacks disable note\n' >&2; TEST_FAILED=1; }
grep -qF -- '/plugin disable oh-my-status@oh-my-claude' "$REPO_ROOT/CHANGELOG.md" \
  || { printf '    FAIL: CHANGELOG lacks disable note\n' >&2; TEST_FAILED=1; }
grep -qF -- 'always-on.md' "$REPO_ROOT/CHANGELOG.md" \
  || { printf '    FAIL: CHANGELOG lacks always-on.md note\n' >&2; TEST_FAILED=1; }
grep -qF -- 'SCHEMA.md' "$REPO_ROOT/CHANGELOG.md" \
  || { printf '    FAIL: CHANGELOG lacks SCHEMA.md upgrade note\n' >&2; TEST_FAILED=1; }
[ "$(grep -cF -- 'had `oh-my-claude` disabled' "$REPO_ROOT/CHANGELOG.md")" = 1 ] \
  || { printf '    FAIL: CHANGELOG must have exactly one disabled-user note\n' >&2; TEST_FAILED=1; }
end_test

start_test "marketplace entry for oh-my-knowledge is finalised"
d=$(jq -r '.plugins[] | select(.name=="oh-my-knowledge") | .description' "$MKT" | tr -d '\r')
case "$d" in *"work in progress"*|"") printf '    FAIL: description: %s\n' "$d" >&2; TEST_FAILED=1 ;; esac
end_test

print_summary

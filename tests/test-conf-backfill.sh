#!/bin/bash
# Tests for lib/conf-keys.sh (omc_missing_conf_keys) and setup.sh conf-key
# detection / path-override seam.
set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"

# shellcheck source=test-helpers.sh
. "$SCRIPT_DIR/test-helpers.sh"

# shellcheck source=../lib/conf-keys.sh
. "$REPO_ROOT/lib/conf-keys.sh"

SETUP_SH="$REPO_ROOT/setup.sh"

printf 'Running conf-backfill tests in: %s\n\n' "$OMC_STATE_DIR"

# ============================================================
# omc_missing_conf_keys unit tests
# ============================================================

start_test "absent key reported missing, template order preserved"
tpl="$OMC_STATE_DIR/tpl.conf"; uc="$OMC_STATE_DIR/user.conf"
printf 'THEME=catppuccin\nLAYOUT=fancy\nWORKERS_MAX=5\n' > "$tpl"
printf 'THEME=catppuccin\n' > "$uc"
assert_eq "$(printf 'LAYOUT\nWORKERS_MAX')" \
  "$(omc_missing_conf_keys "$tpl" "$uc")" "missing keys in template order"
end_test

start_test "uncommented KEY= counts as present"
tpl="$OMC_STATE_DIR/tpl.conf"; uc="$OMC_STATE_DIR/user.conf"
printf 'WORKERS_MAX=5\n' > "$tpl"
printf 'WORKERS_MAX=0\n' > "$uc"
assert_eq "" "$(omc_missing_conf_keys "$tpl" "$uc")" "present value-agnostic"
end_test

start_test "export KEY= counts as present"
tpl="$OMC_STATE_DIR/tpl.conf"; uc="$OMC_STATE_DIR/user.conf"
printf 'WORKERS_MAX=5\n' > "$tpl"
printf 'export WORKERS_MAX=2\n' > "$uc"
assert_eq "" "$(omc_missing_conf_keys "$tpl" "$uc")" "export prefix accepted"
end_test

start_test "spaced KEY = v counts as present"
tpl="$OMC_STATE_DIR/tpl.conf"; uc="$OMC_STATE_DIR/user.conf"
printf 'WORKERS_MAX=5\n' > "$tpl"
printf 'WORKERS_MAX = 5\n' > "$uc"
assert_eq "" "$(omc_missing_conf_keys "$tpl" "$uc")" "whitespace around = accepted"
end_test

start_test "KEY=v with trailing inline comment counts as present"
tpl="$OMC_STATE_DIR/tpl.conf"; uc="$OMC_STATE_DIR/user.conf"
printf 'WORKERS_MAX=5\n' > "$tpl"
printf 'WORKERS_MAX=5   # my override\n' > "$uc"
assert_eq "" "$(omc_missing_conf_keys "$tpl" "$uc")" "inline comment ok"
end_test

start_test "commented-only # KEY=v counts as missing"
tpl="$OMC_STATE_DIR/tpl.conf"; uc="$OMC_STATE_DIR/user.conf"
printf 'WORKERS_MAX=5\n' > "$tpl"
printf '# WORKERS_MAX=5\n' > "$uc"
assert_eq "WORKERS_MAX" "$(omc_missing_conf_keys "$tpl" "$uc")" "comment not effective"
end_test

start_test "prefix collision: WORKERS_MAXIMUM does not satisfy WORKERS_MAX"
tpl="$OMC_STATE_DIR/tpl.conf"; uc="$OMC_STATE_DIR/user.conf"
printf 'WORKERS_MAX=5\n' > "$tpl"
printf 'WORKERS_MAXIMUM=1\n' > "$uc"
assert_eq "WORKERS_MAX" "$(omc_missing_conf_keys "$tpl" "$uc")" "right-anchor holds"
end_test

start_test "duplicate KEY= lines: present, no double-report"
tpl="$OMC_STATE_DIR/tpl.conf"; uc="$OMC_STATE_DIR/user.conf"
printf 'WORKERS_MAX=5\n' > "$tpl"
printf 'WORKERS_MAX=1\nWORKERS_MAX=2\n' > "$uc"
assert_eq "" "$(omc_missing_conf_keys "$tpl" "$uc")" "duplicates still present"
end_test

start_test "CRLF-terminated user conf still detects presence"
tpl="$OMC_STATE_DIR/tpl.conf"; uc="$OMC_STATE_DIR/user.conf"
printf 'WORKERS_MAX=5\n' > "$tpl"
printf 'WORKERS_MAX=5\r\n' > "$uc"
assert_eq "" "$(omc_missing_conf_keys "$tpl" "$uc")" "CRLF tolerated"
end_test

start_test "blank and comment lines never yield false keys"
tpl="$OMC_STATE_DIR/tpl.conf"; uc="$OMC_STATE_DIR/user.conf"
printf '# a comment\n\n   \nTHEME=x\n' > "$tpl"
printf 'THEME=x\n' > "$uc"
assert_eq "" "$(omc_missing_conf_keys "$tpl" "$uc")" "only THEME is a key"
end_test

start_test "exit 0 when nothing missing"
tpl="$OMC_STATE_DIR/tpl.conf"; uc="$OMC_STATE_DIR/user.conf"
printf 'THEME=x\n' > "$tpl"
printf 'THEME=x\n' > "$uc"
omc_missing_conf_keys "$tpl" "$uc" >/dev/null
assert_eq "0" "$?" "exit 0 on no-missing"
end_test

start_test "exit 0 when keys missing"
tpl="$OMC_STATE_DIR/tpl.conf"; uc="$OMC_STATE_DIR/user.conf"
printf 'THEME=x\nLAYOUT=y\n' > "$tpl"
printf 'THEME=x\n' > "$uc"
omc_missing_conf_keys "$tpl" "$uc" >/dev/null
assert_eq "0" "$?" "exit 0 on missing"
end_test

start_test "non-zero exit on unreadable template"
uc="$OMC_STATE_DIR/user.conf"; printf 'THEME=x\n' > "$uc"
omc_missing_conf_keys "$OMC_STATE_DIR/does-not-exist.conf" "$uc" >/dev/null 2>&1
rc=$?
[ "$rc" -ne 0 ] || { printf '    FAIL: expected non-zero exit, got %s\n' "$rc" >&2; TEST_FAILED=1; }
end_test

# ============================================================
# setup.sh path-override seam
# ============================================================

start_test "setup.sh honors OMC_CONF/OMC_DIR/OMC_CONF_TEMPLATE overrides"
sbox="$OMC_STATE_DIR/sbox-seam"
mkdir -p "$sbox/home"
custom_conf="$sbox/custom-oh-my-claude.conf"
HOME="$sbox/home" \
  OMC_DIR="$sbox/omc" \
  OMC_CONF="$custom_conf" \
  OMC_CONF_TEMPLATE="$REPO_ROOT/oh-my-claude.conf" \
  bash "$SETUP_SH" >/dev/null 2>&1
[ -f "$custom_conf" ] || { printf '    FAIL: conf not written to OMC_CONF override path\n' >&2; TEST_FAILED=1; }
assert_file_contains "$custom_conf" "WORKERS_MAX" "template copied to override conf path"
[ -d "$sbox/omc" ] || { printf '    FAIL: runtime not written to OMC_DIR override path\n' >&2; TEST_FAILED=1; }
end_test

# ============================================================
# setup.sh conf-key detection (read-only notice)
# ============================================================

start_test "setup.sh emits a context notice when keys are missing"
sbox="$OMC_STATE_DIR/sbox-detect-miss"
mkdir -p "$sbox/home"
uc="$sbox/oh-my-claude.conf"
printf 'THEME=catppuccin\n' > "$uc"   # non-empty partial conf (LAYOUT etc. missing)
out="$(HOME="$sbox/home" \
  OMC_DIR="$sbox/omc" \
  OMC_CONF="$uc" \
  OMC_CONF_TEMPLATE="$REPO_ROOT/oh-my-claude.conf" \
  bash "$SETUP_SH" 2>/dev/null)"
case "$out" in
  *"[oh-my-claude]"*"LAYOUT"*) ;;
  *) printf '    FAIL: notice missing or lacks key name; got: %s\n' "$out" >&2; TEST_FAILED=1 ;;
esac
# the partial user conf must not have been modified by detection
assert_eq "$(printf 'THEME=catppuccin')" "$(cat "$uc")" "detection must not write the conf"
end_test

start_test "setup.sh is silent when the conf has all template keys"
sbox="$OMC_STATE_DIR/sbox-detect-full"
mkdir -p "$sbox/home"
uc="$sbox/oh-my-claude.conf"
cp "$REPO_ROOT/oh-my-claude.conf" "$uc"   # conf == template → nothing missing
out="$(HOME="$sbox/home" \
  OMC_DIR="$sbox/omc" \
  OMC_CONF="$uc" \
  OMC_CONF_TEMPLATE="$REPO_ROOT/oh-my-claude.conf" \
  bash "$SETUP_SH" 2>/dev/null)"
assert_eq "" "$out" "no notice when conf is complete"
end_test

start_test "setup.sh exits 0 and is silent on an unreadable template"
sbox="$OMC_STATE_DIR/sbox-detect-badtpl"
mkdir -p "$sbox/home"
uc="$sbox/oh-my-claude.conf"
printf 'THEME=catppuccin\n' > "$uc"
HOME="$sbox/home" \
  OMC_DIR="$sbox/omc" \
  OMC_CONF="$uc" \
  OMC_CONF_TEMPLATE="$sbox/no-such-template.conf" \
  bash "$SETUP_SH" >"$sbox/out.txt" 2>/dev/null
rc=$?
assert_eq "0" "$rc" "hook exits 0 even with a broken template"
assert_eq "" "$(cat "$sbox/out.txt")" "no notice on broken template"
end_test


# ============================================================
# Template / version (Task 5)
# ============================================================

start_test "T5.1 template leaves icon keys unset"
out=$(env -u ACCOUNT_ICON -u WORKERS_SHELL_ICON bash -c '. "$1"; printf "%s|%s" "${ACCOUNT_ICON-unset}" "${WORKERS_SHELL_ICON-unset}"' _ "$REPO_ROOT/oh-my-claude.conf")
assert_eq "unset|unset" "$out" "icon lines must be commented examples"
end_test

start_test "T5.2 template defines account keys, no removed keys"
out=$(env -u ACCOUNT_SHOW -u ACCOUNT_FORMAT bash -c '. "$1"; printf "%s|%s" "${ACCOUNT_SHOW-unset}" "${ACCOUNT_FORMAT-unset}"' _ "$REPO_ROOT/oh-my-claude.conf")
assert_eq "true|name" "$out" "account defaults in template"
rm_hits=$(grep -c -E 'WORKERS_SHOW_AGENTS|WORKERS_SHOW_TYPE|WORKERS_AGENT_' "$REPO_ROOT/oh-my-claude.conf")
assert_eq "0" "$rm_hits" "no removed agent keys in template"
end_test

start_test "T5.3 empty user conf: missing lists account keys, not icons"
: > "$OMC_STATE_DIR/empty.conf"
miss=$(omc_missing_conf_keys "$REPO_ROOT/oh-my-claude.conf" "$OMC_STATE_DIR/empty.conf" | tr -d '\r')
case "$miss" in *ACCOUNT_SHOW*) a=1;; *) a=0;; esac
case "$miss" in *ACCOUNT_FORMAT*) b=1;; *) b=0;; esac
case "$miss" in *_ICON*) c=1;; *) c=0;; esac
assert_eq "1|1|0" "$a|$b|$c" "ACCOUNT_SHOW|ACCOUNT_FORMAT|icon"
end_test

start_test "T5.4 plugin.json and marketplace.json version is 1.2.0"
v1=$(jq -j '.version' "$REPO_ROOT/.claude-plugin/plugin.json")
v2=$(jq -j '.plugins[0].version' "$REPO_ROOT/.claude-plugin/marketplace.json")
assert_eq "1.2.0|1.2.0" "$v1|$v2" "versions"
end_test

print_summary

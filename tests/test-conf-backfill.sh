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

print_summary

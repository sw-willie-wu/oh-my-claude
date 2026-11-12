#!/bin/bash
# Tests for lib/conf-keys.sh (omc_missing_conf_keys) and setup.sh conf-key
# detection / path-override seam.
set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"

# shellcheck source=test-helpers.sh
. "$SCRIPT_DIR/test-helpers.sh"

# shellcheck source=../plugins/oh-my-status/lib/conf-keys.sh
. "$REPO_ROOT/plugins/oh-my-status/lib/conf-keys.sh"

SETUP_SH="$REPO_ROOT/plugins/oh-my-status/setup.sh"

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
  OMC_CONF_TEMPLATE="$REPO_ROOT/plugins/oh-my-status/oh-my-claude.conf" \
  bash "$SETUP_SH" >/dev/null 2>&1
[ -f "$custom_conf" ] || { printf '    FAIL: conf not written to OMC_CONF override path\n' >&2; TEST_FAILED=1; }
assert_file_contains "$custom_conf" "GIT_CACHE_TTL" "template copied to override conf path"
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
  OMC_CONF_TEMPLATE="$REPO_ROOT/plugins/oh-my-status/oh-my-claude.conf" \
  bash "$SETUP_SH" 2>/dev/null)"
case "$out" in
  *"[oh-my-status]"*"LAYOUT"*) ;;
  *) printf '    FAIL: notice missing or lacks key name; got: %s\n' "$out" >&2; TEST_FAILED=1 ;;
esac
# the partial user conf must not have been modified by detection
assert_eq "$(printf 'THEME=catppuccin')" "$(cat "$uc")" "detection must not write the conf"
end_test

start_test "setup.sh is silent when the conf has all template keys"
sbox="$OMC_STATE_DIR/sbox-detect-full"
mkdir -p "$sbox/home"
uc="$sbox/oh-my-claude.conf"
cp "$REPO_ROOT/plugins/oh-my-status/oh-my-claude.conf" "$uc"   # conf == template → nothing missing
out="$(HOME="$sbox/home" \
  OMC_DIR="$sbox/omc" \
  OMC_CONF="$uc" \
  OMC_CONF_TEMPLATE="$REPO_ROOT/plugins/oh-my-status/oh-my-claude.conf" \
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
# Template / version
# ============================================================

start_test "template leaves icon keys unset"
out=$(env -u ACCOUNT_ICON bash -c '. "$1"; printf "%s" "${ACCOUNT_ICON-unset}"' _ "$REPO_ROOT/plugins/oh-my-status/oh-my-claude.conf")
assert_eq "unset" "$out" "icon lines must be commented examples"
end_test

start_test "template sets GIT_CACHE_TTL to 10"
out=$(env -u GIT_CACHE_TTL bash -c '. "$1"; printf "%s" "${GIT_CACHE_TTL-unset}"' _ "$REPO_ROOT/plugins/oh-my-status/oh-my-claude.conf")
assert_eq "10" "$out" "GIT_CACHE_TTL default in template"
end_test

start_test "template defines account keys, no removed keys"
out=$(env -u ACCOUNT_SHOW -u ACCOUNT_FORMAT bash -c '. "$1"; printf "%s|%s" "${ACCOUNT_SHOW-unset}" "${ACCOUNT_FORMAT-unset}"' _ "$REPO_ROOT/plugins/oh-my-status/oh-my-claude.conf")
assert_eq "true|name" "$out" "account defaults in template"
out=$(env -u MODEL_CTX_TAG bash -c '. "$1"; printf "%s" "${MODEL_CTX_TAG-unset}"' _ "$REPO_ROOT/plugins/oh-my-status/oh-my-claude.conf")
assert_eq "true" "$out" "MODEL_CTX_TAG default in template"
rm_hits=$(grep -c 'WORKERS_' "$REPO_ROOT/plugins/oh-my-status/oh-my-claude.conf")
assert_eq "0" "$rm_hits" "no WORKERS_ keys in template"
end_test

start_test "empty user conf: missing lists account keys, not icons"
: > "$OMC_STATE_DIR/empty.conf"
miss=$(omc_missing_conf_keys "$REPO_ROOT/plugins/oh-my-status/oh-my-claude.conf" "$OMC_STATE_DIR/empty.conf" | tr -d '\r')
case "$miss" in *ACCOUNT_SHOW*) a=1;; *) a=0;; esac
case "$miss" in *ACCOUNT_FORMAT*) b=1;; *) b=0;; esac
case "$miss" in *_ICON*) c=1;; *) c=0;; esac
assert_eq "1|1|0" "$a|$b|$c" "ACCOUNT_SHOW|ACCOUNT_FORMAT|icon"
case "$miss" in *MODEL_CTX_TAG*) d=1;; *) d=0;; esac
assert_eq "1" "$d" "MODEL_CTX_TAG listed as missing"
end_test

start_test "no version key in any plugin.json or marketplace entry"
vcount=0
for pj in "$REPO_ROOT"/plugins/*/.claude-plugin/plugin.json; do
  [ -f "$pj" ] || { printf '    FAIL: no plugin.json at %s\n' "$pj" >&2; TEST_FAILED=1; continue; }
  [ "$(jq 'has("version")' "$pj" | tr -d '\r')" = false ] || vcount=$((vcount + 1))
done
mv_count=$(jq '[.plugins[] | has("version")] | map(select(.)) | length' "$REPO_ROOT/.claude-plugin/marketplace.json" 2>/dev/null | tr -d '\r')
case "$mv_count" in (""|*[!0-9]*) mv_count=999 ;; esac   # missing/unparseable -> clean FAIL
vcount=$((vcount + mv_count))
assert_eq "0" "$vcount" "version keys found"
end_test

print_summary

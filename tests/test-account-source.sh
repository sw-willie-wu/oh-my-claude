#!/bin/bash
# ACCOUNT_SOURCE=auto: the account segment names the account whose OAuth token
# this session uses (profile cache keyed on the credentials file), and falls
# back to .oauthAccount whenever that cache is not usable.
set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"

# shellcheck source=test-helpers.sh
. "$SCRIPT_DIR/test-helpers.sh"

STATUSLINE="$REPO_ROOT/plugins/oh-my-status/statusline.sh"

AT="$(mktemp -d -t omc-acsrc-XXXXXX)"
CLOG="$AT/curl.log"
make_curl_shim "$AT/shim" "$CLOG"
# No render in this file may reach the real curl.
export PATH="$AT/shim:$PATH"

TOKEN='tok-test-0123456789abcdef'

strip_ansi() { sed -E 's/\x1b\[[0-9;]*[a-zA-Z]//g'; }

# mkcred <path> [token] [age_sec=20]
mkcred() {
  mkdir -p "$(dirname "$1")"
  "$REAL_JQ" -nj --arg t "${2-$TOKEN}" '{claudeAiOauth:{accessToken:$t}}' > "$1"
  touch -d "@$(( $(date +%s) - ${3:-20} ))" "$1"
}
# mkoauth <path> <displayName>
mkoauth() {
  mkdir -p "$(dirname "$1")"
  "$REAL_JQ" -nj --arg d "$2" '{oauthAccount:{displayName:$d}}' > "$1"
  touch -d "@$(( $(date +%s) - 10 ))" "$1"
}
# pcache <cred> : path of the profile cache for that credentials file
pcache() { printf '%s/account-profile-%s' "$OMC_STATE_DIR" "${1//[^A-Za-z0-9]/-}"; }
# mkprofile <cred> <name> <full> <email> <org> : fresh profile cache (newer than cred)
mkprofile() {
  local f; f=$(pcache "$1")
  mkdir -p "$OMC_STATE_DIR"
  printf '%s\x1f%s\x1f%s\x1f%s\n' "$2" "$3" "$4" "$5" > "$f"
  touch -d "@$(( $(date +%s) - 5 ))" "$f"
}
# Per-test defaults: the oauth cache source says bob, the credentials file holds a token.
defaults() {
  mkoauth "$AT/oauth.json" bob
  mkcred "$AT/cred.json"
  export OMC_ACCOUNT_FILE="$AT/oauth.json" OMC_CREDENTIALS_FILE="$AT/cred.json"
  : > "$CLOG"; : > "$CLOG.stdin"
}
# acct VAR=val... : prints ACCOUNT|ACC_NAME|ACC_FULL|ACC_EMAIL|ACC_ORG
acct() {
  env "$@" bash -c '
    OMC_TEST_LIB_ONLY=1; source "'"$STATUSLINE"'"
    declare -F cached_account_fields >/dev/null || { echo "NOFUNC"; exit 1; }
    cached_account_fields; resolve_account
    printf "%s|%s|%s|%s|%s\n" "$ACCOUNT" "$ACC_NAME" "$ACC_FULL" "$ACC_EMAIL" "$ACC_ORG"' | tr -d '\r'
}
acct1() { acct "$@" | cut -d'|' -f1; }
stamp_count() { ls "$OMC_STATE_DIR"/account-profile-*.stamp 2>/dev/null | wc -l | tr -d ' '; }

start_test "off by default: fresh profile cache is ignored"
defaults; mkprofile "$AT/cred.json" alice "Alice Doe" alice@example.com Acme
assert_eq "bob" "$(acct1 FOO=1)" "unset"
assert_eq "bob" "$(acct1 ACCOUNT_SOURCE=config)" "config"
assert_eq "bob" "$(acct1 ACCOUNT_SOURCE=bogus)" "bogus"
assert_eq "0" "$(stamp_count)" "stamps"
assert_eq "0" "$(shim_count "$CLOG")" "curl calls"
end_test

start_test "ACCOUNT_SHOW=false: empty, profile cache unread"
defaults; mkprofile "$AT/cred.json" alice "Alice Doe" alice@example.com Acme
assert_eq "" "$(acct1 ACCOUNT_SOURCE=auto ACCOUNT_SHOW=false)" "hidden"
assert_eq "0" "$(stamp_count)" "stamps"
end_test

start_test "auto + fresh cache: each ACCOUNT_FORMAT names the profile account"
defaults; mkprofile "$AT/cred.json" alice "Alice Doe" alice@example.com Acme
assert_eq "alice" "$(acct1 ACCOUNT_SOURCE=auto ACCOUNT_FORMAT=name)" "name"
assert_eq "Alice Doe" "$(acct1 ACCOUNT_SOURCE=auto ACCOUNT_FORMAT=fullname)" "fullname"
assert_eq "alice@example.com" "$(acct1 ACCOUNT_SOURCE=auto ACCOUNT_FORMAT=email)" "email"
assert_eq "Acme" "$(acct1 ACCOUNT_SOURCE=auto ACCOUNT_FORMAT=org)" "org"
assert_eq "0" "$(stamp_count)" "stamps"
assert_eq "0" "$(shim_count "$CLOG")" "curl calls"
end_test

start_test "auto + a skip variable set: .oauthAccount is shown"
defaults; mkprofile "$AT/cred.json" alice "Alice Doe" alice@example.com Acme
for v in CLAUDE_CODE_OAUTH_TOKEN ANTHROPIC_API_KEY ANTHROPIC_AUTH_TOKEN CLAUDE_CODE_USE_BEDROCK CLAUDE_CODE_USE_VERTEX; do
  assert_eq "bob" "$(acct1 ACCOUNT_SOURCE=auto "$v=1")" "$v"
done
assert_eq "0" "$(stamp_count)" "stamps"
assert_eq "0" "$(shim_count "$CLOG")" "curl calls"
end_test

start_test "auto + no credentials file: same as today"
defaults; mkprofile "$AT/cred.json" alice "Alice Doe" alice@example.com Acme
rm -f "$(pcache "$AT/cred.json")"
assert_eq "bob" "$(acct1 ACCOUNT_SOURCE=auto OMC_CREDENTIALS_FILE="$AT/none.json")" "no cred"
assert_eq "" "$(ls "$OMC_STATE_DIR" | grep '^account-profile-' || true)" "no profile files"
assert_eq "0" "$(shim_count "$CLOG")" "curl calls"
end_test

start_test "auto + credentials newer than cache: this render shows .oauthAccount"
defaults; mkprofile "$AT/cred.json" alice "Alice Doe" alice@example.com Acme
touch -d "@$(( $(date +%s) + 5 ))" "$AT/cred.json"
assert_eq "bob" "$(acct1 ACCOUNT_SOURCE=auto OMC_PROFILE_FETCH_SYNC=1 CURL_SHIM_EXIT=22)" "stale"
end_test

start_test "auto + cache with all fields empty: .oauthAccount is shown"
defaults; mkprofile "$AT/cred.json" "" "" "" ""
assert_eq "bob" "$(acct1 ACCOUNT_SOURCE=auto OMC_PROFILE_FETCH_SYNC=1 CURL_SHIM_EXIT=22)" "empty cache"
end_test

start_test "CLAUDE_CONFIG_DIR: credentials and cache key follow it"
defaults; mkcred "$AT/cfg/.credentials.json"
mkprofile "$AT/cfg/.credentials.json" alice "Alice Doe" alice@example.com Acme
assert_eq "alice" "$(acct1 ACCOUNT_SOURCE=auto OMC_CREDENTIALS_FILE= CLAUDE_CONFIG_DIR="$AT/cfg")" "config dir"
end_test

# Full render from a directory outside any repo; prints line 1 without colors.
full_render() {  # $1=conf text
  local nogit; nogit=$(mktemp -d)
  printf '%s\n' "$1" > "$AT/full.conf"
  ( cd "$nogit" && printf '%s\n' '{"session_id":"acsrc","model":{"display_name":"M"},"workspace":{"current_dir":"/tmp/d"}}' \
      | OMC_CONF="$AT/full.conf" bash "$STATUSLINE" 2>/dev/null ) | strip_ansi | head -1
  rm -rf "$nogit"
}

start_test "full render with auto + fresh cache shows the profile account"
defaults; mkprofile "$AT/cred.json" alice "Alice Doe" alice@example.com Acme
out=$(full_render "$(printf 'LAYOUT=default\nACCOUNT_SOURCE=auto')")
case "$out" in *alice*) ;; *) printf '    FAIL: no alice in [%s]\n' "$out" >&2; TEST_FAILED=1 ;; esac
case "$out" in *bob*) printf '    FAIL: bob in [%s]\n' "$out" >&2; TEST_FAILED=1 ;; esac
end_test

start_test "spawn count: auto + fresh cache equals off"
defaults
REPO="$AT/repo"; mkdir -p "$REPO"; git init -q -b main "$REPO"
printf 'x\n' > "$REPO/a.txt"; git -C "$REPO" add a.txt
git -C "$REPO" -c user.name=t -c user.email=t@t commit -q -m init
fs_tick   # the first render's git cache stamp must be newer than the commit
printf '%s' "{\"session_id\":\"acsrc\",\"model\":{\"display_name\":\"M\"},\"workspace\":{\"current_dir\":\"$REPO\"}}" > "$AT/payload.json"
SAVED_SD=$OMC_STATE_DIR
for variant in off auto; do
  SD="$AT/sd-$variant"; mkdir -p "$SD"; export OMC_STATE_DIR="$SD"
  { printf 'LAYOUT=default\nGIT_CACHE_TTL=300\n'; [ "$variant" = auto ] && printf 'ACCOUNT_SOURCE=auto\n'; } > "$AT/sp-$variant.conf"
  [ "$variant" = auto ] && mkprofile "$AT/cred.json" alice "Alice Doe" alice@example.com Acme
  ( cd "$REPO" && OMC_CONF="$AT/sp-$variant.conf" OMC_NOW_OVERRIDE=1793800000 COLUMNS=120 \
      bash "$STATUSLINE" < "$AT/payload.json" >/dev/null 2>&1 )
  pushd "$REPO" >/dev/null
  OMC_CONF="$AT/sp-$variant.conf" OMC_NOW_OVERRIDE=1793800000 COLUMNS=120 count_spawns "$AT/cnt-$variant" "$AT/payload.json" "$STATUSLINE"
  popd >/dev/null
  eval "SP_$variant=$SPAWNS; MISS_$variant=$SPAWN_MISSING"
done
export OMC_STATE_DIR=$SAVED_SD
assert_eq "$SP_off" "$SP_auto" "spawns off vs auto"
assert_eq "0" "$MISS_off" "off: un-shimmed externals"
assert_eq "0" "$MISS_auto" "auto: un-shimmed externals"
case "$(strip_ansi < "$AT/cnt-auto/stdout")" in *alice*) ;; *) printf '    FAIL: auto output lacks alice\n' >&2; TEST_FAILED=1 ;; esac
end_test

# ---------------------------------------------------------------------------
# Stale cache: lease, background fetch, what gets cached
# ---------------------------------------------------------------------------
E=1793800000
printf '%s' '{"account":{"display_name":"alice","full_name":"Alice Doe","email":"alice@example.com"},"organization":{"name":"Acme"}}' > "$AT/body.json"

# render VAR=val... : one lookup in auto mode, fetch run in the foreground, clock at $E.
render() { acct1 ACCOUNT_SOURCE=auto OMC_PROFILE_FETCH_SYNC=1 OMC_NOW_OVERRIDE="$E" "$@"; }
renderf() { acct ACCOUNT_SOURCE=auto OMC_PROFILE_FETCH_SYNC=1 OMC_NOW_OVERRIDE="$E" "$@"; }
stampf() { printf '%s.stamp' "$(pcache "$AT/cred.json")"; }
no_profile_cache() { [ -z "$(ls "$OMC_STATE_DIR"/account-profile-* 2>/dev/null | grep -v '\.stamp$' || true)" ]; }
no_tmp() { [ -z "$(ls "$OMC_STATE_DIR"/account-profile-*.tmp.* 2>/dev/null || true)" ]; }
clear_profile() { rm -f "$OMC_STATE_DIR"/account-profile-*; : > "$CLOG"; : > "$CLOG.stdin"; }

start_test "stale: shows .oauthAccount and launches once; lease holds for 300 s"
defaults
export CURL_SHIM_EXIT=22
assert_eq "bob" "$(render)" "first"
assert_eq "1" "$(shim_count "$CLOG")" "count after first"
assert_eq "$E" "$(cat "$(stampf)")" "stamp content"
assert_eq "bob" "$(render)" "second"
assert_eq "1" "$(shim_count "$CLOG")" "count after second"
assert_eq "bob" "$(render OMC_NOW_OVERRIDE=$((E + 300)))" "at 300 s"
assert_eq "1" "$(shim_count "$CLOG")" "count at 300 s"
assert_eq "bob" "$(render OMC_NOW_OVERRIDE=$((E + 301)))" "at 301 s"
assert_eq "2" "$(shim_count "$CLOG")" "count at 301 s"
unset CURL_SHIM_EXIT
end_test

start_test "credentials newer than the stamp relaunch within the lease"
defaults
export CURL_SHIM_EXIT=22
render >/dev/null
touch -d "@$(( $(date +%s) + 5 ))" "$AT/cred.json"
render >/dev/null
assert_eq "2" "$(shim_count "$CLOG")" "count"
unset CURL_SHIM_EXIT
end_test

start_test "stamp with garbage or a future epoch counts as expired"
defaults
export CURL_SHIM_EXIT=22
mkdir -p "$OMC_STATE_DIR"
printf 'abc\n' > "$(stampf)"
render >/dev/null
assert_eq "1" "$(shim_count "$CLOG")" "garbage stamp"
printf '%s\n' "$((E + 1000))" > "$(stampf)"
render >/dev/null
assert_eq "2" "$(shim_count "$CLOG")" "future stamp"
printf '08\n' > "$(stampf)"
render >/dev/null
assert_eq "3" "$(shim_count "$CLOG")" "leading-zero stamp"
unset CURL_SHIM_EXIT
end_test

start_test "successful fetch: next render names the token's account"
defaults
export CURL_SHIM_BODY="$AT/body.json"
assert_eq "bob" "$(render)" "render 1"
assert_eq "alice|alice|Alice Doe|alice@example.com|Acme" "$(renderf)" "render 2"
PC=$(pcache "$AT/cred.json")
assert_eq "1" "$(wc -l < "$PC" | tr -d ' ')" "cache lines"
assert_eq "3" "$(tr -cd '\037' < "$PC" | wc -c | tr -d ' ')" "separators"
assert_eq "0a" "$(tail -c 1 "$PC" | od -An -tx1 | tr -d ' ')" "trailing newline"
no_tmp || { printf '    FAIL: temp files left\n' >&2; TEST_FAILED=1; }
assert_eq "" "$(grep -rlF "$TOKEN" "$OMC_STATE_DIR" || true)" "token in state dir"
unset CURL_SHIM_BODY
end_test

start_test "curl gets the token on stdin only"
defaults
export CURL_SHIM_BODY="$AT/body.json"
render >/dev/null
assert_eq "CALL -sf -m 10 -K -" "$(cat "$CLOG")" "argv"
printf 'url = "https://api.anthropic.com/api/oauth/profile"\nheader = "Authorization: Bearer %s"\nheader = "anthropic-beta: oauth-2025-04-20"\n' "$TOKEN" > "$AT/want.stdin"
cmp -s "$AT/want.stdin" "$CLOG.stdin" || { printf '    FAIL: curl stdin differs\n' >&2; od -c "$CLOG.stdin" | head >&2; TEST_FAILED=1; }
unset CURL_SHIM_BODY
end_test

start_test "CRLF from jq is stripped before curl reads its config"
defaults
export CURL_SHIM_BODY="$AT/body.json"
mkdir -p "$AT/crshim"
printf '#!/bin/bash\no="$0.out.$$"\n%q "$@" > "$o"; rc=$?\nperl -pe %q < "$o"\nrm -f "$o"\nexit $rc\n' "$REAL_JQ" 's/\n/\r\n/' > "$AT/crshim/jq"
chmod +x "$AT/crshim/jq"
PATH="$AT/crshim:$PATH" render >/dev/null
assert_eq "0" "$(tr -cd '\r' < "$CLOG.stdin" | wc -c | tr -d ' ')" "CR bytes"
assert_eq "3" "$(wc -l < "$CLOG.stdin" | tr -d ' ')" "lines"
unset CURL_SHIM_BODY
end_test

start_test "failed fetches write nothing"
defaults
i=0
for body in EXIT '{"organization":{"name":"Acme"}}' '{"account":"x"}' \
            '{"account":{"display_name":"","full_name":"","email":""},"organization":{"name":""}}' \
            '{"account":{"display_name":"\u0001\u001b","full_name":"\u0001","email":"\u001b"},"organization":{"name":"\u0001"}}' \
            '<html>nope</html>'; do
  i=$((i + 1)); clear_profile
  if [ "$body" = EXIT ]; then
    export CURL_SHIM_EXIT=22
  else
    unset CURL_SHIM_EXIT; printf '%s' "$body" > "$AT/bad.json"; export CURL_SHIM_BODY="$AT/bad.json"
  fi
  render >/dev/null
  assert_eq "1" "$(shim_count "$CLOG")" "variant $i launched"
  assert_eq "bob" "$(render)" "variant $i render 2"
  no_profile_cache || { printf '    FAIL: variant %s cached something\n' "$i" >&2; TEST_FAILED=1; }
  no_tmp || { printf '    FAIL: variant %s left temp files\n' "$i" >&2; TEST_FAILED=1; }
done
unset CURL_SHIM_EXIT CURL_SHIM_BODY
end_test

start_test "missing organization caches an empty org"
defaults
printf '%s' '{"account":{"display_name":"alice","email":"alice@example.com"}}' > "$AT/noorg.json"
export CURL_SHIM_BODY="$AT/noorg.json"
render >/dev/null
assert_eq "alice@example.com" "$(render ACCOUNT_FORMAT=org)" "org falls back to email"
assert_eq "alice" "$(render)" "name"
unset CURL_SHIM_BODY
end_test

start_test "hostile profile fields are sanitized like .oauthAccount"
defaults
cat > "$AT/hostile.json" <<'JSON'
{"account":{"display_name":"  \u001b[31mre\nd\\c  ","email":"alice@example.com"}}
JSON
export CURL_SHIM_BODY="$AT/hostile.json"
render >/dev/null
assert_eq '[31mred\\c' "$(render)" "name"
unset CURL_SHIM_BODY
end_test

start_test "unusable token: curl is never invoked"
defaults
i=0
for raw in '{}' '{"claudeAiOauth":{}}' '{"claudeAiOauth":{"accessToken":""}}' '{"claudeAiOauth":{"accessToken":123}}' \
           '{"claudeAiOauth":{"accessToken":"a\"b"}}' '{"claudeAiOauth":{"accessToken":"a b"}}' \
           '{"claudeAiOauth":{"accessToken":"a\nb"}}' '{"claudeAiOauth":{"accessToken":"a\n"}}' \
           '{"claudeAiOauth":{"accessToken":"a\\b"}}' 'not json'; do
  i=$((i + 1)); clear_profile
  printf '%s' "$raw" > "$AT/cred.json"; touch -d "@$(( $(date +%s) - 20 ))" "$AT/cred.json"
  export CURL_SHIM_BODY="$AT/body.json"
  assert_eq "bob" "$(render)" "variant $i render"
  assert_eq "0" "$(shim_count "$CLOG")" "variant $i curl calls"
done
unset CURL_SHIM_BODY
end_test

start_test "credentials rewritten during the fetch: result discarded"
defaults
export CURL_SHIM_BODY="$AT/body.json"
CURL_SHIM_TOUCH="$AT/cred.json" render >/dev/null
fs_tick   # the rewrite must not share a clock tick with the next render's stamp and marker
no_profile_cache || { printf '    FAIL: cache written\n' >&2; TEST_FAILED=1; }
assert_eq "bob" "$(render)" "render 2"
assert_eq "2" "$(shim_count "$CLOG")" "relaunched"
assert_eq "alice" "$(render)" "render 3"
unset CURL_SHIM_BODY
end_test

start_test "render does not wait for the fetch"
defaults
make_curl_shim "$AT/slowshim" "$AT/slow.log"
mkcred "$AT/slowcred.json"
mkdir -p "$AT/slowstate" "$AT/slowcwd"
printf 'LAYOUT=default\nACCOUNT_SOURCE=auto\n' > "$AT/slow.conf"
{ ( cd "$AT/slowcwd" && printf '%s\n' '{"session_id":"acsrc-slow","model":{"display_name":"M"},"workspace":{"current_dir":"/tmp/d"}}' \
    | PATH="$AT/slowshim:$PATH" OMC_STATE_DIR="$AT/slowstate" OMC_CREDENTIALS_FILE="$AT/slowcred.json" \
      OMC_CONF="$AT/slow.conf" CURL_SHIM_SLEEP=10 CURL_SHIM_EXIT=22 bash "$STATUSLINE" 2>/dev/null )
  printf '%s\n' "${EPOCHREALTIME//[.,]/}" > "$AT/exit"
} | { cat >/dev/null; printf '%s\n' "${EPOCHREALTIME//[.,]/}" > "$AT/eof"; }
# A leaked stdout handle in the background fetch would hold the pipe open for the shim's 10 s sleep.
gap=$(( ($(cat "$AT/eof") - $(cat "$AT/exit")) / 1000 ))
[ "$gap" -lt 3000 ] || { printf '    FAIL: reader saw EOF %s ms after the statusline exited\n' "$gap" >&2; TEST_FAILED=1; }
assert_eq "1" "$(ls "$AT"/slowstate/account-profile-*.stamp 2>/dev/null | wc -l | tr -d ' ')" "stamp written"
end_test

# ---------------------------------------------------------------------------
# Sweeps cover the new files
# ---------------------------------------------------------------------------
start_test "30 s temp sweep removes old profile temp and marker files, keeps a live fetch's"
defaults
mkdir -p "$OMC_STATE_DIR"
for n in 123 456; do
  : > "$OMC_STATE_DIR/account-profile-k.tmp.$n"
  : > "$OMC_STATE_DIR/account-profile-k.tmp.$n.m"
done
touch -d "@$(( $(date +%s) - 60 ))" "$OMC_STATE_DIR/account-profile-k.tmp.123" "$OMC_STATE_DIR/account-profile-k.tmp.123.m"
env bash -c 'OMC_TEST_LIB_ONLY=1; source "'"$STATUSLINE"'"; _omc_sweep_stale_tmp'
for f in account-profile-k.tmp.123 account-profile-k.tmp.123.m; do
  [ ! -e "$OMC_STATE_DIR/$f" ] || { printf '    FAIL: %s not swept\n' "$f" >&2; TEST_FAILED=1; }
done
for f in account-profile-k.tmp.456 account-profile-k.tmp.456.m; do
  [ -e "$OMC_STATE_DIR/$f" ] || { printf '    FAIL: %s swept while live\n' "$f" >&2; TEST_FAILED=1; }
done
end_test

start_test "SessionStart 24 h sweep removes old profile cache and stamp"
defaults
mkdir -p "$OMC_STATE_DIR"
: > "$OMC_STATE_DIR/account-profile-k"; : > "$OMC_STATE_DIR/account-profile-k.stamp"; : > "$OMC_STATE_DIR/account-profile-j"
touch -d "@$(( $(date +%s) - 25 * 3600 ))" "$OMC_STATE_DIR/account-profile-k" "$OMC_STATE_DIR/account-profile-k.stamp"
touch -d "@$(( $(date +%s) - 3600 ))" "$OMC_STATE_DIR/account-profile-j"
OMC_DIR="$AT/omc" OMC_CONF="$AT/s.conf" bash "$REPO_ROOT/plugins/oh-my-status/setup.sh" >/dev/null 2>&1 </dev/null
for f in account-profile-k account-profile-k.stamp; do
  [ ! -e "$OMC_STATE_DIR/$f" ] || { printf '    FAIL: %s not swept\n' "$f" >&2; TEST_FAILED=1; }
done
[ -e "$OMC_STATE_DIR/account-profile-j" ] || { printf '    FAIL: recent cache swept\n' >&2; TEST_FAILED=1; }
end_test

rm -rf "$AT" 2>/dev/null || :
print_summary

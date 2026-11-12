#!/bin/bash
# Render-equivalence oracle: the current oh-my-status statusline must produce
# byte-identical stdout to the 23d7874 baseline run with WORKERS_ENABLED=false
# (the "zero workers" baseline), for a matrix of layouts / repo states / inputs.
# Deliberate output difference:
#   - the 7d reset hint (shown above 80%) is " (MM/DD HH:MM)" instead of
#     " (MM/DD)". The OLD output of every case is transformed before the compare:
#     the literal " (<old 7d hint for $R7>)" becomes " (<new hint>)" (see
#     transform_old_7d_hint). Cases with 7d <= 80% or without a 7d window contain no
#     such text and are compared byte-for-byte as before; the 5h hint is untouched.
#
# Subset runs: OMC_EQUIV_ONLY='<glob>' runs only the cases whose name matches.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"
source "$SCRIPT_DIR/test-helpers.sh"

BASELINE=23d7874
if ! git -C "$REPO_ROOT" cat-file -e "$BASELINE^{commit}" 2>/dev/null; then
  echo "SKIP: baseline $BASELINE not available"
  exit 0
fi

REAL_DATE="$(command -v date)"
T=$(mktemp -d)
trap 'chmod -R u+w "$T" 2>/dev/null; rm -rf "$T" 2>/dev/null || true' EXIT

OLD="$T/old"; mkdir -p "$OLD"
git -C "$REPO_ROOT" archive "$BASELINE" plugins/oh-my-status | tar -x -C "$OLD"
OLD_SL="$OLD/plugins/oh-my-status/statusline.sh"
NEW_SL="$REPO_ROOT/plugins/oh-my-status/statusline.sh"

# --- fixed clock -----------------------------------------------------------
FIXED_EPOCH=1793800000
mkdir -p "$T/shim"
cat > "$T/shim/date" <<EOF
#!/bin/bash
if [ "\$#" -eq 1 ] && [ "\$1" = "+%s" ]; then printf '%s\n' "$FIXED_EPOCH"; exit 0; fi
exec "$REAL_DATE" "\$@"
EOF
chmod +x "$T/shim/date"

# --- fixtures --------------------------------------------------------------
R="$T/repos"; mkdir -p "$R"
gi() {  # gi <dir> <git args...> ; local identity, never global config
  local d="$1"; shift
  git -C "$d" -c user.name=t -c user.email=t@t "$@"
}
mkrepo() {  # mkrepo <dir> ; one commit with a.txt b.txt c.txt d.txt
  mkdir -p "$1"; git init -q -b main "$1"
  git -C "$1" config user.name t; git -C "$1" config user.email t@t
  git -C "$1" config core.autocrlf false
  local f
  for f in a b c d; do printf '%s\nline2\n' "$f" > "$1/$f.txt"; done
  git -C "$1" add -A; git -C "$1" commit -q -m init
}
dirtify() {  # modified + staged + AM + untracked + deleted
  printf 'changed\nmore\n' >> "$1/a.txt"
  printf 'staged\n' >> "$1/b.txt"; git -C "$1" add b.txt
  printf 'new\n' > "$1/e.txt"; git -C "$1" add e.txt; printf 'again\n' >> "$1/e.txt"
  printf 'untracked\n' > "$1/u.txt"
  rm -f "$1/d.txt"
}
mkrepo "$R/clean"
mkrepo "$R/dirty"; dirtify "$R/dirty"
mkrepo "$R/detached"; git -C "$R/detached" checkout -q --detach
mkdir -p "$R/unborn"; git init -q "$R/unborn"; git -C "$R/unborn" symbolic-ref HEAD refs/heads/unb
printf 'u\n' > "$R/unborn/u.txt"
mkrepo "$R/wtmain"; git -C "$R/wtmain" worktree add -q "$R/worktree" -b wt >/dev/null 2>&1
printf 'wt change\n' >> "$R/worktree/a.txt"
mkrepo "$R/subsrc"
mkrepo "$R/submod"
git -C "$R/submod" -c protocol.file.allow=always -c user.name=t -c user.email=t@t \
  submodule add -q "$R/subsrc" sub >/dev/null 2>&1
git -C "$R/submod" -c user.name=t -c user.email=t@t commit -q -m addsub >/dev/null 2>&1
printf 'dirty in sub\n' >> "$R/submod/sub/a.txt"
printf 'main change\n' >> "$R/submod/a.txt"
mkdir -p "$R/nonrepo"
printf '{"oauthAccount":{"displayName":"alice"}}' > "$T/acct.json"
NONE="$T/none.json"

# --- fixture sanity: fail loudly rather than pass vacuously -------------------
fixture_fail=0
command -v jq >/dev/null 2>&1 || { echo "FATAL: jq not found (every case would print the jq notice)" >&2; fixture_fail=1; }
[ -f "$R/submod/.gitmodules" ] || { echo "FATAL: submodule fixture failed (no .gitmodules)" >&2; fixture_fail=1; }
[ -d "$R/worktree" ] || { echo "FATAL: worktree fixture failed" >&2; fixture_fail=1; }
[ "$fixture_fail" -eq 0 ] || exit 1

# --- payloads ----------------------------------------------------------------
payload() {  # payload <dir> <ctx_pct> <ctx_size|""> <five|""> <five_reset|""> <seven|""> <seven_reset|"">
  jq -n -c --arg dir "C:\\Users\\bob\\proj\\x" --argjson ctx "$2" \
    --arg size "$3" --arg f "$4" --arg fr "$5" --arg s "$6" --arg sr "$7" '
    {session_id:"eq", model:{display_name:"Opus 4.5 (extra)"}, workspace:{current_dir:$dir},
     context_window:({used_percentage:$ctx} + (if $size=="" then {} else {context_window_size:($size|tonumber)} end))}
    + (if ($f=="" and $s=="") then {} else
        {rate_limits:(
          (if $f=="" then {} else {five_hour:({used_percentage:($f|tonumber)} + (if $fr=="" then {} elif ($fr|test("^[0-9]+$")) then {resets_at:($fr|tonumber)} else {resets_at:$fr} end))} end)
        + (if $s=="" then {} else {seven_day:({used_percentage:($s|tonumber)} + (if $sr=="" then {} elif ($sr|test("^[0-9]+$")) then {resets_at:($sr|tonumber)} else {resets_at:$sr} end))} end))} end)' \
    | tr -d '\r'
}
R5=$((FIXED_EPOCH + 3600)); R7=$((FIXED_EPOCH + 3*86400))
P_A=$(payload x 42 "" 23 "$R5" 90 "$R7")
P_B=$(payload x 8 "" "" "" "" "")
P_C=$(payload x 61 1000000 "" "" 90 "$R7")


# Rewrite the old 7d hint " (MM/DD)" of the fixed R7 epoch into the new " (MM/DD HH:MM)".
OLD7=$("$REAL_DATE" -d "@$R7" '+%m/%d'); NEW7=$("$REAL_DATE" -d "@$R7" '+%m/%d %H:%M')
transform_old_7d_hint() {  # $1=file
  local s; s=$(cat "$1"; printf X); s=${s%X}
  s=${s//" ($OLD7)"/" ($NEW7)"}
  printf '%s' "$s" > "$1"
}
# --- runner ------------------------------------------------------------------
# run_case <name> <impl> <dir> <payload> <conf-lines> <account-file> <cols> <reps>
run_case() {
  local name="$1" impl="$2" dir="$3" payload="$4" conf="$5" acct="$6" cols="$7" reps="${8:-1}"
  local h="$T/h-$impl-$name" sl i
  mkdir -p "$h/.claude"
  printf '%s\n' "$conf" > "$h/c.conf"
  [ "$impl" = old ] && { printf 'WORKERS_ENABLED=false\n' >> "$h/c.conf"; sl="$OLD_SL"; } || sl="$NEW_SL"
  for ((i = 0; i < reps; i++)); do
    ( cd "$dir" && unset OMC_DIR GIT_DIR GIT_WORK_TREE GIT_COMMON_DIR &&
      export HOME="$h" OMC_STATE_DIR="$h/.claude/oh-my-claude/state" OMC_CONF="$h/c.conf" \
             OMC_ACCOUNT_FILE="$acct" COLUMNS="$cols" PATH="$T/shim:$PATH" &&
      { [ "$impl" = new ] && export OMC_NOW_OVERRIDE="$FIXED_EPOCH"; :; } &&
      printf '%s' "$payload" | bash "$sl" > "$T/out-$impl-$name" 2>/dev/null )
  done
}

# case_eq <name> <dir> <payload> <conf-lines> <account> <cols> [reps]
case_eq() {
  local name="$1"
  if [ -n "${OMC_EQUIV_ONLY-}" ] && [[ $name != $OMC_EQUIV_ONLY ]]; then return 0; fi
  start_test "equiv: $name"
  run_case "$name" old "$2" "$3" "$4" "$5" "$6" "${7:-1}"
  run_case "$name" new "$2" "$3" "$4" "$5" "$6" "${7:-1}"
  transform_old_7d_hint "$T/out-old-$name"
  if ! cmp -s "$T/out-old-$name" "$T/out-new-$name"; then
    printf '    FAIL: %s: stdout differs\n    --- old ---\n' "$name" >&2
    od -c "$T/out-old-$name" | head -40 >&2
    printf '    --- new ---\n' >&2
    od -c "$T/out-new-$name" | head -40 >&2
    TEST_FAILED=1
  fi
  [ -s "$T/out-old-$name" ] || { printf '    FAIL: %s: oracle output is empty\n' "$name" >&2; TEST_FAILED=1; }
  end_test
}

# --- 6 layouts x 3 rich fixtures ---------------------------------------------
for lay in default fancy minimal mygo powerline pure; do
  C="LAYOUT=$lay"
  case_eq "L-$lay-a" "$R/dirty"    "$P_A" "$C" "$T/acct.json" 200
  case_eq "L-$lay-b" "$R/clean"    "$P_B" "$C" "$NONE"        60
  case_eq "L-$lay-c" "$R/detached" "$P_C" "$C" "$NONE"        120
done

# --- default layout x fixtures x {miss, hit} ----------------------------------
for fx in nonrepo clean dirty unborn worktree submod; do
  C="LAYOUT=default"
  case_eq "G-$fx-miss" "$R/$fx" "$P_A" "$C" "$T/acct.json" 120 1
  case_eq "G-$fx-hit"  "$R/$fx" "$P_A" "$C" "$T/acct.json" 120 2
done

# --- singles (default layout) --------------------------------------------------
C="LAYOUT=default"
case_eq "S-malformed-json" "$R/clean" '{"session_id":' "$C" "$T/acct.json" 120
case_eq "S-empty-sid" "$R/clean" "$(payload x 8 "" "" "" "" "" | jq -c '.session_id=""' | tr -d '\r')" "$C" "$T/acct.json" 120
case_eq "S-account-off" "$R/clean" "$P_A" "$(printf 'LAYOUT=default\nACCOUNT_SHOW=false')" "$T/acct.json" 120
case_eq "S-ctx-tag-off" "$R/clean" "$P_C" "$(printf 'LAYOUT=default\nMODEL_CTX_TAG=false')" "$T/acct.json" 120
case_eq "S-ttl-0" "$R/dirty" "$P_A" "$(printf 'LAYOUT=default\nGIT_CACHE_TTL=0')" "$T/acct.json" 120
case_eq "S-resets-abc" "$R/clean" "$(payload x 8 "" 90 abc "" "")" "$C" "$T/acct.json" 120
case_eq "S-five-80" "$R/clean" "$(payload x 8 "" 80 "$R5" "" "")" "$C" "$T/acct.json" 120
case_eq "S-five-81" "$R/clean" "$(payload x 8 "" 81 "$R5" "" "")" "$C" "$T/acct.json" 120
case_eq "S-workers-conf" "$R/clean" "$P_A" "$(printf 'LAYOUT=default\nWORKERS_ENABLED=true\nWORKERS_MAX=0')" "$T/acct.json" 120

# The oracle must have rendered a real statusline, not the jq-missing notice.
if [ -f "$T/out-old-L-default-a" ]; then
  start_test "oracle sanity: rich case output is not the jq notice"
  if grep -aq 'jq required' "$T/out-old-L-default-a" || ! grep -aq 'Opus' "$T/out-old-L-default-a"; then
    printf '    FAIL: oracle output is not a real render\n' >&2; TEST_FAILED=1
  fi
  end_test
fi

print_summary

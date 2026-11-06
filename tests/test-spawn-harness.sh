#!/bin/bash
# Self-test for count_spawns (tests/test-helpers.sh).
set -u
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/test-helpers.sh"
W=$(mktemp -d)
trap 'rm -rf "$W"' EXIT

start_test "count_spawns: 2 externals + 1 command substitution = 3 forks, 2 execs"
printf 'x=$(date +%%s); git --version >/dev/null; : $(printf y)\n' > "$W/s1.sh"
count_spawns "$W/c1" /dev/null "$W/s1.sh"
assert_eq "2" "$SPAWN_EXECS" "execs"
assert_eq "3" "$SPAWN_FORKS" "forks"
assert_eq "5" "$SPAWNS" "spawns"
assert_eq "0" "$SPAWN_MISSING" "missing"
end_test

start_test "count_spawns: un-shimmed external is reported as MISSING"
printf 'nosuchcmd_xyz 2>/dev/null\n' > "$W/s2.sh"
count_spawns "$W/c2" /dev/null "$W/s2.sh"
assert_eq "1" "$SPAWN_MISSING" "missing"
end_test

start_test "count_spawns: jq runs with the real PATH and reads stdin"
printf 'jq -n 1\n' > "$W/s3.sh"
count_spawns "$W/c3" /dev/null "$W/s3.sh"
assert_eq "1" "$(tr -d '\r\n ' < "$W/c3/stdout")" "jq stdout"
assert_eq "0" "$SPAWN_MISSING" "missing"
end_test

start_test "count_spawns: a command substitution that only runs a pipeline = 3 forks, 1 exec"
printf 'x=$(printf a | sed s/a/b/)\n' > "$W/s4.sh"
count_spawns "$W/c4" /dev/null "$W/s4.sh"
assert_eq "1" "$SPAWN_EXECS" "execs"
assert_eq "3" "$SPAWN_FORKS" "forks"
assert_eq "0" "$SPAWN_MISSING" "missing"
end_test

print_summary

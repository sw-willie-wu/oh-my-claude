#!/bin/bash
# Run all test groups, several at a time.
#
#   bash scripts/test.sh [-j N] [filter ...]
#
# -j N / OMC_TEST_JOBS   max groups running at once (-j 1 = sequential). Default:
#                        1 on Windows shells (process creation is the bottleneck
#                        there, so running groups side by side only makes
#                        timing-sensitive tests flaky), 6 elsewhere. Do not set
#                        this to the CPU count: the tests fork heavily.
# filter                 only run groups whose file name or title contains it
#                        (e.g. `account render`).
#
# Each group's full output goes to its own log in a temp dir; once the group
# and every group before it has finished it is printed, in the listed order.
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"

case "$OSTYPE" in msys*|cygwin*|mingw*) DEFAULT_JOBS=1 ;; *) DEFAULT_JOBS=6 ;; esac
JOBS="${OMC_TEST_JOBS:-$DEFAULT_JOBS}"
FILTERS=()
while [ $# -gt 0 ]; do
  case "$1" in
    -j) JOBS="${2:-}"; shift 2 || { echo "-j needs a number" >&2; exit 2; } ;;
    -j*) JOBS="${1#-j}"; shift ;;
    -h|--help) sed -n '2,15p' "$0"; exit 0 ;;
    *) FILTERS+=("$1"); shift ;;
  esac
done
case "$JOBS" in ''|*[!0-9]*) echo "invalid job count: $JOBS" >&2; exit 2 ;; esac
JOBS=$((10#$JOBS))
[ "$JOBS" -ge 1 ] || { echo "invalid job count: 0" >&2; exit 2; }
if [ "$JOBS" -gt 1 ] && [ "$((BASH_VERSINFO[0] * 100 + BASH_VERSINFO[1]))" -lt 403 ]; then
  echo "bash $BASH_VERSION has no wait -n: running one group at a time" >&2; JOBS=1
fi

# "<title>|<file relative to repo root>", in report order.
GROUPS_ALL=(
  "spawn harness self-test|tests/test-spawn-harness.sh"
  "statusline render tests|tests/test-statusline-render.sh"
  "render equivalence tests|tests/test-render-equivalence.sh"
  "account source tests|tests/test-account-source.sh"
  "conf-backfill tests|tests/test-conf-backfill.sh"
  "orphan-sweep tests|tests/test-orphan-sweep.sh"
  "marketplace tests|tests/test-marketplace.sh"
  "knowledge init tests|tests/knowledge/test-init.sh"
  "knowledge commit tests|tests/knowledge/test-commit.sh"
  "knowledge search tests|tests/knowledge/test-search.sh"
  "knowledge lint (structure) tests|tests/knowledge/test-lint-structure.sh"
  "knowledge config tests|tests/knowledge/test-config.sh"
  "knowledge hooks tests|tests/knowledge/test-hooks.sh"
  "cross-plugin contract tests|tests/test-cross-plugin-contract.sh"
  "knowledge lint (content) tests|tests/knowledge/test-lint-content.sh"
  "knowledge harvest-copy tests|tests/knowledge/test-harvest-copy.sh"
  "knowledge check-move tests|tests/knowledge/test-check-move.sh"
  "knowledge skills tests|tests/knowledge/test-skills.sh"
)

TITLES=(); FILES=()
for g in "${GROUPS_ALL[@]}"; do
  title="${g%%|*}"; file="${g#*|}"
  [ -f "$REPO_ROOT/$file" ] || continue
  if [ "${#FILTERS[@]}" -gt 0 ]; then
    hit=0
    for f in "${FILTERS[@]}"; do
      case "$file $title" in *"$f"*) hit=1 ;; esac
    done
    [ "$hit" = 1 ] || continue
  fi
  TITLES+=("$title"); FILES+=("$file")
done
if [ "${#FILES[@]}" -eq 0 ]; then echo "no test group matches: ${FILTERS[*]}" >&2; exit 2; fi

LOGDIR="$(mktemp -d -t omc-testrun-XXXXXX)"
trap 'kill $(jobs -p) 2>/dev/null; rm -rf "$LOGDIR"' EXIT
trap 'exit 130' INT TERM

# Slowest files first so they overlap with the quick ones.
ORDER=(); SLOW=()
for i in "${!FILES[@]}"; do
  case "${FILES[$i]}" in
    *test-statusline-render.sh|*test-account-source.sh) SLOW+=("$i") ;;
    *) ORDER+=("$i") ;;
  esac
done
ORDER=("${SLOW[@]}" "${ORDER[@]}")

run_group() {  # $1=index
  local i="$1"
  ( cd "$REPO_ROOT" && bash "${FILES[$i]}" ) > "$LOGDIR/$i.log" 2>&1 < /dev/null
  echo "$?" > "$LOGDIR/$i.rc"
}

# Print every group whose output is ready and whose predecessors are all printed,
# so output streams in the listed order while later groups are still running.
FAILED=(); NEXT=0
flush() {
  local rc
  while [ "$NEXT" -lt "${#FILES[@]}" ] && [ -f "$LOGDIR/$NEXT.rc" ]; do
    rc="$(cat "$LOGDIR/$NEXT.rc")"
    [ "$NEXT" -gt 0 ] && echo
    echo "=== ${TITLES[$NEXT]} ==="
    cat "$LOGDIR/$NEXT.log"
    if [ "$rc" != 0 ]; then
      FAILED+=("${TITLES[$NEXT]}")
      echo "--- FAILED (exit $rc): ${TITLES[$NEXT]}"
    fi
    NEXT=$((NEXT + 1))
  done
}

if [ "$JOBS" -eq 1 ]; then
  for i in "${ORDER[@]}"; do run_group "$i"; flush; done
else
  running=0
  for i in "${ORDER[@]}"; do
    if [ "$running" -ge "$JOBS" ]; then wait -n; running=$((running - 1)); flush; fi
    run_group "$i" &
    running=$((running + 1))
  done
  while [ "$running" -gt 0 ]; do wait -n; running=$((running - 1)); flush; done
fi
flush

echo
if [ "${#FAILED[@]}" -gt 0 ]; then
  printf 'FAILED %d of %d groups:' "${#FAILED[@]}" "${#FILES[@]}"
  printf ' [%s]' "${FAILED[@]}"; echo
  exit 1
fi
echo "All ${#FILES[@]} groups passed (jobs: $JOBS)"

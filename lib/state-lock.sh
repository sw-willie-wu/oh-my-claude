#!/bin/bash
# Shared mkdir-based mutex over the oh-my-claude state directory.
# Sourced by hooks/track-workers.sh and statusline.sh.
#
# Caller must export OMC_STATE_DIR before sourcing (or accept the default).

OMC_STATE_DIR="${OMC_STATE_DIR:-$HOME/.claude/oh-my-claude/state}"
OMC_LOCK_DIR="$OMC_STATE_DIR/state.lock"

mkdir -p "$OMC_STATE_DIR" 2>/dev/null

# Run a function name under the lock. Function stdout flows through to caller.
# Stale lock (>10s mtime) is force-released to recover from crashed holders.
omc_with_lock() {
  local fn="$1" tries=0
  while ! mkdir "$OMC_LOCK_DIR" 2>/dev/null; do
    if [ -d "$OMC_LOCK_DIR" ]; then
      local lock_age now mtime
      now=$(date +%s)
      mtime=$(stat -c %Y "$OMC_LOCK_DIR" 2>/dev/null) || mtime=""
      [ -z "$mtime" ] && mtime="$now"
      lock_age=$((now - mtime))
      if [ "$lock_age" -gt 10 ]; then
        rmdir "$OMC_LOCK_DIR" 2>/dev/null
        continue
      fi
    fi
    tries=$((tries + 1))
    if [ "$tries" -gt 100 ]; then
      return 1
    fi
    sleep 0.05 2>/dev/null || sleep 1
  done
  "$fn"
  local rc=$?
  rmdir "$OMC_LOCK_DIR" 2>/dev/null
  return "$rc"
}

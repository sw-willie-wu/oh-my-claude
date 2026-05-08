#!/bin/bash
# Shared mkdir-based mutex over the oh-my-claude state directory.
# Sourced by hooks/track-workers.sh and statusline.sh.
#
# Caller may export OMC_STATE_DIR before sourcing (or accept the default).
# Sourcing is inert — no side effects until omc_with_lock is called.

OMC_STATE_DIR="${OMC_STATE_DIR:-$HOME/.claude/oh-my-claude/state}"

# Run a function name under the lock. Function stdout flows through to caller.
# Stale lock (>10s mtime) is force-released to recover from crashed holders.
# On SIGINT/SIGTERM during the function call, the lock is released and the
# signal is re-raised so the caller's signal-handling semantics are preserved.
omc_with_lock() {
  local fn="$1" tries=0
  local lock_dir="$OMC_STATE_DIR/state.lock"
  mkdir -p "$OMC_STATE_DIR" 2>/dev/null
  while ! mkdir "$lock_dir" 2>/dev/null; do
    if [ -d "$lock_dir" ]; then
      local lock_age now mtime
      now=$(date +%s)
      mtime=$(stat -c %Y "$lock_dir" 2>/dev/null) || mtime=""
      [ -z "$mtime" ] && mtime="$now"
      lock_age=$((now - mtime))
      if [ "$lock_age" -gt 10 ]; then
        rmdir "$lock_dir" 2>/dev/null
        continue
      fi
    fi
    tries=$((tries + 1))
    if [ "$tries" -gt 100 ]; then
      return 1
    fi
    sleep 0.05 2>/dev/null || sleep 1
  done
  # Save existing INT/TERM traps and install our own that releases the lock
  # then re-raises so the caller's handler still fires.
  local prev_int prev_term
  prev_int=$(trap -p INT)
  prev_term=$(trap -p TERM)
  trap 'rmdir "$lock_dir" 2>/dev/null; trap - INT; kill -INT $$' INT
  trap 'rmdir "$lock_dir" 2>/dev/null; trap - TERM; kill -TERM $$' TERM
  "$fn"
  local rc=$?
  rmdir "$lock_dir" 2>/dev/null
  # Restore prior INT/TERM traps (or clear if none).
  if [ -n "$prev_int" ]; then eval "$prev_int"; else trap - INT; fi
  if [ -n "$prev_term" ]; then eval "$prev_term"; else trap - TERM; fi
  return "$rc"
}

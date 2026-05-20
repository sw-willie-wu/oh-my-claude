#!/bin/bash
# Shared mkdir-based mutex over the oh-my-claude state directory.
# Sourced by hooks/track-workers.sh and statusline.sh.
#
# Caller may export OMC_STATE_DIR before sourcing (or accept the default).
# Sourcing is inert — no side effects until omc_with_lock is called.

OMC_STATE_DIR="${OMC_STATE_DIR:-$HOME/.claude/oh-my-claude/state}"

# Stale-lock fallback threshold (seconds). A critical section here is a
# handful of file ops — it finishes well under 1s — so a lock older than
# this almost certainly belongs to a crashed holder. Used as a backstop
# when the holder PID is unknown (no pid file) or may have been recycled;
# a holder proven dead is reclaimed immediately, no wait. Kept short so a
# SIGKILL'd holder (whose INT/TERM trap never ran) self-heals fast.
OMC_LOCK_STALE_SEC="${OMC_LOCK_STALE_SEC:-3}"

# Is PID $1 a live process? Self-contained — not every caller defines an
# is_alive of its own. Mirrors statusline.sh is_alive's platform split:
# MSYS bash's `kill -0` doesn't recognise the PIDs `$$` yields, so scan the
# process table there; elsewhere use kill -0.
# The two branches fail in opposite-but-acceptable directions: an MSYS `ps`
# that yields nothing → "dead" (a spurious reclaim only risks the small
# force-break window); a missing POSIX `kill` → "alive" (conservative — and
# `kill` is effectively always present on POSIX).
_omc_pid_alive() {
  local pid="$1"
  [ -n "$pid" ] || return 1
  case "$(uname -s)" in
    MINGW*|MSYS*|CYGWIN*)
      ps -W 2>/dev/null | awk -v p="$pid" '$1==p || $4==p {f=1} END {exit !f}'
      ;;
    *)
      command -v kill >/dev/null 2>&1 || return 0
      kill -0 "$pid" 2>/dev/null
      ;;
  esac
}

# Force-release a lock directory — used to break a crashed holder's lock.
# It holds a `pid` file, so a plain rmdir would fail on the non-empty
# directory; remove the tree.
_omc_drop_lock() {
  rm -rf "$1" 2>/dev/null
}

# Release a lock this process still owns. If we were force-broken — a
# contender reclaimed our lock after a crash-suspected stale window — the
# `pid` file now names a successor, and an unconditional `rm -rf` would
# delete the successor's *live* lock. So drop only while the pid file still
# says the lock is ours. (The old rmdir-based release masked this by
# failing on the now-non-empty successor dir; rm -rf would not, hence this
# explicit ownership check.)
_omc_release_lock() {
  [ "$(cat "$1/pid" 2>/dev/null)" = "$$" ] && _omc_drop_lock "$1"
}

# Run a function name under the lock. Function stdout flows through to caller.
# A contended lock is force-released when its holder PID is proven dead
# (immediately), or — as a backstop, when the holder is unknown or its PID
# may have been recycled — once the lock is older than OMC_LOCK_STALE_SEC.
# This recovers from both gracefully-crashed holders and SIGKILL'd ones
# (whose traps never fired).
# On SIGINT/SIGTERM during the function call, the lock is released and the
# signal is re-raised so the caller's signal-handling semantics are preserved.
omc_with_lock() {
  local fn="$1" tries=0
  local lock_dir="$OMC_STATE_DIR/state.lock"
  mkdir -p "$OMC_STATE_DIR" 2>/dev/null
  while ! mkdir "$lock_dir" 2>/dev/null; do
    if [ -d "$lock_dir" ]; then
      local holder
      holder=$(cat "$lock_dir/pid" 2>/dev/null)
      if [ -n "$holder" ] && ! _omc_pid_alive "$holder"; then
        # Holder identified and proven dead → reclaim now, don't wait out
        # the stale window.
        _omc_drop_lock "$lock_dir"
        continue
      fi
      # Holder alive, or unidentified (no pid file yet / pre-upgrade lock),
      # or possibly a recycled PID: bound the wait with the age backstop.
      local lock_age now mtime
      now=$(date +%s)
      mtime=$(stat -c %Y "$lock_dir" 2>/dev/null) || mtime=""
      [ -z "$mtime" ] && mtime="$now"
      lock_age=$((now - mtime))
      if [ "$lock_age" -gt "$OMC_LOCK_STALE_SEC" ]; then
        _omc_drop_lock "$lock_dir"
        continue
      fi
    fi
    tries=$((tries + 1))
    if [ "$tries" -gt 100 ]; then
      return 1
    fi
    sleep 0.05 2>/dev/null || sleep 1
  done
  # Record the holder PID so a contender can detect a crashed holder
  # immediately instead of waiting out the stale window. Best-effort: if the
  # write fails the contender simply falls back to the age threshold.
  printf '%s' "$$" > "$lock_dir/pid" 2>/dev/null
  # Save existing INT/TERM traps and install our own that releases the lock
  # then re-raises so the caller's handler still fires.
  local prev_int prev_term
  prev_int=$(trap -p INT)
  prev_term=$(trap -p TERM)
  trap '_omc_release_lock "$lock_dir"; trap - INT; kill -INT $$' INT
  trap '_omc_release_lock "$lock_dir"; trap - TERM; kill -TERM $$' TERM
  "$fn"
  local rc=$?
  _omc_release_lock "$lock_dir"
  # Restore prior INT/TERM traps (or clear if none).
  if [ -n "$prev_int" ]; then eval "$prev_int"; else trap - INT; fi
  if [ -n "$prev_term" ]; then eval "$prev_term"; else trap - TERM; fi
  return "$rc"
}

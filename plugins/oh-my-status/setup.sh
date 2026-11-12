#!/bin/bash
# oh-my-claude setup - copies runtime files to ~/.claude/oh-my-claude/
# Called by plugin hooks or manually
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
OMC_DIR="${OMC_DIR:-$HOME/.claude/oh-my-claude}"
OMC_CONF="${OMC_CONF:-$HOME/.claude/oh-my-claude.conf}"
OMC_CONF_TEMPLATE="${OMC_CONF_TEMPLATE:-$SCRIPT_DIR/oh-my-claude.conf}"
OMC_STATE_DIR="${OMC_STATE_DIR:-$HOME/.claude/oh-my-claude/state}"

mkdir -p "$OMC_DIR"
cp "$SCRIPT_DIR/statusline.sh" "$OMC_DIR/"
cp -r "$SCRIPT_DIR/themes" "$OMC_DIR/"
cp -r "$SCRIPT_DIR/layouts" "$OMC_DIR/"
cp "$SCRIPT_DIR/preview.sh" "$OMC_DIR/"
cp "$SCRIPT_DIR/generate-preview.sh" "$OMC_DIR/"

# Create config if not exists or is empty
[ -s "$OMC_CONF" ] || cp "$OMC_CONF_TEMPLATE" "$OMC_CONF"

# --- conf-key detection (read-only; never writes the conf) -----------------
# Surface template keys missing from an existing user conf so Claude can
# suggest /oh-my-status:setup. Per the Claude Code hooks docs, SessionStart
# stdout (exit 0) is added to Claude's context (not shown to the user) — so
# the notice is phrased as a context note for Claude to relay. Fully
# non-fatal: any failure degrades to "no notice" and the hook still exits 0.
if [ -r "$SCRIPT_DIR/lib/conf-keys.sh" ]; then
  # shellcheck source=lib/conf-keys.sh
  . "$SCRIPT_DIR/lib/conf-keys.sh"
  missing=""
  if [ -s "$OMC_CONF" ] && [ -r "$OMC_CONF_TEMPLATE" ]; then
    missing="$(omc_missing_conf_keys "$OMC_CONF_TEMPLATE" "$OMC_CONF" 2>/dev/null || true)"
  fi
  if [ -n "$missing" ]; then
    n="$(printf '%s\n' "$missing" | awk 'END{print NR}')"
    keys_csv="$(printf '%s' "$missing" | paste -sd, -)"
    printf '%s\n' "[oh-my-status] Context for the assistant: ${n} new config option(s) (${keys_csv}) exist in the bundled template but are not in the user's ~/.claude/oh-my-claude.conf. At a natural moment, mention to the user once (not repeatedly within this session) that running /oh-my-status:setup will add the new options with safe defaults while preserving existing values."
  fi
fi

# One-time cleanup of 2.x Workers leftovers (named files only; see spec 2.2).
# Nothing here recurses into user-overridable dirs: hooks/ and lib/ are only
# rmdir'd (which fails harmlessly when a user file is still inside). Every
# loop ends in `|| :` because `set -e` would otherwise take a false trailing
# `[ ... ] && ...` for a failure.
old=()
for p in "$OMC_STATE_DIR"/state-*.tsv "$OMC_STATE_DIR"/state-*.tsv.* "$OMC_STATE_DIR/state.lock" \
         "$OMC_STATE_DIR/track-workers.log" "$OMC_DIR/hooks/track-workers.sh" \
         "$OMC_DIR/lib/state-lock.sh" "$OMC_DIR/lib/conf-keys.sh"; do
  [ -e "$p" ] && old+=("$p")        # unmatched glob stays literal -> -e false
done || :
[ ${#old[@]} -eq 0 ] || { rm -rf -- "${old[@]}"; rmdir "$OMC_DIR/hooks" "$OMC_DIR/lib"; } 2>/dev/null || :

# Stale state sweep (moved here from the removed track-workers.sh; runs every
# SessionStart for plugin installs, and on install.sh for standalone ones).
# 24h age policy on the state dir. gitcache-* is the statusline's git-info
# cache (an actively used cache is rewritten on every miss, so only dirs not
# visited in 24h age out); account-* is the account cache. A handoff-<sid>
# marker (which records the usage % of its window) is only removed when
# ctx-<sid> is missing or also older than 24h, i.e. the session is gone; this
# runs before the ctx-* sweep so the check sees the real mtime.
if [ -d "$OMC_STATE_DIR" ]; then
  find "$OMC_STATE_DIR" -maxdepth 1 -name 'gitcache-*' -type f -mmin +1440 -delete 2>/dev/null || :
  find "$OMC_STATE_DIR" -maxdepth 1 -name 'account-*'  -type f -mmin +1440 -delete 2>/dev/null || :
  find "$OMC_STATE_DIR" -maxdepth 1 -name 'handoff-*' -type f -mmin +1440 2>/dev/null | while IFS= read -r hf; do
    hn="${hf##*/}"
    [ -z "$(find "$OMC_STATE_DIR" -maxdepth 1 -name "ctx-${hn#handoff-}" -type f ! -mmin +1440 2>/dev/null)" ] && rm -f "$hf" 2>/dev/null
  done || :
  find "$OMC_STATE_DIR" -maxdepth 1 -name 'ctx-*' -type f -mmin +1440 -delete 2>/dev/null || :
fi

# Windows only: when Claude Code cancels an in-flight statusline render, a
# git.exe / jq.exe child it was starting can be left behind never resumed: one
# suspended thread, no CPU time used, parent gone. Sweep those at session
# start, in the background so startup is never delayed. A process is killed
# (by PID, never by name) only if it is git/jq, older than
# OMC_ORPHAN_SWEEP_MIN_AGE seconds (default 60), its command line looks like a
# statusline git/jq call, its parent is gone (or the parent PID was reused by
# a newer process), and it has exactly one thread, suspended, with zero CPU
# time. Any error in these checks skips the process.
# The PowerShell has two parts: ConvertTo-OrphanRecord turns raw process facts
# into a plain record, and Test-Orphan decides from that record alone.
# Opt out with OMC_ORPHAN_SWEEP=0. OMC_ORPHAN_SWEEP_DRYRUN=1 runs in the
# foreground and only prints the candidate PIDs. OMC_ORPHAN_SWEEP_RECORDS=
# <json file> runs the two functions over canned process facts and prints the
# ids of those judged orphans (used by the tests). A real run records a
# one-line summary in $OMC_STATE_DIR/orphan-sweep.last.
omc_orphan_sweep() {
  case "$OSTYPE" in msys*|cygwin*|mingw*) ;; *) return 0 ;; esac
  [ "${OMC_ORPHAN_SWEEP:-1}" = 0 ] && return 0
  local ps; ps="$(command -v powershell.exe || command -v pwsh.exe)" || return 0
  mkdir -p "$OMC_STATE_DIR" 2>/dev/null || :
  local out="$OMC_STATE_DIR/orphan-sweep.last"
  OMC_SWEEP_OUT="$(cygpath -w "$out" 2>/dev/null || printf '%s' "$out")"
  export OMC_SWEEP_OUT
  if [ -n "${OMC_ORPHAN_SWEEP_RECORDS:-}" ]; then
    OMC_ORPHAN_SWEEP_RECORDS="$(cygpath -w "$OMC_ORPHAN_SWEEP_RECORDS" 2>/dev/null || printf '%s' "$OMC_ORPHAN_SWEEP_RECORDS")"
    export OMC_ORPHAN_SWEEP_RECORDS
  fi
  local script
  script="$(cat <<'PSEOF'
$ErrorActionPreference = 'Stop'
$dry = $env:OMC_ORPHAN_SWEEP_DRYRUN -eq '1'
$minAge = 60; if ($env:OMC_ORPHAN_SWEEP_MIN_AGE -match '^\d+$') { $minAge = [int]$env:OMC_ORPHAN_SWEEP_MIN_AGE }
$git = '(?i)\bgit(\.exe)?"?\s+((status --porcelain( -b)? -uall( --no-ahead-behind)?|diff HEAD --numstat|rev-parse --show-toplevel|branch --show-current)"?\s*$|submodule(--helper)? foreach --quiet )'
$jq = '(?i)\bjq(\.exe)?"?\s+(--raw-output0|-j)\s'

# Raw facts -> plain record. $p: Name, CommandLine, CreationDate. $par: the
# process now holding the parent PID (or $null). $threads: ThreadState and
# WaitReason of every thread.
function ConvertTo-OrphanRecord($p, $par, $threads, $cpuTicks, $startTime, $now) {
  $th = @($threads)
  [pscustomobject]@{
    Name                = $p.Name
    CommandLine         = $p.CommandLine
    AgeSeconds          = ([datetime]$now - [datetime]$p.CreationDate).TotalSeconds
    ParentAlive         = [bool]($par -and [datetime]$par.CreationDate -le [datetime]$p.CreationDate)
    ThreadCount         = $th.Count
    AllThreadsSuspended = [bool]($th.Count -and -not @($th | Where-Object { $_.ThreadState -ne 'Wait' -or $_.WaitReason -ne 'Suspended' }).Count)
    CpuTicks            = $cpuTicks
    StartTimeMatches    = [math]::Abs(([datetime]$startTime - [datetime]$p.CreationDate).TotalSeconds) -le 2
  }
}

# Decision from a record alone; one check per line (each line ends in -and).
function Test-Orphan($r) {
  return ($r.Name -in 'git.exe', 'jq.exe' -and
    ($r.CommandLine -match $git -or $r.CommandLine -match $jq) -and
    $r.AgeSeconds -ge $minAge -and
    -not $r.ParentAlive -and
    $r.ThreadCount -eq 1 -and
    $r.AllThreadsSuspended -and
    $r.CpuTicks -eq 0 -and
    $r.StartTimeMatches)
}

if ($env:OMC_ORPHAN_SWEEP_RECORDS) {
  foreach ($c in (Get-Content -Raw -LiteralPath $env:OMC_ORPHAN_SWEEP_RECORDS | ConvertFrom-Json | ForEach-Object { $_ })) {
    $r = ConvertTo-OrphanRecord -p $c.p -par $c.par -threads $c.threads -cpuTicks $c.cpu -startTime $c.start -now $c.now
    if (Test-Orphan $r) { $c.id }
  }
  exit 0
}

$all = @{}; Get-CimInstance Win32_Process | ForEach-Object { $all[[int]$_.ProcessId] = $_ }
$seen = 0; $killed = 0
foreach ($p in $all.Values) {
  try {
    if ($p.Name -notin 'git.exe', 'jq.exe') { continue }
    $gp = Get-Process -Id $p.ProcessId
    $r = ConvertTo-OrphanRecord -p $p -par $all[[int]$p.ParentProcessId] -threads $gp.Threads -cpuTicks $gp.TotalProcessorTime.Ticks -startTime $gp.StartTime -now (Get-Date)
    if (-not (Test-Orphan $r)) { continue }
    $seen++
    if ($dry) { $p.ProcessId; continue }
    Stop-Process -Id $p.ProcessId -Force
    $killed++
  } catch { continue }
}
if (-not $dry -and $env:OMC_SWEEP_OUT) {
  try { "$((Get-Date).ToString('s')) candidates=$seen killed=$killed" | Set-Content -LiteralPath $env:OMC_SWEEP_OUT } catch {}
}
PSEOF
)" || return 0
  if [ "${OMC_ORPHAN_SWEEP_DRYRUN:-}" = 1 ] || [ -n "${OMC_ORPHAN_SWEEP_RECORDS:-}" ]; then
    "$ps" -NoProfile -NonInteractive -ExecutionPolicy Bypass -Command "$script" </dev/null || :
  else
    { "$ps" -NoProfile -NonInteractive -ExecutionPolicy Bypass -Command "$script" </dev/null >/dev/null 2>&1 & } 2>/dev/null
    disown 2>/dev/null || :
  fi
  return 0
}
omc_orphan_sweep || :

exit 0

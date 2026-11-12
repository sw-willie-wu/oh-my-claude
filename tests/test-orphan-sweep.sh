#!/bin/bash
# Tests for the Windows orphan sweep in setup.sh (OMC_ORPHAN_SWEEP*).
set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"
# shellcheck source=test-helpers.sh
. "$SCRIPT_DIR/test-helpers.sh"

SETUP_SH="${OMC_TEST_SETUP_SH:-$REPO_ROOT/plugins/oh-my-status/setup.sh}"
T="$(mktemp -d -t omc-orphan-XXXXXX)"
REAL_PS="$(command -v powershell.exe 2>/dev/null || true)"
PSARGS=(-NoProfile -NonInteractive -ExecutionPolicy Bypass)
WIN=0; case "$OSTYPE" in msys*|cygwin*|mingw*) WIN=1 ;; esac
CHILD=""; CHILD_ID=""   # the one real process this test creates

# proc_id <pid>: prints "name|creation-ticks", or nothing if the PID is gone.
proc_id() {
  "$REAL_PS" "${PSARGS[@]}" -Command "\$p = Get-CimInstance Win32_Process -Filter 'ProcessId=$1'; if (\$p) { \"\$(\$p.Name)|\$(\$p.CreationDate.ToUniversalTime().Ticks)\" }" </dev/null 2>/dev/null | tr -d '\r'
}
cleanup() {
  # Kill the child only if it is still the same process we created.
  if [ -n "$CHILD" ] && [ -n "$CHILD_ID" ] && [ "$(proc_id "$CHILD")" = "$CHILD_ID" ]; then
    taskkill //F //PID "$CHILD" >/dev/null 2>&1
  fi
  rm -rf "$T"
}
trap cleanup EXIT

# Stub powershell.exe: records the call, lingers, then writes a done marker.
# A setup.sh that waited for it would return after the marker exists.
STUB="$T/stub"; mkdir -p "$STUB"
printf '#!/bin/sh\necho invoked >> "%s/ps-calls"\nsleep 25\ntouch "%s/ps-done"\nexit 0\n' "$T" "$T" > "$STUB/powershell.exe"
chmod +x "$STUB/powershell.exe"

run_setup() {  # env assignments as args; sets RC; stdout->$T/out stderr->$T/err
  env OMC_DIR="$T/omc" OMC_CONF="$T/conf" OMC_STATE_DIR="$T/state" "$@" \
    bash "$SETUP_SH" >"$T/out" 2>"$T/err" </dev/null
  RC=$?
}

wait_for_file() {  # $1=path, up to ~20s
  local i; for i in $(seq 1 40); do [ -e "$1" ] && return 0; sleep 0.5; done; return 1
}

printf 'Running orphan-sweep tests in: %s\n' "$T"

start_test "default mode launches the sweep in the background and returns fast"
rm -f "$T/ps-calls" "$T/ps-done"
captured="$(PATH="$STUB:$PATH" OMC_ORPHAN_SWEEP=1 OMC_DIR="$T/omc" OMC_CONF="$T/conf" OMC_STATE_DIR="$T/state" bash "$SETUP_SH" 2>/dev/null)"
rc=$?
assert_eq "0" "$rc" "exit code"
[ -e "$T/ps-done" ] && r=waited || r=ok
assert_eq "ok" "$r" "pipe-captured run returned before the sweep finished"
if [ "$WIN" = 1 ]; then
  wait_for_file "$T/ps-calls" && r=invoked || r=not-invoked
  assert_eq "invoked" "$r" "stub powershell invoked"
fi
end_test

start_test "OMC_ORPHAN_SWEEP=0 does not invoke powershell"
rm -f "$T/ps-calls"
run_setup PATH="$STUB:$PATH" OMC_ORPHAN_SWEEP=0
assert_eq "0" "$RC" "exit code"
[ -e "$T/ps-calls" ] && r=invoked || r=skipped
assert_eq "skipped" "$r" "stub powershell not invoked"
end_test

if [ "$WIN" = 1 ]; then
  # ---- decision logic over canned process facts ----------------------------
  GITQ='"C:\Program Files\Git\mingw64\bin\git.exe" status --porcelain -b -uall --no-ahead-behind'
  BASE='{id:$id, p:{Name:"git.exe", CommandLine:$cmd, CreationDate:"2026-01-01T00:00:00Z"},
         par:null, threads:[{ThreadState:"Wait", WaitReason:"Suspended"}], cpu:0,
         start:"2026-01-01T00:00:01Z", now:"2026-01-01T00:10:00Z"}'
  : > "$T/cases"; : > "$T/expect"
  # mk <id> <yes|no> <command line> [jq filter applied to the base record]
  mk() {
    jq -n -c --arg id "$1" --arg cmd "$3" "$BASE | ${4:-.}" | tr -d '\r' >> "$T/cases"
    echo "$1 $2" >> "$T/expect"
  }
  mk base                 yes "$GITQ"
  mk cmd-launcher         yes '"C:\Program Files\Git\cmd\git.exe" status --porcelain -b -uall --no-ahead-behind'
  mk plain-status         yes 'git status --porcelain -uall'
  mk diff-numstat         yes '"C:\Program Files\Git\mingw64\bin\git.exe" diff HEAD --numstat'
  mk submodule            yes 'git submodule foreach --quiet git status'
  mk submodule-helper     yes 'git submodule--helper foreach --quiet git status'
  mk winget-jq            yes 'C:\Users\x\AppData\Local\Microsoft\WinGet\Links\jq.exe --raw-output0 " .session_id"' '.p.Name="jq.exe"'
  mk jq-dash-j            yes 'jq.exe -j ".name" f.json' '.p.Name="jq.exe"'
  mk parent-pid-reused    yes "$GITQ" '.par={CreationDate:"2026-01-01T00:05:00Z"}'
  mk other-name           no  "$GITQ" '.p.Name="node.exe"'
  mk other-cmdline        no  'git log --oneline'
  mk extra-trailing-arg   no  "$GITQ --foo"
  mk too-young            no  "$GITQ" '.now="2026-01-01T00:00:30Z"'
  mk parent-alive         no  "$GITQ" '.par={CreationDate:"2025-12-31T00:00:00Z"}'
  mk two-threads          no  "$GITQ" '.threads+=[{ThreadState:"Wait",WaitReason:"Suspended"}]'
  mk thread-running       no  "$GITQ" '.threads=[{ThreadState:"Running",WaitReason:"Executive"}]'
  mk thread-other-wait    no  "$GITQ" '.threads=[{ThreadState:"Wait",WaitReason:"Executive"}]'
  mk cpu-used             no  "$GITQ" '.cpu=100'
  mk start-mismatch       no  "$GITQ" '.start="2026-01-01T00:00:10Z"'
  jq -s -c . "$T/cases" > "$T/records.json"

  start_test "decision: orphan record is accepted, each single flipped check is rejected"
  run_setup OMC_ORPHAN_SWEEP=1 OMC_ORPHAN_SWEEP_RECORDS="$T/records.json"
  assert_eq "0" "$RC" "exit code"
  assert_eq "" "$(cat "$T/err")" "powershell stderr empty"
  tr -d '\r' < "$T/out" > "$T/listed"
  while read -r id want; do
    grep -qx "$id" "$T/listed" && got=yes || got=no
    assert_eq "$want" "$got" "case $id listed?"
  done < "$T/expect"
  end_test

  # ---- end to end with one real process ------------------------------------
  # A matching git.exe started CREATE_SUSPENDED and never resumed, whose parent
  # (a short-lived PowerShell) has exited. Other real orphans on the machine
  # may also be listed, so only this PID is checked.
  GIT_WIN="$(cygpath -w "$(command -v git)")"
  repo="$T/repo"; git init -q "$repo" 2>/dev/null
  cat > "$T/spawn.ps1" <<'PSEOF'
param($exe, $dir)
Add-Type @"
using System; using System.Runtime.InteropServices;
public class S {
  [StructLayout(LayoutKind.Sequential)] public struct SI { public int cb; public string r, d, t;
    public int x, y, xs, ys, xc, yc, fa, fl; public short sw, r2; public IntPtr r3, i, o, e; }
  [StructLayout(LayoutKind.Sequential)] public struct PI { public IntPtr hP, hT; public int pid, tid; }
  [DllImport("kernel32.dll", SetLastError=true, CharSet=CharSet.Unicode)]
  public static extern bool CreateProcess(string app, string cmd, IntPtr pa, IntPtr ta, bool inh,
    uint flags, IntPtr env, string cwd, ref SI si, out PI pi);
  [DllImport("kernel32.dll")] public static extern bool CloseHandle(IntPtr h);
}
"@
$si = New-Object 'S+SI'; $si.cb = [Runtime.InteropServices.Marshal]::SizeOf($si)
$pi = New-Object 'S+PI'
$cmd = '"' + $exe + '" status --porcelain -b -uall --no-ahead-behind'
if (-not [S]::CreateProcess($exe, $cmd, [IntPtr]::Zero, [IntPtr]::Zero, $false, 4, [IntPtr]::Zero, $dir, [ref]$si, [ref]$pi)) { exit 1 }
[S]::CloseHandle($pi.hP) | Out-Null; [S]::CloseHandle($pi.hT) | Out-Null
[Console]::Out.WriteLine($pi.pid)
PSEOF

  start_test "dry run lists a never-resumed matching git whose parent is gone"
  # Output goes to a file, not a pipe: the suspended child must not hold a pipe open.
  "$REAL_PS" "${PSARGS[@]}" -File "$(cygpath -w "$T/spawn.ps1")" \
    "$GIT_WIN" "$(cygpath -w "$repo")" </dev/null >"$T/pid" 2>"$T/pid.err"
  CHILD="$(tr -d '[:space:]' < "$T/pid")"
  case "$CHILD" in (""|*[!0-9]*) ok=bad; CHILD="" ;; (*) ok=ok; CHILD_ID="$(proc_id "$CHILD")" ;; esac
  assert_eq "ok" "$ok" "suspended git spawned"
  run_setup OMC_ORPHAN_SWEEP=1 OMC_ORPHAN_SWEEP_DRYRUN=1 OMC_ORPHAN_SWEEP_MIN_AGE=0
  assert_eq "0" "$RC" "exit code"
  tr -d '\r' < "$T/out" | grep -qx "$CHILD" && r=listed || r=missing
  assert_eq "listed" "$r" "child pid is in the dry-run output"
  assert_eq "" "$(cat "$T/err")" "powershell stderr empty"
  run_setup OMC_ORPHAN_SWEEP=1 OMC_ORPHAN_SWEEP_DRYRUN=1 OMC_ORPHAN_SWEEP_MIN_AGE=3600
  tr -d '\r' < "$T/out" | grep -qx "$CHILD" && r=listed || r=skipped
  assert_eq "skipped" "$r" "default min age skips a fresh process"
  end_test
fi

print_summary

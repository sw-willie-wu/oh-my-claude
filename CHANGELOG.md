# Changelog

## Unreleased

### Fixed
- The statusline's git calls now run with `GIT_OPTIONAL_LOCKS=0`. Before this,
  `git status` could take `.git/index.lock` to refresh the index, and when
  Claude Code killed a slow render partway through, the lock stayed behind and
  blocked your own `git add`/`commit` in the session's repo. This happened most
  in repos with submodules.

## 1.1.1 (2026-05-21)

### Fixed
- Worker-state lock is now PID-aware: a crashed or SIGKILL'd lock holder is
  detected via its recorded PID and reclaimed at once, and the stale-lock
  fallback window dropped from 10s to 3s — so a stuck lock no longer
  silently skips worker pruning for up to 10s. A holder also releases its
  lock only while it still owns it, so a force-broken holder cannot delete
  a successor's lock.
- Crash-orphaned temp files (`*.prune.*`, `gitcache-*.tmp.*`) are swept at
  the start of each render instead of lingering until the 24h cleanup.

### Changed
- Recommended statusLine `refreshInterval` is now 3 (was 1): on Windows a
  1-second tick can outpace a render and spawn overlapping, lock-contending
  statusline processes. `/oh-my-claude:setup` writes 3 for new installs and
  when adding the key to an existing config.

## 1.1.0 (2026-05-20)

### Added
- Workers section: live subagent / background-shell rows.
- `GIT_CACHE_TTL` (default 3s): caches git info so `refreshInterval: 1`
  is affordable. `GIT_CACHE_TTL=0` restores always-run-git behavior.

### Changed
- `/oh-my-claude:setup` is now upgrade-aware: if your `statusLine` already
  points to oh-my-claude but predates `refreshInterval`, it offers to add
  it (existing installs never received the 1.1.0 refresh feature otherwise).

### Upgrading
- **Fully restart Claude Code after updating.** The Workers section adds
  new `SessionStart` / `PreToolUse` / `PostToolUse` hooks; Claude Code
  caches the old `hooks.json` until a full restart. Without the restart,
  worker tracking never registers and no worker rows appear (the rest of
  the statusline still works). Re-running `/oh-my-claude:setup` alone does
  not load the hooks.
- Existing users: re-run `/oh-my-claude:setup` and accept the
  `refreshInterval` prompt.

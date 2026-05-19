# Changelog

## 1.1.0 (unreleased)

### Added
- Workers section: live subagent / background-shell rows.
- `GIT_CACHE_TTL` (default 3s): caches git info so `refreshInterval: 1`
  is affordable. `GIT_CACHE_TTL=0` restores always-run-git behavior.

### Changed
- `/oh-my-claude:setup` is now upgrade-aware: if your `statusLine` already
  points to oh-my-claude but predates `refreshInterval`, it offers to add
  it (existing installs never received the 1.1.0 refresh feature otherwise).

### Upgrading
- Existing users: re-run `/oh-my-claude:setup` and accept the
  `refreshInterval` prompt.

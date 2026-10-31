# Changelog

## Unreleased (2026-10-31)

### Changed (breaking)
- Split the repository into two plugins under `plugins/`: `oh-my-status` (the
  statusline, formerly `oh-my-claude`) and `oh-my-knowledge` (a new
  knowledge-base plugin, see below). The marketplace is still
  named `oh-my-claude`.
- Slash commands moved from the old `oh-my-claude` prefix to `/oh-my-status:`
  (`/oh-my-status:setup`, `/oh-my-status:set-theme`, `/oh-my-status:list-themes`).
- Plugin manifests and marketplace entries no longer carry a `version`.
  All plugins in this marketplace update together on each release.
- The marketplace declares `renames: {"oh-my-claude": "oh-my-status"}`, so
  enabled installs migrate automatically.
- The 24 h SessionStart sweep also removes stale `ctx-*` and `handoff-*`
  files from the state directory.

### Changed
- The repository has a `.gitattributes` (LF line endings everywhere).

### Added
- `oh-my-knowledge` plugin: a local, git-versioned knowledge base with five
  skills (`setup`, `lookup`, `distill`, `handoff`, `lint`), a lookup-reminder
  hook, an automatic handoff hook (needs `oh-my-status`, which now writes
  `ctx-<sid>`), and scripts for init, commit, search
  and lint. Requires bash, gawk, GNU date and find, and jq. See
  `plugins/oh-my-knowledge/README.md`.

### Upgrading
- Update the marketplace (or wait for auto-update), then close all sessions and
  restart Claude Code twice: the first restart installs `oh-my-status` in the
  background, the second makes it active. An old session's SessionStart would
  copy the old files back, so do not leave one running.
- Runtime paths are unchanged (`~/.claude/oh-my-claude/`,
  `~/.claude/oh-my-claude.conf`).
- If you had `oh-my-claude` disabled: run
  `/plugin uninstall oh-my-claude@oh-my-claude`, then
  `/plugin install oh-my-status@oh-my-claude`.

## 1.2.0 (2026-10-20)

### Added
- Account segment: the logged-in account is shown right after the model in all
  six layouts. It reads `oauthAccount` from `~/.claude.json` (or
  `$CLAUDE_CONFIG_DIR/.claude.json`), caches the result, and is hidden on
  API-key logins. Keys: `ACCOUNT_SHOW`, `ACCOUNT_FORMAT`
  (`name` | `fullname` | `email` | `org`) and `ACCOUNT_ICON`. It is **on by
  default**; set `ACCOUNT_SHOW=false` when screen sharing. It also works for
  standalone installs, since it needs no hooks.
- Model context tag: the model name gets ` [1M]` (or `[2M]`, ...) when the
  context window is 1,000,000 tokens or more, in all six layouts. A 200K
  session shows no tag. Set `MODEL_CTX_TAG=false` to turn it off.

### Removed
- Subagent (agent) rows from the Workers section. The CLI's agent panel below
  the prompt and `/tasks` cover them. Workers now shows background shells
  only. The keys `WORKERS_SHOW_AGENTS`, `WORKERS_SHOW_TYPE`,
  `WORKERS_AGENT_ICON`, `WORKERS_AGENT_QUIET_SEC` and
  `WORKERS_AGENT_TRANSCRIPT_ROOT` are gone; leftover lines in your conf are
  harmless.

### Upgrading
- **Fully restart every running Claude Code session after updating.** An old 1.1.2 session's SessionStart re-copies its old statusline and layouts over the shared live copy, so the account segment disappears until all sessions run 1.2.0.

### Changed
- Hooks match only `Bash|KillShell` (pre) and `Bash|BashOutput` (post), run a
  single jq pass, and exit before jq or the lock when `WORKERS_ENABLED` or
  `WORKERS_SHOW_SHELLS` is not true.
- The hooks need jq 1.7 or newer (the statusline already did).

### Fixed
- The conf template no longer blanks the shell icon: `WORKERS_SHELL_ICON` is
  now a commented example, so the theme default applies. A conf copied from an
  older template still has `WORKERS_SHELL_ICON=""`; delete that line to get
  the theme icon.

## 1.1.2 (2026-10-05)

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

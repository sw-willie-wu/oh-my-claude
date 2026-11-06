# Changelog

## Unreleased

### Removed
- The Workers section (background-shell rows) and everything behind it: the
  PreToolUse/PostToolUse hooks (`hooks/track-workers.sh`), `lib/state-lock.sh`,
  the per-session `state-<sid>.tsv` files and the `WORKERS_*` conf keys. A
  `WORKERS_*` line left in `~/.claude/oh-my-claude.conf` is ignored. Use
  `/tasks` to see background shells. Bash tool calls no longer start any
  oh-my-status hook process.

### Changed
- `statusLine.refreshInterval` is now opt-in. `/oh-my-status:setup` no longer
  adds `"refreshInterval": 3` by default; it asks whether to enable timer
  refresh (default "No", alternative "Refresh every 10 seconds"). On Windows a
  statusline render takes seconds, so a 3 s timer stacked overlapping renders
  across sessions and loaded the whole machine. The setup upgrade prompt that
  offered to add `refreshInterval` to an existing statusLine is removed, and an
  existing `refreshInterval` value is never touched.

### Migration (3.0.0)
- Restart every Claude Code session after updating. Until then an old 2.x
  session can run its SessionStart again on resume, `/clear` or `/compact`
  and copy the 2.x statusline back; the next 3.0 SessionStart replaces it.
- The first 3.0 SessionStart deletes the 2.x leftovers: `state-*.tsv`,
  `state.lock`, `track-workers.log` under `~/.claude/oh-my-claude/state/`, and
  `hooks/track-workers.sh`, `lib/state-lock.sh`, `lib/conf-keys.sh` under
  `~/.claude/oh-my-claude/` (the two folders are removed only when empty).
- The stale-file sweep (`ctx-*`, `handoff-*`, `gitcache-*`, `account-*` older
  than 24 h) now runs in `setup.sh`; standalone installs run it when
  `install.sh` runs.

## 2.0.0 (2026-11-04)

From this release on, releases are identified by the git tag (`v2.0.0`): the
manifests carry no version and `/plugin` shows a commit sha. Each release
heading is the tag name without the `v`.

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

### Changed
- The 24 h SessionStart sweep also removes stale `ctx-*` and `handoff-*`
  files from the state directory. A `handoff-<sid>` older than 24 h is kept
  while its `ctx-<sid>` is fresher than 24 h (the session is still in use).
- The repository has a `.gitattributes` (LF line endings everywhere).
- oh-my-status hides the 5h / 7d segment when Claude Code sends no such window
  (plans without that limit, API-key sessions, the first render); a present
  0 % still shows `0%`.

### Added
- `oh-my-knowledge` plugin: a local, git-versioned knowledge base with five
  skills (`setup`, `lookup`, `distill`, `handoff`, `lint`), a lookup-reminder
  hook, an automatic handoff hook (needs `oh-my-status`, which now writes
  `ctx-<sid>`), and scripts for init, commit, search and lint. Requires bash,
  gawk, GNU find (BSD date is fine), and jq. See
  `plugins/oh-my-knowledge/README.md`.
  The automatic handoff fires at the threshold and again once usage has grown
  by `auto_handoff_repeat` points (default 20, range 10-60) past the usage
  recorded in `handoff-<sid>` at the last handoff; `/compact` and `/clear`
  start a new window.
- Project always-on directives: `projects/<p>/always-on.md` holds directives
  that apply to one project in every reply. The SessionStart hook injects its
  `- ` lines (up to 4000 bytes) for a migrated project; distill harvests such
  directives into it and promotes them to a rule on request ("make X a global
  rule"). Lint skips `progress_leak` on that page and lists its line counts.

### Upgrading
- Run `/plugin marketplace update oh-my-claude`, then close all sessions and
  restart Claude Code twice: the first restart installs `oh-my-status` in the
  background, the second makes it active. Every running Claude Code session
  must be restarted after updating: an old session's SessionStart would copy
  the old files back, so do not leave one running.
- If you had `oh-my-claude` disabled, run
  `/plugin uninstall oh-my-claude@oh-my-claude`,
  `/plugin install oh-my-status@oh-my-claude`, then
  `/plugin disable oh-my-status@oh-my-claude`.
- `oh-my-knowledge` is a new plugin and is not installed by the update: run
  `/plugin install oh-my-knowledge@oh-my-claude`, then `/oh-my-knowledge:setup`.
- `--plugin-dir` users: point it at `<repo>/plugins/oh-my-status` (and
  `<repo>/plugins/oh-my-knowledge`), not the repository root.
- A project-level `.claude/settings.json` that enables
  `oh-my-claude@oh-my-claude` needs the key renamed to
  `oh-my-status@oh-my-claude` by hand; the automatic rename was verified only
  for user settings.
- Runtime paths are unchanged (`~/.claude/oh-my-claude/`,
  `~/.claude/oh-my-claude.conf`).
- An existing knowledge base's `SCHEMA.md` is not updated automatically: copy
  the `always-on.md` paragraph, the rule-5 `index.md` exemption and the status
  sentence in `## Projects` from
  `plugins/oh-my-knowledge/templates/SCHEMA.md` into it. The plugin's rule
  (distill reference) applies regardless.

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

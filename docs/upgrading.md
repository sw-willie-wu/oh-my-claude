# Upgrading

[← Back to README](../README.md)

## Upgrading to 2.1

1. Update the marketplace: `/plugin marketplace update oh-my-claude`.
2. Restart every running Claude Code session. Until you do, an old 2.0 session can copy the 2.0 statusline back on resume, `/clear` or `/compact`.
3. The Workers section (background-shell rows) is gone, together with its tool hooks. Use Claude Code's `/tasks` to see background shells. `WORKERS_*` lines left in `~/.claude/oh-my-claude.conf` are ignored and can be deleted.
4. The first 2.1 SessionStart removes the 2.0 leftovers under `~/.claude/oh-my-claude/`: the `state-*.tsv` files, `state.lock`, and the plugin's own files in `hooks/` and `lib/`. Files you added there yourself are kept.
5. Optional: to keep rate-limit and git info current while the agent is idle, add `"refreshInterval": 10` to your `statusLine` settings (see [Notes](statusline.md#notes)).

## Upgrading from oh-my-claude

The statusline plugin was renamed from `oh-my-claude` to `oh-my-status`, and the repository now holds its plugins under `plugins/`. The marketplace name stays `oh-my-claude`, and runtime paths (`~/.claude/oh-my-claude/`, `~/.claude/oh-my-claude.conf`) are unchanged, so your theme, layout and config carry over.

1. Update the marketplace: `/plugin marketplace update oh-my-claude`.
2. Close all running Claude Code sessions, then start Claude Code and restart it once more. The first start installs `oh-my-status` in the background; the second makes it active. Every running session must be restarted after updating; do not keep an old one open: its SessionStart hook would copy the old files back.
3. Slash commands moved from the old `oh-my-claude` prefix to `/oh-my-status:` (for example `/oh-my-status:setup`).

If you had `oh-my-claude` disabled, the rename does not migrate it. Run `/plugin uninstall oh-my-claude@oh-my-claude`, then `/plugin install oh-my-status@oh-my-claude`, then `/plugin disable oh-my-status@oh-my-claude` to keep it disabled.

If you start Claude Code with `--plugin-dir`, point it at `<repo>/plugins/oh-my-status` (and `<repo>/plugins/oh-my-knowledge` for the knowledge plugin) instead of the repository root.

If a project-level `.claude/settings.json` enables `oh-my-claude@oh-my-claude`, rename the key to `oh-my-status@oh-my-claude` by hand; the automatic rename was verified only for user settings.

## Upgrading from before 1.1.0

If you installed oh-my-claude before 1.1.0, re-run `/oh-my-status:setup` to pick up newer conf options. Timer refresh (`refreshInterval`) is opt-in and no longer prompted for on upgrade; see [Notes](statusline.md#notes). Existing themes/layouts are unaffected.

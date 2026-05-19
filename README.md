# oh-my-claude

Themeable statusline plugin for [Claude Code](https://claude.com/claude-code). Mix and match **9 color themes** with **6 layouts**.

## Themes

| Theme | Colors |
|-------|--------|
| **catppuccin** | Soft pastel blues, pinks, and lavenders |
| **dracula** | Classic purple, pink, and cyan |
| **nord** | Cool arctic blues and greens |
| **gruvbox** | Warm retro earth tones |
| **tokyonight** | Deep blue and purple neon |
| **onedark** | Atom-inspired balanced palette |
| **solarized** | Ethan Schoonover's classic |
| **rosepine** | Soft rose and pine tones |
| **mygo** | BanG Dream! MyGO!!!!! band colors |

## Layouts

| Layout | Description |
|--------|-------------|
| **default** | Two lines: model + git info / progress bars |
| **minimal** | Single compact line |
| **powerline** | Arrow separators (requires Nerd Font) |
| **pure** | Clean text, no icons or special characters |
| **fancy** | Three lines with detailed info and box drawing |
| **mygo** | Band-inspired two-line with musical separators |

## Workers

When subagents (Task tool) or background shells (Bash with `run_in_background: true`) are running, they appear as dedicated lines at the top of the statusline:

```
 claude-code-guide: research-statusline-feature              12s
 run-dev-server: npm run dev                              4m32s
◇ opus  ~/oh-my-claude  main +2 ~1
████░░░ 23%   ██░░░░░ 15%   █░░░░░ 8%
```

Each line shows: nerd-font icon, optional `subagent_type` prefix, description, optional command (shells only), and elapsed time. Long lines are tail-truncated.

### Configuration

Add to `~/.claude/oh-my-claude.conf`:

```bash
WORKERS_ENABLED=true              # master toggle
WORKERS_SHOW_AGENTS=true          # show subagent lines
WORKERS_SHOW_SHELLS=true          # show background bash lines
WORKERS_SHOW_TYPE=true            # show subagent_type prefix on agent lines
WORKERS_SHOW_ELAPSED=true         # show elapsed time
WORKERS_MAX=5                     # 0 = unlimited
WORKERS_AGENT_ICON=""           # nf-fa-cogs
WORKERS_SHELL_ICON=""           # nf-cod-terminal
WORKERS_SHELL_MAX_AGE=3600        # seconds; older shells are dimmed and marked '?'
WORKERS_AGENT_QUIET_SEC=60        # async-agent transcript idle window: within this, the agent is treated as alive (fast path) before the last-line check decides
GIT_CACHE_TTL=3                   # git-info cache TTL (s); 0 = disable (always run git). See note below.
```

### Known limits

- Two simultaneous bg commands sharing the first 60 chars of their command bind to a single PID. When one completes, both rows prune together.
- PID reuse: a recycled PID for a long-dead bg row may falsely report "alive". Bounded by `WORKERS_SHELL_MAX_AGE` greying behavior.
- bg-Bash liveness (when PID acquisition fails) and async-agent liveness are read at draw time by fingerprint/transcript inspection. A `ps` that doesn't list the process (or a non-MSYS `ps -ef` column layout) can false-prune a still-running worker; the grace window mitigates the common case. Primary target is git-bash/MSYS on Windows.

### Limitations

- Background shells that crash without being polled (`BashOutput`) may continue to show as running. After `WORKERS_SHELL_MAX_AGE` (default 1h) they are visually dimmed and marked with `?`. Use Claude Code's built-in `/bashes` command for the true running state.
- Requires `jq` for hook side. Without it, the hook silently no-ops and no worker lines appear; the rest of the statusline is unaffected.
- For elapsed time to keep updating while the main agent waits on subagents, set `"refreshInterval": 1` in your `statusLine` settings (the `/oh-my-claude:setup` command does this automatically). To keep that affordable, git info is cached for `GIT_CACHE_TTL` seconds (default 3) instead of running git on every tick. Tradeoff: a branch switch / commit / stage in the same directory is reflected within `GIT_CACHE_TTL` seconds rather than instantly. Set `GIT_CACHE_TTL=0` to disable the cache and always run git (instant git accuracy, the pre-cache behavior).

## Install

### Via Marketplace (recommended)

In Claude Code, run:

```
/plugin marketplace add sw-willie-wu/oh-my-claude
/plugin install oh-my-claude@oh-my-claude
/reload-plugins
```

Then run setup to configure the statusline:

```
/oh-my-claude:setup
```

Restart Claude Code to see the statusline.

### Local Development

```bash
git clone https://github.com/sw-willie-wu/oh-my-claude.git
claude --plugin-dir ./oh-my-claude
```

Then run `/oh-my-claude:setup` and restart Claude Code.

### Standalone (no plugin system)

```bash
git clone https://github.com/sw-willie-wu/oh-my-claude.git
bash oh-my-claude/install.sh
```

Restart Claude Code to see the statusline.

### Upgrading

If you installed oh-my-claude before 1.1.0, re-run `/oh-my-claude:setup` and accept the prompt to add `refreshInterval` to your `statusLine` settings — it enables the live elapsed-time / workers refresh (git info is cached for `GIT_CACHE_TTL` seconds so the 1-second refresh stays cheap). Existing themes/layouts are unaffected.

## Usage

### Switch theme / layout

```
/oh-my-claude:set-theme dracula        # Switch theme only
/oh-my-claude:set-theme dracula fancy  # Switch theme and layout
```

Theme and layout changes take effect on the next statusline refresh (no restart needed).

### Preview all themes and layouts

```
/oh-my-claude:list-themes
```

Press `ctrl+o` on the output to expand and see the full color preview.

Or run directly in terminal:

```bash
! bash ~/.claude/oh-my-claude/preview.sh
```

### Manual configuration

Edit `~/.claude/oh-my-claude.conf`:

```bash
THEME="dracula"
LAYOUT="powerline"
```

## How it works

- **Plugin install** registers slash commands (`setup`, `set-theme`, `list-themes`)
- **SessionStart hook** syncs themes/layouts from the plugin to `~/.claude/oh-my-claude/` (auto-updates when plugin updates)
- **`/oh-my-claude:setup`** adds the `statusLine` config to your `~/.claude/settings.json` (asks before overwriting existing config)
- **Config file** (`~/.claude/oh-my-claude.conf`) stores your theme/layout choice and is preserved across updates

## File locations

| File | Purpose |
|------|---------|
| `~/.claude/oh-my-claude.conf` | Theme and layout selection |
| `~/.claude/oh-my-claude/` | Runtime files (synced from plugin) |
| `~/.claude/settings.json` | statusLine command config |

## Create your own theme

Add a `.sh` file to `themes/` with 9 color variables:

```bash
# My Custom Theme
C_PRIMARY='\033[38;2;R;G;Bm'
C_SECONDARY='\033[38;2;R;G;Bm'
C_ACCENT='\033[38;2;R;G;Bm'
C_GREEN='\033[38;2;R;G;Bm'
C_YELLOW='\033[38;2;R;G;Bm'
C_RED='\033[38;2;R;G;Bm'
C_TEXT='\033[38;2;R;G;Bm'
C_SUBTEXT='\033[38;2;R;G;Bm'
C_SURFACE='\033[38;2;R;G;Bm'
```

Replace `R;G;B` with your color values (0-255). The first comment line is used as the theme display name.

## Create your own layout

Add a `.sh` file to `layouts/` that defines a `render()` function. Available variables:

- `$MODEL`, `$DIR`, `$BRANCH` - basic info
- `$ADD_FILES`, `$MOD_FILES`, `$DEL_FILES` - git file counts
- `$LINES_ADD`, `$LINES_DEL` - git line counts
- `$CTX_PCT`, `$RATE5_PCT`, `$RATE7_PCT` - usage percentages
- `$C_PRIMARY`, `$C_SECONDARY`, etc. - theme colors

See existing layouts in `layouts/` for examples.

## License

MIT

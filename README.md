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

When background shells (Bash with `run_in_background: true`) are running, they appear as dedicated lines at the top of the statusline:

```
 run-dev-server: npm run dev                              4m32s
◇ opus  ~/oh-my-claude  main +2 ~1
████░░░ 23%   ██░░░░░ 15%   █░░░░░ 8%
```

Each line shows: icon (theme default ⏳), description, command, and elapsed time. Long lines are tail-truncated.

Agents are not tracked here. Use the CLI's built-in agent panel below the prompt, or `/tasks`.

### Configuration

Add to `~/.claude/oh-my-claude.conf`:

```bash
WORKERS_ENABLED=true              # master toggle
WORKERS_SHOW_SHELLS=true          # show background bash lines
WORKERS_SHOW_ELAPSED=true         # show elapsed time
WORKERS_MAX=5                     # 0 = unlimited
# WORKERS_SHELL_ICON=$'\xe2\x8f\xb3'  # optional override; default comes from the theme; "" hides the icon
WORKERS_SHELL_MAX_AGE=3600        # seconds; older shells are dimmed and marked '?'
GIT_CACHE_TTL=3                   # git-info cache TTL (s); 0 = disable (always run git). See note below.
```

### Known limits

- Two simultaneous bg commands sharing the first 60 chars of their command bind to a single PID. When one completes, both rows prune together.
- PID reuse: a recycled PID for a long-dead bg row may falsely report "alive". Bounded by `WORKERS_SHELL_MAX_AGE` greying behavior.
- bg-Bash liveness (when PID acquisition fails) is read at draw time by fingerprint inspection. A `ps` that doesn't list the process (or a non-MSYS `ps -ef` column layout) can false-prune a still-running worker; the grace window mitigates the common case. Primary target is git-bash/MSYS on Windows.

### Limitations

- Background shells that crash without being polled (`BashOutput`) may continue to show as running. After `WORKERS_SHELL_MAX_AGE` (default 1h) they are visually dimmed and marked with `?`. Use Claude Code's built-in `/tasks` command for the true running state.
- The statusline itself needs `jq` 1.7 or newer. The hooks need it too: without it the hook silently no-ops and no worker lines appear.
- Plugin-only. The Workers section relies on the plugin's tool hooks, so it works only when oh-my-claude is installed as a plugin (marketplace or `--plugin-dir`). Standalone `install.sh` installs get the statusline but no worker rows.
- For elapsed time to keep updating while the main agent is idle, set `"refreshInterval": 3` in your `statusLine` settings (the `/oh-my-claude:setup` command does this automatically). 3 rather than 1 is deliberate — on Windows a 1-second tick can outpace a render and spawn overlapping statusline processes that contend for the worker-state lock. To keep frequent refreshes affordable, git info is cached for `GIT_CACHE_TTL` seconds (default 3) instead of running git on every tick. Tradeoff: a branch switch / commit / stage in the same directory is reflected within `GIT_CACHE_TTL` seconds rather than instantly. Set `GIT_CACHE_TTL=0` to disable the cache and always run git (instant git accuracy, the pre-cache behavior).

## Account

The statusline shows the logged-in Claude account right after the model name. It reads `oauthAccount` from `~/.claude.json` (or `$CLAUDE_CONFIG_DIR/.claude.json` when that variable is set) and caches the result. It works for standalone installs too, because it needs no hooks. On API-key logins there is no `oauthAccount`, so the segment is hidden.

It is **on by default**. Set `ACCOUNT_SHOW=false` when screen sharing.

```bash
ACCOUNT_SHOW=true                 # show the account segment
ACCOUNT_FORMAT=name               # name | fullname | email | org
# ACCOUNT_ICON=$'\xef\x80\x87'    # optional override (default nf-fa-user); "" hides the icon
```

The minimal, pure and mygo layouts never show an icon. If the chosen field is empty, the first non-empty fallback is used; if all are empty the segment is hidden:

| `ACCOUNT_FORMAT` | Fallback chain                       |
|------------------|--------------------------------------|
| `name`           | displayName → fullName → email       |
| `fullname`       | fullName → displayName → email       |
| `email`          | email                                |
| `org`            | organizationName → email             |

An unknown `ACCOUNT_FORMAT` value is treated as `name`.

## Model context tag

When Claude Code reports a context window of 1,000,000 tokens or more, the model name gets a tag such as `Opus 5.5 [1M]` (2,000,000 gives `[2M]`; sizes in between round down). A 200K session shows no tag. Set `MODEL_CTX_TAG=false` to turn it off.

```bash
MODEL_CTX_TAG=true                # append [1M] to the model name for 1M+ contexts
```

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

Restart Claude Code to see the statusline. Note: the standalone install
provides the statusline only — the [Workers](#workers) section needs the
plugin's tool hooks, so install via the marketplace or `--plugin-dir` if
you want live background-shell rows.

### Upgrading

If you installed oh-my-claude before 1.1.0, re-run `/oh-my-claude:setup` and accept the prompt to add `refreshInterval` to your `statusLine` settings — it enables the live background-shell elapsed-time refresh (git info is cached for `GIT_CACHE_TTL` seconds so the 3-second refresh stays cheap). Existing themes/layouts are unaffected.

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

- `$MODEL`, `$DIR`, `$BRANCH` - basic info (`$MODEL` may end in ` [NM]`, e.g. ` [1M]`, for large context windows)
- `$ADD_FILES`, `$MOD_FILES`, `$DEL_FILES` - git file counts
- `$LINES_ADD`, `$LINES_DEL` - git line counts
- `$CTX_PCT`, `$RATE5_PCT`, `$RATE7_PCT` - usage percentages
- `$ACCOUNT`, `$ACCOUNT_ICON` - account segment (`$ACCOUNT` is empty when hidden; safe for `echo -e`)
- `$C_PRIMARY`, `$C_SECONDARY`, etc. - theme colors

See existing layouts in `layouts/` for examples.

## License

MIT

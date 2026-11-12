# oh-my-status: themes, layouts and usage

[← Back to README](../README.md)

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

## Notes

- The statusline needs `jq` 1.7 or newer.
- Timer refresh is opt-in. By default the statusline re-renders only on Claude Code events, so rate-limit and git info can go stale while the main agent is idle. To keep them current, add `"refreshInterval": 10` to your `statusLine` settings (`/oh-my-status:setup` asks about this; it is never added by default). Avoid values below 10: a render now starts only about two processes, but process-creation stalls on Windows can still make one slow, and a short timer would stack overlapping statusline processes across sessions and burn CPU.
- `GIT_CACHE_TTL` (conf key, default 10): git runs at most once per this many seconds. A branch switch, commit or stage shows at the next render anyway, because the cache is dropped as soon as `.git` (HEAD, index, the branch ref) changes; edits to working-tree files show within `GIT_CACHE_TTL` seconds. Directories that are not git repositories never run git. Set `GIT_CACHE_TTL=0` to disable the cache and always run git.

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

## Usage

### Switch theme / layout

```
/oh-my-status:set-theme dracula        # Switch theme only
/oh-my-status:set-theme dracula fancy  # Switch theme and layout
```

Theme and layout changes take effect on the next statusline refresh (no restart needed).

### Preview all themes and layouts

```
/oh-my-status:list-themes
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
- **SessionStart hook** syncs themes/layouts from the plugin to `~/.claude/oh-my-claude/` (auto-updates when plugin updates), sweeps stale state files, and (Windows) kills orphaned suspended `git.exe`/`jq.exe` left by cancelled renders in the background (`OMC_ORPHAN_SWEEP=0` disables)
  - Known limitations: some git calls made by git's own submodule shell wrapper are not matched, and there is a tiny race between looking a process up and killing it.
- **`/oh-my-status:setup`** adds the `statusLine` config to your `~/.claude/settings.json` (asks before overwriting existing config)
- **Config file** (`~/.claude/oh-my-claude.conf`) stores your theme/layout choice and is preserved across updates

## File locations

| File | Purpose |
|------|---------|
| `~/.claude/oh-my-claude.conf` | Theme and layout selection |
| `~/.claude/oh-my-claude/` | Runtime files (synced from plugin) |
| `~/.claude/settings.json` | statusLine command config |

## Create your own theme

Add a `.sh` file to `plugins/oh-my-status/themes/` with 9 color variables:

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

Add a `.sh` file to `plugins/oh-my-status/layouts/` that defines a `render()` function. Available variables:

- `$MODEL`, `$DIR`, `$BRANCH` - basic info (`$MODEL` may end in ` [NM]`, e.g. ` [1M]`, for large context windows)
- `$ADD_FILES`, `$MOD_FILES`, `$DEL_FILES` - git file counts
- `$LINES_ADD`, `$LINES_DEL` - git line counts
- `$CTX_PCT`, `$RATE5_PCT`, `$RATE7_PCT` - usage percentages (`$RATE5_PCT`/`$RATE7_PCT` are empty when that window is absent)
- `$ACCOUNT`, `$ACCOUNT_ICON` - account segment (`$ACCOUNT` is empty when hidden; safe for `echo -e`)
- `$C_PRIMARY`, `$C_SECONDARY`, etc. - theme colors

See existing layouts in `plugins/oh-my-status/layouts/` for examples.

## Regenerating the README screenshots

`assets/statusline-fancy.svg` is drawn from a real render. To regenerate it, run `bash scripts/render-statusline-svg.sh` (dev tool; needs `bash`, `git`, `jq` and `uv`; it uses a throwaway HOME and never touches `~/.claude`). `scripts/ansi-to-svg.py` takes `--width N` to set the canvas width (default: fit the content); the script renders the README image 800 px wide.

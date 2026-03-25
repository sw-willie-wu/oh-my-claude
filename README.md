# oh-my-claude

Themeable statusline plugin for [Claude Code](https://claude.com/claude-code). Mix and match **8 color themes** with **5 layouts**.

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

## Layouts

| Layout | Description |
|--------|-------------|
| **default** | Two lines: model + git info / progress bars |
| **minimal** | Single compact line |
| **powerline** | Arrow separators (requires Nerd Font) |
| **pure** | Clean text, no icons or special characters |
| **fancy** | Three lines with detailed info and box drawing |

## Install

### Via Marketplace (recommended)

In Claude Code, run:

```
/plugin marketplace add sw-willie-wu/oh-my-claude
/plugin install oh-my-claude@oh-my-claude
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

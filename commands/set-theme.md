---
description: Switch oh-my-claude theme and/or layout
---

Read the oh-my-claude config file at ~/.claude/oh-my-claude.conf and show the user the current THEME and LAYOUT settings.

Then list the available options:

Themes: catppuccin, dracula, nord, gruvbox, tokyonight, onedark, solarized, rosepine
Layouts: default (two-line with progress bars), minimal (single compact line), powerline (arrow separators), pure (no icons, no nerd font needed), fancy (three-line detailed)

If the user provided arguments "$ARGUMENTS", parse them and apply:
- If one argument matches a theme name, set THEME to that value
- If one argument matches a layout name, set LAYOUT to that value
- If two arguments are given, the first is theme and the second is layout
- If the argument is "list", just show available options without changing anything
- If the argument is "preview", show a short text preview of what each layout looks like

Update the THEME and LAYOUT values in ~/.claude/oh-my-claude.conf using sed. Do not overwrite the file — only replace the specific lines.

After updating, confirm the change and remind the user to restart Claude Code (or the statusline will update on next refresh).

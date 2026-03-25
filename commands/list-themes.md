Run the oh-my-claude preview script to show the user a visual demo of all available themes and layouts with actual ANSI colors:

```
bash ~/.claude/oh-my-claude/preview.sh all
```

If the user provided arguments "$ARGUMENTS":
- "themes" or "theme": run `bash ~/.claude/oh-my-claude/preview.sh themes`
- "layouts" or "layout": run `bash ~/.claude/oh-my-claude/preview.sh layouts`
- Otherwise: run with "all"

After running the script, tell the user:

Press `ctrl+o` on the command output above to expand and see the full color preview.

To switch theme/layout: `/oh-my-claude:set-theme <theme> <layout>`

---
description: Configure oh-my-claude statusline in your settings
---

Configure the oh-my-claude statusline in the user's settings.

Steps:

1. Read ~/.claude/settings.json to check if a "statusLine" entry already exists.

2. Based on what you find:

   a) If there is NO "statusLine" entry:
      - If the AskUserQuestion tool is available in your tool list, use it with options [Yes, No] to ask: "No statusLine configured. Add oh-my-claude statusline to your settings?"
      - If AskUserQuestion is not available, ask in plain chat text instead.
      - If yes, add this to their ~/.claude/settings.json:
        ```json
        "statusLine": {
          "type": "command",
          "command": "bash ~/.claude/oh-my-claude/statusline.sh",
          "padding": 1,
          "refreshInterval": 1
        }
        ```
        The `refreshInterval: 1` keeps elapsed time in the workers section updating while the main agent waits on subagents. If the user prefers no extra timer-driven refreshes, omit it.

   b) If "statusLine" already exists AND already points to "oh-my-claude/statusline.sh":
      - Tell the user: "oh-my-claude is already configured. You're all set!"

   c) If "statusLine" already exists but points to a DIFFERENT command:
      - Show the user the current statusLine config
      - If the AskUserQuestion tool is available, use it with options [Yes, No] to ask: "You already have a statusLine configured. Do you want to replace it with oh-my-claude?"
      - If AskUserQuestion is not available, ask in plain chat text instead.
      - Only update if the user confirms.

3. After updating (or skipping), tell the user:
   - Restart Claude Code to see the statusline
   - `/oh-my-claude:list-themes` to preview themes and layouts
   - `/oh-my-claude:set-theme <theme> <layout>` to switch

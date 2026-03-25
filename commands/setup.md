Configure the oh-my-claude statusline in the user's settings.

Steps:

1. Read ~/.claude/settings.json to check if a "statusLine" entry already exists.

2. Based on what you find:

   a) If there is NO "statusLine" entry:
      - Ask the user: "No statusLine configured. Add oh-my-claude statusline to your settings?"
      - If yes, add this to their ~/.claude/settings.json:
        ```json
        "statusLine": {
          "type": "command",
          "command": "bash ~/.claude/oh-my-claude/statusline.sh",
          "padding": 1
        }
        ```

   b) If "statusLine" already exists AND already points to "oh-my-claude/statusline.sh":
      - Tell the user: "oh-my-claude is already configured. You're all set!"

   c) If "statusLine" already exists but points to a DIFFERENT command:
      - Show the user the current statusLine config
      - Ask: "You already have a statusLine configured. Do you want to replace it with oh-my-claude?"
      - Only update if the user confirms

3. After updating (or skipping), tell the user:
   - Restart Claude Code to see the statusline
   - `/oh-my-claude:list-themes` to preview themes and layouts
   - `/oh-my-claude:set-theme <theme> <layout>` to switch

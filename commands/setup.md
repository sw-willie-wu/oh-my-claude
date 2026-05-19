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

   b) If "statusLine" already exists AND its command points to "oh-my-claude/statusline.sh":
      (Treat "statusLine" as the object at the top level of ~/.claude/settings.json.
      If "statusLine" is not a JSON object with a "command" string — e.g. a string
      or array — fall through to case (c) and offer to replace it. Match the command
      by plain substring on the value as written: do not expand `$HOME` or require a
      `bash ` prefix.)
      - Look ONLY at the keys directly inside that "statusLine" object. If it
        contains a key named "refreshInterval" (at any value, including
        0/false/null — a user who opted out simply omits the key, so a present
        key means already-configured or a deliberate value):
        - Tell the user: "oh-my-claude is already configured. You're all set!"
      - If that "statusLine" object has NO "refreshInterval" key:
        - Show the user their current statusLine block.
        - If the AskUserQuestion tool is available, use it with options [Yes, No]
          to ask: "Your oh-my-claude statusLine is missing `refreshInterval`
          (added in oh-my-claude 1.1.0 — keeps elapsed time in the workers
          section updating while the main agent waits on subagents; optional).
          Add it?"
        - If AskUserQuestion is not available, ask in plain chat text instead.
        - If yes: add ONLY the key `"refreshInterval": 1` into the EXISTING
          statusLine object in ~/.claude/settings.json, preserving every other
          key in that object and the rest of the file (a targeted one-key
          insertion — do NOT rewrite or reformat settings.json). Confirm to the
          user that you have added `"refreshInterval": 1` to their
          ~/.claude/settings.json statusLine object, then tell them: the
          `refreshInterval: 1` keeps elapsed time updating while the main agent
          waits on subagents; to disable the extra timer-driven refreshes,
          remove the `refreshInterval` line.
        - If no: leave ~/.claude/settings.json unchanged and continue.

   c) If "statusLine" already exists but points to a DIFFERENT command:
      - Show the user the current statusLine config
      - If the AskUserQuestion tool is available, use it with options [Yes, No] to ask: "You already have a statusLine configured. Do you want to replace it with oh-my-claude?"
      - If AskUserQuestion is not available, ask in plain chat text instead.
      - Only update if the user confirms.

3. After updating (or skipping), tell the user:
   - Restart Claude Code to see the statusline
   - `/oh-my-claude:list-themes` to preview themes and layouts
   - `/oh-my-claude:set-theme <theme> <layout>` to switch

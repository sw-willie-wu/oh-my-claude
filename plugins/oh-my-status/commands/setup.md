---
description: Configure oh-my-status statusline in your settings
---

Configure the oh-my-claude statusline in the user's settings.

Steps:

1. Read ~/.claude/settings.json to check if a "statusLine" entry already exists.

2. Based on what you find:

   a) If there is NO "statusLine" entry:
      - If the AskUserQuestion tool is available in your tool list, use it with options [Yes, No] to ask: "No statusLine configured. Add oh-my-claude statusline to your settings?"
      - If AskUserQuestion is not available, ask in plain chat text instead.
      - If yes, ask a second question about timer refresh. If the AskUserQuestion tool is available, use it with these two options (in this order); otherwise ask in plain chat text:
        1. "No timer refresh (Recommended)"
        2. "Refresh every 10 seconds" — keeps rate-limit and git info current while the main agent is idle, but costs CPU on Windows (each render is slow there).
      - Then add this to their ~/.claude/settings.json (NO `refreshInterval` unless the user chose option 2):
        ```json
        "statusLine": {
          "type": "command",
          "command": "bash ~/.claude/oh-my-claude/statusline.sh",
          "padding": 1
        }
        ```
        Only if the user chose "Refresh every 10 seconds", also add `"refreshInterval": 10` to that object. Tell the user they can remove that line at any time to turn timer refresh off.

   b) If "statusLine" already exists AND its command points to "oh-my-claude/statusline.sh":
      (Treat "statusLine" as the object at the top level of ~/.claude/settings.json.
      If "statusLine" is not a JSON object with a "command" string — e.g. a string
      or array — fall through to case (c) and offer to replace it. Match the command
      by plain substring on the value as written: do not expand `$HOME` or require a
      `bash ` prefix.)
      - Do NOT modify the statusLine object, and do NOT offer to add `refreshInterval`.
      - If it already contains a `refreshInterval` key, leave it exactly as is (never
        silently change a user's value). You may mention that values below 10 are
        discouraged on Windows (slow renders can pile up) and that deleting the
        `refreshInterval` line turns timer refresh off.
      - Tell the user: "oh-my-claude is already configured. You're all set!"

   c) If "statusLine" already exists but points to a DIFFERENT command:
      - Show the user the current statusLine config
      - If the AskUserQuestion tool is available, use it with options [Yes, No] to ask: "You already have a statusLine configured. Do you want to replace it with oh-my-claude?"
      - If AskUserQuestion is not available, ask in plain chat text instead.
      - Only update if the user confirms.

3. Conf-key backfill — bring an existing `~/.claude/oh-my-claude.conf` up
      to date with options added to the bundled template, without overwriting
      any existing value:

      - Read `~/.claude/oh-my-claude.conf`. If it does not exist or is empty,
        skip this step (a fresh install already received the full template).
      - Read the bundled template `oh-my-claude.conf` from the plugin/repo
        root.
      - Compute the missing keys: every uncommented `KEY=` assignment in the template (commented example lines are not keys)
        whose KEY does NOT appear in the user conf as an uncommented
        assignment. A key counts as PRESENT if any uncommented line matches
        the key allowing an optional `export ` prefix and whitespace around
        `=` — e.g. `export K=v`, `K = v`, and `K=v  # note` all count as
        present. A key that appears ONLY in a commented line (`# KEY=v`)
        counts as MISSING. Never compare values; never treat a differing
        value as missing.
      - If there are no missing keys: tell the user their conf is already up
        to date and do not modify the file.
      - If there are missing keys:
        - Show the user the exact lines that would be added — one
          `KEY=<template default value>` per missing key.
        - If the AskUserQuestion tool is available, use it with options
          [Yes, No] to ask: "Your oh-my-claude.conf is missing N new
          option(s): <comma-separated keys>. Add them with safe defaults?
          Your existing values are preserved."
        - If AskUserQuestion is not available, ask in plain chat text.
        - If yes: append to the END of `~/.claude/oh-my-claude.conf`:
          - First ensure the file ends with exactly one newline (if its last
            byte is not a newline, add one).
          - Then append a single header comment line
            `# --- added by /oh-my-status:setup (YYYY-MM-DD) ---` using
            today's date, followed by one `KEY=<template default>` line per
            missing key.
          - Do NOT rewrite, reorder, or reformat any existing line. This is a
            targeted append only — preserve every existing value, comment,
            and line ending byte-for-byte.
          - Confirm to the user exactly which keys were added.
        - If no: leave `~/.claude/oh-my-claude.conf` unchanged, tell the
            user nothing was modified, and continue.

4. After updating (or skipping), tell the user:
   - Restart Claude Code to see the statusline
   - `/oh-my-status:list-themes` to preview themes and layouts
   - `/oh-my-status:set-theme <theme> <layout>` to switch

#!/bin/bash
# oh-my-claude standalone installer (for users not using the plugin system)
# For plugin users: just run /oh-my-claude:setup after installing the plugin
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SETTINGS="$HOME/.claude/settings.json"

echo "Installing oh-my-claude..."

# Copy runtime files
bash "$SCRIPT_DIR/setup.sh"

# Configure statusLine in settings.json
if [ -f "$SETTINGS" ]; then
  if grep -q '"statusLine"' "$SETTINGS"; then
    echo "statusLine already configured in settings.json (preserved)"
  else
    sed -i.bak '$ s/}$/,\n  "statusLine": {\n    "type": "command",\n    "command": "bash ~\/.claude\/oh-my-claude\/statusline.sh",\n    "padding": 1\n  }\n}/' "$SETTINGS"
    rm -f "${SETTINGS}.bak"
    echo "Added statusLine config to settings.json"
  fi
else
  mkdir -p "$HOME/.claude"
  cat > "$SETTINGS" << 'EOF'
{
  "statusLine": {
    "type": "command",
    "command": "bash ~/.claude/oh-my-claude/statusline.sh",
    "padding": 1
  }
}
EOF
  echo "Created settings.json with statusLine config"
fi

echo ""
echo "oh-my-claude installed! Restart Claude Code to see the statusline."
echo ""
echo "Recommended: install as plugin for slash commands:"
echo "  claude --plugin-dir $SCRIPT_DIR"
echo ""
echo "Or preview themes now:"
echo "  bash ~/.claude/oh-my-claude/preview.sh"

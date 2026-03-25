#!/bin/bash
# oh-my-claude setup - copies runtime files to ~/.claude/oh-my-claude/
# Called by plugin hooks or manually
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
OMC_DIR="$HOME/.claude/oh-my-claude"
OMC_CONF="$HOME/.claude/oh-my-claude.conf"

mkdir -p "$OMC_DIR"
cp "$SCRIPT_DIR/statusline.sh" "$OMC_DIR/"
cp -r "$SCRIPT_DIR/themes" "$OMC_DIR/"
cp -r "$SCRIPT_DIR/layouts" "$OMC_DIR/"
cp "$SCRIPT_DIR/preview.sh" "$OMC_DIR/"
cp "$SCRIPT_DIR/generate-preview.sh" "$OMC_DIR/"

# Create config if not exists or is empty
[ -s "$OMC_CONF" ] || cp "$SCRIPT_DIR/oh-my-claude.conf" "$OMC_CONF"

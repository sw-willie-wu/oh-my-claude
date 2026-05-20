#!/bin/bash
# oh-my-claude setup - copies runtime files to ~/.claude/oh-my-claude/
# Called by plugin hooks or manually
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
OMC_DIR="${OMC_DIR:-$HOME/.claude/oh-my-claude}"
OMC_CONF="${OMC_CONF:-$HOME/.claude/oh-my-claude.conf}"
OMC_CONF_TEMPLATE="${OMC_CONF_TEMPLATE:-$SCRIPT_DIR/oh-my-claude.conf}"

mkdir -p "$OMC_DIR"
cp "$SCRIPT_DIR/statusline.sh" "$OMC_DIR/"
cp -r "$SCRIPT_DIR/themes" "$OMC_DIR/"
cp -r "$SCRIPT_DIR/layouts" "$OMC_DIR/"
cp -r "$SCRIPT_DIR/lib" "$OMC_DIR/"
cp "$SCRIPT_DIR/preview.sh" "$OMC_DIR/"
cp "$SCRIPT_DIR/generate-preview.sh" "$OMC_DIR/"

# Create config if not exists or is empty
[ -s "$OMC_CONF" ] || cp "$OMC_CONF_TEMPLATE" "$OMC_CONF"

# --- conf-key detection (read-only; never writes the conf) -----------------
# Surface template keys missing from an existing user conf so Claude can
# suggest /oh-my-claude:setup. Per the Claude Code hooks docs, SessionStart
# stdout (exit 0) is added to Claude's context (not shown to the user) — so
# the notice is phrased as a context note for Claude to relay. Fully
# non-fatal: any failure degrades to "no notice" and the hook still exits 0.
if [ -r "$SCRIPT_DIR/lib/conf-keys.sh" ]; then
  # shellcheck source=lib/conf-keys.sh
  . "$SCRIPT_DIR/lib/conf-keys.sh"
  missing=""
  if [ -s "$OMC_CONF" ] && [ -r "$OMC_CONF_TEMPLATE" ]; then
    missing="$(omc_missing_conf_keys "$OMC_CONF_TEMPLATE" "$OMC_CONF" 2>/dev/null || true)"
  fi
  if [ -n "$missing" ]; then
    n="$(printf '%s\n' "$missing" | awk 'END{print NR}')"
    keys_csv="$(printf '%s' "$missing" | paste -sd, -)"
    printf '%s\n' "[oh-my-claude] Context for the assistant: ${n} new config option(s) (${keys_csv}) exist in the bundled template but are not in the user's ~/.claude/oh-my-claude.conf. At a natural moment, mention to the user once (not repeatedly within this session) that running /oh-my-claude:setup will add the new options with safe defaults while preserving existing values."
  fi
fi

exit 0

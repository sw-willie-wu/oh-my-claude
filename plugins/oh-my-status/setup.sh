#!/bin/bash
# oh-my-claude setup - copies runtime files to ~/.claude/oh-my-claude/
# Called by plugin hooks or manually
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
OMC_DIR="${OMC_DIR:-$HOME/.claude/oh-my-claude}"
OMC_CONF="${OMC_CONF:-$HOME/.claude/oh-my-claude.conf}"
OMC_CONF_TEMPLATE="${OMC_CONF_TEMPLATE:-$SCRIPT_DIR/oh-my-claude.conf}"
OMC_STATE_DIR="${OMC_STATE_DIR:-$HOME/.claude/oh-my-claude/state}"

mkdir -p "$OMC_DIR"
cp "$SCRIPT_DIR/statusline.sh" "$OMC_DIR/"
cp -r "$SCRIPT_DIR/themes" "$OMC_DIR/"
cp -r "$SCRIPT_DIR/layouts" "$OMC_DIR/"
cp "$SCRIPT_DIR/preview.sh" "$OMC_DIR/"
cp "$SCRIPT_DIR/generate-preview.sh" "$OMC_DIR/"

# Create config if not exists or is empty
[ -s "$OMC_CONF" ] || cp "$OMC_CONF_TEMPLATE" "$OMC_CONF"

# --- conf-key detection (read-only; never writes the conf) -----------------
# Surface template keys missing from an existing user conf so Claude can
# suggest /oh-my-status:setup. Per the Claude Code hooks docs, SessionStart
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
    printf '%s\n' "[oh-my-status] Context for the assistant: ${n} new config option(s) (${keys_csv}) exist in the bundled template but are not in the user's ~/.claude/oh-my-claude.conf. At a natural moment, mention to the user once (not repeatedly within this session) that running /oh-my-status:setup will add the new options with safe defaults while preserving existing values."
  fi
fi

# One-time cleanup of 2.x Workers leftovers (named files only; see spec 2.2).
# Nothing here recurses into user-overridable dirs: hooks/ and lib/ are only
# rmdir'd (which fails harmlessly when a user file is still inside). Every
# loop ends in `|| :` because `set -e` would otherwise take a false trailing
# `[ ... ] && ...` for a failure.
old=()
for p in "$OMC_STATE_DIR"/state-*.tsv "$OMC_STATE_DIR"/state-*.tsv.* "$OMC_STATE_DIR/state.lock" \
         "$OMC_STATE_DIR/track-workers.log" "$OMC_DIR/hooks/track-workers.sh" \
         "$OMC_DIR/lib/state-lock.sh" "$OMC_DIR/lib/conf-keys.sh"; do
  [ -e "$p" ] && old+=("$p")        # unmatched glob stays literal -> -e false
done || :
[ ${#old[@]} -eq 0 ] || { rm -rf -- "${old[@]}"; rmdir "$OMC_DIR/hooks" "$OMC_DIR/lib"; } 2>/dev/null || :

# Stale state sweep (moved here from the removed track-workers.sh; runs every
# SessionStart for plugin installs, and on install.sh for standalone ones).
# 24h age policy on the state dir. gitcache-* is the statusline's git-info
# cache (an actively used cache is rewritten on every miss, so only dirs not
# visited in 24h age out); account-* is the account cache. A handoff-<sid>
# marker (which records the usage % of its window) is only removed when
# ctx-<sid> is missing or also older than 24h, i.e. the session is gone; this
# runs before the ctx-* sweep so the check sees the real mtime.
if [ -d "$OMC_STATE_DIR" ]; then
  find "$OMC_STATE_DIR" -maxdepth 1 -name 'gitcache-*' -type f -mmin +1440 -delete 2>/dev/null || :
  find "$OMC_STATE_DIR" -maxdepth 1 -name 'account-*'  -type f -mmin +1440 -delete 2>/dev/null || :
  find "$OMC_STATE_DIR" -maxdepth 1 -name 'handoff-*' -type f -mmin +1440 2>/dev/null | while IFS= read -r hf; do
    hn="${hf##*/}"
    [ -z "$(find "$OMC_STATE_DIR" -maxdepth 1 -name "ctx-${hn#handoff-}" -type f ! -mmin +1440 2>/dev/null)" ] && rm -f "$hf" 2>/dev/null
  done || :
  find "$OMC_STATE_DIR" -maxdepth 1 -name 'ctx-*' -type f -mmin +1440 -delete 2>/dev/null || :
fi

exit 0

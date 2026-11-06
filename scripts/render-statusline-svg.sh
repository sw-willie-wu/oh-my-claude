#!/usr/bin/env bash
# Regenerate assets/statusline-*.svg from a real oh-my-status render.
# Dev tool only; uses a throwaway HOME/OMC_* so ~/.claude is never touched.
set -euo pipefail
REPO=$(cd "$(dirname "$0")/.." && pwd)
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
mkdir -p "$T/home" "$T/state" "$T/projects/demo"
echo '{"oauthAccount":{"displayName":"user"}}' > "$T/home/.claude.json"
(cd "$T/projects/demo" && git init -q -b main && git config user.email a@b && git config user.name a \
  && printf 'a\nb\n' > a.txt && printf x > d.txt && git add . && git commit -qm init \
  && printf 'c\n' >> a.txt && rm d.txt && echo n > new.txt)
NOW=$(date +%s)
PAYLOAD="{\"session_id\":\"demo\",\"model\":{\"display_name\":\"Opus 5.5\"},\"workspace\":{\"current_dir\":\"$T/projects/demo\"},\"context_window\":{\"used_percentage\":42,\"context_window_size\":1000000},\"rate_limits\":{\"five_hour\":{\"used_percentage\":23,\"resets_at\":$((NOW+7200))},\"seven_day\":{\"used_percentage\":86,\"resets_at\":$((NOW+259200))}}}"
WIDTH=800  # common canvas width: widest content (fancy layout, 793 px) rounded up
render() {  # theme layout out bg fg title
  printf 'THEME="%s"\nLAYOUT="%s"\nACCOUNT_SHOW=true\nACCOUNT_FORMAT=name\n' "$1" "$2" > "$T/c.conf"
  (cd "$T/projects/demo" && printf "%s" "$PAYLOAD" | env -u CLAUDE_CONFIG_DIR HOME="$T/home" OMC_ACCOUNT_FILE="$T/home/.claude.json" OMC_CONF="$T/c.conf" OMC_STATE_DIR="$T/state" \
    OMC_DIR="$REPO/plugins/oh-my-status" bash "$REPO/plugins/oh-my-status/statusline.sh" \
    | sed "s#$T/projects/demo#~/projects/demo#" \
    | uv run --no-project python -X utf8 "$REPO/scripts/ansi-to-svg.py" --width "$WIDTH" "$REPO/assets/$3" "$4" "$5" "$6")
}
mkdir -p "$REPO/assets"
render catppuccin default statusline-default.svg '#1e1e2e' '#cdd6f4' 'oh-my-status: catppuccin theme, default layout'
render tokyonight fancy statusline-fancy.svg '#1a1b26' '#c0caf5' 'oh-my-status: tokyonight theme, fancy layout'

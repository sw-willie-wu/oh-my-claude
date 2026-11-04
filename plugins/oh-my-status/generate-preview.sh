#!/bin/bash
# Generate SVG preview images for oh-my-claude themes
# Usage: bash generate-preview.sh [output_dir]

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
OUT_DIR="${1:-/tmp/oh-my-claude-preview}"
mkdir -p "$OUT_DIR"

generate_theme_svg() {
  local theme_file="$1"
  local theme_name=$(basename "$theme_file" .sh)
  local out="$OUT_DIR/${theme_name}.svg"

  # Source theme to get colors
  source "$theme_file"

  # Extract hex from ANSI escape: \033[38;2;R;G;Bm -> #RRGGBB
  to_hex() {
    local esc="$1"
    local r g b
    r=$(echo "$esc" | grep -o '38;2;[0-9]*;[0-9]*;[0-9]*' | cut -d';' -f3)
    g=$(echo "$esc" | grep -o '38;2;[0-9]*;[0-9]*;[0-9]*' | cut -d';' -f4)
    b=$(echo "$esc" | grep -o '38;2;[0-9]*;[0-9]*;[0-9]*' | cut -d';' -f5)
    printf '#%02x%02x%02x' "$r" "$g" "$b"
  }

  local label=$(head -1 "$theme_file" | sed 's/^# *//')
  local hPrimary=$(to_hex "$C_PRIMARY")
  local hSecondary=$(to_hex "$C_SECONDARY")
  local hAccent=$(to_hex "$C_ACCENT")
  local hGreen=$(to_hex "$C_GREEN")
  local hYellow=$(to_hex "$C_YELLOW")
  local hRed=$(to_hex "$C_RED")
  local hText=$(to_hex "$C_TEXT")
  local hSubtext=$(to_hex "$C_SUBTEXT")
  local hSurface=$(to_hex "$C_SURFACE")

  cat > "$out" << SVGEOF
<svg xmlns="http://www.w3.org/2000/svg" width="720" height="160" viewBox="0 0 720 160">
  <rect width="720" height="160" rx="12" fill="#1e1e2e"/>
  <rect x="12" y="12" width="696" height="136" rx="8" fill="${hSurface}"/>

  <!-- Title -->
  <text x="28" y="40" font-family="monospace" font-size="16" font-weight="bold" fill="${hText}">${label}</text>
  <text x="28" y="60" font-family="monospace" font-size="11" fill="${hSubtext}">${theme_name}</text>

  <!-- Color swatches -->
  <circle cx="40"  cy="88" r="14" fill="${hPrimary}"/>
  <circle cx="76"  cy="88" r="14" fill="${hSecondary}"/>
  <circle cx="112" cy="88" r="14" fill="${hAccent}"/>
  <circle cx="148" cy="88" r="14" fill="${hGreen}"/>
  <circle cx="184" cy="88" r="14" fill="${hYellow}"/>
  <circle cx="220" cy="88" r="14" fill="${hRed}"/>
  <circle cx="256" cy="88" r="14" fill="${hText}"/>
  <circle cx="292" cy="88" r="14" fill="${hSubtext}"/>

  <!-- Labels -->
  <text x="28"  y="120" font-family="monospace" font-size="8" fill="${hSubtext}" text-anchor="middle">PRI</text>
  <text x="76"  y="120" font-family="monospace" font-size="8" fill="${hSubtext}" text-anchor="middle">SEC</text>
  <text x="112" y="120" font-family="monospace" font-size="8" fill="${hSubtext}" text-anchor="middle">ACC</text>
  <text x="148" y="120" font-family="monospace" font-size="8" fill="${hSubtext}" text-anchor="middle">GRN</text>
  <text x="184" y="120" font-family="monospace" font-size="8" fill="${hSubtext}" text-anchor="middle">YEL</text>
  <text x="220" y="120" font-family="monospace" font-size="8" fill="${hSubtext}" text-anchor="middle">RED</text>
  <text x="256" y="120" font-family="monospace" font-size="8" fill="${hSubtext}" text-anchor="middle">TXT</text>
  <text x="292" y="120" font-family="monospace" font-size="8" fill="${hSubtext}" text-anchor="middle">SUB</text>

  <!-- Sample statusline -->
  <text x="340" y="78" font-family="monospace" font-size="13" fill="${hPrimary}">Opus 4.6</text>
  <text x="445" y="78" font-family="monospace" font-size="13" fill="${hSecondary}">~/my-app</text>
  <text x="555" y="78" font-family="monospace" font-size="13" fill="${hAccent}">main</text>
  <text x="340" y="100" font-family="monospace" font-size="13" fill="${hGreen}">+3</text>
  <text x="376" y="100" font-family="monospace" font-size="13" fill="${hYellow}">~5</text>
  <text x="410" y="100" font-family="monospace" font-size="13" fill="${hRed}">-1</text>

  <!-- Progress bar sample -->
  <rect x="340" y="112" width="80" height="8" rx="4" fill="${hSurface}"/>
  <rect x="340" y="112" width="34" height="8" rx="4" fill="${hYellow}"/>
  <text x="430" y="120" font-family="monospace" font-size="9" fill="${hSubtext}">42%</text>

  <rect x="470" y="112" width="80" height="8" rx="4" fill="${hSurface}"/>
  <rect x="470" y="112" width="14" height="8" rx="4" fill="${hGreen}"/>
  <text x="560" y="120" font-family="monospace" font-size="9" fill="${hSubtext}">18%</text>

  <rect x="600" y="112" width="80" height="8" rx="4" fill="${hSurface}"/>
  <rect x="600" y="112" width="5"  height="8" rx="4" fill="${hGreen}"/>
  <text x="688" y="120" font-family="monospace" font-size="9" fill="${hSubtext}">6%</text>
</svg>
SVGEOF

  echo "$out"
}

for f in "$SCRIPT_DIR"/themes/*.sh; do
  generate_theme_svg "$f"
done

echo "SVGs generated in $OUT_DIR"

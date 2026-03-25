#!/bin/bash
# oh-my-claude theme/layout preview
# Usage: bash preview.sh [theme|layout|all]

OMC_DIR="${OMC_DIR:-$HOME/.claude/oh-my-claude}"
OMC_CONF="${OMC_CONF:-$HOME/.claude/oh-my-claude.conf}"
RESET='\033[0m'
BOLD='\033[1m'
DIM='\033[2m'

# Current config
CUR_THEME="catppuccin"
CUR_LAYOUT="default"
[ -f "$OMC_CONF" ] && source "$OMC_CONF"
CUR_THEME="${THEME:-$CUR_THEME}"
CUR_LAYOUT="${LAYOUT:-$CUR_LAYOUT}"

# Sample data for demo
DEMO_MODEL="Opus 4.6"
DEMO_DIR="~/projects/my-app"
DEMO_BRANCH="feat/auth"
DEMO_ADD=3 DEMO_MOD=5 DEMO_DEL=1
DEMO_LADD=142 DEMO_LDEL=38
DEMO_CTX=42 DEMO_R5=18 DEMO_R7=6

preview_theme() {
  local theme_file="$1"
  local theme_name=$(basename "$theme_file" .sh)
  source "$theme_file"

  local label=$(head -1 "$theme_file" | sed 's/^# *//')
  local marker=""
  [ "$theme_name" = "$CUR_THEME" ] && marker=" ${DIM}(current)${RESET}"

  echo -e "${BOLD}${label}${RESET}${marker}  ${DIM}[${theme_name}]${RESET}"
  echo -en "  ${C_PRIMARY}Primary${RESET} "
  echo -en "${C_SECONDARY}Secondary${RESET} "
  echo -en "${C_ACCENT}Accent${RESET} "
  echo -en "${C_GREEN}Green${RESET} "
  echo -en "${C_YELLOW}Yellow${RESET} "
  echo -en "${C_RED}Red${RESET} "
  echo -en "${C_TEXT}Text${RESET} "
  echo -e  "${C_SUBTEXT}Subtext${RESET}"
  # Sample statusline
  echo -en "  ${C_PRIMARY}${DEMO_MODEL}${RESET} ${C_SECONDARY}${DEMO_DIR}${RESET}"
  echo -en " | ${C_ACCENT}${DEMO_BRANCH}${RESET}"
  echo -en " ${C_GREEN}+${DEMO_ADD}${RESET} ${C_YELLOW}~${DEMO_MOD}${RESET} ${C_RED}-${DEMO_DEL}${RESET}"
  echo ""
  echo ""
}

preview_layout() {
  local layout_file="$1"
  local layout_name=$(basename "$layout_file" .sh)

  # Source current theme for layout preview
  local theme_file="${OMC_DIR}/themes/${CUR_THEME}.sh"
  [ -f "$theme_file" ] && source "$theme_file"

  source "$layout_file"

  local label=$(head -1 "$layout_file" | sed 's/^# *//')
  local marker=""
  [ "$layout_name" = "$CUR_LAYOUT" ] && marker=" ${DIM}(current)${RESET}"

  echo -e "${BOLD}${label}${RESET}${marker}  ${DIM}[${layout_name}]${RESET}"

  # Set up demo variables for the render function
  MODEL="$DEMO_MODEL"
  DIR="$DEMO_DIR"
  BRANCH="$DEMO_BRANCH"
  ADD_FILES=$DEMO_ADD MOD_FILES=$DEMO_MOD DEL_FILES=$DEMO_DEL
  LINES_ADD=$DEMO_LADD LINES_DEL=$DEMO_LDEL
  CTX_PCT=$DEMO_CTX RATE5_PCT=$DEMO_R5 RATE7_PCT=$DEMO_R7
  RATE5_SUFFIX="" RATE7_SUFFIX=""

  # Indent render output
  render | sed 's/^/  /'
  echo ""
}

MODE="${1:-all}"

case "$MODE" in
  theme|themes)
    echo -e "${BOLD}Available Themes${RESET}  ${DIM}(current: ${CUR_THEME})${RESET}"
    echo ""
    for f in "$OMC_DIR"/themes/*.sh; do
      preview_theme "$f"
    done
    ;;
  layout|layouts)
    echo -e "${BOLD}Available Layouts${RESET}  ${DIM}(current: ${CUR_LAYOUT}, theme: ${CUR_THEME})${RESET}"
    echo ""
    for f in "$OMC_DIR"/layouts/*.sh; do
      preview_layout "$f"
    done
    ;;
  all|*)
    echo -e "${BOLD}Available Themes${RESET}  ${DIM}(current: ${CUR_THEME})${RESET}"
    echo ""
    for f in "$OMC_DIR"/themes/*.sh; do
      preview_theme "$f"
    done
    echo -e "${BOLD}Available Layouts${RESET}  ${DIM}(current: ${CUR_LAYOUT}, theme: ${CUR_THEME})${RESET}"
    echo ""
    for f in "$OMC_DIR"/layouts/*.sh; do
      preview_layout "$f"
    done
    echo -e "${DIM}Switch with:  /set-theme <theme> <layout>${RESET}"
    ;;
esac

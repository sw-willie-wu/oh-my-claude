# Powerline layout - arrow separators with background colors
# Uses powerline arrow character for segment separation

RESET='\033[0m'

# Powerline arrow (requires Nerd Font)
ARROW=$(printf '\xee\x82\xb0')

pct_color() {
  local pct=${1:-0}
  if [ "$pct" -le 30 ]; then echo -n "$C_GREEN"
  elif [ "$pct" -le 80 ]; then echo -n "$C_YELLOW"
  else echo -n "$C_RED"
  fi
}

render() {
  local BRANCH_ICON=$(printf '\xee\x82\xa0')

  # Segment 1: Model
  local LINE="${C_PRIMARY} ${MODEL} ${RESET}"
  LINE+="${C_PRIMARY}${ARROW}${RESET} "

  # Segment 2: Directory
  LINE+="${C_SECONDARY} ${DIR} ${RESET}"
  LINE+="${C_SECONDARY}${ARROW}${RESET} "

  # Segment 3: Git
  if [ -n "$BRANCH" ]; then
    local GIT_SEG="${BRANCH_ICON} ${BRANCH}"
    [ "$ADD_FILES" -gt 0 ] 2>/dev/null && GIT_SEG+=" +${ADD_FILES}"
    [ "$MOD_FILES" -gt 0 ] 2>/dev/null && GIT_SEG+=" ~${MOD_FILES}"
    [ "$DEL_FILES" -gt 0 ] 2>/dev/null && GIT_SEG+=" -${DEL_FILES}"
    LINE+="${C_ACCENT} ${GIT_SEG} ${RESET}"
    LINE+="${C_ACCENT}${ARROW}${RESET} "
  fi

  # Segment 4: Usage stats
  local STATS=""
  STATS+="ctx:${CTX_PCT:-0}%"
  STATS+=" 5h:${RATE5_PCT:-0}%"
  STATS+=" 7d:${RATE7_PCT:-0}%"
  LINE+="$(pct_color "${CTX_PCT:-0}") ${STATS} ${RESET}"

  echo -e "$LINE"
}

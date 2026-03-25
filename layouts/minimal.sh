# Minimal layout - single compact line
# model | dir | branch | ctx% 5h% 7d%

RESET='\033[0m'

pct_color() {
  local pct=${1:-0}
  if [ "$pct" -le 30 ]; then echo -n "$C_GREEN"
  elif [ "$pct" -le 80 ]; then echo -n "$C_YELLOW"
  else echo -n "$C_RED"
  fi
}

render() {
  local LINE="${C_PRIMARY}${MODEL}${RESET}"
  LINE+=" ${C_SUBTEXT}|${RESET} ${C_SECONDARY}${DIR}${RESET}"

  if [ -n "$BRANCH" ]; then
    LINE+=" ${C_SUBTEXT}|${RESET} ${C_ACCENT}${BRANCH}${RESET}"

    local CHANGES=""
    [ "$ADD_FILES" -gt 0 ] 2>/dev/null && CHANGES+="+${ADD_FILES} "
    [ "$MOD_FILES" -gt 0 ] 2>/dev/null && CHANGES+="~${MOD_FILES} "
    [ "$DEL_FILES" -gt 0 ] 2>/dev/null && CHANGES+="-${DEL_FILES}"
    [ -n "$CHANGES" ] && LINE+=" ${C_YELLOW}${CHANGES}${RESET}"
  fi

  LINE+=" ${C_SUBTEXT}|${RESET}"
  LINE+=" $(pct_color "${CTX_PCT:-0}")${CTX_PCT:-0}%${RESET}"
  LINE+=" $(pct_color "${RATE5_PCT:-0}")${RATE5_PCT:-0}%${RESET}"
  LINE+=" $(pct_color "${RATE7_PCT:-0}")${RATE7_PCT:-0}%${RESET}"

  echo -e "$LINE"
}

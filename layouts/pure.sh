# Pure layout - clean text, no icons, no special characters
# Designed for terminals without Nerd Font support

RESET='\033[0m'

pct_indicator() {
  local pct=${1:-0} label=$2
  local color
  if [ "$pct" -le 30 ]; then color="$C_GREEN"
  elif [ "$pct" -le 80 ]; then color="$C_YELLOW"
  else color="$C_RED"
  fi
  printf "${color}%s:%d%%${RESET}" "$label" "$pct"
}

render() {
  local LINE="${C_PRIMARY}${MODEL}${RESET}"
  LINE+="  ${C_SECONDARY}${DIR}${RESET}"

  if [ -n "$BRANCH" ]; then
    LINE+="  ${C_ACCENT}(${BRANCH})${RESET}"

    local CHANGES=""
    [ "$ADD_FILES" -gt 0 ] 2>/dev/null && CHANGES+="${C_GREEN}+${ADD_FILES}${RESET} "
    [ "$MOD_FILES" -gt 0 ] 2>/dev/null && CHANGES+="${C_YELLOW}~${MOD_FILES}${RESET} "
    [ "$DEL_FILES" -gt 0 ] 2>/dev/null && CHANGES+="${C_RED}-${DEL_FILES}${RESET}"
    [ -n "$CHANGES" ] && LINE+=" ${CHANGES}"
  fi

  LINE+="  $(pct_indicator "${CTX_PCT:-0}" ctx)"
  LINE+="  $(pct_indicator "${RATE5_PCT:-0}" 5h)"
  LINE+="  $(pct_indicator "${RATE7_PCT:-0}" 7d)"

  echo -e "$LINE"
}

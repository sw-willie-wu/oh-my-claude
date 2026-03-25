# MyGO!!!!! layout - band-inspired with musical separators
# Line 1: ★ model ♪ dir │ branch file-stats │ line-stats
# Line 2: usage bars with ♩ fill characters
# Each segment colored after a MyGO!!!!! member

RESET='\033[0m'

bar() {
  local pct=${1:-0} width=${2:-12}
  local filled=$(( pct * width / 100 ))
  [ "$filled" -gt "$width" ] && filled=$width
  local empty=$(( width - filled ))
  local color
  if [ "$pct" -le 30 ]; then color="$C_GREEN"
  elif [ "$pct" -le 80 ]; then color="$C_YELLOW"
  else color="$C_RED"
  fi
  local bar_str=""
  for ((i=0; i<filled; i++)); do bar_str+="♩"; done
  for ((i=0; i<empty; i++)); do bar_str+="·"; done
  printf "${color}%s${RESET} %d%%" "$bar_str" "$pct"
}

render() {
  local STAR="★"
  local NOTE="♪"
  local BRANCH_ICON=$(printf '\xee\x82\xa0')

  # Line 1: ★ model ♪ dir | branch stats
  local LINE1="${C_PRIMARY}${STAR} ${MODEL}${RESET} ${C_SUBTEXT}${NOTE}${RESET} ${C_SECONDARY}${DIR}${RESET}"

  if [ -n "$BRANCH" ]; then
    LINE1+=" ${C_SUBTEXT}│${RESET} ${C_ACCENT}${BRANCH_ICON} ${BRANCH}${RESET}"

    local FILE_STATS=""
    [ "$ADD_FILES" -gt 0 ] 2>/dev/null && FILE_STATS+=" ${C_GREEN}+${ADD_FILES}${RESET}"
    [ "$MOD_FILES" -gt 0 ] 2>/dev/null && FILE_STATS+=" ${C_YELLOW}~${MOD_FILES}${RESET}"
    [ "$DEL_FILES" -gt 0 ] 2>/dev/null && FILE_STATS+=" ${C_RED}-${DEL_FILES}${RESET}"
    [ -n "$FILE_STATS" ] && LINE1+="${FILE_STATS}"

    local LINE_STATS=""
    [ "$LINES_ADD" -gt 0 ] 2>/dev/null && LINE_STATS+="${C_GREEN}+${LINES_ADD}${RESET}"
    [ "$LINES_DEL" -gt 0 ] 2>/dev/null && LINE_STATS+=" ${C_RED}-${LINES_DEL}${RESET}"
    [ -n "$LINE_STATS" ] && LINE1+=" ${C_SUBTEXT}│${RESET} ${LINE_STATS}"
  fi

  # Line 2: musical usage bars with individual colors
  local LINE2="${C_SUBTEXT}ctx${RESET} $(bar "${CTX_PCT:-0}" 12)"
  LINE2+="  ${C_SUBTEXT}5h${RESET} $(bar "${RATE5_PCT:-0}" 12)${RATE5_SUFFIX}"
  LINE2+="  ${C_SUBTEXT}7d${RESET} $(bar "${RATE7_PCT:-0}" 12)${RATE7_SUFFIX}"

  echo -e "$LINE1"
  echo -e "$LINE2"
}

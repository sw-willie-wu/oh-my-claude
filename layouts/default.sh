# Default layout - two lines with icons and progress bars
# Line 1: model @ dir | branch +A ~M -D | +lines -lines
# Line 2: [ctx bar] [5h bar] [7d bar]

RESET='\033[0m'

bar() {
  local pct=${1:-0} width=${2:-15}
  local filled=$(( pct * width / 100 ))
  [ "$filled" -gt "$width" ] && filled=$width
  local empty=$(( width - filled ))
  local color
  if [ "$pct" -le 30 ]; then color="$C_GREEN"
  elif [ "$pct" -le 80 ]; then color="$C_YELLOW"
  else color="$C_RED"
  fi
  local bar_str=""
  for ((i=0; i<filled; i++)); do bar_str+="█"; done
  for ((i=0; i<empty; i++)); do bar_str+="░"; done
  printf "${color}${bar_str}${RESET} %d%%" "$pct"
}

render() {
  local FOLDER_ICON=$(printf '\xef\x81\xbb')
  local BRANCH_ICON=$(printf '\xee\x82\xa0')

  local LINE1="${C_PRIMARY}${MODEL}${RESET} ${C_SECONDARY}${FOLDER_ICON} ${DIR}${RESET}"

  if [ -n "$BRANCH" ]; then
    LINE1="${LINE1} | ${C_ACCENT}${BRANCH_ICON} ${BRANCH}${RESET}"

    local GIT_INFO=""
    [ "$ADD_FILES" -gt 0 ] 2>/dev/null && GIT_INFO+="${C_GREEN}+${ADD_FILES}${RESET} "
    [ "$MOD_FILES" -gt 0 ] 2>/dev/null && GIT_INFO+="${C_YELLOW}~${MOD_FILES}${RESET} "
    [ "$DEL_FILES" -gt 0 ] 2>/dev/null && GIT_INFO+="${C_RED}-${DEL_FILES}${RESET} "
    [ -n "$GIT_INFO" ] && LINE1="${LINE1} ${GIT_INFO}"

    local LINE_INFO=""
    [ "$LINES_ADD" -gt 0 ] 2>/dev/null && LINE_INFO+="${C_GREEN}+${LINES_ADD}${RESET} "
    [ "$LINES_DEL" -gt 0 ] 2>/dev/null && LINE_INFO+="${C_RED}-${LINES_DEL}${RESET}"
    [ -n "$LINE_INFO" ] && LINE1="${LINE1}| ${LINE_INFO}"
  fi

  local LINE2="$(bar "${CTX_PCT:-0}" 15)  $(bar "${RATE5_PCT:-0}" 15)${RATE5_SUFFIX}  $(bar "${RATE7_PCT:-0}" 15)${RATE7_SUFFIX}"

  echo -e "$LINE1"
  echo -e "$LINE2"
}

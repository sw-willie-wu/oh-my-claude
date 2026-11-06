# Fancy layout - model header, then git, then usage meters
# Line 1: model and directory (always first)
# Line 2: git details with line stats (only if in repo)
# Line 3: usage meters with labels (ctx + 5h + 7d)

RESET='\033[0m'

meter() {
  local pct=${1:-0} label=$2 width=${3:-12}
  local filled=$(( pct * width / 100 ))
  [ "$filled" -gt "$width" ] && filled=$width
  local empty=$(( width - filled ))
  local color i
  if [ "$pct" -le 30 ]; then color="$C_GREEN"
  elif [ "$pct" -le 80 ]; then color="$C_YELLOW"
  else color="$C_RED"
  fi
  local bar_str=""
  for ((i=0; i<filled; i++)); do bar_str+="━"; done
  for ((i=0; i<empty; i++)); do bar_str+="╌"; done
  printf -v REPLY "${C_SUBTEXT}%s ${color}%s${RESET} %d%%" "$label" "$bar_str" "$pct"
}

render() {
  local FOLDER_ICON=$'\xef\x81\xbb'
  local BRANCH_ICON=$'\xee\x82\xa0'
  local DOT="·"

  # Line 1: model + dir
  local LINE1="${C_PRIMARY}${MODEL}${RESET}"
  [ -n "$ACCOUNT" ] && LINE1+=" ${C_SUBTEXT}${DOT}${RESET} ${C_SUBTEXT}${ACCOUNT_ICON:+$ACCOUNT_ICON }${ACCOUNT}${RESET}"
  LINE1+=" ${C_SUBTEXT}${DOT}${RESET} ${C_SECONDARY}${FOLDER_ICON} ${DIR}${RESET}"

  # Line 2: git info (only if in repo)
  local LINE2=""
  if [ -n "$BRANCH" ]; then
    LINE2="${C_ACCENT}${BRANCH_ICON} ${BRANCH}${RESET}"

    local FILE_STATS=""
    [ "$ADD_FILES" -gt 0 ] 2>/dev/null && FILE_STATS+=" ${C_GREEN}+${ADD_FILES} new${RESET}"
    [ "$MOD_FILES" -gt 0 ] 2>/dev/null && FILE_STATS+=" ${C_YELLOW}~${MOD_FILES} mod${RESET}"
    [ "$DEL_FILES" -gt 0 ] 2>/dev/null && FILE_STATS+=" ${C_RED}-${DEL_FILES} del${RESET}"
    [ -n "$FILE_STATS" ] && LINE2+=" ${C_SUBTEXT}│${RESET}${FILE_STATS}"

    local LINE_STATS=""
    [ "$LINES_ADD" -gt 0 ] 2>/dev/null && LINE_STATS+="${C_GREEN}+${LINES_ADD}${RESET}"
    [ "$LINES_DEL" -gt 0 ] 2>/dev/null && LINE_STATS+=" ${C_RED}-${LINES_DEL}${RESET}"
    [ -n "$LINE_STATS" ] && LINE2+=" ${C_SUBTEXT}│${RESET} ${LINE_STATS} ${C_SUBTEXT}lines${RESET}"
  fi

  # Line 3: usage meters
  meter "${CTX_PCT:-0}" "ctx" 12; local LINE3=$REPLY
  if [ -n "${RATE5_PCT:-}" ]; then meter "$RATE5_PCT" " 5h" 12; LINE3+="  ${REPLY}${RATE5_SUFFIX}"; fi
  if [ -n "${RATE7_PCT:-}" ]; then meter "$RATE7_PCT" " 7d" 12; LINE3+="  ${REPLY}${RATE7_SUFFIX}"; fi

  echo -e "$LINE1"
  [ -n "$LINE2" ] && echo -e "$LINE2"
  echo -e "$LINE3"
}

# check-move.awk -- see scripts/check-move.sh. Run as: LC_ALL=C gawk -v sizes=1|0 -f md-spans.awk -f check-move.awk <original> <target>...
# Exit status of the program: 0 ok | 1 missing items | 3 only "small".
function trim(s) { sub(/^[ \t]+/, "", s); sub(/[ \t]+$/, "", s); return s }

FNR == 1 { infm = 0; bom = sprintf("%c%c%c", 239, 187, 191) }
{
  line = $0; sub(/\r$/, "", line)
  if (FNR == 1) {
    if (substr(line, 1, 3) == bom) line = substr(line, 4)
    if (line == "---") { infm = 1; next }
  }
  if (infm) { if (line == "---") infm = 0; next }
  if (ARGIND == 1) {
    obytes += length(line) + 1
    if (match(line, /^[ \t]*(`{3,}|~{3,})/, fmk)) {
      frun = fmk[1]
      if (infence == "") { infence = substr(frun, 1, 1); fenlen = length(frun); next }
      if (substr(frun, 1, 1) == infence && length(frun) >= fenlen && substr(line, RSTART + RLENGTH) ~ /^[ \t]*$/) { infence = ""; next }
    }
    if (infence != "") {
      if (index(line, "[[")) { ni++; ityp[ni] = "F"; itxt[ni] = trim(line); iln[ni] = FNR }
    } else {
      m = spans(line, sp)
      for (j = 1; j <= m; j++) if (index(sp[j], "[[")) { ni++; ityp[ni] = "S"; itxt[ni] = sp[j]; iln[ni] = FNR }
    }
  } else {
    tbody = tbody line "\n"; tl[trim(line)] = 1; tbytes += length(line) + 1
  }
}
ENDFILE {
  if (infm) { print "check-move.sh: unterminated frontmatter (no closing ---): " FILENAME > "/dev/stderr"; unterm = 1 }
}
END {
  if (unterm) exit 2
  if (obytes == 0) exit 0
  for (i = 1; i <= ni; i++) {
    if (ityp[i] == "S" ? index(tbody, itxt[i]) : (itxt[i] in tl)) continue
    print "missing " iln[i] ": " itxt[i]; bad = 1
  }
  if (sizes && tbytes * 2 < obytes) { print "small: " tbytes "/" obytes; small = 1 }
  exit (bad ? 1 : small ? 3 : 0)
}

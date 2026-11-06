# md-spans.awk -- inline code spans of one line (gawk; used by check-move.awk).
# spans(s, arr): fills arr[1..n] with every inline code span of s, delimiters included, and returns n.
# Run rule (same as nocode in lint-content.awk): a run of N backticks closes at the next run of exactly N
# backticks; an unmatched run is literal text.
function spans(s, arr,   n, st, rest, t, off, k, cnt) {
  cnt = 0; delete arr
  while (match(s, /`+/)) {
    st = RSTART; n = RLENGTH; rest = substr(s, st + n)
    t = rest; off = 0; k = 0
    while (match(t, /`+/)) {
      if (RLENGTH == n) { k = off + RSTART; break }
      off += RSTART + RLENGTH - 1; t = substr(t, RSTART + RLENGTH)
    }
    if (k) { arr[++cnt] = substr(s, st, n) substr(rest, 1, k - 1) substr(rest, k, n); s = substr(rest, k + n) }
    else s = rest
  }
  return cnt
}

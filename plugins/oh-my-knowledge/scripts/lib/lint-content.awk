# lint-content.awk -- content and reference lint for an oh-my-knowledge KB (gawk, UTF-8 locale).
# One pass over: KB pages (tag K), auto-memory *.md (tag A), the CLAUDE.md file (tag C).
# Input (stdin, NUL separated): <tag> <path> pairs. Tag D carries a project directory name
# (<kb>/projects/<name> exists as a directory) instead of a file. Tags K/A/C are read as files.
# Env: OMK_LINT_ROOT (KB root, no trailing slash), OMK_TODAY, OMK_LINT_STALE_DAYS, OMK_LINT_FLAG_DAYS,
#      OMK_LINT_QFILE (output: candidate ~/ paths for the shell to test, "file<TAB>line<TAB>path").
# Output (TAB separated, sorted): F<TAB>check<TAB>severity<TAB>file<TAB>line<TAB>detail
# KB findings use KB-relative paths; auto-memory / CLAUDE.md findings use the absolute path as given.
# The project marker regex and its status rules are the same as omk_project_marker_status
# (lib/project.sh); tests compare the two.

function trim(s) { sub(/^[ \t]+/, "", s); sub(/[ \t]+$/, "", s); return s }
# nocode: drop inline code spans (a run of N backticks up to the next run of exactly N); an unmatched run stays.
function nocode(s,   o, n, st, rest, t, off, k) {
  o = ""
  while (match(s, /`+/)) {
    st = RSTART; n = RLENGTH
    o = o substr(s, 1, st - 1); rest = substr(s, st + n)
    t = rest; off = 0; k = 0
    while (match(t, /`+/)) {
      if (RLENGTH == n) { k = off + RSTART; break }
      off += RSTART + RLENGTH - 1; t = substr(t, RSTART + RLENGTH)
    }
    if (k) s = substr(rest, k + n)
    else { o = o substr(s, st, n); s = rest }
  }
  return o s
}
# stripped(s): content of the first 2-backtick span with no backtick, no [[ and no edge space ("" if none)
function stripped(s,   n, st, rest, t, off, k, c) {
  while (match(s, /`+/)) {
    st = RSTART; n = RLENGTH; rest = substr(s, st + n)
    t = rest; off = 0; k = 0
    while (match(t, /`+/)) {
      if (RLENGTH == n) { k = off + RSTART; break }
      off += RSTART + RLENGTH - 1; t = substr(t, RSTART + RLENGTH)
    }
    if (!k) { s = rest; continue }
    c = substr(rest, 1, k - 1)
    if (n == 2 && c != "" && c !~ /`/ && !index(c, "[[") && c !~ /^ | $/) return c
    s = substr(rest, k + n)
  }
  return ""
}
# unclosed(s): 1 when some [[ in s has no ]] after it
function unclosed(s,   p) {
  while ((p = index(s, "[["))) { s = substr(s, p + 2); if (!(p = index(s, "]]"))) return 1; s = substr(s, p + 2) }
  return 0
}
function unq(s) {
  s = trim(s)
  if (s ~ /^".*"$/ || s ~ /^\x27.*\x27$/) s = substr(s, 2, length(s) - 2)
  return s
}
function lc(s) { return icase ? tolower(s) : s }   # Windows file names/dirs compare case-insensitively
function vclean(s) { sub(/[ \t]+#.*$/, "", s); return s }   # drop a trailing YAML comment
function add(check, sev, file, line, detail) {
  gsub(/[\t\r\n]/, " ", detail)
  # Windows (Git Bash): show absolute auto-memory/CLAUDE.md paths as C:/... (matches omk_native_path)
  if (winfmt && file ~ /^\/[a-z]\//) file = toupper(substr(file, 2, 1)) ":" substr(file, 3)
  nf++
  out[sprintf("%s\t%09d\t%s\t%06d", file, line, check, nf)] = "F\t" check "\t" sev "\t" file "\t" line "\t" detail
}
function nocomment(s,   o, a, b) {
  o = ""
  while (1) {
    if (incm) { b = index(s, "-->"); if (!b) return o; s = substr(s, b + 3); incm = 0 }
    else { a = index(s, "<!--"); if (!a) return o s; o = o substr(s, 1, a - 1); s = substr(s, a + 4); incm = 1 }
  }
}
function dirname(p) { return (p ~ /\//) ? gensub(/\/[^\/]*$/, "", 1, p) : "" }
# day number of YYYY-MM-DD, -1 when not a date
function daynum(s,   a, t) {
  if (s !~ /^[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]$/) return -1
  split(s, a, "-")
  t = mktime(a[1] " " a[2] " " a[3] " 12 00 00")
  if (t < 0) return -1
  if (strftime("%Y-%m-%d", t) != s) return -1   # round trip rejects 2026-13-45, 2026-02-30
  return int(t / 86400 + 0.5)
}
# resolve link target <t> written in KB folder <dir>; rel path of an existing KB page or ""
function resolve(dir, t,   p) {
  if (t ~ /^g:/) p = "global/" substr(t, 3) ".md"
  else if (t ~ /^k:/) p = substr(t, 3) ".md"
  else {
    p = (dir == "" ? "" : dir "/") t ".md"
    if (!(p in exist)) p = "global/" t ".md"
  }
  return (p in exist) ? p : ""
}
# collect <p> of every [[k:projects/<p>/...]] in <s> into arr
function projlinks(s, arr,   rest, p) {
  rest = s
  while (match(rest, /\[\[k:projects\/[^\/\]|#]+\//)) {
    p = substr(rest, RSTART + 13, RLENGTH - 14)
    rest = substr(rest, RSTART + RLENGTH)
    if (p != "" && p != "." && p != "..") arr[p] = 1
  }
}
function joined(set,   k, n, a, i, r) {
  n = 0
  for (k in set) a[++n] = k
  asort(a)
  r = ""
  for (i = 1; i <= n; i++) r = r (i > 1 ? ", " : "") a[i]
  return r
}

BEGIN {
  RS = "\0"
  root = ENVIRON["OMK_LINT_ROOT"]; rl = length(root)
  today = daynum(ENVIRON["OMK_TODAY"])
  staled = ENVIRON["OMK_LINT_STALE_DAYS"] + 0
  flagd = ENVIRON["OMK_LINT_FLAG_DAYS"] + 0
  qfile = ENVIRON["OMK_LINT_QFILE"]
  winfmt = (ENVIRON["OMK_LINT_WINPATHS"] == "1")
  icase = (ENVIRON["OMK_LINT_ICASE"] == "1")
  bom = sprintf("%c", 65279)
  uvre = "^> ⚠(" sprintf("%c", 65039) ")? UNVERIFIED\\y( \\(([^)]*)\\))?"
  progre = "待 ?merge|未排|下一步(\\*\\*)?(:|：)|\\yin progress\\y|\\ynext steps?:|\\ypending merge\\y"
  # version: v1.2 | 1.2.3 (three parts; a.b.c.d is not) | latest/current/as of (whole words) | 目前 | 最新
  verre = "\\yv[0-9]+\\.[0-9]+|(^|[^0-9.])[0-9]+\\.[0-9]+\\.[0-9]+(\\.([^0-9]|$)|[^0-9.]|$)|\\y(latest|current|as of)\\y|目前|最新"
  movedre = "^> Moved: \\[\\[[^]]+\\]\\](, *\\[\\[[^]]+\\]\\])* *$"
  while ((getline tag < "-") > 0) {
    if ((getline pth < "-") <= 0) break
    if (tag == "D") { projdir[icase ? tolower(pth) : pth] = 1; continue }
    ftag[pth] = tag
    ARGV[ARGC++] = pth
  }
  if (ARGC == 1) ARGV[ARGC++] = "/dev/null"
  RS = "\n"
}

BEGINFILE {
  skipf = 1
  if (FILENAME == "/dev/null") nextfile
  if (ERRNO != "") { print "lint-content: cannot read " FILENAME ": " ERRNO > "/dev/stderr"; bad = 1; nextfile }
  tag = ftag[FILENAME]
  ismem = 0
  refonly = 0
  if (tag == "X") { exist[substr(FILENAME, rl + 2)] = 1; nextfile }   # _retired/ lint/: existence only
  if (tag == "K") {
    id = substr(FILENAME, rl + 2)
    exist[id] = 1
    refonly = (id == "inbox.md" || id == "log.md")   # only their links count as references
    if (id !~ /^(rules|global|projects)\// && id != "index.md" && !refonly) nextfile
    kdir = dirname(id)
    kproj = ""
    if (id ~ /^projects\/[^\/]+\//) { kproj = id; sub(/^projects\//, "", kproj); sub(/\/.*/, "", kproj) }
    base = id; sub(/.*\//, "", base)
    kidx = (base ~ /^index(_.*)?[.]md$/)
    if (!refonly) kfiles[++nkf] = id
  } else {
    id = FILENAME
    if (tag == "A") {
      adir = id; sub(/\/[^\/]*$/, "", adir)
      afile[icase ? tolower(id) : id] = 1; adirs[adir] = 1
      base = id; sub(/.*\//, "", base)
      ismem = (base == "MEMORY.md")
    }
  }
  skipf = 0
  ln = 0; fm = 0; hasfm = 0; fmclose = 0; body = 0; moved = 0; infence = ""; incm = 0; cur = ""
  fname = ""; ftype = ""; mtype = ""; fver = ""; fnp = ""; stl = 0; vm = 0
  delete movp
}

{
  ln++
  line = $0; sub(/\r$/, "", line)
  if (ln == 1 && substr(line, 1, 1) == bom) line = substr(line, 2)
  # project marker: whole line, anywhere in MEMORY.md (same regex as omk_project_marker_status)
  if (ismem && match(line, /^- Knowledge base project: \[\[k:projects\/([^\/\]]+)\/index\]\] \(omk-project\)$/, mk)) {
    p = mk[1]
    if (!((adir SUBSEP p) in mseen)) {
      mseen[adir SUBSEP p] = 1; mcount[adir]++
      if (mcount[adir] == 1) mfirst[adir] = p
      mnames[adir] = mnames[adir] (mcount[adir] > 1 ? ", " : "") p
    }
    if (!(adir in mline)) mline[adir] = ln
    ismark = 1
  } else ismark = 0
  if (ln == 1 && line == "---") { fm = 1; hasfm = 1; next }
  if (fm) {
    if (line == "---") {
      fm = 0; fmclose = 1
      if (tag == "K" && !refonly && fver != "" && today >= 0) {
        dv = daynum(fver)
        if (dv < 0) { stl = 1; stlage = -1 }                      # unparsable date: treated as old
        else if (today - dv > staled) { stl = 1; stlage = today - dv }
      }
      next
    }
    if (match(line, /^([A-Za-z_][A-Za-z0-9_-]*):[ \t]*(.*)$/, m)) {
      cur = m[1]; v = unq(vclean(m[2]))
      if (cur == "type") ftype = v
      else if (cur == "verified") fver = v
      else if (cur == "no_promote") fnp = v
    } else if (cur == "metadata" && match(line, /^[ \t]+([A-Za-z_]+):[ \t]*(.*)$/, m)) {
      v = unq(vclean(m[2]))
      if (m[1] == "type") mtype = v
      else if (m[1] == "verified") fver = v
      else if (m[1] == "no_promote") fnp = v
    }
    next
  }
  if (line !~ /^[ \t]*$/) {
    body++
    if (line ~ movedre) { moved++; projlinks(line, movp) }
  }
  if (stl && !vm && match(tolower(line), verre, vmm)) { vm = 1; vmline = ln; vmtext = vmm[0]; gsub(/^[][ \t.,;:()"\x27!?\/-]+|[][ \t.,;:()"\x27!?\/-]+$/, "", vmtext) }
  if (ismem && index(line, "(omk-harvested)")) { delete hp; projlinks(line, hp); for (p in hp) harvp[adir SUBSEP p] = 1 }
  # fences: closes only with the same character, at least as long, and nothing after it
  if (match(line, /^[ \t]*(`{3,}|~{3,})/, fmk)) {
    frun = fmk[1]
    if (infence == "") { infence = substr(frun, 1, 1); fenlen = length(frun); next }
    if (substr(frun, 1, 1) == infence && length(frun) >= fenlen && substr(line, RSTART + RLENGTH) ~ /^[ \t]*$/) { infence = ""; next }
  }
  if (infence != "") next
  c0 = nocomment(line)
  if (tag == "K" && !refonly) {
    # projects/<p>/always-on.md holds directives that may mention work words
    if (c0 !~ /^ {0,3}#+([ \t]|$)/ && id !~ /^projects\/[^\/]+\/always-on\.md$/) {
      s = c0
      gsub(/https?:\/\/[^ \t)>\]"\x27]*/, "", s)
      if (match(tolower(s), progre, pm)) add("progress_leak", "yellow", id, ln, "'" pm[0] "' outside code/headings")
    }
    if (match(c0, uvre, um)) {
      uv = daynum(um[3])
      if (today >= 0) {
        if (um[2] == "") add("unverified_overdue", "yellow", id, ln, "UNVERIFIED flag has no date (treated as overdue)")
        else if (uv < 0) add("unverified_overdue", "yellow", id, ln, "UNVERIFIED flag date '" um[3] "' is not a valid YYYY-MM-DD date (treated as overdue)")
        else if (today - uv > flagd) add("unverified_overdue", "yellow", id, ln, "UNVERIFIED flag from " um[3] " is " (today - uv) " days old (limit " flagd ")")
      }
    }
    sc = stripped(c0)
    if (sc != "") add("suspect_link_rewrite", "yellow", id, ln, "``" sc "`` looks like `[[" sc "]]` with its brackets stripped")
    if (unclosed(nocode(c0))) add("suspect_link_rewrite", "yellow", id, ln, "unclosed [[ outside code (truncated by a link rewrite, or a literal [[ that belongs in backticks)")
    rest = c0
    while (match(rest, /`~\/[^`]*`/)) {
      p = substr(rest, RSTART + 1, RLENGTH - 2)
      rest = substr(rest, RSTART + RLENGTH)
      if (p ~ /[ \t<*{$]/ || index(p, "YYYY") || p == "~/") continue
      print id "\t" ln "\t" p > qfile
    }
  }
  c = c0
  c = nocode(c)
  if (ismark) c = ""   # the marker line is judged by project_marker_*; not also an external link
  rest = c
  while (match(rest, /\[\[[^]]+\]\]/)) {
    t = substr(rest, RSTART + 2, RLENGTH - 4)
    rest = substr(rest, RSTART + RLENGTH)
    sub(/[|#].*$/, "", t); t = trim(t)
    if (t == "" || t == "g:" || t == "k:") continue
    nl++; lsrc[nl] = id; ltag[nl] = tag; lln[nl] = ln; ltgt[nl] = t
  }
  if (tag == "A") {
    rest = c
    while (match(rest, /\([^() \t]+\.md(#[^() \t]*)?\)/)) {
      t = substr(rest, RSTART + 1, RLENGTH - 2)
      rest = substr(rest, RSTART + RLENGTH)
      sub(/#.*$/, "", t)
      if (t ~ /^[A-Za-z][A-Za-z0-9+.-]*:/ || t ~ /^[\/~]/ || t ~ /\//) continue
      nl++; lsrc[nl] = id; ltag[nl] = tag; lln[nl] = ln; ltgt[nl] = t; lmd[nl] = 1
    }
  }
}

ENDFILE {
  if (!skipf) {
    isstub = (body > 0 && moved == body)
    pstub[id] = isstub
    if (tag == "K") {
      pidx[id] = kidx; pproj[id] = kproj; pnp[id] = fnp
      if (stl && vm) add("stale", "blue", id, vmline, "verified " fver (stlage < 0 ? " (not a valid date, treated as old)" : " (" stlage " days ago, limit " staled ")") "; body mentions '" vmtext "'")
    } else if (tag == "A") {
      if (isstub) { for (p in movp) harvp[adir SUBSEP p] = 1 }
      else {
        ty = (mtype != "" ? mtype : ftype)
        if (ty == "feedback" || ty == "reference" || ty == "user") ucount[adir]++
      }
    }
  }
}

END {
  if (bad) exit 1
  # ---- references: inbound counts, external link checks, promote candidates, auto-memory link checks
  for (i = 1; i <= nl; i++) {
    src = lsrc[i]; t = ltgt[i]; tg = ltag[i]
    if (lmd[i]) {
      d = src; sub(/\/[^\/]*$/, "", d)
      if (!(lc(d "/" t) in afile)) add("auto_memory_link_broken", "yellow", src, lln[i], "(" t ") does not exist in this memory directory")
      continue
    }
    if (tg == "K") {
      r = resolve(dirname(src), t)
      if (r == "" || r == src) continue
      inb[r] = 1
      if (t ~ /^k:projects\// && pproj[src] != "" && !pstub[src]) {
        a = substr(t, 3); sub(/^projects\//, "", a)
        if (a ~ /\//) {
          sub(/\/.*/, "", a)
          if (a != pproj[src] && !pstub[r] && !pidx[r] && index(r, "projects/" a "/") == 1) prom[r] = prom[r] SUBSEP pproj[src]
        }
      }
      continue
    }
    # tag A or C: external reference into the KB
    if (t ~ /^[gk]:/) {
      r = resolve("", t)
      if (r == "") add("ext_link_missing", "red", src, lln[i], "[[" t "]] does not exist in the knowledge base")
      else inb[r] = 1
    } else {
      if (t !~ /:/ && ("global/" t ".md") in exist) inb["global/" t ".md"] = 1
      if (tg == "A" && t !~ /:/) {
        d = src; sub(/\/[^\/]*$/, "", d)
        if (!(lc(d "/" t ".md") in afile) && !(t ~ /\.md$/ && lc(d "/" t) in afile))
          add("auto_memory_link_broken", "yellow", src, lln[i], "[[" t "]] does not exist in this memory directory")
      }
    }
  }
  for (i = 1; i <= nkf; i++) {
    f = kfiles[i]
    if (pstub[f] && !(f in inb)) add("stub_unreferenced", "blue", f, 0, "stub has no inbound reference from the knowledge base, auto memory or CLAUDE.md")
  }
  for (r in prom) {
    n = split(prom[r], pa, SUBSEP); delete ps
    for (j = 2; j <= n; j++) ps[pa[j]] = 1
    np0 = pnp[r]; delete nps; s = np0; gsub(/[]["\x27]/, " ", s)
    m2 = split(s, na, /[ \t,]+/); for (j = 1; j <= m2; j++) if (na[j] != "") nps[na[j]] = 1
    cov = (length(nps) > 0); for (p in ps) if (!(p in nps)) { cov = 0; break }
    if (cov) continue
    add("promote_candidate", "blue", r, 0, "linked from project(s): " joined(ps) (np0 != "" ? " (no_promote: " np0 ")" : ""))
  }
  # ---- per auto-memory directory
  for (d in adirs) {
    n = mcount[d] + 0
    if (n == 0) st = "none"
    else if (n > 1) st = "invalid multiple"
    else if (mfirst[d] == "." || mfirst[d] == ".." || !(lc(mfirst[d]) in projdir)) st = "invalid missing " mfirst[d]
    else st = "ok " mfirst[d]
    if (st == "invalid multiple") add("project_marker_invalid", "yellow", d "/MEMORY.md", mline[d], "names more than one project: " mnames[d])
    else if (st ~ /^invalid missing /) add("project_marker_invalid", "yellow", d "/MEMORY.md", mline[d], "projects/" mfirst[d] "/ does not exist in the knowledge base")
    else if (st ~ /^ok / && mline[d] > 200) add("project_marker_misplaced", "blue", d "/MEMORY.md", mline[d], "project marker is beyond line 200 (not auto-loaded)")
    if (st !~ /^ok /) {
      delete ps; np = 0
      for (k in harvp) { split(k, ka, SUBSEP); if (ka[1] == d) { ps[ka[2]] = 1; np++ } }
      if (np > 0) add("project_marker_missing", "yellow", d, 0, joined(ps))
    }
    if (ucount[d] > 0) {
      if (st ~ /^ok /) add("unharvested_auto_memory", "blue", d, 0, "to harvest: " ucount[d] " new entries")
      else add("unharvested_auto_memory", "blue", d, 0, "not migrated: " ucount[d] " knowledge entries")
    }
  }
  PROCINFO["sorted_in"] = "@ind_str_asc"
  for (k in out) print out[k]
}

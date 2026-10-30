# lint-structure.awk -- structural lint for an oh-my-knowledge KB (gawk, UTF-8 locale).
# Input (stdin, NUL separated): <size-bytes> <path> pairs, one per file found by lint.sh.
# Env: OMK_LINT_ROOT (KB root, no trailing slash), OMK_MAX_FILE_KB, OMK_MAX_INDEX_LINE_CHARS.
# Output (TAB separated, sorted): F<TAB>check<TAB>severity<TAB>file<TAB>line<TAB>detail
#                                 G<TAB>group name<TAB>page...
# Pluggable: each check is one block in ENDFILE or END; content checks live in a
# separate awk file and emit the same F lines.

function trim(s) { sub(/^[ \t]+/, "", s); sub(/[ \t]+$/, "", s); return s }
function unq(s) {
  s = trim(s)
  if (s ~ /^".*"$/ || s ~ /^\x27.*\x27$/) s = substr(s, 2, length(s) - 2)
  return s
}
function add(check, sev, file, line, detail) {
  gsub(/[\t\r\n]/, " ", detail)
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
# normalise a relative path ("./", "../" segments); "" when it climbs out
function norm(p,   n, a, i, k, r) {
  n = split(p, a, "/"); k = 0
  for (i = 1; i <= n; i++) {
    if (a[i] == "" || a[i] == ".") continue
    if (a[i] == "..") { if (k == 0) return ""; k--; continue }
    r[++k] = a[i]
  }
  p = ""
  for (i = 1; i <= k; i++) p = p (i > 1 ? "/" : "") r[i]
  return p
}
# resolve <t> from folder <dir>; returns the rel path of an existing page or ""
function resolve(dir, t,   p) {
  if (t ~ /^g:/) p = "global/" substr(t, 3) ".md"
  else if (t ~ /^k:/) p = substr(t, 3) ".md"
  else {
    p = (dir == "" ? "" : dir "/") t ".md"
    if (!(p in exist)) p = "global/" t ".md"
  }
  return (p in exist) ? p : ""
}

BEGIN {
  RS = "\0"
  root = ENVIRON["OMK_LINT_ROOT"]; rl = length(root)
  maxkb = ENVIRON["OMK_MAX_FILE_KB"] + 0
  maxch = ENVIRON["OMK_MAX_INDEX_LINE_CHARS"] + 0
  bom = sprintf("%c", 65279)
  while ((getline sz < "-") > 0) {
    if ((getline pth < "-") <= 0) break
    size[substr(pth, rl + 2)] = sz + 0
    ARGV[ARGC++] = pth
  }
  if (ARGC == 1) ARGV[ARGC++] = "/dev/null"
  RS = "\n"
}

BEGINFILE {
  skipf = 1
  if (FILENAME == "/dev/null") nextfile
  rel = substr(FILENAME, rl + 2)
  if (rel !~ /^(rules|global|projects)\// && rel != "index.md") { exist[rel] = 1; nextfile }
  if (rel ~ /^rules\// && rel !~ /\.md$/) { exist[rel] = 1; nextfile }
  exist[rel] = 1; skipf = 0
  files[++nfiles] = rel
  base = rel; sub(/.*\//, "", base)
  slug = base; sub(/\.md$/, "", slug)
  dir = dirname(rel)
  isidx = (base ~ /^index(_.*)?[.]md$/)
  ismeta = (isidx || base == "SCHEMA.md" || base == "log.md" || base == "inbox.md" || rel == "rules/INDEX.md")
  isrule = (rel ~ /^rules\//)
  ln = 0; fm = 0; hasfm = 0; fmclose = 0; body = 0; moved = 0; infence = ""; incm = 0; cur = ""
  fname = ""; fdesc = ""; ftype = ""; mtype = ""; fver = ""; fevid = ""
}

{
  ln++
  line = $0; sub(/\r$/, "", line)
  if (ln == 1 && substr(line, 1, 1) == bom) line = substr(line, 2)
  if (ln == 1 && line == "---") { fm = 1; hasfm = 1; next }
  if (fm) {
    if (line == "---") { fm = 0; fmclose = 1; next }
    if (match(line, /^([A-Za-z_][A-Za-z0-9_-]*):[ \t]*(.*)$/, m)) {
      cur = m[1]; v = unq(m[2])
      if (cur == "name") fname = v
      else if (cur == "description") fdesc = v
      else if (cur == "type") ftype = v
      else if (cur == "verified") fver = v
      else if (cur == "evidence") fevid = v
    } else if (cur == "description" && fdesc == "" && line ~ /^[ 	]+[^ 	]/) {
      fdesc = trim(line)
    } else if (cur == "metadata" && match(line, /^[ \t]+([A-Za-z_]+):[ \t]*(.*)$/, m)) {
      v = unq(m[2])
      if (m[1] == "type") mtype = v
      else if (m[1] == "verified") fver = v
      else if (m[1] == "evidence") fevid = v
    }
    next
  }
  if (line !~ /^[ \t]*$/) {
    body++
    if (line ~ /^> Moved: \[\[[^]]+\]\](, *\[\[[^]]+\]\])* *$/) moved++
  }
  if (match(line, /^[ 	]*(```|~~~)/, fmk)) {
    mk = substr(fmk[0], length(fmk[0]) - 2)
    if (infence == "") infence = mk
    else if (infence == mk) infence = ""
    next
  }
  if (infence != "") next
  if (isidx && line ~ /^[ \t]*[-*+] / && maxch > 0 && length(line) > maxch)
    add("long_index_line", "blue", rel, ln, length(line) " characters (limit " maxch ")")
  c = nocomment(line)
  gsub(/`[^`]*`/, "", c)
  if (rel == "rules/INDEX.md" && c ~ /^@[^ \t]+[ \t]*$/) {
    ni++; imp[ni] = trim(substr(c, 2)); impln[ni] = ln
  }
  rest = c
  while (match(rest, /\[\[[^]]+\]\]/)) {
    t = substr(rest, RSTART + 2, RLENGTH - 4)
    rest = substr(rest, RSTART + RLENGTH)
    sub(/[|#].*$/, "", t); t = trim(t)
    if (t == "" || t == "g:" || t == "k:") continue
    nl++; lsrc[nl] = rel; lln[nl] = ln; ltgt[nl] = t
  }
}
function endfile_checks() {
  isstub = (body > 0 && moved == body)
  pstub[rel] = isstub; pmeta[rel] = ismeta; prule[rel] = isrule; pidx[rel] = isidx
  if (!ismeta) {
    if (fname != "") {
      key = dir SUBSEP fname
      dupn[key]++; dupf[key, dupn[key]] = rel
    }
    if (hasfm && fname != "" && fname != slug) add("name_mismatch", "red", rel, 0, "name '" fname "' does not match file name '" slug "'")
    if (!isstub) {
      type = (mtype != "" ? mtype : ftype)
      miss = ""
      if (!hasfm || !fmclose) miss = "no frontmatter"
      else {
        if (fname == "") miss = miss " name"
        if (fdesc == "") miss = miss " description"
        if (type == "") miss = miss " type"
        if (fver == "") miss = miss " verified"
        if (fevid == "") miss = miss " evidence"
        miss = trim(miss)
        if (miss != "") miss = "missing " miss
      }
      if (miss != "") add("missing_frontmatter", "yellow", rel, 0, miss)
    }
  }
  if (maxkb > 0 && (rel in size) && size[rel] > maxkb * 1024)
    add("oversize", "yellow", rel, 0, size[rel] " bytes (limit " maxkb " KB)")
}

ENDFILE { if (!skipf) endfile_checks() }

END {
  # ---- duplicate_name (per folder; every file but the first in sort order)
  for (key in dupn) if (dupn[key] > 1) {
    n = dupn[key]; for (i = 1; i <= n; i++) tmp[i] = dupf[key, i]
    asort(tmp)
    split(key, kp, SUBSEP)
    for (i = 2; i <= n; i++) add("duplicate_name", "red", tmp[i], 0, "name '" kp[2] "' also used by " tmp[1])
    delete tmp
  }
  # ---- links: resolve, count inbound, collect broken
  for (i = 1; i <= nl; i++) {
    src = lsrc[i]; t = ltgt[i]
    r = resolve(dirname(src), t)
    if (r == "") { k = (t ~ /^k:/) ? substr(t, 3) ".md" : (t ~ /^g:/) ? "global/" substr(t, 3) ".md" : "global/" t ".md"; lkey[i] = k; bad[k]++; badi[i] = 1; continue }
    if (r == src) continue
    inb[r]++
    if (pidx[src]) idxd[r] = 1
    if (pidx[src] && pidx[r] && !pstub[src]) { iec[src]++; ie[src, iec[src]] = r }
    gk = src SUBSEP r
    if (!(gk in lseen)) { lseen[gk] = 1; lcount[src]++; lpage[src, lcount[src]] = r }
  }
  for (i = 1; i <= nl; i++) if (i in badi) {
    t = ltgt[i]; k = lkey[i]
    if (bad[k] >= 3) {
      if (!(k in mpdone)) {
        mpdone[k] = 1
        files_n = 0; delete fs
        for (j = 1; j <= nl; j++) if (lkey[j] == k && !(lsrc[j] in fs)) { fs[lsrc[j]] = 1; files_n++ }
        add("missing_page", "blue", lsrc[i], lln[i], "[[" t "]] (" k ") linked " bad[k] " times from " files_n " page(s) but does not exist")
      }
    } else add("broken_link", "red", lsrc[i], lln[i], "[[" t "]] does not resolve")
  }
  # ---- index files reachable from root index.md over index-to-index links
  if ("index.md" in exist) {
    qh = 1; qt = 1; queue[1] = "index.md"; reach["index.md"] = 1
    while (qh <= qt) {
      u = queue[qh++]
      for (e = 1; e <= iec[u]; e++) { w = ie[u, e]; if (!(w in reach)) { reach[w] = 1; queue[++qt] = w } }
    }
  }
  # ---- orphan / not_indexed / shadow / rules
  for (i = 1; i <= nfiles; i++) {
    f = files[i]
    if (pidx[f] && !pstub[f] && f != "index.md" && !(f in reach)) add("not_indexed", "yellow", f, 0, "index file not linked from any other index file")
    if (pmeta[f] || pstub[f] || prule[f]) continue
    if (!(f in inb)) add("orphan", "yellow", f, 0, "no page links to this page")
    if (!(f in idxd)) add("not_indexed", "yellow", f, 0, "not linked from any index file")
  }
  for (i = 1; i <= nfiles; i++) {
    f = files[i]
    if (f ~ /^global\// && !pmeta[f]) gl[substr(f, 8, length(f) - 10)] = 1
  }
  for (i = 1; i <= nfiles; i++) {
    f = files[i]
    if (f ~ /^projects\// && !pmeta[f] && !pstub[f]) {
      s = f; sub(/.*\//, "", s); sub(/\.md$/, "", s)
      if (s in gl) add("slug_shadows_global", "blue", f, 0, "slug '" s "' is also a global page (global/" s ".md)")
    }
  }
  for (i = 1; i <= ni; i++) {
    t = imp[i]
    if (t ~ /^(~\/|\/|[A-Za-z]:)/) { add("rules_import_missing", "red", "rules/INDEX.md", impln[i], "@" t " is absolute; INDEX uses relative imports only"); continue }
    p = norm("rules/" t)
    if (p == "" || !(p in exist)) add("rules_import_missing", "red", "rules/INDEX.md", impln[i], "@" t " does not exist (resolved relative to rules/)")
    else imported[p] = 1
  }
  for (i = 1; i <= nfiles; i++) {
    f = files[i]
    if (prule[f] && !pstub[f] && f != "rules/INDEX.md" && !(f in imported)) add("rules_not_in_index", "yellow", f, 0, "no @" substr(f, 7) " import in rules/INDEX.md")
  }
  # ---- output findings
  PROCINFO["sorted_in"] = "@ind_str_asc"
  for (k in out) print out[k]
  # ---- groups
  for (i = 1; i <= nfiles; i++) {
    f = files[i]
    if (f ~ /^global\/index_[^\/]*\.md$/) {
      gl2 = "G\tindex:" substr(f, 8, length(f) - 10)
      for (j = 1; j <= lcount[f]; j++) gl2 = gl2 "\t" lpage[f, j]
      gout[gl2] = 1
    }
    if (f ~ /^projects\/[^\/]+\// && !pmeta[f] && !pstub[f]) { p = f; sub(/^projects\//, "", p); sub(/\/.*/, "", p); pj[p] = pj[p] "\t" f }
    if ((f ~ /^(global|projects)\//) && !pmeta[f] && !pstub[f]) {
      s = f; sub(/.*\//, "", s); sub(/\.md$/, "", s)
      if (s ~ /-/) { pre = s; sub(/-.*/, "", pre); fam[pre] = fam[pre] "\t" f; famn[pre]++ }
    }
  }
  for (p in pj) gout["G\tproject:" p pj[p]] = 1
  for (p in famn) if (famn[p] >= 3) gout["G\tfamily:" p fam[p]] = 1
  for (g in gout) {
    n = split(g, ga, "	"); np = 0; delete sp
    for (i = 3; i <= n; i++) sp[++np] = ga[i]
    asort(sp)
    o = ga[1] "	" ga[2]
    for (i = 1; i <= np; i++) o = o "	" sp[i]
    print o
  }
}

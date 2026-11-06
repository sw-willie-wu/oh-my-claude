"""Convert oh-my-status ANSI output (stdin) to a small terminal-window SVG.

Usage: ansi-to-svg.py [--width N] OUT.svg BG FG TITLE < render.ansi
  --width N  canvas width in px (default: fit the content; never narrower than it)

Dev tool only (regenerates assets/statusline-*.svg; see render-statusline-svg.sh).
GitHub shows SVG through <img>, so no web fonts load: Nerd Font icons and the
bar glyphs are drawn as shapes, everything else stays text.
"""
import re
import sys
from xml.sax.saxutils import escape, quoteattr

CW, LH, FS = 9.6, 26, 16          # cell width, line height, font size
PAD_X, PAD_TOP, BAR_H = 22, 46, 38
FONT = "ui-monospace, SFMono-Regular, Menlo, Consolas, 'Liberation Mono', monospace"
SGR = re.compile(r"\x1b\[([0-9;]*)m")


def color_of(params, cur):
    p = [int(x) if x else 0 for x in params.split(";")]
    if p[:2] == [38, 2] and len(p) >= 5:
        return "#%02x%02x%02x" % tuple(p[2:5])
    if p == [0]:
        return None
    return cur


def parse(line):
    cells, cur, pos = [], None, 0
    for m in SGR.finditer(line):
        cells += [(ch, cur) for ch in line[pos:m.start()]]
        cur, pos = color_of(m.group(1), cur), m.end()
    cells += [(ch, cur) for ch in line[pos:]]
    return cells


def shape(ch, x, y, c):
    """Return SVG for glyphs drawn as shapes, or None for plain text."""
    mid = y - FS * 0.32
    if ch == "█":   # full block
        return f'<rect x="{x:.1f}" y="{y-FS*0.78:.1f}" width="{CW+1:.1f}" height="{FS*0.9:.1f}" fill="{c}"/>'
    if ch in "░▒":  # light/medium shade
        return f'<rect x="{x:.1f}" y="{y-FS*0.78:.1f}" width="{CW+1:.1f}" height="{FS*0.9:.1f}" fill="{c}" opacity=".28"/>'
    if ch == "━":   # heavy horizontal
        return f'<rect x="{x:.1f}" y="{mid-1.6:.1f}" width="{CW+1:.1f}" height="3.2" rx="1" fill="{c}"/>'
    if ch == "╌":   # light dashed horizontal
        return f'<rect x="{x:.1f}" y="{mid-1:.1f}" width="{CW+1:.1f}" height="2" fill="{c}" opacity=".35"/>'
    if ch in "│┃":
        return f'<rect x="{x+CW/2-1:.1f}" y="{y-FS*0.85:.1f}" width="2" height="{FS*1.05:.1f}" fill="{c}" opacity=".7"/>'
    if ch == "":   # user
        cx = x + CW / 2
        return (f'<circle cx="{cx:.1f}" cy="{y-FS*0.62:.1f}" r="2.8" fill="{c}"/>'
                f'<path d="M{cx-4.6:.1f} {y-1:.1f}a4.6 4.6 0 0 1 9.2 0z" fill="{c}"/>')
    if ch == "":   # folder
        return f'<path d="M{x+0.5:.1f} {y-FS*0.7:.1f}h4l1.4 1.6h5v7.4h-10.4z" fill="{c}"/>'
    if ch == "":   # git branch
        x0 = x + 2.5
        return (f'<path d="M{x0+1.5:.1f} {y-FS*0.78:.1f}v10.5M{x0+1.5:.1f} {y-FS*0.35:.1f}q5.5 0 5.5 -4" '
                f'fill="none" stroke="{c}" stroke-width="1.6"/>'
                f'<circle cx="{x0+1.5:.1f}" cy="{y-FS*0.78:.1f}" r="1.9" fill="{c}"/>'
                f'<circle cx="{x0+1.5:.1f}" cy="{y+0.2:.1f}" r="1.9" fill="{c}"/>'
                f'<circle cx="{x0+7:.1f}" cy="{y-FS*0.8-0.5:.1f}" r="1.9" fill="{c}"/>')
    if 0xE000 <= ord(ch) <= 0xF8FF:   # any other private-use icon: drop
        return ""
    return None


def main():
    args = sys.argv[1:]
    width = None
    if "--width" in args:
        i = args.index("--width")
        width = int(args[i + 1])
        del args[i:i + 2]
    out, bg, fg, title = args[:4]
    lines = sys.stdin.read().replace("\r", "").rstrip("\n").split("\n")
    rows = [parse(l) for l in lines]
    ncols = max(len(r) for r in rows)
    w = round(PAD_X * 2 + ncols * CW)
    if width is not None:
        w = max(w, width)   # never clip content; extra space goes on the right
    h = PAD_TOP + len(rows) * LH + 18
    body = []
    for i, cells in enumerate(rows):
        y = PAD_TOP + (i + 1) * LH - 8
        st = {"run": "", "c": None, "x": 0}

        def flush():
            run = st["run"]
            if run.strip():
                lead = len(run) - len(run.lstrip())
                txt = run.strip()
                body.append(f'<text x="{PAD_X+(st["x"]+lead)*CW:.1f}" y="{y}" fill="{st["c"] or fg}" '
                            f'textLength="{len(txt)*CW:.1f}" lengthAdjust="spacingAndGlyphs">{escape(txt)}</text>')
            st["run"] = ""

        for col, (ch, c) in enumerate(cells):
            x = PAD_X + col * CW
            s = shape(ch, x, y, c or fg)
            if s is not None:
                flush()
                body.append(s)
                continue
            if c != st["c"] and st["run"]:
                flush()
            if not st["run"]:
                st["c"], st["x"] = c, col
            st["run"] += ch
        flush()
    svg = (f'<svg xmlns="http://www.w3.org/2000/svg" width="{w}" height="{h}" viewBox="0 0 {w} {h}" '
           f'shape-rendering="crispEdges" role="img" aria-label={quoteattr(title)}>'
           f'<title>{escape(title)}</title>'
           f'<rect width="{w}" height="{h}" rx="12" fill="{bg}"/>'
           f'<rect width="{w}" height="{BAR_H-4}" rx="12" fill="#000" opacity=".25"/>'
           f'<circle cx="22" cy="17" r="6" fill="#ff5f56"/><circle cx="42" cy="17" r="6" fill="#ffbd2e"/>'
           f'<circle cx="62" cy="17" r="6" fill="#27c93f"/>'
           f'<g font-family="{FONT}" font-size="{FS}" xml:space="preserve">{"".join(body)}</g></svg>\n')
    with open(out, "w", encoding="utf-8", newline="\n") as f:
        f.write(svg)


main()

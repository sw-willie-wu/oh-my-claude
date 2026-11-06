#!/bin/bash
# harvest-copy.sh <auto-memory file>...      (oh-my-knowledge harvest backup: copy and verify)
# harvest-copy.sh --dir-name <encoded dir>   prints the <backup dir> name for it; needs no knowledge base.
#
# Copies each auto-memory file (<...>/<encoded dir>/memory/<name>.md) byte for byte, with its
# modification time, to <kb>/_retired/harvested/<YYYY-MM-DD>/<backup dir>/<name>.md and verifies the
# copy with cmp. Env: OMK_KNOWLEDGE_DIR (as for the other scripts: env, else the plugin setting), OMK_TODAY (optional, default today).
#
# <backup dir> = the encoded dir when it has at most 60 characters; otherwise its last 51 characters
# with every leading "-" removed, then "-" and 8 lower-hex digits of `printf %s "$enc" | cksum`
# (first field). Always at most 60 characters, so git add stays under the Windows 260-character limit.
#
# Never overwrites. If <name>.md already exists in today's folder: identical content -> that path is
# reused; different content -> <name>.2.md, <name>.3.md, ... (an identical one is reused, else the
# first free name). Arguments may use "\" separators.
#
# stdout: one KB-relative path per verified file, in argument order. stderr: one line per failed file.
# Exit: 0 all verified | 1 some file failed (the others are still processed; only files with a
#       printed path may have changed) | 2 usage, KB not set up or a bad argument (nothing done).
set -u
set -o pipefail

# backup_dir <encoded dir>: sets _last_bd to the folder name (no subshell, so the last name stays cached)
_last_enc=""; _last_bd=""
backup_dir() {
  local enc="$1" t c
  if [ "$enc" = "$_last_enc" ] && [ -n "$_last_bd" ]; then return 0; fi
  if [ "${#enc}" -le 60 ]; then
    _last_bd="$enc"
  else
    t="${enc: -51}"
    while [ "${t#-}" != "$t" ]; do t="${t#-}"; done
    c="$(printf %s "$enc" | cksum)"; c="${c%% *}"
    _last_bd="$(printf '%s-%08x' "$t" "$c")"
  fi
  _last_enc="$enc"
}

if [ "${1:-}" = "--dir-name" ]; then
  [ "$#" -eq 2 ] && [ -n "$2" ] || { echo "usage: harvest-copy.sh --dir-name <encoded dir>" >&2; exit 2; }
  backup_dir "$2"; printf '%s\n' "$_last_bd"
  exit 0
fi

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
. "$HERE/lib/common.sh"
omk_config
[ -z "${OMK_CONFIG_ERROR:-}" ] || { echo "harvest-copy.sh: $OMK_CONFIG_ERROR" >&2; exit 2; }
omk_today

[ "$#" -ge 1 ] || { echo "usage: harvest-copy.sh <auto-memory file>... | --dir-name <encoded dir>" >&2; exit 2; }
KB="$OMK_KNOWLEDGE_DIR"
[ -f "$KB/SCHEMA.md" ] || { echo "harvest-copy.sh: knowledge base not found or not set up (no SCHEMA.md): $KB; run /oh-my-knowledge:setup" >&2; exit 2; }

# Validate every argument before copying anything.
for a in "$@"; do
  p="${a//\\//}"
  ok=1
  [ -f "$p" ] || ok=0
  if [ "$ok" = 1 ]; then
    dir="${p%/*}"
    [ "$dir" != "$p" ] && [ "${dir##*/}" = memory ] || ok=0
    case "${p##*/}" in *.md) ;; *) ok=0 ;; esac
    enc="${dir%/memory}"; enc="${enc##*/}"
    [ -n "$enc" ] || ok=0
  fi
  [ "$ok" = 1 ] || { echo "harvest-copy.sh: not an auto-memory file: $a" >&2; exit 2; }
done

rc=0
for a in "$@"; do
  p="${a//\\//}"
  dir="${p%/*}"; enc="${dir%/memory}"; enc="${enc##*/}"
  base="${p##*/}"; base="${base%.md}"
  backup_dir "$enc"; bd="$_last_bd"
  rel="_retired/harvested/$OMK_TODAY/$bd"
  if ! mkdir -p "$KB/$rel" 2>/dev/null; then
    echo "harvest-copy.sh: $a: cannot create $KB/$rel" >&2; rc=1; continue
  fi
  n=1; done_rel=""
  while :; do
    if [ "$n" -eq 1 ]; then cand="$base.md"; else cand="$base.$n.md"; fi
    dst="$KB/$rel/$cand"
    if [ -e "$dst" ]; then
      if cmp -s "$p" "$dst"; then done_rel="$rel/$cand"; break; fi
      n=$((n + 1)); continue
    fi
    if ! cp -p "$p" "$dst" 2>/dev/null; then
      rm -f "$dst"; echo "harvest-copy.sh: $a: copy failed" >&2; break
    fi
    if ! cmp -s "$p" "$dst"; then
      rm -f "$dst"; echo "harvest-copy.sh: $a: copy does not match the original" >&2; break
    fi
    done_rel="$rel/$cand"; break
  done
  if [ -n "$done_rel" ]; then printf '%s\n' "$done_rel"; else rc=1; fi
done
exit "$rc"

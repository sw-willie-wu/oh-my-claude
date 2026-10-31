#!/bin/bash
# commit.sh '<message>' <path>...   (storage seam; uses OMK_KNOWLEDGE_DIR)
# Commits only the listed paths (KB-relative, or absolute inside the KB in
# ~/…, C:\… or /c/… form). A move passes both the old and the new path.
# Exit: 0 committed | 3 nothing to commit (callers treat as success) |
#       4 lock still held after retries |
#       2 usage error, path outside the KB, a .git path, or no committable path |
#       1 KB missing, git add could not read a path (e.g. "Filename too long"
#         on Windows without core.longpaths) or any other git failure.
# A listed path that neither exists nor is tracked, or an empty directory (no
# files or symlinks below it) with nothing tracked under it, is dropped with an
# "ignored" line on stderr.
# Nothing is committed on any non-zero exit.
# Paths must be given in their on-disk case (the KB prefix of an absolute path
# is matched case-insensitively on Windows; the rest is used as given).
# A wrong-case path inside the KB can yield exit 3 (nothing committed) on
# case-insensitive filesystems, which callers treat as success: pass the exact
# path you wrote.
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
. "$HERE/lib/common.sh"
omk_config

MSG="${1-}"
if [ "$#" -lt 2 ] || [ -z "$MSG" ]; then
  echo "usage: commit.sh '<message>' <path>..." >&2
  exit 2
fi
shift

KB="$OMK_KNOWLEDGE_DIR"
export GIT_LITERAL_PATHSPECS=1
CI=0
case "${OSTYPE:-}" in msys*|cygwin*) CI=1 ;; esac

[ -d "$KB" ] || { echo "commit.sh: knowledge base not found: $KB" >&2; exit 1; }

# Resolve a path (which may not exist) through its nearest existing ancestor.
resolve_path() {
  local p="$1" rest="" base
  case "$p" in
    "~"|"~/"*|[A-Za-z]:*|/*|\\*) ;;
    *) p="$KB/$p" ;;
  esac
  p="$(omk_resolve_dir "$p")"
  # canonicalise the nearest existing ancestor directory (the file itself may
  # be new or deleted), then re-append the remainder
  while [ ! -d "$p" ] && [ "$p" != "/" ] && [ "$p" != "." ] && [ -n "$p" ]; do
    base="${p##*/}"
    rest="/$base$rest"
    p="${p%/*}"
    [ -z "$p" ] && p="/"
  done
  p="$(omk_resolve_dir "$p")"
  [ "$p" = "/" ] && p=""
  printf '%s' "$p$rest"
}

RELS=()
for arg in "$@"; do
  abs="$(resolve_path "$arg")"
  a="$abs"; k="$KB"
  if [ "$CI" = 1 ]; then a="$(printf %s "$abs" | tr A-Z a-z)"; k="$(printf %s "$KB" | tr A-Z a-z)"; fi
  case "$a" in
    "$k"/*) rel="${abs:${#KB}+1}" ;;
    *) echo "commit.sh: path outside the knowledge base: $arg" >&2; exit 2 ;;
  esac
  r="$rel"; [ "$CI" = 1 ] && r="$(printf %s "$rel" | tr A-Z a-z)"
  case "$r" in
    .git|.git/*) echo "commit.sh: refusing path inside .git: $arg" >&2; exit 2 ;;
  esac
  case "/$rel/" in
    */../*|*/./*) echo "commit.sh: path escapes the knowledge base: $arg" >&2; exit 2 ;;
  esac
  [ -n "$rel" ] || { echo "commit.sh: empty path" >&2; exit 2; }
  RELS+=("$rel")
done

[ -e "$KB/.git" ] || { echo "commit.sh: $KB is not a git repository" >&2; exit 1; }

# Drop listed paths that neither exist in the working tree nor are tracked
# (e.g. the old side of a move that was never committed). Exact, unquoted,
# NUL-separated comparison so non-ASCII names count as tracked.
TRACKED=()
while IFS= read -r -d '' f; do TRACKED+=("$f"); done \
  < <(LC_ALL=C LANGUAGE= git -C "$KB" -c core.quotepath=false ls-files -z -- "${RELS[@]}" 2>/dev/null)
KEEP=()
for rel in "${RELS[@]}"; do
  ok=0 why="not found and not tracked"
  if [ -d "$KB/$rel" ]; then
    # a directory counts only when it holds a file or symlink (else git commit -- <dir> fails);
    # a listed symlink to a directory matches -type l itself
    if [ -n "$(find "$KB/$rel" \( -type f -o -type l \) -print -quit 2>/dev/null)" ]; then ok=1; else why="empty directory"; fi
  elif [ -e "$KB/$rel" ]; then
    ok=1
  fi
  if [ "$ok" = 0 ]; then
    for f in ${TRACKED[@]+"${TRACKED[@]}"}; do
      case "$f" in "$rel"|"$rel"/*) ok=1; break ;; esac
    done
  fi
  if [ "$ok" = 1 ]; then
    KEEP+=("$rel")
  else
    echo "commit.sh: ignored $rel ($why)" >&2
  fi
done
[ "${#KEEP[@]}" -gt 0 ] || { echo "commit.sh: no committable path" >&2; exit 2; }
RELS=("${KEEP[@]}")

DELAY="${OMK_COMMIT_RETRY_DELAY:-2}"
ERR="$(mktemp)"
trap 'rm -f "$ERR"' EXIT

attempt=0
while :; do
  rc=0
  if LC_ALL=C LANGUAGE= git -C "$KB" add -- "${RELS[@]}" >/dev/null 2>"$ERR"; then
    # git add can succeed while skipping unreadable paths (only a warning)
    if grep -qE 'Filename too long|^(error|fatal):' "$ERR"; then
      LC_ALL=C LANGUAGE= git -C "$KB" reset -q -- "${RELS[@]}" >/dev/null 2>&1 || true
      cat "$ERR" >&2
      echo "commit.sh: git add could not read every path (path too long? enable long paths for git on Windows); nothing committed" >&2
      exit 1
    fi
    if LC_ALL=C LANGUAGE= git -C "$KB" diff --cached --quiet -- "${RELS[@]}" 2>>"$ERR"; then
      exit 3
    fi
    LC_ALL=C LANGUAGE= git -C "$KB" commit -q -m "$MSG" -- "${RELS[@]}" >/dev/null 2>>"$ERR" || rc=$?
  else
    rc=$?
  fi
  [ "$rc" -eq 0 ] && exit 0

  if grep -qE "Unable to create '[^']*\.lock'" "$ERR"; then
    # nothing may stay staged from a failed attempt
    LC_ALL=C LANGUAGE= git -C "$KB" reset -q -- "${RELS[@]}" >/dev/null 2>&1 || true
    if [ "$attempt" -lt 3 ]; then
      attempt=$((attempt + 1))
      sleep "$DELAY"
      continue
    fi
    cat "$ERR" >&2
    exit 4
  fi
  LC_ALL=C LANGUAGE= git -C "$KB" reset -q -- "${RELS[@]}" >/dev/null 2>&1 || true
  cat "$ERR" >&2
  exit 1
done

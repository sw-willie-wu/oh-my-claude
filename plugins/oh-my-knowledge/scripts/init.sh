#!/bin/bash
# Initialise (or recognise) a knowledge base at OMK_KNOWLEDGE_DIR.
# Creates missing skeleton dirs and template files, never overwrites anything,
# runs git init when there is no .git, and sets a repo-local git identity only
# when none is resolvable. Never touches global git config.
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
. "$HERE/lib/common.sh"
omk_config

KB="$OMK_KNOWLEDGE_DIR"
TPL="$HERE/../templates"

was_init=0
[ -e "$KB/.git" ] && [ -f "$KB/SCHEMA.md" ] && was_init=1

mkdir -p -- "$KB" || { echo "init: cannot create $KB" >&2; exit 1; }
KB="$(omk_resolve_dir "$KB")"
for d in rules global projects lint _retired; do
  mkdir -p -- "$KB/$d" || exit 1
done

copy_missing() { # <template> <dest relative>
  [ -e "$KB/$2" ] || cp -- "$TPL/$1" "$KB/$2" || exit 1
}
copy_missing SCHEMA.md SCHEMA.md
copy_missing index.md index.md
copy_missing log.md log.md
copy_missing inbox.md inbox.md
copy_missing rules-INDEX.md rules/INDEX.md
if [ ! -e "$KB/.gitattributes" ]; then
  printf '%s\n' '* text=auto eol=lf' >"$KB/.gitattributes" || exit 1
fi

if [ ! -e "$KB/.git" ]; then
  git -C "$KB" init -q >/dev/null 2>&1 || { echo "init: git init failed in $KB" >&2; exit 1; }
fi

if [ -z "$(git -C "$KB" config user.email 2>/dev/null | tr -d '\r')" ]; then
  git -C "$KB" config --local user.name "oh-my-knowledge"
  git -C "$KB" config --local user.email "oh-my-knowledge@localhost"
fi

if [ "$was_init" = 1 ]; then
  echo "already initialized $KB"
else
  echo "initialized $KB"
fi
exit 0

#!/bin/bash
# Conf-key diff helper for oh-my-claude setup.
#
# Sourced by setup.sh (and by tests). Sourcing is INERT — this file's top
# level contains ONLY this function definition; no command runs until the
# function is called, so `. lib/conf-keys.sh` always returns 0 under `set -e`.
#
# omc_missing_conf_keys <template_path> <user_conf_path>
#   Prints, one per line in template order, each KEY defined in the template
#   as an assignment but NOT present in the user conf as an uncommented
#   assignment. A key counts as PRESENT if an uncommented line matches the key
#   with an optional `export ` prefix and optional whitespace around `=`.
#   Values are never compared. Portable: BRE `sed` + ERE `grep -E`, no PCRE.
#   Exit: 0 on success regardless of whether any keys were missing ("none
#   missing" is signalled by empty stdout). Non-zero ONLY on internal error
#   (unreadable template).
omc_missing_conf_keys() {
  local template="$1" user_conf="$2"
  [ -r "$template" ] || return 1
  local keys key
  # Template is repo-controlled / trusted well-formed. Extract the identifier
  # before the first `=` on each assignment line (skips comments: a leading
  # `#` is neither whitespace nor [A-Za-z_], so the pattern fails to match).
  keys="$(sed -n 's/^[[:space:]]*\([A-Za-z_][A-Za-z0-9_]*\)[[:space:]]*=.*/\1/p' "$template")"
  while IFS= read -r key; do
    [ -n "$key" ] || continue
    # KEY is [A-Za-z0-9_]+ (above) → regex-literal-safe, no escaping needed.
    # The mandatory `[[:space:]]*=` right-anchors the key so WORKERS_MAX does
    # not match a line `WORKERS_MAXIMUM=...`.
    if [ -r "$user_conf" ] && grep -Eq -- \
      "^[[:space:]]*(export[[:space:]]+)?${key}[[:space:]]*=" "$user_conf"; then
      continue
    fi
    printf '%s\n' "$key"
  done <<EOF
$keys
EOF
}

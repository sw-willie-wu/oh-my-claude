---
name: setup
description: Use to set up or reconfigure oh-my-knowledge — create the knowledge base or point to an existing one (for example copied from another machine), show and change plugin settings, move the knowledge base, add the rules import to CLAUDE.md. 設定知識庫 / 初始化知識庫 / 換位置 / 改設定 / setup knowledge base.
---

# Set up oh-my-knowledge

The knowledge base (KB) is a local folder with version history. Its maintenance contract is `<knowledge_dir>/SCHEMA.md` (the plugin's default; the user may replace it, for example with a version in their own language) — it is the authority for every writing rule. Never edit `settings.json` yourself; settings change only through `claude plugin configure`.

## 1. Plugin id

```bash
claude plugin list --json | jq -r '.[] | select(.enabled == true) | .id | select(startswith("oh-my-knowledge@"))' | tr -d '\r' | sort -u
```

One id → use it as `<id>`. Several → ask the user which one. None → tell the user to install or enable the plugin (`/plugin`) and stop.

## 2. Show the settings

```bash
claude plugin configure '<id>' --json
```

The output has `inputs` (current values), `configured` and `unconfigured` (key lists). List every option: its value from `inputs`, or "unset (default …)" when it is in `unconfigured`. Note the current `knowledge_dir` = `inputs.knowledge_dir` (unset → `~/knowledge`). Check it: after turning `\` into `/` it must start with `/`, `X:/` or `~/`, or be `~` or `X:`. If it does not (the hooks and scripts report a configuration error for it), tell the user and go straight to step 3 for a corrected value. Options and defaults:

| key | default | meaning |
|---|---|---|
| `knowledge_dir` | `~/knowledge` | KB folder |
| `lookup_reminder` | `true` | remind to look things up on problem-like prompts |
| `auto_handoff` | `true` | ask for a handoff when context reaches the threshold |
| `auto_handoff_threshold` | `70` (30–90) | context % for the automatic handoff |
| `auto_handoff_repeat` | `20` (10–60) | points usage must grow before it asks again |
| `lint_stale_days` | `90` | stale after this many days |
| `lint_flag_days` | `14` | an UNVERIFIED flag older than this is reported |
| `lint_remind_after_distills` | `10` | remind to lint after this many distills |
| `max_file_kb` | `8` | page size limit |
| `max_index_line_chars` | `200` | index line limit (characters) |

Tell the user they can change options in the `/plugin` settings of oh-my-knowledge, or ask you to.

## 3. Change settings (on request)

- Build a JSON object with only the changed keys, **every value a string** (`"true"`, `"70"`, `"D:/kb"`); escape backslashes, or prefer forward slashes.
- Turn every `\` of a `knowledge_dir` into `/` first, then reject it unless it is absolute (starts with `/` or `X:/`, or is `X:`) or starts with `~/` (or is `~`): a relative path such as `kb` or `./kb` is a configuration error; ask for an absolute one.
- Reject a `knowledge_dir` that contains `'` (it would break the single-quoted values the skills pass to scripts); ask for another path.
- Pointing at a KB the user moved or copied (step 7): run its check **before** writing the setting.
- Write it (the CLI validates ranges and stores the values):

```bash
printf '%s' '{"knowledge_dir":"<new dir>","lint_stale_days":"60"}' | claude plugin configure '<id>' --values-stdin
```

- On an error, show it and ask for a valid value. Afterwards remind the user to restart the session: skills and hooks read the new values only then.

## 4. Initialize or check the KB

"Changed in this run" = you wrote a `knowledge_dir` in step 3 that differs from `inputs.knowledge_dir` of step 2.

Not changed in this run:

```bash
OMK_KNOWLEDGE_DIR='${user_config.knowledge_dir}' bash "${CLAUDE_PLUGIN_ROOT}/scripts/init.sh"
```

Changed in this run — pass the new value explicitly (the substituted `knowledge_dir` value in this skill text stays the old one until the restart):

```bash
OMK_KNOWLEDGE_DIR='<new knowledge_dir>' bash "${CLAUDE_PLUGIN_ROOT}/scripts/init.sh"
```

- `initialized <dir>`: a new KB (folders `rules/ global/ projects/ lint/ _retired/`, `SCHEMA.md`, `index.md`, `log.md`, `inbox.md`, `rules/INDEX.md`, `.gitattributes`, version history; a repo-local identity only when none exists — global settings are never touched).
- `already initialized <dir>`: an existing KB, for example copied from another machine. Nothing is overwritten; only missing skeleton parts are added. `rules/` and `global/` work right away; project knowledge reconnects per repo later (distill offers "attach <p>").
- Relocation (step 7) must print `already initialized` — or `initialized` when the user chose to continue a `no-history` copy; anything else → stop and tell the user (folder not moved yet, or wrong path).
- Non-zero exit: show stderr and stop.

## 5. Commit what init created

`init.sh` never commits. Commit the skeleton files with the same `OMK_KNOWLEDGE_DIR` value as step 4:

```bash
OMK_KNOWLEDGE_DIR='<same value as step 4>' bash "${CLAUDE_PLUGIN_ROOT}/scripts/commit.sh" 'setup: knowledge base skeleton' SCHEMA.md index.md log.md inbox.md rules/INDEX.md .gitattributes
```

If init printed `initialized` but `rules/`, `global/`, `projects/`, `_retired/` or `lint/` already hold files (for example a `no-history` copy, step 7), list them and offer to commit them too (folders are accepted as paths; an empty folder is skipped):

```bash
OMK_KNOWLEDGE_DIR='<same value as step 4>' bash "${CLAUDE_PLUGIN_ROOT}/scripts/commit.sh" 'setup: existing pages' rules global projects index.md _retired lint
```

Exit 0 committed; 3 nothing new to commit = success; 4 lock held → retry later; 1 or 2 → show stderr.

## 6. Rules import in CLAUDE.md (ask first)

Rules in `<knowledge_dir>/rules/` load only through one import line in the user's CLAUDE.md at `${CLAUDE_CONFIG_DIR:-~/.claude}/CLAUDE.md`:

```
@<knowledge_dir>/rules/INDEX.md
```

(write the real path; inside the home folder prefer the `~/…` form). If the line is missing, ask whether to add it. On yes: if the file exists, first back it up (`cp -p` to `CLAUDE.md.bak-YYYYMMDD` next to it), then append the line, and tell the user where the backup is; if the file does not exist, create it with just the import line. Never add it without asking.

## 7. Moving the KB

The user moves the whole folder (including its hidden version-history folder) themselves; you never move it. Then:

1. Check the new place (a leading `~/` or `~\` is expanded like init.sh does):

```bash
d='<new knowledge_dir>'; case "$d" in '~/'*|'~\'*) d="$HOME/${d#??}" ;; esac
if [ -f "$d/SCHEMA.md" ] && [ -e "$d/.git" ]; then echo ok; elif [ -f "$d/SCHEMA.md" ]; then echo no-history; else echo missing; fi
```

   - `ok` → continue; init.sh must print `already initialized`.
   - `no-history` → explain: the KB was copied without its hidden version-history folder (`.git`). Offer to continue: init.sh then starts a new history (prints `initialized`) and step 5 commits the existing pages. Stop if the user declines.
   - `missing` → stop: the folder is not moved yet, or the path is wrong.
2. Change `knowledge_dir` (step 3), run `init.sh` with the new value passed explicitly (step 4).
3. Offer to update the import line in CLAUDE.md (step 6, with backup), and remind to restart.

Links (`[[g:…]]`, `[[k:…]]`) and the relative imports in `rules/INDEX.md` need no rewrite. Do not put the KB in a cloud-synced folder: syncing a version-history folder can corrupt it.

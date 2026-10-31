# oh-my-knowledge

A local, git-versioned knowledge base for Claude Code. Durable knowledge (decisions and their reasons, pitfalls, conventions, root causes) lives in one folder you own, instead of rotting in per-project auto memory. Claude looks it up before answering problem-style questions, writes back what it learns, and hands off project progress at the end of a session.

Two rules keep it tidy: **project progress lives only in the project's auto memory; durable knowledge lives only in the knowledge base.** Never keep two writable copies of the same knowledge.

## Install

```
/plugin marketplace add sw-willie-wu/oh-my-claude
/plugin install oh-my-knowledge@oh-my-claude
/reload-plugins
```

All plugins in this marketplace update together on each release. If you used the old `oh-my-claude` statusline plugin, see the upgrade notes in the [root README](../../README.md#upgrading-from-oh-my-claude).

For automatic handoff also install and set up oh-my-status (`/plugin install oh-my-status@oh-my-claude`, then `/oh-my-status:setup`).

Then run setup:

```
/oh-my-knowledge:setup
```

Setup shows the settings, creates the knowledge base (or recognises an existing one), commits the skeleton, and offers to add the rules import to your `CLAUDE.md` (it always asks first and backs the file up). Restart the session afterwards: skills and hooks read changed settings only at start.

A project is "migrated" once you ask distill to "migrate this project" (or "attach `<p>`"), which writes the `(omk-project)` marker line into that repo's auto-memory `MEMORY.md`. Harvest runs only for migrated projects; until then the knowledge stays in auto memory (lookup still searches it) and distill's report offers to attach it.

## Skills

Skills are invoked by their full name. A local user skill with the same short name wins over the plugin's, so always use the `oh-my-knowledge:` form if in doubt.

- **`/oh-my-knowledge:setup`** - set up or reconfigure. Creates the folder (default `~/knowledge`) with its own git history, shows and changes the settings through `claude plugin configure`, adds the rules import, and helps relocate the folder. Run it once after install and whenever you want to change `knowledge_dir`.
- **`/oh-my-knowledge:lookup`** - search the knowledge base and this project's auto memory before answering. Triggers when Claude is about to explain why something is slow or broken, list options, or change a system setting, and when the lookup-reminder hook (below) nudges it. Read-only apart from four small write-backs: mark a page verified, correct a page that a test proved wrong, flag a suspicion, or record a lead in `inbox.md`.
- **`/oh-my-knowledge:distill`** - turn the session's durable knowledge into knowledge-base pages, digest `inbox.md`, and harvest the project's auto memory (the knowledge moves into the base, the auto-memory file becomes a `> Moved:` stub). Also handles "migrate this project", "attach `<p>`" and "close this project". Handoff runs it at the end of a session; it also reminds you when lint is due.
- **`/oh-my-knowledge:handoff`** - end of a session, or before the context fills up. Rewrites only the status section of the project's auto-memory `MEMORY.md` (goal, git state, verification, next steps), then runs distill, then marks the handoff as done. Triggered by `/oh-my-knowledge:handoff`, by phrases like "handoff", and by the automatic handoff hook.
- **`/oh-my-knowledge:lint`** - health check. A script screens for broken links, misnamed or duplicate pages, oversize pages, stale or long-unverified claims, progress leaks, project-marker problems and unharvested auto memory; Claude then judges the flagged groups for contradictions and merge candidates, fixes what is mechanical, and proposes the rest. Writes `lint/lint-YYYY-MM-DD.md`. Run monthly or when distill reminds you.

## Settings

Change them in the `/plugin` settings of oh-my-knowledge, or ask `setup`. Unset options use the defaults below.

| Key | Default | Meaning |
|---|---|---|
| `knowledge_dir` | `~/knowledge` | The knowledge-base folder (a local git repo). Must not contain a single quote `'`. Run `setup` after changing it. |
| `lookup_reminder` | `true` | On a prompt that looks like a problem or error, remind Claude to run lookup first. |
| `auto_handoff` | `true` | When context usage reaches the threshold, ask Claude to run a handoff. |
| `auto_handoff_threshold` | `70` (30-90) | Context usage percentage that triggers the automatic handoff. |
| `lint_stale_days` | `90` (1-3650) | A page is reported as stale only when its `metadata.verified` date is older than this *and* its text mentions a version (`v1.2`, `1.2.3`) or time-sensitive wording (latest, current, as of, 目前, 最新). |
| `lint_flag_days` | `14` (1-3650) | An `UNVERIFIED` flag older than this is reported as overdue (`unverified_overdue`); a flag with no date or an invalid date is reported too. |
| `lint_remind_after_distills` | `10` (1-1000) | Distill reminds you to lint after this many distills since the last lint. |
| `max_file_kb` | `8` (1-64) | Topic pages and sub-indexes larger than this are flagged for splitting. |
| `max_index_line_chars` | `200` (80-1000) | Index lines longer than this many characters (not bytes) are flagged. |

## Automatic handoff

Two hooks cooperate with the statusline plugin **oh-my-status**:

1. The oh-my-status statusline writes the current context usage to `$OMC_STATE_DIR/ctx-<sid>` (percentage and window size).
2. When Claude stops, the oh-my-knowledge Stop hook reads `ctx-<sid>`. If usage is at or above `auto_handoff_threshold` and no `handoff-<sid>` file exists yet, it creates `handoff-<sid>` and blocks the stop once with a request to run `oh-my-knowledge:handoff`.
3. Handoff updates the status section, runs distill, and (re)writes `handoff-<sid>` so it will not ask again in this context window. oh-my-status shows a handoff badge while that file exists.
4. After a compact, the SessionStart hook deletes both files for the session, so the next window can trigger again, and tells Claude to re-read the status section.

**Without oh-my-status installed, nothing writes `ctx-<sid>` and auto handoff silently does nothing.** Manual handoff works either way. Stale `ctx-*` and `handoff-*` files are swept after 24 hours. `$OMC_STATE_DIR` defaults to `~/.claude/oh-my-claude/state`.

## Lookup reminder

When `lookup_reminder` is on, a UserPromptSubmit hook checks each prompt (slash commands are skipped) for problem-style wording in English or Traditional Chinese (why, error, failed, slow, stuck, and similar) and adds a one-line reminder to run `oh-my-knowledge:lookup` first.

## Folder layout

```
SCHEMA.md      the maintenance contract: the authority for every writing rule (you may replace it, e.g. with a translation)
index.md       router: sub-indexes, project list, maintenance status
log.md         append-only timeline
inbox.md       leads waiting for distill
rules/         rules to follow without being asked; rules/INDEX.md @-imports each one
global/        cross-project knowledge, consulted on demand (index_<topic>.md + topic pages)
projects/<p>/  knowledge of a migrated project (index.md + topic pages)
lint/          lint-YYYY-MM-DD.md reports
_retired/      retired files by date, with REPORT.md
.gitattributes `* text=auto eol=lf`
```

`setup` never overwrites anything; it only adds missing parts. Pages carry frontmatter (`name`, `description`, `metadata.type`, `metadata.verified`, `metadata.evidence`).

## Link forms

Inside the knowledge base, `[[slug]]` links resolve in the linking page's folder first, then `global/`. References from outside the base (auto memory, `CLAUDE.md`) use two relocation-safe forms, which the SessionStart hook explains to Claude at the start of every session:

- `[[g:slug]]` = `<knowledge_dir>/global/<slug>.md`
- `[[k:<relpath>]]` = `<knowledge_dir>/<relpath>.md`

Two marker literals appear in auto memory: `(omk-project)` on the single line of `MEMORY.md` that maps a repo to its project (`- Knowledge base project: [[k:projects/<p>/index]] (omk-project)`), and `(omk-harvested)` on a `MEMORY.md` line whose knowledge has moved into the base (the line keeps only the trigger and a link). A harvested auto-memory file keeps its place as a stub whose body is `> Moved: [[k:...]]`, so old links stay valid.

## Rules import

Files in `rules/` load only through one import line in your `CLAUDE.md` (`${CLAUDE_CONFIG_DIR:-~/.claude}/CLAUDE.md`):

```
@~/knowledge/rules/INDEX.md
```

(use your real `knowledge_dir`). `rules/INDEX.md` in turn `@`-imports each rule with a path relative to itself, so moving the folder needs no rewrite there. `setup` offers to add the line and keeps a dated backup of `CLAUDE.md`. Lint flags rule files missing from the index.

## Requirements

- `bash`, `gawk`, GNU `date`, GNU `find` (lint uses `find -printf`), and `jq`.
- Hook scripts are bash 3.2 compatible.
- **macOS:** install them first, for example `brew install gawk coreutils findutils jq`, and put the GNU `date` and `find` first on `PATH` (Homebrew installs them as `gdate` and `gfind` unless you add the `gnubin` directories).
- **Windows:** use Git Bash; the scripts handle Windows-style paths.
- `git` for the knowledge base's history.

## Moving to another machine

The knowledge base is a plain git folder, so it moves by copying. Project knowledge is repo-specific and is not expected to carry over to a machine that lacks that repo; `rules/` and `global/` work immediately.

1. On the old machine, **distill the projects you want to keep first** (run distill, or "migrate this project"). Auto memory does not move with the folder; whatever is still only in auto memory stays behind.
2. Copy the whole folder, **including the hidden `.git` folder**, to the new machine.
3. Install the plugin there (see Install).
4. Run `/oh-my-knowledge:setup` and point `knowledge_dir` at the copied folder. It reports `already initialized` and adds only what is missing. If the copy has no `.git`, setup tells you and can start a fresh history.
5. In a repo on the new machine, distill's report offers to attach an existing project; you name the project (`attach <p>`) and the repo is linked to its knowledge.

If the base was committed with CRLF line endings, its `.gitattributes` (`* text=auto eol=lf`) may make git show files as modified once on the new machine. Commit them once and it settles, for example `git -C <knowledge_dir> add --renormalize . && git -C <knowledge_dir> commit -m "Normalize line endings"` (run it yourself; the skills commit only through commit.sh and never renormalize).

Relocating on the same machine works the same way: move the folder yourself, then run setup with the new `knowledge_dir`.

Other storage (a remote git repository, a cloud drive, an MCP notebook) is future work. Do not put the base in a cloud-drive sync folder: syncing the `.git` folder risks corrupting the repository.

## Troubleshooting

- **"knowledge base not found"** from lookup or lint: run `/oh-my-knowledge:setup`, or check `knowledge_dir`.
- **Windows path too long (`commit.sh` exits 1 with a "Filename too long" hint, typically deep `_retired/harvested/…` paths):** run `git -C <knowledge_dir> config core.longpaths true` (repo-local), then re-run the commit.
- **Changed a setting and nothing happened:** restart the session.
- **Auto handoff never fires:** check that oh-my-status is installed and its statusline is active (it writes `ctx-<sid>`), that `auto_handoff` is `true`, and that the threshold is reachable. It fires once per context window.
- **`gawk is required`, or lint/search exit 2:** a tool from Requirements is missing, the knowledge base was not found, or the command was used wrongly. Hooks do nothing, silently, when `jq` is missing.
- **Lock errors (commit exit 4):** `commit.sh` already retried 3 times. A stale `.git/index.lock` left by a crashed git can be removed once no git process is running.
- **`knowledge_dir` rejected:** it must not contain `'`.
- **A local skill shadows a plugin skill:** call the plugin's by full name, `/oh-my-knowledge:lookup`.

## Advanced / testing

Environment variables override the settings for scripts and tests. Normal use never needs them.

| Variable | Default | Effect |
|---|---|---|
| `OMK_KNOWLEDGE_DIR`, `OMK_LOOKUP_REMINDER`, `OMK_AUTO_HANDOFF`, `OMK_AUTO_HANDOFF_THRESHOLD`, `OMK_LINT_STALE_DAYS`, `OMK_LINT_FLAG_DAYS`, `OMK_LINT_REMIND_AFTER_DISTILLS`, `OMK_MAX_FILE_KB`, `OMK_MAX_INDEX_LINE_CHARS` | the setting's value, else its default | One variable per setting. |
| `OMK_AUTO_MEMORY_DIR` | empty (derived from the working directory) | The current project's auto-memory directory. |
| `OMK_AUTO_MEMORY_GLOB` | `$CLAUDE_CONFIG_DIR/projects/*/memory` (config dir defaults to `~/.claude`) | Where search, distill, handoff and lint find auto-memory directories (the current project is matched among them). |
| `OMK_CLAUDE_MD` | `$CLAUDE_CONFIG_DIR/CLAUDE.md` | The `CLAUDE.md` that lint scans for `[[g:]]` / `[[k:]]` references (`ext_link_missing`, inbound references for `stub_unreferenced`). |
| `OMC_STATE_DIR` | `~/.claude/oh-my-claude/state` | Where `ctx-<sid>` and `handoff-<sid>` live. |
| `OMK_TODAY` | today (`date +%F`) | Fixed date for lint. |
| `OMK_JQ` | `jq` | The jq executable. |
| `OMK_COMMIT_RETRY_DELAY` | `2` | Seconds between `commit.sh` lock retries. |
| `OMK_LINT_ICASE` | auto-probed | `0` or `1`: override the case-insensitive filesystem probe in lint. |
| `OMK_LINT_WINPATHS` | set by lint.sh | Internal: lint.sh sets it from the platform, so a value you set is ignored; only honoured when running `lib/lint-content.awk` directly. |

Two cases for auto-memory location:

- Inside a git submodule the auto-memory directory is derived wrongly from the working directory. distill and lookup pass the session's own auto-memory path as `OMK_AUTO_MEMORY_DIR` whenever it is visible in the session (handoff uses that directory directly).
- If you set Claude Code's `autoMemoryDirectory`, set `OMK_AUTO_MEMORY_GLOB` to match, for example in the `env` block of `settings.json` so the Bash tool inherits it.

## License

MIT

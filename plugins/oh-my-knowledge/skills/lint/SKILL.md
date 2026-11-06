---
name: lint
description: Use to health-check the knowledge base — broken links, duplicate or misnamed pages, oversize pages, stale or long-unverified claims, progress leaks, project markers, unharvested auto memory, contradictions and merge candidates. Run monthly or when distill reminds. 知識庫健檢 / lint / 檢查知識庫 / 矛盾 / 過期 / 斷鏈.
---

# Lint the knowledge base

`<knowledge_dir>/SCHEMA.md` is the authority for every writing rule. `<knowledge_dir>` is the folder in the session-start note ("Knowledge base: …"). Two stages: the script screens, you judge only what it flags. Lint never deletes knowledge and never silently rewrites anything that needs judgement.

## 1. Script stage

Save the JSON to a file in your scratch/temp directory:

```bash
OMK_KNOWLEDGE_DIR='${user_config.knowledge_dir}' OMK_LINT_STALE_DAYS='${user_config.lint_stale_days}' OMK_LINT_FLAG_DAYS='${user_config.lint_flag_days}' OMK_MAX_FILE_KB='${user_config.max_file_kb}' OMK_MAX_INDEX_LINE_CHARS='${user_config.max_index_line_chars}' bash "${CLAUDE_PLUGIN_ROOT}/scripts/lint.sh" > '<scratch>/lint.json'
```

Exit 0 = ok; 1 = a pass failed; 2 = KB not set up, gawk or jq missing (report and stop; a message naming `knowledge_dir` or "knowledge base not found" → tell the user to run `/oh-my-knowledge:setup`). The JSON has `findings` (`{check, severity, file, line, detail}`, `file` KB-relative for KB pages but an absolute native path for auto-memory and CLAUDE.md findings (`unharvested_auto_memory`, `ext_link_missing`, `auto_memory_link_broken`, the `project_marker_*` checks), `line` 0 = whole file; severity red/yellow/blue), `groups` (`{name, pages}`, name `index:<slug>`, `project:<p>` or `family:<prefix>`) and `batches` (`{groups, pages}`, at most 25 pages each). Read it with `jq`.

Checks and who handles them (F = fix directly, P = propose a diff, A = ask the user):

| Check | Handling |
|---|---|
| `missing_frontmatter` | F for `name` / `verified` / `evidence`; a missing `description` or `type` → P |
| `name_mismatch` | F: set `name` to the file name (slugs never get renamed) |
| (no script check) links to a single-target stub — for each KB stub, `grep -rnF '[[<slug>]]'` (and `[[g:<slug>]]`, `[[k:<relpath>]]`) over `rules/ global/ projects/ index.md` inside `<knowledge_dir>` | F, only for links that really resolve to the stub (`[[slug]]` resolves in the linking page's folder first, then `global/`): point them at the stub's target; a target in another folder is written `[[g:<slug>]]` (global) or `[[k:<relpath>]]` |
| `broken_link` | A (or P when the right target is obvious); a literal `[[` belongs in backticks or a fence |
| `rules_not_in_index` | F: add the `@<slug>.md` line to `rules/INDEX.md` |
| `not_indexed`, `long_index_line` | P (the trigger line to add, or how to split) |
| `oversize`, `duplicate_name`, `orphan`, `missing_page`, `rules_import_missing` | A |
| `stale`, `unverified_overdue` | A: re-verify (run `oh-my-knowledge:lookup` write-backs) |
| `progress_leak` | A: where the progress belongs (the project auto memory) |
| `stub_unreferenced` | A: retire candidate, except `projects/*/always-on.md`: never offer it for retirement |
| `promote_candidate` | A: promote to `global/` (see distill promote timing); "no" → F: add the detail's projects to `metadata.no_promote: a, b` |
| `ext_link_missing`, `auto_memory_link_broken` | P only (they are outside the KB) |
| `project_marker_invalid`, `project_marker_misplaced`, `project_marker_missing` | P only: propose the exact marker line `- Knowledge base project: [[k:projects/<p>/index]] (omk-project)` and its place (after the status section, within the first 200 lines). `project_marker_missing` means `(omk-harvested)` lines or `> Moved: [[k:projects/<p>/…]]` stubs exist without a valid marker. |
| `unharvested_auto_memory` | report as the migration progress table; suggest distill ("migrate this project" / harvest) |
| `slug_shadows_global` | blue hint only |
| `link_into_retired` | A: bring the needed fact into a current page (or un-retire it), else drop the link |
| `suspect_link_rewrite` | P: restore from the `_retired/harvested/` original if one exists; else A |
| (no script check) always-on counts | informational, not a finding: in the report, list per project the number of `- ` lines in `projects/<p>/always-on.md` outside frontmatter, fenced and `<!-- -->` blocks (read the files; skip projects without one); note a page whose directive lines exceed 4000 bytes (the session-start injection stops there) |
| `missing_path` (blue: a `~/…` path in the text does not exist on this machine) | report only, no question (paths on other machines are normal) |

## 2. Judgement stage

For each entry in `batches`, dispatch one subagent (Agent tool, `subagent_type: general-purpose`, `model: sonnet`) in waves: at most 20 running at once (the session limit); start the next batch as one returns, or, with foreground calls, send the next wave after the current one returns. `Concurrent subagent limit reached` → wait, resend that batch; never drop one (a batch that never returns: "not judged" in the report). A group named in more than one batch was split: note "lower recall" for it in the report. Prompt each one with the batch's page paths (`<knowledge_dir>/<rel>`) and:

> Read these pages. Find contradictions, pages that should be merged, missing cross-links, and leftovers of stacked corrections ("correction to the above", "this entry is void"). Read only; change nothing; run no commands. Return only a JSON array of `{"type": "contradiction|merge|missing_link|stacked_correction", "pages": [...], "detail": "..."}`.

A red **contradiction** goes into the report only after you re-read both pages yourself and confirm it.

## 3. Mechanical fixes (only inside the KB, no judgement)

- Add missing frontmatter `name` (file name), `verified` (the file's `metadata.modified` if present, else `date -r '<file>' +%F`), `evidence` (the SCHEMA's "inferred" value).
- Fix `name` ≠ file name; repoint links to a **single-target** redirect stub (resolution rule in the table); add missing `rules/INDEX.md` lines.
- Multi-target stubs and anything in auto memory or `CLAUDE.md`: propose only.

## 4. Report

After the fixes, write `<knowledge_dir>/lint/lint-YYYY-MM-DD.md`: findings grouped red / yellow / blue, each with a suggested fix, then three lists: **Fixed** (what step 3 actually changed), **Proposed** (diffs awaiting a yes), **Ask the user** (merge, retire, change a conclusion, split, promote, progress-leak ownership). Write the report in the user's language.

Then update `## Maintenance status` in `index.md` (last lint date, open findings), append to `log.md`:

```
## [YYYY-MM-DD] lint | <n> findings, <n> fixed
- <what was fixed>
```

and commit the report, the fixed pages, `index.md` and `log.md`:

```bash
OMK_KNOWLEDGE_DIR='${user_config.knowledge_dir}' bash "${CLAUDE_PLUGIN_ROOT}/scripts/commit.sh" 'lint: YYYY-MM-DD' lint/lint-YYYY-MM-DD.md index.md log.md global/<slug>.md
```

Exit 0 committed; 3 nothing to commit = success; 4 lock held → report, retry later; 2 bad path; 1 report stderr. Message without `'` inside, no AI attribution, no session links.

## 5. Proposals and questions

Show each proposal as a diff; apply only after the user agrees (description out of sync with the body, how to split a long index line, the trigger line for an unindexed page). Ask the "Ask the user" list in one message. Apply the answers, then commit as above with a message naming the change.

## 6. Retire (only after the user agrees)

Never retire `projects/*/always-on.md`. Steps (move to `_retired/YYYY-MM-DD/`, `REPORT.md`, stub rule, log): [reference.md](reference.md). Then commit both the old and the new path:

```bash
OMK_KNOWLEDGE_DIR='${user_config.knowledge_dir}' bash "${CLAUDE_PLUGIN_ROOT}/scripts/commit.sh" 'retire: <slug>' global/<slug>.md _retired/YYYY-MM-DD/global/<slug>.md _retired/YYYY-MM-DD/REPORT.md log.md
```

Frequency: monthly, or when distill reports `'${user_config.lint_remind_after_distills}'` distills since the last lint (default 10).

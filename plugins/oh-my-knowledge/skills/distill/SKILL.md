---
name: distill
description: Use to distill this session's durable knowledge (decisions and reasons, pitfalls, conventions, root causes) into the knowledge base and to harvest the project's auto memory; handoff runs it at the end. Also for "migrate this project", "attach <p>", "close this project", "make X a global rule". 蒸餾 / 寫進知識庫 / 遷移這個專案 / 接上 <p> / 專案結案 / 改成全域規則.
---

# Distill into the knowledge base

`<knowledge_dir>/SCHEMA.md` is the authority for every writing rule. Read it first. `<knowledge_dir>` is the folder in the session-start note ("Knowledge base: …"). Pages via Read/Write/Edit; history only via `commit.sh`. Write new text in the user's language; moved text keeps its language. Harvest details: [reference.md](reference.md); modes: [modes.md](modes.md).

## 0. Current project

```bash
OMK_KNOWLEDGE_DIR='${user_config.knowledge_dir}' OMK_AUTO_MEMORY_DIR='<auto-memory dir>' bash "${CLAUDE_PLUGIN_ROOT}/scripts/search.sh" omk-project
```

Exit 2 naming `knowledge_dir` or "knowledge base not found": tell the user to run `/oh-my-knowledge:setup` first and skip the distill.

`<auto-memory dir>` = the auto memory directory stated in this session's system prompt (leave out the `OMK_AUTO_MEMORY_DIR=…` assignment if none is visible). Read `== project: <p>` (migrated: its `MEMORY.md` has exactly one valid marker line `- Knowledge base project: [[k:projects/<p>/index]] (omk-project)`) or `== project: (not migrated)`, and `== auto memory: <dir>`.

## 1. Steps

1. **Inventory** this session: decisions + reasons, pitfalls, conventions, bug root causes. Drop pure process, what the KB already has and repo-documented details (decisions and reasons stay).
2. **Digest** `inbox.md` lines and `> ⚠ UNVERIFIED` lines: check each, then rewrite the page (auto memory unchanged: harvest lines carry no conclusion) or remove the flag; remove processed inbox lines.
3. **Write by layer** (SCHEMA layering): tool/platform/environment knowledge → `global/` the first time; this project's architecture, deployment, domain rules, data quirks, repo conventions → `projects/<p>/`; unsure → `projects/<p>/`; reflex rules → `rules/<slug>.md` plus an `@<slug>.md` line in `rules/INDEX.md`. Before writing: search for the same subject, read the target index and related pages, add only the delta, update `description` and the index line. Rewrite machine-specific paths (repo-relative, `~/…`, `<user>`; see SCHEMA).
4. **Promote timing**: design patterns and trade-offs stay in the project page until a second project needs them (or it closes); then extract a `global/` page under `global/index_architecture.md`; the project page keeps a one-line summary + link.
5. **Harvest** the auto memory — only when the project is migrated (section 2).
6. **Log, commit, remind, report** (section 4).

Not migrated → skip harvest; the report says the project is not migrated yet, lists the `projects/*` folders and says: if one is this project (new machine, another repo), say 'attach <p>'.

## 2. Harvest (migrated projects only)

Candidates in the current auto-memory dir (not `MEMORY.md`, not stubs; type = `metadata.type`, else top-level `type:`):
- every file of type feedback, reference or user;
- type project: not a stub, and either modified (`date -r '<file>' +%F`) on or after the last `## [YYYY-MM-DD] harvest | <p>` date in `log.md` or not containing `→ [[k:`; only if you judge it knowledge (cost rule: reference.md). A **full harvest** (migrate, attach, close) reads every project-typed file.

Each candidate gets exactly one outcome (step-by-step in reference.md — follow it):

| Content | KB | Auto-memory file | Its `MEMORY.md` line |
|---|---|---|---|
| always-on directive (applies in every situation; precedence over duplicate and all knowledge) | any project: a rule if the rules import loads (ask first); this project only, or declined: a `- ` line in `projects/<p>/always-on.md` | copy-and-verify, then `> Moved: [[k:rules/<slug>]]` or `> Moved: [[k:projects/<p>/always-on]]` | `- always-on rule → [[k:rules/<slug>]] (omk-harvested)` or `- always-on (this project) → [[k:projects/<p>/always-on]] (omk-harvested)` |
| all knowledge | progress-free (reference.md) into the page that covers it, new or existing, in `projects/<p>/` or `global/` | `> Moved: [[k:<that page>]]` | `- <trigger> → [[k:…]] (omk-harvested)` — trigger only, no conclusion |
| progress + knowledge | write the knowledge part | keep the progress; a non-leading line `→ [[k:…]]`; frontmatter type → `project` | stays a progress line, no `(omk-harvested)` |
| duplicate | — | `> Moved: [[k:<existing page>]]` or `> Moved: [[g:<slug>]]` | like "all knowledge" |
| obsolete / not worth keeping (no KB page links it) | the backup only | `> Moved: [[k:<backup path without .md>]]` | `- <trigger> → [[k:<backup path without .md>]] (omk-harvested)` (or ask the user) |

- New KB pages get `verified` from the original's `metadata.modified`, else its modification date read **before** you change it; `evidence` = the SCHEMA's inferred value unless the content shows it was tested or documented. Add an index line for each new page (its sub-index or `projects/<p>/index.md`).
- Always-on steps, more outcomes (progress only, redirect stub, `⚠` lines in `MEMORY.md`), which `MEMORY.md` lines to rewrite, marker edge cases, large harvests: reference.md.
- Copy-and-verify before every outcome that changes an auto-memory file (one call per batch; prints each verified `_retired/harvested/…` path; a file without one → stop, file untouched, report):
  ```bash
  OMK_KNOWLEDGE_DIR='${user_config.knowledge_dir}' bash "${CLAUDE_PLUGIN_ROOT}/scripts/harvest-copy.sh" '<auto-memory dir>/<file>' …
  ```
- After writing the KB page, before stubbing (mixed: after the auto-memory edit, plus that file; always-on: `--spans-only`); exit 1 or 3 (not success) → reference.md step 3b:
  ```bash
  bash "${CLAUDE_PLUGIN_ROOT}/scripts/check-move.sh" '<backup path>' '<KB page>' …
  ```
- No `MEMORY.md` line → none added.

Unclear split → list the files, ask. After **every** `MEMORY.md` write, re-check the marker line; restore it if lost or changed.

## 3. Modes (only on explicit request)

Steps for each mode: modes.md.
- **migrate this project**: a full harvest into a new `projects/<p>/` (`## Projects` line, marker, first `harvest` log entry). If `projects/<p>/` already exists, stop: this is **attach <p>**.
- **attach <p>**: an existing `projects/<p>/`: marker, full harvest.
- **make X a global rule / change X / drop X** (always-on).
- **close this project** (project ended, repo archived or deleted). Precondition: not migrated → migrate this project first; migrated → run a full harvest first.

## 4. Log, commit, remind, report

Append to `log.md` (one entry per action):

```
## [YYYY-MM-DD] distill | <topic>
- added global/<slug>; updated projects/<p>/<slug> (<what>)
## [YYYY-MM-DD] harvest | <p>
- <n> moved, <n> mixed, <n> duplicate, <n> retired, <n> always-on
```

Commit every KB file you wrote, including `_retired/harvested/` copies and `log.md` (auto memory is outside the KB: never pass it). KB-relative paths, exact on-disk case; a move passes the old and the new path:

```bash
OMK_KNOWLEDGE_DIR='${user_config.knowledge_dir}' bash "${CLAUDE_PLUGIN_ROOT}/scripts/commit.sh" 'distill: <topic>' log.md global/<slug>.md projects/<p>/<slug>.md
```

- Message single-quoted, no `'` inside, no AI attribution or session links.
- exit 0 committed; exit 3 nothing to commit = success (another session committed your change along); exit 4 lock held → report, retry later (inside handoff: report and continue); exit 2 bad path → fix; exit 1 → report stderr.

Lint reminder: count `## [….] distill |` entries in `log.md` after the latest `## [….] lint |` entry. If the count reaches `'${user_config.lint_remind_after_distills}'` (literal placeholder → 10), or the last lint is over a month old, suggest `oh-my-knowledge:lint`.

Report: pages written, promotions, harvest counts, questions, the not-migrated hint, the always-on promote hint.

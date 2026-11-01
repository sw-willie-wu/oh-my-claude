---
name: distill
description: Use to distill this session's durable knowledge (decisions and reasons, pitfalls, conventions, root causes) into the knowledge base and to harvest the project's auto memory; handoff runs it at the end. Also for "migrate this project", "attach <p>", "close this project". 蒸餾 / 寫進知識庫 / 遷移這個專案 / 接上 <p> / 專案結案.
---

# Distill into the knowledge base

`<knowledge_dir>/SCHEMA.md` is the authority for every writing rule. Read it first. `<knowledge_dir>` is the folder in the session-start note ("Knowledge base: …"). Pages via Read/Write/Edit; history only via `commit.sh`. Write knowledge in the user's language. Detailed harvest and mode procedures: [reference.md](reference.md).

## 0. Current project

```bash
OMK_KNOWLEDGE_DIR='${user_config.knowledge_dir}' OMK_AUTO_MEMORY_DIR='<auto-memory dir>' bash "${CLAUDE_PLUGIN_ROOT}/scripts/search.sh" omk-project
```

Exit 2 naming `knowledge_dir` or "knowledge base not found": tell the user to run `/oh-my-knowledge:setup` first and skip the distill.

`<auto-memory dir>` = the auto memory directory stated in this session's system prompt (leave out the `OMK_AUTO_MEMORY_DIR=…` assignment if none is visible). Read `== project: <p>` (migrated: its `MEMORY.md` has exactly one valid marker line `- Knowledge base project: [[k:projects/<p>/index]] (omk-project)`) or `== project: (not migrated)`, and `== auto memory: <dir>`.

## 1. Steps

1. **Inventory** this session: decisions + reasons, pitfalls, conventions, bug root causes. Drop pure process and what the KB already has. Repo-documented details are not copied; decisions and reasons are.
2. **Digest** `inbox.md` lines and `> ⚠ UNVERIFIED` lines: check each, then rewrite the page or remove the flag; remove processed inbox lines.
3. **Write by layer** (SCHEMA layering): tool/platform/environment knowledge → `global/` the first time; this project's architecture, deployment, domain rules, data quirks, repo conventions → `projects/<p>/`; unsure → `projects/<p>/`; reflex rules → `rules/<slug>.md` plus an `@<slug>.md` line in `rules/INDEX.md`. Before writing: search for the same subject, read the target index and related pages, add only the delta, update `description` and the index line. Rewrite machine-specific paths (repo-relative, `~/…`, `<user>`; see SCHEMA).
4. **Promote timing**: design patterns and architecture trade-offs stay in the project page until a second project needs them (or the project closes); then extract a `global/` page (problem, structure, trade-offs, users) under `global/index_architecture.md`; the project page keeps a one-line summary + link.
5. **Harvest** the auto memory — only when the project is migrated (section 2).
6. Rewriting a page's conclusion never requires touching auto memory (harvest lines carry no conclusion).
7. **Log, commit, remind, report** (section 4).

Not migrated → skip harvest; the report says: "This project is not migrated yet. If the knowledge base already has it (new machine, another repo of the same project), say 'attach <p>'." and lists the existing `projects/*` folders.

## 2. Harvest (migrated projects only)

Candidates in the current auto-memory dir (not `MEMORY.md`, not stubs; type = `metadata.type`, else top-level `type:`):
- every file of type feedback, reference or user;
- type project: only files modified (`date -r '<file>' +%F`) on or after the last `## [YYYY-MM-DD] harvest | <p>` date in `log.md`, and only if you judge the content to be knowledge. A **full harvest** (migrate, attach, close) has no date filter: look at every project-typed file.

Each candidate gets exactly one outcome (step-by-step in reference.md — follow it):

| Content | KB | Auto-memory file | Its `MEMORY.md` line |
|---|---|---|---|
| all knowledge | write into `projects/<p>/` or `global/`; copy the original byte-for-byte with `cp -p` into `<knowledge_dir>/_retired/harvested/YYYY-MM-DD/<encoded dir>/` and confirm with `cmp` | only after `cmp` succeeds: body becomes `> Moved: [[k:projects/<p>/<slug>]]` (or `[[k:global/<slug>]]`) | `- <trigger> → [[k:…]] (omk-harvested)` — trigger only, no conclusion |
| progress + knowledge | write the knowledge part | keep the progress; a non-leading line `→ [[k:…]]`; frontmatter type → `project` | stays a progress line, no `(omk-harvested)` |
| duplicate | — | `> Moved: [[k:<existing page>]]` or `> Moved: [[g:<slug>]]` | like "all knowledge" |
| obsolete / not worth keeping | `cp -p` + `cmp` into `_retired/harvested/` | `> Moved: [[k:_retired/harvested/YYYY-MM-DD/<encoded dir>/<name>]]` | `- <trigger> → [[k:_retired/harvested/…]] (omk-harvested)` (or ask the user) |

- New KB pages get `verified` from the original's `metadata.modified`, else its modification date read **before** you change it (`date -r '<file>' +%F`); `evidence` = the SCHEMA's inferred value unless the content shows it was tested or documented. Add an index line for each new page (its sub-index or `projects/<p>/index.md`).
- A candidate with no `MEMORY.md` line gets none added.
- A copy that `cmp` reports as different → stop, leave the auto-memory file untouched, report.

Unclear split → list the files, ask. After **every** `MEMORY.md` write, re-check the marker line; restore it if lost or changed.

## 3. Modes (only on explicit request)

- **migrate this project**: a full harvest. If `projects/<p>/` already exists, stop: this is **attach <p>**, never overwrite its index. Otherwise first create `projects/<p>/index.md`, add `- [[k:projects/<p>/index]] — <one sentence>` under `## Projects` in `index.md` only if absent, and write the marker line into the current `MEMORY.md` (placement: reference.md, "Marker line placement"). Non-git project: also mark each existing subdirectory auto-memory dir, after the user confirms the list. Large projects go in batches, one commit per batch. End with the first `harvest` log entry.
- **attach <p>**: the user names an existing `projects/<p>/`. No marker yet: write the marker line (same placement). An invalid marker (it names a missing project): after the user confirms, replace that line; never add a second marker. Then run a full harvest of the current auto-memory dir and add a `harvest` log entry.
- **close this project** (the user says the project ended or the repo will be archived or deleted). Precondition: if the project is not migrated, run migrate this project first; if it is migrated, run a full harvest first. Keep the marker line and the `## Projects` entry. Then follow reference.md: promote reusable parts to `global/`, make every project page readable without the repo, put `Closed: YYYY-MM-DD` in `projects/<p>/index.md`, log `distill`.

## 4. Log, commit, remind, report

Append to `log.md` (one entry per action):

```
## [YYYY-MM-DD] distill | <topic>
- added global/<slug>; updated projects/<p>/<slug> (<what>)
## [YYYY-MM-DD] harvest | <p>
- <n> moved, <n> mixed, <n> duplicate, <n> retired
```

Commit every KB file you wrote, including `_retired/harvested/` copies and `log.md` (auto memory is outside the KB: never pass it). KB-relative paths, exact on-disk case; a move passes the old and the new path:

```bash
OMK_KNOWLEDGE_DIR='${user_config.knowledge_dir}' bash "${CLAUDE_PLUGIN_ROOT}/scripts/commit.sh" 'distill: <topic>' log.md global/<slug>.md projects/<p>/<slug>.md
```

- Message single-quoted, no `'` inside, no AI attribution or session links.
- exit 0 committed; exit 3 nothing to commit = success (another session committed your change along; a same-file uncommitted change of another session is committed together with yours); exit 4 lock held → report, retry later (inside handoff: report and continue); exit 2 bad path → fix; exit 1 → report stderr.

Lint reminder: count `## [….] distill |` entries in `log.md` after the latest `## [….] lint |` entry. If the count reaches `'${user_config.lint_remind_after_distills}'` (literal placeholder → 10), or the last lint is over a month old, suggest `oh-my-knowledge:lint`.

Report: pages written, promotions, harvest counts, questions, the not-migrated hint.

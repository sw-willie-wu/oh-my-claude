# SCHEMA — how this knowledge base is maintained

This file is the maintenance contract for the knowledge base (KB). The plugin ships this default; you may replace it with your own (for example in your own language). Skills read it before writing.

## Layout

```
SCHEMA.md      this file
index.md       router: sub-indexes, project list, maintenance status
log.md         append-only timeline
inbox.md       leads found while looking things up, waiting for distill
rules/         rules to follow without being asked; rules/INDEX.md @-imports each one
global/        cross-project knowledge, consulted on demand (index_<topic>.md + topic pages)
projects/<p>/  knowledge of a migrated project (index.md + topic pages)
lint/          lint-YYYY-MM-DD.md reports
_retired/YYYY-MM-DD/  retired files + REPORT.md
```

## Where progress and knowledge go

- Project progress lives only in the project's auto memory. Durable knowledge lives only here. Never keep two writable copies of the same knowledge.

## Writing rules

1. Index lines are at most `max_index_line_chars` characters (default 200; characters, not bytes), shaped "trigger situation -> one-sentence conclusion -> link".
2. Corrections rewrite in place, new conclusion first. History is one trailing sentence ("once misjudged X because Y"). No stacked corrections, no relative-position references ("above", "the previous section").
3. One bullet, one fact. When a topic changes, update its frontmatter `description`.
4. No machine-specific paths in pages: no real-user home directories (`C:\Users\<name>\...`, `/home/<name>/...`), no location of local repos or data. Write repo-relative paths (`src/x.py`), tool-standard locations as `~/...`, and `<user>` as placeholder when the knowledge is about path formats themselves. Pages only; `lint/` and `_retired/` are exempt. Writers obey this; lint does not check it.
5. Topic pages and sub-indexes are at most `max_file_kb` KB (default 8). Split when larger; the original slug stays with the larger half.
6. Slugs never get renamed.
7. Layering. Ask: "in a completely unrelated project, would this still apply?" Yes (tool/platform/environment behaviour and pitfalls, clearly generic practice, work preferences) -> `global/` the first time. No (this project's architecture decisions, deployment topology, customer/domain rules, data quirks, repo conventions) -> `projects/<p>/`. When unsure -> `projects/<p>/` (promote later). Rules to follow reflexively -> `rules/`.
8. Design patterns and architecture trade-offs are the exception: write them in the project page first; promote to `global/` only when a second project needs them (or at project close-out). A promoted page states the problem, structure, trade-offs and which projects use it; project pages keep only their differences and link to it. Promoted design trade-offs hang under the `global/index_architecture.md` sub-index.
9. When one subject has both a general mechanism and a project-specific application, split: mechanism in `global/`, the project's application in `projects/<p>/` linking to the global page.
10. System design: the full detail (interfaces, flows, diagrams) stays in the project repo; the project page must still stand alone if the repo disappears: one line per decision "chose X -> because Y -> did not choose Z because W", plus limits discovered while building. Repo links are only "full version (may vanish)".
11. Do not use tier codes such as T0/T1/T2.

## Projects

A repo belongs to a KB project through one marker line in that repo's auto memory `MEMORY.md`, matched as a whole line anywhere in the file:

```
- Knowledge base project: [[k:projects/<p>/index]] (omk-project)
```

(regex `^- Knowledge base project: \[\[k:projects/([^/\]]+)/index\]\] \(omk-project\)\r?$`.) The status section is the block owned by handoff: from the status section heading (for example `## ⚡ 現況`) through the end of its completed-items block. The marker goes after the status section with a blank line before it, and must be within the first 200 lines (only those load at session start). When there is no status section yet, the marker goes at the top of the file and handoff later creates the status section above it. One `MEMORY.md` points to one project; `<p>` must exist as `projects/<p>/`, otherwise the repo counts as not migrated. Several repos of one project each carry a line to the same `<p>`. `index.md` lists projects as `- [[k:projects/<p>/index]] — <description>`, without paths. Writers re-check the marker after every write of `MEMORY.md` and restore it if missing or changed.

## Links and slugs

- A slug is unique within its folder (`global/`, or one `projects/<p>/`). Inside the KB, `[[slug]]` resolves in the same folder first, then `global/`.
- From outside the KB (auto memory, CLAUDE.md) and for cross-project links use only: `[[g:slug]]` = `<kb>/global/<slug>.md` and `[[k:<relpath>]]` = `<kb>/<relpath>.md` (for example `[[k:projects/p0001/deploy-prod]]`). Never an absolute path.
- A project slug equal to a global slug is a hint, not an error.

## Frontmatter

```yaml
---
name: <slug>
description: <trigger keywords + one-sentence scope>
metadata:
  type: reference | feedback | user | project
  verified: YYYY-MM-DD        # last confirmed still true
  evidence: tested | documented | inferred
---
```

Read the type from `metadata.type`, else from a top-level `type:` (auto memory uses both). To change a type, edit the key that exists; never add a second. Meta files need no frontmatter: `SCHEMA.md`, `index.md`, `log.md`, `inbox.md`, every `index_*.md`, `rules/INDEX.md`, `_retired/**`, `lint/**`.

## Markers

- Harvested auto-memory entry: `(omk-harvested)`.
- Always-on directive kept in auto memory: frontmatter `omk: always-on` (this project only) or `omk: always-on-declined`; harvest and lint skip the file.
- Unverified claim: a line `> ⚠ UNVERIFIED (YYYY-MM-DD): <what is unconfirmed>`.
- Stub (a moved page): after the frontmatter the body (blank lines ignored) contains only `> Moved: ` lines whose targets are comma-separated `[[slug]]`, `[[g:slug]]` or `[[k:<relpath>]]`.

## Rules take effect through import

Rule bodies live in `rules/<slug>.md`; `rules/INDEX.md` imports each with one `@<slug>.md` per line (relative path, relative to INDEX.md). Rule bodies reference other knowledge with `[[g:]]`/`[[k:]]` only. Your `~/.claude/CLAUDE.md` needs the single line `@<kb>/rules/INDEX.md`. Adding a rule means adding its import line.

## log.md

Append only, one entry per action:

```
## [YYYY-MM-DD] <action> | <title>
- what changed
```

Actions: `distill`, `lint`, `retire`, `migrate`, `fix`, `verify`, `flag`, `inbox`, `harvest`. The current maintenance status lives in the last section of `index.md`; the running history only in `log.md`.

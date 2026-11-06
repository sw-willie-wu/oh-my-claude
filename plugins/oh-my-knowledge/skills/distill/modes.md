# distill — modes

Companion to [SKILL.md](SKILL.md); harvest steps: [reference.md](reference.md). Commit with the SKILL.md section 4 command line.

## Always-on on request

**On request** (explicit wording only; no automatic re-offer of a declined rule exists)
- **make X a global rule**: run the rules-import check (import missing → offer setup step 6; the user declines → stop, nothing changes). If an existing rule already covers it, reuse that rule (no new file). Otherwise write `rules/<slug>.md` (frontmatter per SCHEMA, `verified` = the always-on page's `verified`; links only to `global/` pages, so drop a `[[k:projects/…]]` detail link or replace it with a `global/` page link) and add `@<slug>.md` to `rules/INDEX.md`. In both cases remove the line from `projects/<p>/always-on.md`, log `distill`, and commit the files that changed (`projects/<p>/always-on.md` and `log.md`, plus `rules/<slug>.md` and `rules/INDEX.md` when written).
- **change X** / **drop X**: edit or remove the line in `projects/<p>/always-on.md`; log and commit it like any page edit.
- Never delete the page: auto-memory stubs and `MEMORY.md` pointer lines on other machines link to it. When its last line is promoted the body becomes `> Moved: [[k:rules/<slug>]]`; when its last line is dropped the page stays with no `- ` lines. Either way nothing is injected, and the page's index line stays (lint may repoint it).

## migrate this project

1. Ask for the project name `<p>` (short slug: lower-case letters, digits, `-`).
2. If `<knowledge_dir>/projects/<p>/` already exists, stop: tell the user the KB already has this project and do **attach <p>** instead. Never overwrite an existing `index.md`. Otherwise create `projects/<p>/index.md`: a `# <title>` line, one sentence on the project, a `## Pages` list.
3. Add `- [[k:projects/<p>/index]] — <one sentence>` under `## Projects` in `index.md`, only if no line for `<p>` exists.
4. Write the marker line into the current `MEMORY.md` (placement above).
5. Non-git project (no `.git` in the working directory or any parent): list the sibling auto-memory dirs whose `<encoded dir>` starts with this project's `<encoded dir>` followed by `-` (sessions opened in subdirectories). The prefix also matches unrelated siblings (for example `C--src-demo-old` for `C--src-demo`): say so when you show the list, and let the user confirm or remove entries. Write the marker into each confirmed dir's `MEMORY.md` (create the file with just the marker line if absent).
6. Full harvest of every candidate. Split mixed files; list files you cannot classify and ask.
7. Large project: work in batches; after each batch append its entries and commit (`'distill: migrate <p> (batch <n>)'`). Each batch is a safe stopping point.
8. At the end append the first `## [YYYY-MM-DD] harvest | <p>` entry and commit.

Subdirectory auto-memory dirs created after the migration have no marker; use **attach <p>** there.

## attach <p>

For a new machine or another repo of an existing project. Check that `projects/<p>/` exists (else list `projects/*` and ask). No marker in `MEMORY.md`: write the marker line (placement above). An invalid marker (it names a project folder that does not exist, e.g. a stale `<p>`): show it, and after the user confirms, replace that line in place — never add a second marker. Then a full harvest of the current auto-memory dir, append `## [YYYY-MM-DD] harvest | <p>`, commit (`'distill: attach <p>'`). No new index page, no `## Projects` change.

## close this project

1. Precondition: not migrated → run **migrate this project**; migrated → run a full harvest.
2. Keep the marker line and the `## Projects` entry.
3. Promote every reusable part to `global/` (project close is the one exception to waiting for a second project).
4. Read every page in `projects/<p>/`: it must make sense with the repo gone. Add missing decision reasons; rewrite link-only pages into decision summaries ("chose X → because Y → not Z because W", plus limits found while building).
5. Put `Closed: YYYY-MM-DD` at the top of `projects/<p>/index.md`.
6. Log `## [YYYY-MM-DD] distill | <p> close` and commit (`'distill: close <p>'`).

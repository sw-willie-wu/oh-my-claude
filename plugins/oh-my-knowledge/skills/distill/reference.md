# distill — harvest and mode details

Companion to [SKILL.md](SKILL.md). `<knowledge_dir>/SCHEMA.md` stays the authority for writing rules.

## Terms

- **auto-memory dir**: `…/projects/<encoded dir>/memory/`. **`<encoded dir>`** is the name of the folder that contains `memory/` (the project path with every character outside `[A-Za-z0-9]` turned into `-`, for example `C--src-demo`).
- **stub**: a file whose body (after frontmatter, blank lines ignored) is only `> Moved: ` lines. Keep the frontmatter; replace the body with the single `> Moved: [[k:…]]` line.
- **type**: read `metadata.type`, else top-level `type:`. To change it, edit the key that exists; never add a second one.
- **modification date**: `date -r '<file>' +%F` (works with GNU and BSD date). No `harvest` entry for this project in `log.md` yet → treat every project-typed file as a candidate.

## Harvest outcomes, step by step

**All knowledge**
1. Before changing anything, record the original's date: its frontmatter `metadata.modified` if present, else `date -r '<file>' +%F`.
2. Copy the original byte-for-byte and verify the copy (never re-type it):

   ```bash
   mkdir -p '<knowledge_dir>/_retired/harvested/YYYY-MM-DD/<encoded dir>' && cp -p '<auto-memory dir>/<file>' '<knowledge_dir>/_retired/harvested/YYYY-MM-DD/<encoded dir>/' && cmp '<auto-memory dir>/<file>' '<knowledge_dir>/_retired/harvested/YYYY-MM-DD/<encoded dir>/<file>' && echo identical
   ```

   No `identical` → stop, leave the auto-memory file untouched, report.
3. Write the knowledge into `projects/<p>/<slug>.md` or `global/<slug>.md` (layering per SCHEMA; merge into an existing page when one covers the subject). Rewrite machine-specific paths. Frontmatter: `metadata.verified` = the date from step 1; `evidence` = the SCHEMA's inferred value unless the content shows it was tested or documented. A new page also gets an index line (its `global/index_<topic>.md` sub-index, or `projects/<p>/index.md`).
4. Replace the auto-memory file's body with `> Moved: [[k:projects/<p>/<slug>]]` (or `[[k:global/<slug>]]`).
5. If it has a `MEMORY.md` line, edit only that line into `- <trigger situation> → [[k:…]] (omk-harvested)`. Keep the trigger, drop the conclusion. Example: `- before touching production → [[k:projects/p0001/deploy-prod]] (omk-harvested)`. No line → add none.

**Progress + knowledge (mixed)**
1. Record the date (step 1 above), then move the knowledge part into the KB as in step 3.
2. In the auto-memory file, replace the moved part with one line `→ [[k:…]]`; it must not be the first body line (the file is not a stub and stays searchable).
3. Set its frontmatter type to `project`. Its `MEMORY.md` line keeps describing the progress; no `(omk-harvested)`.

**Duplicate** of an existing page: body → `> Moved: [[k:<existing relpath>]]` (or `[[g:<slug>]]`); rewrite its `MEMORY.md` line (if any) like "all knowledge".

**Obsolete / not worth keeping**: copy and verify as in step 2, body → `> Moved: [[k:_retired/harvested/YYYY-MM-DD/<encoded dir>/<name without .md>]]`; rewrite its `MEMORY.md` line (if any) trigger-only to `- <trigger> → [[k:_retired/harvested/YYYY-MM-DD/<encoded dir>/<name without .md>]] (omk-harvested)`, or ask the user. Never delete the line silently.

Links from other auto-memory files to a harvested file stay valid (the file still exists, as a stub).

## Marker line placement and protection

The marker line is exactly `- Knowledge base project: [[k:projects/<p>/index]] (omk-project)`.

- Status section = from the `## ⚡ 現況` heading (or its equivalent in the user's language) through the end of its 已完成 (done) block. The marker goes on the line after that block, with one blank line before it.
- No status section yet → the marker is the first line of the file (handoff later creates the status section above it).
- It must stay within the first 200 lines (only those load at session start).
- After every `MEMORY.md` write: Read the file, confirm the marker line is present once and unchanged; if not, put it back at its place.
- One `MEMORY.md` names one project; never add a second, different marker.

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

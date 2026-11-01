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

**Always-on directive** (feedback/user candidate whose content is an instruction that applies in every situation; takes precedence over duplicate and all knowledge)
1. Record the original's date first (step 1 above).
2. Rules-import check: `${CLAUDE_CONFIG_DIR:-~/.claude}/CLAUDE.md` (setup step 6's path) must contain a direct `@` import line that resolves to this knowledge base's `rules/INDEX.md`. Expand `~` and `~\`, turn `\` into `/`, compare with the path in the session-start "Knowledge base:" note, case-insensitive on Windows, treating `/c/…` and `C:/…` as the same path (Git Bash expands `~` to the `/c/` form). Nested imports are not followed.
3. Scope. **This project only** → **project always-on** (below). **Applies in any project** → step 4.
4. No import: offer setup step 6 first. Accepted → run setup step 6 (backup, append the import), then continue with step 5. If the user declines the import offer → project always-on.
5. Import present: if an existing rule already covers the directive, reuse it (no new rule file) and go to step 7 with that rule. Otherwise list the proposed `rules/<slug>.md` files (one short rule each; frontmatter per SCHEMA with `verified` from step 1, never today's date; link to a `global/` page only if details are needed) and ask the user. If the user declines the rule → project always-on.
6. Approved: write the rule and add the line `@<slug>.md` to `rules/INDEX.md`.
7. Copy-and-verify the original (all-knowledge step 2). Then body → `> Moved: [[k:rules/<slug>]]`, and rewrite its `MEMORY.md` line (if any) pointer-only: `- always-on rule → [[k:rules/<slug>]] (omk-harvested)`. The rule loads every session itself; no second copy of the directive.

**Project always-on** (the directive is for this project only, or the rule or the import was declined). The plugin injects `projects/<p>/always-on.md` into every session of this project, so the KB holds the only copy.
1. Record the original's date (step 1 above); copy-and-verify the original (all-knowledge step 2).
2. Edit `projects/<p>/always-on.md`. If a line with the same directive already exists, add nothing (dedupe). Otherwise append one line `- <directive>`: self-contained, in the user's language; links only as `[[g:…]]` / `[[k:…]]` (details can live on a normal project page, linked at the end of the line).
   - Page missing → create it: frontmatter per SCHEMA (`description`, `verified` = the date from step 1, `evidence` inferred unless the content shows otherwise) and add its index line to `projects/<p>/index.md`. Appending to an existing page does not change `verified`.
   - Stub page (its last line was promoted earlier, body is `> Moved: …`): replace the body with the new line and restore its index line in `projects/<p>/index.md` only if it was removed or repointed.
3. Stub the auto-memory file: body → `> Moved: [[k:projects/<p>/always-on]]`. Rewrite its `MEMORY.md` line (if any) pointer-only: `- always-on (this project) → [[k:projects/<p>/always-on]] (omk-harvested)`. With no line, add none. If that exact pointer line already exists in `MEMORY.md`, remove this file's line instead of adding a second one.
4. The report names each such directive and says how to make it global later: say 'make X a global rule' (in the user's language).

**On request** (explicit wording only; no automatic re-offer of a declined rule exists)
- **make X a global rule**: run the rules-import check (import missing → offer setup step 6; the user declines → stop, nothing changes). If an existing rule already covers it, reuse that rule (no new file). Otherwise write `rules/<slug>.md` (frontmatter per SCHEMA, `verified` = the always-on page's `verified`; links only to `global/` pages, so drop a `[[k:projects/…]]` detail link or replace it with a `global/` page link) and add `@<slug>.md` to `rules/INDEX.md`; remove the line from `projects/<p>/always-on.md`; log `distill`; commit `rules/<slug>.md`, `rules/INDEX.md`, `projects/<p>/always-on.md` and `log.md`.
- **change X** / **drop X**: edit or remove the line in `projects/<p>/always-on.md`; log and commit it like any page edit.
- Never delete the page: auto-memory stubs and `MEMORY.md` pointer lines on other machines link to it. When its last line is promoted the body becomes `> Moved: [[k:rules/<slug>]]`; when its last line is dropped the page stays with no `- ` lines. Either way nothing is injected, and the page's index line stays (lint may repoint it).

Copy-and-verify (`cp -p` + `cmp`, all-knowledge step 2) comes before each of the six outcomes that change an auto-memory file: all knowledge, mixed, duplicate, obsolete, always-on rule, project always-on. A mismatch stops that file.

In the harvest log line, `<n> always-on` counts the rule outcomes (a new or a reused rule) plus the project always-on outcomes handled in this harvest.

**Progress + knowledge (mixed)**
1. Record the date (step 1 above) and copy-and-verify the original (step 2 above), then move the knowledge part into the KB as in step 3.
2. In the auto-memory file, replace the moved part with one line `→ [[k:…]]`; it must not be the first body line (the file is not a stub and stays searchable).
3. Set its frontmatter type to `project`. Its `MEMORY.md` line keeps describing the progress; no `(omk-harvested)`.

**Duplicate** of an existing page: copy-and-verify first (step 2 above), then body → `> Moved: [[k:<existing relpath>]]` (or `[[g:<slug>]]`); rewrite its `MEMORY.md` line (if any) like "all knowledge".

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

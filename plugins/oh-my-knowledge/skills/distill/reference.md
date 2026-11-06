# distill — harvest and mode details

Companion to [SKILL.md](SKILL.md). `<knowledge_dir>/SCHEMA.md` stays the authority for writing rules (except the status section, below).

## Terms

- **auto-memory dir**: `…/projects/<encoded dir>/memory/`. **`<encoded dir>`** is the name of the folder that contains `memory/` (the project path with every character outside `[A-Za-z0-9]` turned into `-`, for example `C--src-demo`). **`<backup dir>`**: `<encoded dir>` up to 60 characters; longer → its last 51 characters (leading `-` removed), `-`, 8 hex digits of its `cksum`. `harvest-copy.sh` computes it; never by hand.
- **stub**: a file whose body (after frontmatter, blank lines ignored) is only `> Moved: ` lines. Keep the frontmatter; replace the body with the single `> Moved: [[k:…]]` line.
- **type**: read `metadata.type`, else top-level `type:`. To change it, edit the key that exists; never add a second one.
- **modification date**: `date -r '<file>' +%F` (works with GNU and BSD date). No `harvest` entry for this project in `log.md` yet → treat every project-typed file as a candidate.

## Status section

This overrides any status-section wording in `SCHEMA.md`.

- Status heading: the first line starting `## ⚡`. Done heading: the next `## ` heading containing 已完成 (or its translation), above the marker line.
- A block's body starts at the first non-blank line below its heading and ends before the next blank line or heading, or at the end of the file.
- The status section is exactly the `## ⚡` block and the done block, with their headings. Content between them is outside the status section.
- Harvest never changes a status-section line.
- Index-shaped line: a `- ` line linking an auto-memory file, or an `(omk-harvested)` pointer line. A candidate's index line is index-shaped, outside the status section, links the candidate once (`(<file>.md)`, `[[<file>]]` or `[[<file>.md]]`) and links no other auto-memory file.
- Pointer outcomes (all knowledge, duplicate, obsolete, redirect stub, both always-on) rewrite each such line whole into the pointer. For mixed and progress-only files the lines stay unchanged. Non-qualifying lines that link the candidate stay unchanged and are reported.
- Pointer dedupe: each `(omk-harvested)` line text appears at most once outside the status section; keep the first.

## Harvest outcomes, step by step

**No progress in the KB** (before every KB write): never write the current state of our own open work — open, pending, unmerged or to-do items, branch, PR or MR state. Provenance and tool limits stay. Such content makes the file mixed.

**All knowledge**
1. Before changing anything, record the original's date: its frontmatter `metadata.modified` if present, else `date -r '<file>' +%F`.
2. Copy and verify the original with the SKILL.md copy-and-verify command line (`harvest-copy.sh`; never re-type the file). Use the backup path it prints (a changed file backed up earlier the same day gets `<name>.2.md`, …). No path printed → stop, leave the auto-memory file untouched, report.
3. Run the **No progress in the KB** check first. Rewrite links only outside inline code and fenced blocks; text inside backticks or a fence is copied byte for byte (a `[[` there is literal). Never link into `[[k:_retired/…]]`. Write the knowledge into `projects/<p>/<slug>.md` or `global/<slug>.md` (layering per SCHEMA; merge into an existing page when one covers the subject). Rewrite machine-specific paths. Frontmatter: `metadata.verified` = the date from step 1; `evidence` = the SCHEMA's inferred value unless the content shows it was tested or documented. A new page also gets an index line (its `global/index_<topic>.md` sub-index, or `projects/<p>/index.md`).
3b. Run the SKILL.md `check-move.sh` command line (original = the backup path). Exit 1 → read each `missing` item: restore it, or confirm it was reworded or dropped on purpose (merge delta, path rewrite) and name it in the report. Exit 3 → read both; continue only if the shrink is intended.
4. Replace the auto-memory file's body with `> Moved: [[k:<that page>]]`: the page that received the content, new or existing (`[[g:<slug>]]` for a global page also works).
5. Rewrite its index lines (see Status section) into `- <trigger situation> → [[k:…]] (omk-harvested)`. Keep the trigger, drop the conclusion. Example: `- before touching production → [[k:projects/p0001/deploy-prod]] (omk-harvested)`. No line → add none.

**Always-on directive** (feedback/user candidate whose content is an instruction that applies in every situation; takes precedence over duplicate and all knowledge)
1. Record the original's date first (step 1 above).
2. Rules-import check: `${CLAUDE_CONFIG_DIR:-~/.claude}/CLAUDE.md` (setup step 6's path) must contain a direct `@` import line that resolves to this knowledge base's `rules/INDEX.md`. Expand `~` and `~\`, turn `\` into `/`, compare with the path in the session-start "Knowledge base:" note, case-insensitive on Windows, treating `/c/…` and `C:/…` as the same path (Git Bash expands `~` to the `/c/` form). Nested imports are not followed.
3. Scope. **This project only** → **project always-on** (below). **Applies in any project** → step 4.
4. No import: offer setup step 6 first. Accepted → run setup step 6 (backup, append the import), then continue with step 5. If the user declines the import offer → project always-on.
5. Import present: if an existing rule already covers the directive, reuse it (no new rule file) and go to step 7 with that rule. Otherwise list the proposed `rules/<slug>.md` files (one short rule each; frontmatter per SCHEMA with `verified` from step 1, never today's date; link to a `global/` page only if details are needed) and ask the user. If the user declines the rule → project always-on.
6. Approved: write the rule and add the line `@<slug>.md` to `rules/INDEX.md`.
7. Copy-and-verify the original (all-knowledge step 2), write the rule, run step 3b with `--spans-only`. Then body → `> Moved: [[k:rules/<slug>]]`, and rewrite its index lines (if any) pointer-only: `- always-on rule → [[k:rules/<slug>]] (omk-harvested)`. The rule loads every session itself; no second copy of the directive. Then the pointer dedupe (Status section) applies.

**Project always-on** (the directive is for this project only, or the rule or the import was declined). The plugin injects `projects/<p>/always-on.md` into every session of this project, so the KB holds the only copy.
1. Record the original's date (step 1 above); copy-and-verify the original (all-knowledge step 2).
2. Edit `projects/<p>/always-on.md`. If a line with the same directive already exists, add nothing (dedupe). Otherwise append one line `- <directive>`: self-contained, in the user's language; links only as `[[g:…]]` / `[[k:…]]` (details can live on a normal project page, linked at the end of the line).
   - Page missing → create it: frontmatter per SCHEMA (`description`, `verified` = the date from step 1, `evidence` inferred unless the content shows otherwise) and add its index line to `projects/<p>/index.md`. Appending to an existing page does not change `verified`.
   - Stub page (its last line was promoted earlier, body is `> Moved: …`): replace the body with the new line and restore its index line in `projects/<p>/index.md` only if it was removed or repointed.
3. Run step 3b with `--spans-only`, then stub the auto-memory file: body → `> Moved: [[k:projects/<p>/always-on]]`. Rewrite its index lines (if any) pointer-only: `- always-on (this project) → [[k:projects/<p>/always-on]] (omk-harvested)`. With no line, add none. If that exact pointer line already exists in `MEMORY.md`, remove this file's line instead of adding a second one. The general pointer dedupe (Status section) also applies.
4. The report names each such directive and says how to make it global later: say 'make X a global rule' (in the user's language).

Copy-and-verify (`harvest-copy.sh`, all-knowledge step 2) comes before each of the seven outcomes that change an auto-memory file: all knowledge, mixed, duplicate, obsolete, always-on rule, project always-on, redirect stub. A mismatch stops that file.

In the harvest log line, `<n> always-on` counts the rule outcomes (a new or a reused rule) plus the project always-on outcomes handled in this harvest.

**Progress + knowledge (mixed)**
1. Record the date (step 1 above) and copy-and-verify the original (step 2 above), then move the knowledge part into the KB as in step 3.
2. In the auto-memory file, replace the moved part with one line `→ [[k:…]]`; it must not be the first body line (the file is not a stub and stays searchable). Then run step 3b with the edited auto-memory file as an extra target.
3. Set its frontmatter type to `project`. Its `MEMORY.md` line keeps describing the progress; no `(omk-harvested)`.

**Duplicate** of an existing page: copy-and-verify first (step 2 above), then body → `> Moved: [[k:<existing relpath>]]` (or `[[g:<slug>]]`); rewrite its index lines (if any) like "all knowledge".

**Obsolete / not worth keeping**: first Grep (fixed strings, `files_with_matches`) `[[<name>]]`, `[[<name>.md]]`, `(<name>.md)`, `/<name>]]` over `rules/ global/ projects/ index.md` and this harvest's other candidates; a page that stays links it → not obsolete: move it as all knowledge, or rewrite that text first. Then copy and verify as in step 2, body → `> Moved: [[k:<printed backup path without .md>]]`; rewrite its index lines (if any) trigger-only to `- <trigger> → [[k:<same path>]] (omk-harvested)`, or ask the user. Never delete the line silently.

Links from other auto-memory files to a harvested file stay valid (the file still exists, as a stub).

## More outcomes

- **Progress only** (history log, live backlog, status, to-do): file and lines unchanged.
- **A redirect stub** (body only points elsewhere, not in `> Moved:` form): copy-and-verify, then `> Moved: [[k:<final target>]]`; its index lines point there. Final target = the KB page holding the content after this harvest (follow auto-memory redirects, harvest each target first). A cycle → ask the user. Chain ends at a progress file or a mixed file → file and lines unchanged, report it. Chain ends outside the KB → obsolete. Redirect stubs count as duplicate in the log line.
- **Directives only in `MEMORY.md`**: a line outside the status section starting with `⚠` (after an optional `- ` or `> `), linking no auto-memory file, judged an always-on directive, takes that outcome (rule, ask first; or project always-on). 1. Write each directive verbatim as a `- ` line in its target (skip if present). 2. Read the target back; confirm each line is unchanged. 3. Per distinct target, replace its first moved line with the pointer line; delete the other moved lines. When a pointer already exists, also delete the first moved line. No file, so no copy-and-verify.

## Harvest candidates

- List in one pass: `find '<dir>' -maxdepth 1 -name '*.md' -newermt '<last harvest date>'`, plus Glob `*.md` minus the files containing `→ [[k:` (Grep `→ \[\[k:`, `files_with_matches`; never split); drop stubs. Or one python run; never a per-file shell loop.
- Files modified since the last harvest: read whole. Older ones: judged from `description` and their index line, opened only if those suggest knowledge. Progress-only files are re-judged so on every harvest.

## Marker line placement and protection

The marker line is exactly `- Knowledge base project: [[k:projects/<p>/index]] (omk-project)`.

- The marker goes after the done block, or after the `## ⚡` block without one (Status section): blank line, marker, blank line. Status section at the end of the file: append a blank line and the marker. A list after the done block stays after the marker; content between the blocks is not moved.
- No status section yet → the marker is the first line of the file (handoff later creates the status section above it).
- It must stay within the first 200 lines (only those load at session start).
- After every `MEMORY.md` write: Read the file, confirm the marker line is present once and unchanged; if not, put it back at its place.
- One `MEMORY.md` names one project; never add a second, different marker.

## Large harvests (more than 30 candidates)

- Batches of at most 30 files; log and commit after each.
- Subagents get disjoint file lists and unique scratch script names. Shared files (`index.md`, `log.md`, `projects/<p>/index.md`, `global/*`, `MEMORY.md`) are Edit-only, re-read before each Edit. Only the coordinator runs the commit.
- `commit.sh`: 600000 ms Bash timeout or background; exit 4 → retry.
- Python on Windows: run `harvest-copy.sh` (path from the SKILL.md command line) once per batch with `subprocess.run(["bash", <script>, *files], env={**os.environ, "OMK_KNOWLEDGE_DIR": <knowledge_dir>})` (list form, no `shell=True`); never reimplement the copy or the folder name.
- Split a page over `max_file_kb` per SCHEMA rule 5 before the commit.

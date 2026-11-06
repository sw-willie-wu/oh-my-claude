# lint — retire procedure

Companion to [SKILL.md](SKILL.md) section 6. Only after the user agrees. Never retire `projects/*/always-on.md` (other machines' stubs and pointer lines link to it).

1. Move the file to `_retired/YYYY-MM-DD/<same relative path>` (`mv`).
2. Append one line per file to `_retired/YYYY-MM-DD/REPORT.md`: path and reason.
3. Still referenced (inside the KB, or by `[[g:…]]` / `[[k:…]]` in auto memory or `CLAUDE.md`)? Leave a stub at the old path: `> Moved: [[k:<replacement>]]`.
4. Log `## [YYYY-MM-DD] retire | <slug>` and commit with the SKILL.md section 6 command line (old path, new path, `REPORT.md`, `log.md`).

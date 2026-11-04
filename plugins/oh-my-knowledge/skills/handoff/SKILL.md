---
name: handoff
description: Use at the end of a work session, before context runs out mid-project, when the automatic-handoff hook asks for it, or when the user says /handoff, "update memory", "更新 memory", "交接", or "下個 session 見". Updates only the progress section of this project's auto memory, then runs distill.
---

# Handoff — progress only, then distill

The next session is a weak model with a small context: it reads `MEMORY.md` at start-up and must act from the status section alone. Handoff owns only that section; knowledge goes through distill. `<knowledge_dir>/SCHEMA.md` is the writing-rules authority (marker line).

## 1. Find MEMORY.md

The current auto-memory dir is the one stated in this session's system prompt. If none is visible, run

```bash
OMK_KNOWLEDGE_DIR='${user_config.knowledge_dir}' bash "${CLAUDE_PLUGIN_ROOT}/scripts/search.sh" omk-project
```

from the working directory. Exit 2 naming `knowledge_dir` or "knowledge base not found": tell the user to run `/oh-my-knowledge:setup` first and skip the knowledge-base part (the status section is still updated; distill is skipped). Otherwise use its `== auto memory: <dir>` line (`(none)` → ask the user where this project's auto memory is). Read the whole `MEMORY.md`. Note the marker line `- Knowledge base project: [[k:projects/<p>/index]] (omk-project)` exactly, if there is one.

## 2. Rewrite the status section only

The status section is exactly two blocks: the `## ⚡ 現況（YYYY-MM-DD）` block and the 已完成 (done) block (next `##` containing 已完成 or its translation, above marker). A block's body starts at the first non-blank line below its heading and ends before the next blank line or heading (full rule: distill reference.md, "Status section"). Write heading and labels in the user's language (keep an existing heading's wording). Schema, at most 20 lines (plus kept lines, below), only work in flight:

```
## ⚡ 現況（YYYY-MM-DD）
- 🎯 Goal: <one sentence>
- git: <branch> @ <short hash>; uncommitted: <none | what>; unpushed: <commits ahead>
- Verification: <what is green | what is still pending, and who verifies>
- Next: ① ② ③ (directly executable actions, not wishes)
- Waiting on user: <decisions or actions needed; omit when none>
- Open issues: <one per line + pointer; omit when none>

## 已完成
- YYYY-MM-DD <one line> → <pointer>
```

- For the git line, check the project repository (the working directory's repository, never the knowledge base) now: current branch, HEAD, uncommitted changes, commits not pushed. Record what you see, not what you remember.
- Rewrite, do not append. Finished or merged items move to the done block, one line each plus pointer.
- Change nothing outside the two blocks: replace each block's old text with its own Edit, so every other line — the marker line and any content between the blocks included — stays byte-identical.
- No status section yet: insert it at the top of the file, before the marker line, followed by one blank line. No done block yet: insert one directly after the ⚡ block, one blank line between.
- Keep every existing line in either block that is not progress (only a pointer such as `- [Project status](project_status.md)`, or a standalone pitfall or directive) as it is; keep its position among the lines; never delete or reword it; not counted in the 20. A line under a schema label (goal, git, verification, next, waiting on user, open issues) or about a finished item is progress even when it holds a link or a directive; keep only lines that are neither.
- Do not add new conclusions or pitfalls (they belong to distill); no session-only codes.

Then Read the file again. If step 1 found a marker line: it must be present once, unchanged, after the status section with a blank line before it, within the first 200 lines. Restore it if lost or changed.

## 3. Distill

Run `oh-my-knowledge:distill` (Skill tool) for this session's knowledge and the harvest. A lock or commit problem is reported, not a reason to stop.

## 4. Mark the handoff

So the automatic handoff does not ask again until usage grows by `auto_handoff_repeat` points, write the highest usage seen (marker `handoff-<sid>` or usage `ctx-<sid>`; valid = 1–3 digits, at most 100; `0` if neither) into `handoff-<sid>` (skipped without a session id):

```bash
d="${OMC_STATE_DIR:-$HOME/.claude/oh-my-claude/state}"; sid='${CLAUDE_SESSION_ID}'
case "$sid" in ''|*'{'*) echo "no session id; marker skipped" ;; *)
  s="${sid//[^A-Za-z0-9_-]/_}"; best=0
  for f in "handoff-$s" "ctx-$s"; do
    v=""; IFS= read -r v 2>/dev/null < "$d/$f"; v="${v%$'\r'}"
    case "$f" in ctx-*) v="${v%% *}" ;; esac
    case "$v" in ''|*[!0-9]*|????*) continue ;; esac
    v=$((10#$v)); if [ "$v" -le 100 ] && [ "$v" -gt "$best" ]; then best=$v; fi
  done
  mkdir -p "$d" && printf '%s\n' "$best" > "$d/handoff-$s" && echo "marker written: $best" ;;
esac
```

## 5. Report

List what changed in `MEMORY.md`, what distill wrote and committed (or why not), anything waiting on the user. End: you can now `/clear` or `/compact`.

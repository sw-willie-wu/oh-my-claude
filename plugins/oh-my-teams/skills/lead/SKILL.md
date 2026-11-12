---
name: lead
description: Use when a feature or change is about to be delegated to subagents, when a spec or plan is about to be written, or when the user names a review level. Runs the flow with role agents, a review level and a converging review loop. 派工 / 審查等級 / 寫規格 / 寫計畫 / 子代理 / 審查迴圈.
---

# Lead: run the flow

You are the main session: you talk to the user and coordinate, and never write product code. Roles are the agents `oh-my-teams:spec`, `oh-my-teams:implementer`, `oh-my-teams:reviewer`, `oh-my-teams:qa`.

## When this applies

- The discussion workflow in use or the user decides whether a spec or plan is written, and where it goes. Do not add one and do not skip one.
- From the point of delegation you take over: these rules replace that workflow's own steps for writing, reviewing, executing and committing.
- A spec or plan is called for: follow "Spec and plan" below.
- Nothing written is called for (a direct request): there is no spec or plan stage. The request goes straight to the implementer. The level governs implementation only.

## Review level

Ask the user for the level once per feature, proposing one; skip if Settings gives a default. One level covers spec, plan and implementation.

| Level | Spec / plan, when one is written | Implementation review | QA | For |
|---|---|---|---|---|
| 0 none | Main session writes; no review | No reviewer | None; implementer's tests only | Small changes, experiments |
| 1 light | Main session writes; one review round | One round. Fix only what fails in normal use | None | Personal tools |
| 2 standard | Spec agent writes; reviewed until it passes | Until it passes. Fix failures and clear omissions | Once, on the finished feature | Ordinary features |
| 3 strict | Spec agent writes; reviewed until it passes | Until it passes. Edge cases and security problems too | Per task | Public products, money, user data |

- Never dispatch the spec agent or QA at levels 0–1.
- Pass `Level:` to every reviewer and QA dispatch. It is the only bar; do not raise it.

## Dispatching

Every dispatch carries `Task:`, `Scope:`, `Level:` (0–3). Add:

- spec agent: `Brief:`, with the headings `### Goal`, `### User decisions`, `### Constraints`, `### Out of scope`, `### Open points`, `### Target file`. When writing a plan, add `Plan-stage notes:` if any.
- implementer: `Tests:` (the tests for this task).
- reviewer: `Review target:` and `Round:`. From round 2 add `Previous findings:`.
- Pass a model override as `model` only as Settings says.

Spec and plan (a spec or plan is called for):
1. Level 0–1: write it yourself, to the path upstream named. Level 1: dispatch one reviewer round.
2. Level 2–3: dispatch the spec agent with the brief. Done = it returns `## Written`.
3. Level 2–3: review the spec with the loop below. Done = a round with no must-fix.
4. Take every `## Plan-stage notes` item from the spec review to the plan stage. They never cause a spec revision.
5. If a plan is called for, write it the same way (spec agent at 2–3), reviewed the same way.
6. Tell the user in a few sentences how you will build it. Wait for a yes.

Implementation, per plan task (a direct request is one task):
1. Dispatch the implementer. Done = tests pass and `## Not done` is `none` or dealt with.
2. Level 3: dispatch QA on the task.
3. Level 1–3: run the review loop on the change.
4. Commit (see Commits). Next task.
5. Level 2: dispatch QA once after the last task.

QA must-fix findings (levels 2 and 3): the implementer fixes them, the fix goes through the review loop, then commit.

Ask the user only at: the level question, judgment questions (batch them), the plan summary, a loop that is not converging, a blocked verdict only the user can resolve, the end. A role cannot ask the user; its `## Questions for the user` come to you. Settle what the discussion, code or a default settles; ask the rest. After the user answers, dispatch the writer again with the answers added under `### User decisions`.

## Review loop

A `blocked:` verdict from a reviewer or QA, at any level, is not a pass. Remove the cause and dispatch the same round again. If only the user can resolve it, ask the user. Commit nothing while a verdict is blocked.

Level 1: one reviewer round. Fix its must-fix. Do not review the fix again.

Levels 2–3:
1. Round 1: a full review of the target. Every round uses a fresh reviewer.
2. If the verdict is `fix needed`, fix every must-fix finding (spec or plan: the writer; code: the implementer). Then run the next round.
3. Before dispatching a fix, record the state. Project files: `git add` the reviewed change (staging only, no commit), so `git diff` afterwards shows only the fix. Spec or plan: keep a copy of the reviewed version in a temp directory and diff against it.
4. Round 2 and later: pass `Round:`, the fix diff as the review target, and `Previous findings:` (the previous round's must-fix lines, verbatim). The re-check covers the fix and what it can affect, not a full review.
5. Repeat until a round has none. That is done.
6. Every must-fix is labelled `pre-existing` or `from-fix`. Count the must-fix findings each round.
7. Compare each round's count with the previous round's. Two comparisons in a row without a decrease (two consecutive rounds): stop; dispatch no more fixes. 3→3→3 stops after round 3; 3→2→2 continues to round 4. Report to the user: the findings with their labels, a recommendation, and that the reviewed change is staged and uncommitted. If most are `from-fix`, recommend changing or removing the design that produces them, not patching. Offer "lower the level".
8. `## Below the bar` items: collect them once, for the final report as known limitations. They never re-enter the loop.
9. `## Plan-stage notes`: keep for the plan stage. Not must-fix.

## Knowledge

- Every role report begins with `## Knowledge lookup`. If one lacks it, note that in your summary to the user. It is not re-dispatched. Do the same if a report says `no knowledge base installed` while `oh-my-knowledge:lookup` is in your skill list.
- Collect every `## Lessons`.
- If the skill `oh-my-knowledge:lookup` is in your skill list, record each lesson as one inbox line through its write-back for "not in the knowledge base, solved it yourself": situation, conclusion, evidence. Call no other oh-my-knowledge skill; write to the knowledge base only this way.
- If it is not in the list, put the lessons in the final report.

## Commits

These rules cover the project repository only.
- Never commit on the default branch (the target of `origin/HEAD`, else `main` or `master`). If it is checked out, create `feature/<short-name>` first.
- Commit once per plan task, after that task's review passed (level 0: after its tests pass). Before committing, stage that task's files again so the fix is included; stage only them.
- Leave spec and plan files uncommitted for the user.
- Commit locally only: never push, merge, tag or release; merge decisions are the user's.
- Roles never commit.

The final report lists: what was built, commits, known limitations (`## Below the bar` items), unrecorded lessons, lookup notes.

## Settings

Settings are optional. Current values:

| Setting | Value |
|---|---|
| default level | '${user_config.default_level}' |
| spec model | '${user_config.spec_model}' |
| implementer model | '${user_config.implementer_model}' |
| reviewer model | '${user_config.reviewer_model}' |
| QA model | '${user_config.qa_model}' |
| spec folder | '${user_config.spec_dir}' |
| plan folder | '${user_config.plan_dir}' |

- A value is unset if it is empty, or if it still starts with a dollar sign and a brace (the placeholder was not filled in).
- Default level: if the value is `0`, `1`, `2` or `3`, use it and do not ask. Anything else (unset or outside 0–3): ask.
- Model values: if the value is exactly `sonnet`, `opus`, `haiku` or `fable`, pass it as `model` on every dispatch of that role. Anything else: leave `model` out and the agent uses its own default.
- Folders: use the value if set. If unset, use `docs/specs` for a spec and `docs/plans` for a plan. Only when no path is named.

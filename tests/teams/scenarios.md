# oh-my-teams: hand-run scenarios

These scenarios check behaviour that structural tests cannot: whether a weaker model follows the role and lead instructions. They are run by hand and are not part of `scripts/test.sh`.

## How to run

1. Make a throwaway project (a small git repo with a few files and a test command).
2. Install the plugin from a local marketplace: `/plugin marketplace add <path to this repository>`, then `/plugin install oh-my-teams@oh-my-claude` and `/reload-plugins`. If a marketplace named `oh-my-claude` is already added, remove it first (or use the installed plugin instead).
3. Weaker-model check: in the plugin settings set `spec_model`, `implementer_model`, `reviewer_model` and `qa_model` to `haiku`, and run the main session on `sonnet`. Leave `default_level` empty unless a scenario says otherwise.
4. Run each scenario in a fresh session. Run all of them whenever role or lead wording changes.
5. Record pass or fail for each by hand. A scenario passes only if every `Expected:` item happened and no `Fails if:` item did.

## S1: loop continues

Setup: a small repo with a pre-written, uncommitted change in the working tree: a `total(items)` helper that skips the last item (an off-by-one that gives a wrong sum for any normal list), with a test that only uses an empty list.
Prompt: "/oh-my-teams:lead level 2: run the review loop on the uncommitted change in the working tree" (no implementer first).
Expected: the first reviewer round returns `fix needed` with the bug as a `normal-use` must-fix; the implementer fixes it; a second reviewer round runs with `Round: 2`, the fix diff as the target and `Previous findings:`; the loop stops when a round has no must-fix.
Fails if: the lead stops after one round, never dispatches a second reviewer, reuses a reviewer, or the second round is a full review of the whole change.

## S2: bar respected

Setup: a pre-written, uncommitted function that reads the first line of a file. The file it reads exists and is non-empty in the setup, and the function works for it; its only flaws need a deliberately built input (for example a path containing a newline).
Prompt: "/oh-my-teams:lead level 1: review the uncommitted change in the working tree".
Expected: the reviewer's verdict is `pass`; the flaws appear once under `## Below the bar` and again in the final report as known limitations; no fix round.
Fails if: the flaws are listed under `## Findings`, a fix is dispatched, or a second review round runs.

## S3: spec stays spec-level

Setup: level 2. A short discussion that settles a small feature and says a spec is called for.
Prompt: discuss a feature such as "export the report as CSV", then say "write the spec and go".
Expected: the spec agent writes the spec; it has no file names, function names, step order or test lists; any plan-level remark from the reviewer appears under `## Plan-stage notes`, is passed to the plan stage, and the spec is not revised for it. The scenario passes even if the reviewer raises no such remark.
Fails if: the spec names files, functions, steps or tests; the lead dispatches a spec revision because of a plan-stage note; the main session writes the spec itself.

## S4: lookup with oh-my-knowledge present

Setup: oh-my-knowledge installed and set up. Add a knowledge page that answers a question the task needs (for example the project's required date format).
Prompt: a small task whose correct solution depends on that page, at level 2.
Expected: every role report begins with `## Knowledge lookup` naming that page; the work uses what the page says. This also confirms a plugin subagent can invoke `oh-my-knowledge:lookup`.
Fails if: a report lacks the section, says `nothing matched` or `no knowledge base installed` although the page exists, or the work ignores the page.

## S5: lookup with oh-my-knowledge absent

Setup: disable or uninstall oh-my-knowledge, then `/reload-plugins`.
Prompt: any small task at level 2.
Expected: each role report starts with `## Knowledge lookup` saying `no knowledge base installed`; the work completes; the lead raises no error.
Fails if: a role errors, pretends it searched, or leaves out the section.

## S6: light levels

Setup: two runs.
Prompt: run 1, level 0, "rename the variable `tmp` to `buffer` in one function". Run 2, level 1, a small feature.
Expected: level 0: no spec agent, no reviewer, no QA, one commit after the implementer's tests pass. Level 1: exactly one reviewer dispatch, its fixes are not reviewed again, no QA.
Fails if: any of these is dispatched at level 0, or a second reviewer, a QA run or a spec agent appears at level 1.

## S7: non-convergence

Setup: level 2. A change where each fix tends to create a new problem (for example a validation rule whose every patch exposes another input). If needed, instruct the reviewer in the prompt to report one new `from-fix` problem each round.
Prompt: "Add input validation for the upload name." Choose level 2.
Expected: after two comparisons in a row without a drop in the must-fix count, the lead stops; it lists the findings with their `pre-existing` or `from-fix` labels, says the reviewed change is staged and uncommitted, recommends changing or removing the design that produces them, and offers to lower the level.
Fails if: it keeps dispatching fixes, stops early after a single non-decrease, or does not offer to lower the level.

## S8: commits

Setup: the throwaway project on its default branch, with a remote configured. A plan with two tasks.
Prompt: "Implement this plan" at level 2.
Expected: a `feature/<name>` branch is created before the first commit; one commit per plan task, each with only that task's files, plus one more commit if QA required a fix after the last task; nothing is pushed, merged or tagged; spec and plan files stay uncommitted.
Fails if: a commit lands on the default branch, a task is split or combined into other commits, a push or tag happens, or the spec or plan is committed.

## S9: no written documents

Setup: level 2, a fresh session with no spec or plan.
Prompt: a direct request such as "add a `--quiet` flag to the CLI".
Expected: no spec or plan stage; the implementer is dispatched straight away; the level governs implementation only (reviewer and QA as the level says).
Fails if: the spec agent is dispatched, or the lead writes or asks for a spec or plan.

## S10: lessons

Setup: a task in which a role will report a lesson (for example the implementer hits a tool quirk and says so under `## Lessons`). Run once with oh-my-knowledge and once without.
Prompt: any task at level 2 that triggers the quirk.
Expected: with oh-my-knowledge, the lead records each lesson as one inbox line (situation, conclusion, evidence) through `oh-my-knowledge:lookup` and calls no other oh-my-knowledge skill; without it, the lessons are listed in the final report.
Fails if: the lead calls `oh-my-knowledge:distill` or another skill, writes to the knowledge base directly, or drops the lesson.

## S11: level 1 with a written spec

Setup: level 1. A discussion workflow that calls for a spec.
Prompt: discuss a small feature and say "write the spec and go", choose level 1.
Expected: the main session writes the spec; exactly one reviewer round; no re-review; no QA; the spec agent is not dispatched.
Fails if: the spec agent is dispatched, a second review round runs, or QA runs.

## S12: blocked verdict

Setup: the throwaway project with a small uncommitted change; the path named below does not exist.
Prompt: "/oh-my-teams:lead level 2: review the change in `src/does-not-exist.py`" (a path that is not in the project). Alternatively, let the implementer finish a task and delete the changed file before review starts.
Expected: the reviewer returns the verdict `blocked: <reason>`; the lead treats it as not a pass, commits nothing, and either removes the cause and dispatches the same round again or asks the user.
Fails if: the lead commits, counts the round as a pass, or moves on to the next task.

## S13: QA finding at level 2

Setup: a pre-written, uncommitted change in the working tree: a command whose default limit is meant to come from a config file, but the code never loads that file (it falls back to a hard-coded wrong default). Its tests pass explicit values, so they pass; only running the command for real shows the wrong default.
Prompt: "/oh-my-teams:lead level 2: review and finish the uncommitted change in the working tree".
Expected: review passes; then QA runs once on the finished feature and returns `fix needed` with the bug as a must-fix; the implementer fixes it; the fix goes through the review loop; then the commit.
Fails if: the QA finding is ignored, fixed without a review round, or the lead commits the fix straight away.

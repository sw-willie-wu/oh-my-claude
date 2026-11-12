# oh-my-teams

[← Back to README](../README.md)

Role agents and a lead skill for Claude Code. When you hand a feature to subagents, the main session becomes the lead: it asks how thorough the review should be, dispatches a spec writer, an implementer, a reviewer and a QA tester as needed, loops fixes and reviews until the reviewer is satisfied (or tells you it is not converging), and commits each finished task on a feature branch. Every role looks in your knowledge base before it starts, if you have one.

## Install

```
/plugin marketplace add sw-willie-wu/oh-my-claude
/plugin install oh-my-teams@oh-my-claude
/reload-plugins
```

All plugins in this marketplace update together on each release. No setup step is needed. To start, type `/oh-my-teams:lead <what to build>`, optionally with a level (for example `/oh-my-teams:lead level 2: add CSV export`). The skill also starts on its own when work is about to be delegated to subagents. oh-my-knowledge is optional (see [Knowledge base](#knowledge-base)).

## How it works

The `oh-my-teams:lead` skill triggers when a feature or change is about to be delegated to subagents, when a spec or plan is about to be written, or when you name a review level. You can also name it directly. From then on the main session only talks to you and coordinates; it writes no product code.

1. It asks for a review level once per feature (or uses your default).
2. If a spec or plan is being written, it handles that stage (see the table). Whether one is written at all is decided by your discussion workflow or by you; with a direct request there is no spec stage.
3. For each task the implementer builds it, QA and the reviewer check it according to the level, and the task is committed (at level 0 as soon as its tests pass; otherwise after its review passed).
4. It reports what was built, the commits, known limitations and anything it could not record.

It asks you questions only for: the level, judgment calls it cannot settle itself (batched), a short plan summary before building starts, a review loop that is not converging, a blocked verdict only you can resolve, and the end.

## Review levels

One level covers the spec, the plan and the implementation of a feature.

| Level | Spec / plan, when one is written | Implementation review | QA | For |
|---|---|---|---|---|
| 0 none | Main session writes; no review | No reviewer | None; implementer's tests only | Small changes, experiments |
| 1 light | Main session writes; one review round | One round. Fix only what fails in normal use | None | Personal tools |
| 2 standard | Spec agent writes; reviewed until it passes | Until it passes. Fix failures and clear omissions | Once, on the finished feature | Ordinary features |
| 3 strict | Spec agent writes; reviewed until it passes | Until it passes. Edge cases and security problems too | Per task | Public products, money, user data |

The level is the only bar. A reviewer or QA never holds the work to a higher one; anything below the bar is reported once as a known limitation and never goes back into the loop.

At levels 2 and 3 each review round uses a fresh reviewer. After the first round a reviewer checks only the fix and what it can affect, and labels each finding `pre-existing` or `from-fix`. If the number of must-fix findings does not drop for two comparisons in a row, the lead stops, shows you the labelled findings with a recommendation (usually to change the design that keeps producing them) and offers to lower the level. A `blocked:` verdict from a reviewer or QA is never treated as a pass.

## Roles

| Role | Default model | What it does |
|---|---|---|
| `oh-my-teams:spec` | opus | Writes a spec (what and why) or a plan (files, order, tests) from a brief. Levels 2-3 only. |
| `oh-my-teams:implementer` | sonnet | Builds one task and runs its tests. Does nothing beyond the task. |
| `oh-my-teams:reviewer` | opus | Reviews a spec, plan or change against the level's bar. Does not edit; has no edit tools. |
| `oh-my-teams:qa` | sonnet | Runs the finished work for real and checks that its tests can fail, using a throwaway copy. Levels 2-3 only. |

Roles cannot ask you questions; anything that needs your judgment comes back in their report and the lead asks. Roles never commit, push, merge or tag.

## Settings

Change them in the `/plugin` settings of oh-my-teams. Unset options use the defaults below.

| Key | Default | Meaning |
|---|---|---|
| `default_level` | empty | `0`-`3`: use this level without asking. Empty or anything else: ask once per feature. |
| `spec_model` | empty | Model for the spec agent: `sonnet`, `opus`, `haiku` or `fable`. Empty: the agent's default (`opus`). |
| `implementer_model` | empty | Same for the implementer (default `sonnet`). |
| `reviewer_model` | empty | Same for the reviewer (default `opus`). |
| `qa_model` | empty | Same for QA (default `sonnet`). |
| `spec_dir` | `docs/specs` | Where a spec is written when your workflow names no path. |
| `plan_dir` | `docs/plans` | Same for a plan. |

## Knowledge base

If [oh-my-knowledge](knowledge.md) is installed, every role starts by searching it for the task's key terms (`oh-my-knowledge:lookup`) and begins its report with a `## Knowledge lookup` section saying what it found. Without it the report says `no knowledge base installed` and the role works from built-in knowledge. Roles never write to the knowledge base. Each report ends with `## Lessons`; with oh-my-knowledge installed the lead records each lesson as one inbox line through the lookup skill's write-back, otherwise it lists them in the final report.

## Commits

These rules cover your project repository only.

- The lead never commits on the default branch; if it is checked out it creates `feature/<short-name>` first.
- One commit per plan task, after that task's review passed, containing only that task's files. At levels 2-3, a QA fix after the last task adds one more commit.
- Spec and plan files are left uncommitted for you.
- It never pushes, merges, tags or releases. Merge decisions are yours.

## Limitations

- "Does not edit" for the reviewer, QA and spec agent is an instruction, not a restriction: the reviewer and QA have no edit tools, but all three have a shell.
- No hooks: the rules are carried by the instructions and the tool lists of the roles, so a model that ignores instructions can break them.
- No frontend variant: nothing here reviews visual design or runs a browser.
- One working tree, one implementer at a time: no parallel implementers.
- Behaviour with weaker models is checked by hand (`tests/teams/scenarios.md`), not by the automated tests.

## License

[MIT](../LICENSE)

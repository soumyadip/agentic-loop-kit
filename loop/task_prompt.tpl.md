You are working in a fresh checkout on branch {{BRANCH}}, worktree of the project's main branch. You have no memory of any prior run — everything you need is on disk. Read it before writing anything.

Read, in order:

1. `{{PRINCIPLES_DOC}}` — working principles for this repo, if it exists.
2. The task file below — this is your entire scope. Do not expand it.
3. Any files the task file references under `docs/` or `specs/`.

## Task

{{TASK_BODY}}

## Rules

- Touch only what the task's "Scope" section says, plus tests for that scope. If finishing the task properly requires touching something outside that scope, stop, do not improvise, and write a file `loop/queue/in_progress/{{TASK_ID}}.NEEDS_INPUT.md` explaining exactly what's blocking you and why. That is a valid, complete outcome for this run — better than guessing.
- Practice TDD if `{{PRINCIPLES_DOC}}` calls for it: if this task changes application code, write or update a failing test first, then make it pass. The project's test command must exercise the behavior the acceptance criteria describe, not just compile. If the task is pure design/infra glue (an ADR update, a compose file, a shell script) rather than application code, honest verification (actually running it) substitutes for a unit test — say which category applies and why in your closing summary.
- If a prior attempt failed, its failure output is included below under "Previous attempt failed". Fix that specific failure; do not restart the task from scratch in a different shape unless the failure shows the previous approach was fundamentally wrong.
- Commit your work with `git commit` when you believe the acceptance criteria are met. One commit, message starting with `{{TASK_ID}}: `. Do not push, do not merge, do not touch branches other than the current one.
- Do not modify files under `loop/`, or any path this project always requires a human for (see `{{PRINCIPLES_DOC}}` / `LOOP_KIT_REQUIRE_HUMAN_REVIEW_PATHS` in `loop.config.sh`) — those are out of scope for any task that doesn't explicitly name them.
- When done, briefly state what you changed and why, referencing the acceptance criteria.

{{PREVIOUS_FAILURE_BLOCK}}

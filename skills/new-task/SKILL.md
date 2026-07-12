---
description: Scaffold a new loop/queue/pending/Txxx-<slug>.md task file with correct frontmatter (next task id, milestone validated against the project's roadmap doc, sensitive-path awareness). Use when adding new work to the loop's task queue.
argument-hint: [short description of the task]
---

Scaffold a new task for `loop/queue/pending/` for:

$ARGUMENTS

The actual scaffolding logic lives in `loop/new_task.sh`, not in this
skill — so contributors using other agentic tools can run it directly too.
Read `loop/README.md`'s "Adding tasks" section first if you haven't; it
covers the atomicity requirement (one PR-sized unit, not a whole feature)
and the `milestone:` field convention this script enforces.

## What to do

1. Figure out: a short kebab-case slug, which milestone this belongs to
   (must match a `## <milestone-id> — ...` heading in the roadmap doc
   configured via `LOOP_KIT_ROADMAP_DOC` in `loop/loop.config.sh` — skip
   this if that variable is unset/empty, meaning the project doesn't
   track milestones that way), and whether the task's scope will touch a
   sensitive path — check `SENSITIVE_PATTERN` in `loop/run.sh` (and
   `LOOP_KIT_SENSITIVE_PATTERN` in `loop/loop.config.sh` if set). If it
   touches any of those, `sensitive` must be `true` — the loop routes it
   to `blocked/` for human sign-off regardless of what the maker/checker
   conclude.
2. Run `loop/new_task.sh <slug> <milestone> <true|false> [depends_on,comma,separated]`.
   It refuses to run if the milestone id doesn't exist in the roadmap doc
   (when one is configured), and picks the next task id by scanning every
   `loop/queue/*/T*.md`, not just `pending/`.
3. Open the file it wrote and replace every `TODO:` — a fresh-context agent
   gets exactly this file as its entire scope, so under-specifying it here
   is the single most common way a loop task goes sideways. Look at 2-3
   recent files in `loop/queue/done/` for the level of specificity
   expected in "Why", "Scope", and "Acceptance criteria".
4. Leave it in `loop/queue/pending/` — do not move it or run the loop
   yourself unless asked to.

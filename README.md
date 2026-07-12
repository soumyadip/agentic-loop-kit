# agentic-loop-kit

A portable extraction of the maker/checker "loop" and three-model "council"
system originally built for the Entrepot Data Platform project. It runs a
queue of small, spec'd tasks through a maker CLI (Codex/Claude/Cursor),
gates each attempt behind a project-specific verify script, and hands
every diff to a *different* model to review before it can merge — so no
model ever grades its own homework. `council.sh` is the separate,
read-only counterpart: fan one design question out to three models in
parallel and synthesize their independent answers yourself.

Nothing here is Entrepot-specific machinery — it's bash + markdown
templates that shell out to CLIs already on your `$PATH`. The parts that
*were* project-specific (build/test commands, which paths are
governance-sensitive, which doc to validate milestones against) are now
config, filled in by `install.sh`.

## Prerequisites

The loop only orchestrates CLIs it doesn't ship — install and authenticate
whichever of these you intend to use as makers/checkers:

- [`codex`](https://github.com/openai/codex) — default maker, and reviewer for `maker: cursor` tasks
- [`claude`](https://claude.com/claude-code) — reviewer for `maker: codex` tasks, or maker for `maker: claude` tasks
- [`cursor-agent`](https://cursor.com/cli) — reviewer for `maker: claude` tasks, or maker for `maker: cursor` tasks
- [`opencode`](https://opencode.ai) — optional, only used by `council.sh`'s third seat

You don't need all four on day one. A queue where every task uses the
default `maker: codex` only needs `codex` and `claude` installed (maker
and its one reviewer); add the others as you start routing tasks to them.

Also needed: `python3` (template rendering, backoff-timestamp parsing),
`git` (worktrees — this is load-bearing, not optional), and `bash` 4+.

## Install into a project

```sh
./install.sh /path/to/your-repo
```

Run without flags against a terminal, it prompts for the five things that
are genuinely per-project (see below) with sensible defaults; pass
`--non-interactive` plus flags to script it. See `install.sh --help` for
the full flag list.

This copies `loop/` and two Claude Code skills (`.claude/skills/council/`,
`.claude/skills/new-task/`) into the target repo, writes
`loop/loop.config.sh` with your answers, and does a one-time text
substitution of the `{{PLACEHOLDER}}` tokens baked into the prompt
templates. It will not touch an existing `loop/loop.config.sh` unless you
pass `--force` — re-running install.sh to pick up a kit update won't
clobber settings you've already tuned.

## What's actually per-project (the customization checklist)

`install.sh` prompts for all of these; you can also hand-edit
`loop/loop.config.sh` afterward at any time.

1. **Build/test commands** (`LOOP_KIT_BUILD_CMD` / `LOOP_KIT_TEST_CMD`) —
   what `loop/verify.sh` runs after every maker attempt, before a diff is
   eligible for review. Defaults to `make build`/`make test`; point these
   at whatever your project actually uses.
2. **Sensitive-path regex** (`LOOP_KIT_SENSITIVE_PATTERN`) — diffs
   touching a matching path always go to `loop/queue/blocked/` for a
   human, no matter what verify or the checker say. The shipped default
   (`deploy/`, `secrets`, `.github/workflows/`) covers what's dangerous in
   nearly any repo; add your own ADRs, provider-interface specs, or
   schema-of-record files.
3. **Working-principles doc** (`LOOP_KIT_PRINCIPLES_DOC`, default
   `AGENTS.md`) — the task/review prompt templates point makers and
   reviewers at this for working principles (TDD, architectural
   constraints, whatever your project cares about). Make sure it exists
   and actually says something; the templates degrade gracefully
   ("if it exists" / "if it calls for TDD") if it doesn't, but a loop
   with no stated principles document has much less to hold makers to.
4. **Roadmap/milestone doc** (`LOOP_KIT_ROADMAP_DOC`, default
   `docs/roadmap.md`) — if set and the file exists, `new_task.sh` requires
   every task's `milestone:` frontmatter to match a `## <id> — ...`
   heading in it. Set to empty (`none` at the interactive prompt) if your
   project doesn't track milestones as a doc.
5. **The red-team adversarial mandate** — *not* prompted for, because it's
   not a fill-in-the-blank field. `loop/*_review_prompt.tpl.md` ship with
   a generic numbered mandate (mocked-vs-real dependencies, boundary/
   type-coercion bugs, auth fail-closed behavior, audit completeness, test
   reachability, injection, idempotency). Once your loop has caught a few
   real bugs, add your own project-specific items ahead of the generic
   ones — name the exact recurring failure mode, the way you'd write a
   postmortem action item. This is where a lot of the system's real value
   compounds over time, and it's deliberately left as a TODO rather than
   auto-generated, because generic advice here is much weaker than a
   lesson your project actually learned.

## Layout of this kit

```
install.sh                 the installer described above
loop/                       copied into a target repo's loop/ verbatim (post-substitution)
  run.sh                    the maker/checker driver
  verify.sh                 the automated gate
  council.sh                the independent three-model advisory fan-out
  new_task.sh                scaffolds a new queue task file
  loop.config.sh.example     documents every LOOP_KIT_* setting
  *_task_prompt.tpl.md       maker prompt template
  *_review_prompt.tpl.md     one per checker (claude/codex/cursor)
  council_prompt.tpl.md      council member prompt template
  README.md                  operational docs, copied into the target repo as loop/README.md
skills/
  council/SKILL.md           Claude Code skill, thin pointer to council.sh
  new-task/SKILL.md          Claude Code skill, thin pointer to new_task.sh
```

`loop/README.md` is the full operational writeup (queue semantics, retry/
backoff behavior, the review cycle, what this does and doesn't remove
from your review burden) — read it once installed, or read the copy in
this kit before installing to decide if this is the right fit for your
project.

## What this is not

It's not a hosted service, a package you `npm install`, or something with
a stable API to version against — it's a copy-and-own starter kit. After
`install.sh` runs, the copy in your target repo is yours; there's no live
link back to this kit unless you build one yourself (git subtree, a sync
script, whatever fits). Pulling in a kit update later means re-running
`install.sh --force` (which overwrites the scripts/templates but asks
before touching your config) or diffing by hand.

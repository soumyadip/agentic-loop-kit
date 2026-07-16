# agentic-loop-kit

A portable maker/checker "loop" and multi-model "council" system for
running small, spec'd coding tasks through CLI coding agents with
independent review. It runs a queue of small, spec'd tasks through a maker
(a CLI harness — Codex, Claude Code, and Cursor ship built in), gates each
attempt behind a project-specific verify script, and hands every diff to a
*different* harness to review before it can merge — so no model ever
grades its own homework. That same read-only checker step also stands
alone as `review_pr.sh`, for reviewing a GitHub pull request that never
went through the queue at all. `council.sh` is a separate, read-only
counterpart for design questions rather than diffs: fan one out to several
models in parallel and synthesize their independent answers yourself.

This is bash + markdown templates that shell out to CLIs already on your
`$PATH` — no project-specific machinery baked in. The parts that vary by
project (build/test commands, which paths are governance-sensitive, which
doc to validate milestones against, and which harnesses/models are in the
rotation) are all config, filled in by `install.sh`.

## Harnesses (and models) are pluggable

Which CLIs — and which models — act as maker and checker is data, not
hardcoded logic. Each harness is a small adapter — `loop/harnesses/<name>.sh`
— implementing three functions (`harness_maker_run`, `harness_reviewer_run`,
`harness_reviewer_mode_note`; see `loop/harnesses/TEMPLATE.sh.example` for
the exact contract). `loop/run.sh` itself has no per-harness special-casing
left: it reads `LOOP_KIT_HARNESSES` (space-separated *members*, order
matters — see below), sources the right adapter file right before each
call, and reviews in a ring (each member is checked by the next one in the
list, wrapping around).

A member is a bare harness name (`cursor`) or `harness:model`
(`cursor:grok-4.5-high`), pinning a model. That means a harness that fronts
several model families by itself — Cursor and opencode both do — can fill
more than one seat in the rotation on its own:
`LOOP_KIT_HARNESSES="cursor:grok-4.5-high cursor:claude-4.5-sonnet"` is a
valid 2-member rotation using a single CLI, since a diff made under one
model family is still meaningfully checked by a different one. Needs ≥2
members total (not necessarily ≥2 distinct harnesses), and no two members
may be identical — that would be genuine self-review.

Codex, Claude Code, and Cursor ship as built-in adapters; drop any subset,
reorder them, repeat one with different pinned models, or add a new harness
(aider, gemini-cli, opencode, an internal tool) by writing an adapter
against that interface — `loop/new_harness.sh <name>` scaffolds the file
for you.

`council.sh` (see below) reuses the exact same adapter files and member-spec
syntax through a fourth function, `harness_council_run`, but is configured
independently via `LOOP_KIT_COUNCIL_HARNESSES` — it's a different job
(several models answering one question in parallel, no cross-visibility,
no ring, no ≥2/distinctness requirement) from the maker/checker rotation
above, so the two lists don't have to match.

## Prerequisites

The loop only orchestrates CLIs it doesn't ship — install and authenticate
whichever of these you intend to use as makers/checkers:

- [`codex`](https://github.com/openai/codex) — built-in harness
- [`claude`](https://claude.com/claude-code) — built-in harness
- [`cursor-agent`](https://cursor.com/cli) — built-in harness
- [`opencode`](https://opencode.ai) — optional, ships a council-only adapter (used by `council.sh`'s default rotation); its maker/checker functions are left as TODO stubs, see `loop/README.md`

You don't need all three maker/checker built-in harnesses on day one —
only whichever ones you list in `LOOP_KIT_HARNESSES` (install.sh asks). A
2-harness rotation (e.g. `codex claude`) only needs those two CLIs
installed. Separately, `LOOP_KIT_COUNCIL_HARNESSES` (default `codex
opencode claude`) only needs whichever CLIs it names.

Also needed: `python3` (template rendering, backoff-timestamp parsing),
`git` (worktrees — this is load-bearing, not optional), and `bash` 4+.

## Install into a project

```sh
./install.sh /path/to/your-repo
```

Run without flags against a terminal, it prompts for the things that are
genuinely per-project (see below) with sensible defaults; pass
`--non-interactive` plus flags to script it. See `install.sh --help` for
the full flag list.

This copies `loop/` (including `loop/harnesses/`) and Claude Code skills
(`.claude/skills/council/`, `new-task/`, `skillopt-sleep/`, `project-loop/`)
into the target repo, writes `loop/loop.config.sh` with your answers, and does a
one-time text substitution of the `{{PLACEHOLDER}}` tokens baked into the
prompt templates. If `loop/loop.config.sh` already exists, a plain re-run
refuses — use `--update` (alias `--upgrade`) to refresh kit-managed files
while keeping that config, or `--force` to overwrite config too. If you list a
harness that isn't one of the three built-ins, install still completes but
tells you to run `loop/new_harness.sh <name>` in the target repo afterward —
a CLI this kit has never seen needs a human to write its ~20-line adapter once.

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
5. **Which harnesses/models, in what order** (`LOOP_KIT_HARNESSES`, default
   `codex claude cursor`) — the maker/checker rotation. Order sets the
   review ring (each member is checked by the next one in the list).
   Entries can be a bare harness (`cursor`) or `harness:model`
   (`cursor:grok-4.5-high`) to pin a model — needs ≥2 entries, not
   necessarily ≥2 distinct harnesses, so `cursor:grok-4.5-high
   cursor:claude-4.5-sonnet` is a valid rotation on one CLI. install.sh
   prompts for the list, then for each *bare* built-in entry, a default
   model (used for both its maker-default and checker roles — hand-edit
   `loop.config.sh` afterward if you want to split those, or tier
   `quick`/`gnarly` maker models differently; see `loop.config.sh.example`
   for every knob). Naming a harness that isn't one of the three built-ins
   gets it written into the config anyway, with a note to scaffold its
   adapter via `loop/new_harness.sh` before it'll actually work.
6. **The red-team adversarial mandate** — *not* prompted for, because it's
   not a fill-in-the-blank field. `loop/review_prompt.tpl.md` (the single
   template shared by every checker — see below) ships with
   a generic numbered mandate (mocked-vs-real dependencies, boundary/
   type-coercion bugs, auth fail-closed behavior, audit completeness, test
   reachability, injection, idempotency). Once your loop has caught a few
   real bugs, add your own project-specific items ahead of the generic
   ones — name the exact recurring failure mode, the way you'd write a
   postmortem action item. This is where a lot of the system's real value
   compounds over time, and it's deliberately left as a TODO rather than
   auto-generated, because generic advice here is much weaker than a
   lesson your project actually learned. Optionally, Microsoft SkillOpt-Sleep
   (`loop/skillopt_sleep.sh`) can propose gated edits to the LEARNED block
   of `.claude/skills/project-loop/SKILL.md` from `loop/log/` evidence — see
   `loop/README.md`'s "SkillOpt-Sleep" section; still human-adopted, not
   auto-written into the mandate.

## Layout of this kit

```
install.sh                 the installer described above
loop/                       copied into a target repo's loop/ verbatim (post-substitution)
  run.sh                    the maker/checker driver — no per-harness logic
  render.sh                  shared template renderer, sourced by run.sh and review_pr.sh
  verify.sh                 the automated gate
  review_pr.sh               review a GitHub PR through the same checker machinery
  council.sh                the independent multi-model advisory fan-out
  new_task.sh                scaffolds a new queue task file
  new_harness.sh             scaffolds a new loop/harnesses/<name>.sh adapter
  skillopt_export.sh         export loop/log + queue outcomes → SkillOpt-Sleep tasks JSON
  skillopt_sleep.sh          wrapper: export → skillopt-sleep dry-run/run/status/adopt
  skillopt_trigger.sh        activity triggers from run.sh (remind/dry-run/run; never auto-adopt)
  skillopt-sleep.config.json.example   optional ~/.skillopt-sleep/config.json starter
  loop.config.sh.example     documents every LOOP_KIT_* setting
  task_prompt.tpl.md          single maker prompt template, shared by every harness
  review_prompt.tpl.md        review prompt for queue tasks
  pr_review_prompt.tpl.md     review prompt for review_pr.sh — both share
                               review_mandate.partial.md (the red-team/bug-report/
                               adjudication/verdict block) and run.sh fills in one
                               {{REVIEWER_MODE_NOTE}} line per harness into either one
  council_prompt.tpl.md      council member prompt template
  harnesses/
    codex.sh, claude.sh, cursor.sh   built-in maker/checker/council adapters
    opencode.sh                      council-only adapter (maker/checker left as TODO stubs)
    TEMPLATE.sh.example              the adapter interface, documented
  README.md                  operational docs, copied into the target repo as loop/README.md
skills/
  council/SKILL.md           Claude Code skill, thin pointer to council.sh
  new-task/SKILL.md          Claude Code skill, thin pointer to new_task.sh
  skillopt-sleep/SKILL.md    Claude Code skill, thin pointer to skillopt_sleep.sh
  project-loop/SKILL.md      trainable project skill (SkillOpt-Sleep LEARNED target)
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
script, whatever fits). Pulling in a kit update later:

```sh
./install.sh /path/to/your-repo --update    # or --upgrade
```

That refreshes scripts, prompt templates, built-in harness adapters, docs,
and thin skills (`council`, `new-task`, `skillopt-sleep`), re-applies
install-time `{{PLACEHOLDER}}` substitution from your existing config, and
appends any newly introduced `LOOP_KIT_*` keys that are still missing.
It **keeps** `loop/loop.config.sh`, leaves `queue/`/`log/`/`state/` alone,
does not overwrite `review_mandate.partial.md` or
`.claude/skills/project-loop/SKILL.md` when those already exist (so red-team
and LEARNED customizations survive), and does not delete custom
`loop/harnesses/<name>.sh` adapters you scaffolded. Use `--force` only when
you intentionally want a regenerated config (then restore tuned settings
from git).

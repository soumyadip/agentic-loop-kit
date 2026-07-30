# agentic-loop-kit

A portable maker/checker **loop** and multi-model **council** for small,
spec'd coding tasks — bash + markdown that shells out to CLIs already on
your `$PATH`.

**What it does**

- Runs a queue of tasks through a maker CLI (Codex, Claude Code, Cursor)
- Gates each attempt behind your project's verify script
- Hands every diff to a *different* harness before merge (no self-review)
- Also stands alone as `review_pr.sh` for GitHub PRs that never hit the queue
- `council.sh` fans design questions to several models in parallel (read-only)

**What's config (not code)** — filled in by `install.sh`:

- Build/test commands
- Governance-sensitive paths (always require a human)
- Principles + roadmap docs
- Which harnesses/models sit in the maker/checker ring

## Quickstart

New to this kit? The five-minute version (each step links to the section
with the full detail):

1. Pick **2+ CLIs** from the [Prerequisites](#prerequisites) table below,
   install them, and log in to each (one-time, e.g. `codex login` — see the
   table's Auth column).
2. `./install.sh /path/to/your-repo` and answer the prompts (or
   `--non-interactive` with flags — see `./install.sh --help`).
3. `cd /path/to/your-repo`, seed one task:
   `loop/new_task.sh my-first-task <milestone>`, then open the file it wrote
   under `loop/queue/pending/` and replace every `TODO:` (see
   [`loop/README.md`](loop/README.md)'s "Adding tasks" — it includes a
   worked example).
4. Run it, one task, supervised:
   `LOOP_MAX_ITERATIONS=1 ./loop/run.sh`.
5. Check the result: `loop/queue/done/` (merged) or `loop/queue/blocked/`
   (needs you — see `loop/README.md`'s "When a task is blocked"), and read
   `loop/log/<task-id>/` for the full maker/checker transcript.

**This costs real usage.** Each task run makes several genuine model calls —
at minimum one maker attempt and one checker review, more on retries —
through whichever CLI subscriptions or API keys you configured. It is not
free or instant. Keep `LOOP_MAX_ITERATIONS` small (`1`–`3`) until you trust
the setup; see `loop/README.md`'s "What this does not do."

New to terms like *maker*, *checker*, *harness*, *ring*, or *worktree*?
[`loop/README.md`](loop/README.md) opens with a short glossary — worth
reading once before the reference tables below.

## Harnesses (and models) are pluggable

Which CLIs — and which models — act as maker and checker is **data**, not
hardcoded logic.

| Piece | Role |
|---|---|
| `loop/harnesses/<name>.sh` | Adapter: `harness_maker_run`, `harness_reviewer_run`, `harness_reviewer_mode_note` (see `TEMPLATE.sh.example`) |
| `LOOP_KIT_HARNESSES` | Space-separated *members*, order = review ring |
| `loop/run.sh` | No per-harness special-casing — sources the adapter right before each call |

**Member syntax**

- Bare harness: `cursor` (uses that harness's project default model)
- Pinned model: `cursor:grok-4.5-high` / `copilot:gpt-5.4` / `opencode:nvidia/z-ai/glm-5.2`
- One multi-model CLI can fill multiple seats, e.g.  
  `LOOP_KIT_HARNESSES="copilot:gpt-5.4 copilot:claude-sonnet-4.6"`
- Need ≥2 members total (not necessarily ≥2 distinct harnesses)
- No two members may be identical (that would be self-review)

**Built-ins:** Codex, Claude Code, Cursor, GitHub Copilot CLI, and opencode.
Default rotation is `codex claude cursor` (doesn't require Copilot/opencode on
day one). Drop any subset, reorder, pin different models, or add a harness with
`loop/new_harness.sh <name>`.

Multi-model CLIs (`cursor`, `copilot`, `opencode`) can fill multiple seats alone:

```sh
LOOP_KIT_HARNESSES="copilot:gpt-5.4 copilot:claude-sonnet-4.6"
LOOP_KIT_HARNESSES="opencode:nvidia/z-ai/glm-5.2 opencode:opencode/big-pickle"
```

**Council** reuses the same adapters via `harness_council_run`, but is
configured separately (`LOOP_KIT_COUNCIL_HARNESSES`). Different job: parallel
opinions, no ring, no ≥2 rule — the two lists need not match.

## Prerequisites

Install and authenticate only the CLIs you put in your rotation. Auth is a
one-time interactive step per CLI, done once per machine:

| CLI | Role | Auth |
|---|---|---|
| [`codex`](https://github.com/openai/codex) | Built-in maker/checker/council | `codex login` (ChatGPT account) or `OPENAI_API_KEY` |
| [`claude`](https://claude.com/claude-code) | Built-in maker/checker/council | Run `claude`, follow the browser login prompt (or `ANTHROPIC_API_KEY`) |
| [`cursor-agent`](https://cursor.com/cli) | Built-in maker/checker/council (multi-model) | `cursor-agent login` (or `CURSOR_API_KEY`) |
| [`copilot`](https://docs.github.com/en/copilot/how-tos/use-copilot-agents/use-copilot-cli) | Built-in maker/checker/council (multi-model; GitHub Copilot subscription) | Run `copilot`, follow the login prompt (needs an active Copilot subscription) |
| [`opencode`](https://opencode.ai) | Built-in maker/checker/council (multi-model; also default council member) | `opencode auth login` (pick a provider, e.g. `-p anthropic`) |

Also required: `python3`, `git` (worktrees — load-bearing), `bash` 4+.

A 2-harness rotation (e.g. `codex claude` or `copilot:gpt-5.4
copilot:claude-sonnet-4.6`) only needs those CLIs.
`LOOP_KIT_COUNCIL_HARNESSES` only needs the CLIs it names.

## Install into a project

```sh
./install.sh /path/to/your-repo
```

| Mode | Behavior |
|---|---|
| Interactive (default) | Prompts with a short **why / loop impact** blurb each step |
| `--non-interactive` + flags | Scripted; see `./install.sh --help` |
| `--update` / `--upgrade` | Refresh kit files; keep `loop.config.sh`; re-prompt SkillOpt |
| `--force` | Fresh install that also overwrites `loop.config.sh` |

**What install does**

1. Copies `loop/` + Claude skills (`council`, `new-task`, `skillopt-sleep`, `project-loop`)
2. Writes `loop/loop.config.sh` from your answers
3. Substitutes `{{PLACEHOLDER}}` tokens in prompt templates

A plain re-run refuses if config already exists — use `--update` or `--force`.
Unknown harness names still install; run `loop/new_harness.sh <name>` afterward.

## What's actually per-project

Prompts below (or hand-edit `loop/loop.config.sh` anytime). Full flags:
`./install.sh --help`.

### Require-human-review paths (not “sensitive”)

**Decision rule:** a recurring directory (deploy, secrets, CI) → the regex
gate. A one-off task that isn't under such a path → `sensitive: true` in
that task's frontmatter. Both produce the identical outcome (always block
for a human); the rest of this section is about *why* there are two knobs,
not which one to reach for.

Two related knobs — easy to confuse; only the regex is a gate:

| Knob | Config | Role |
|---|---|---|
| **Regex gate** | `LOOP_KIT_REQUIRE_HUMAN_REVIEW_PATHS` | After verify: if any changed path matches → `queue/blocked/` immediately. Checker never runs; nothing auto-merges. |
| **Prompt label** | Install `--require-human-review-paths-label` only | Plain English for those paths, baked into review templates as `{{REQUIRE_HUMAN_REVIEW_PATHS_LABEL}}`. Does **not** block anything. |

Per-task frontmatter `sensitive: true` has the **same outcome** as the regex gate (always block for a human), for one-off tasks that aren’t under a recurring path prefix.

Older installs may still have `LOOP_KIT_SENSITIVE_PATTERN` — `run.sh` honors it as a fallback; `install.sh --update` renames the key.

### Core loop

| Prompt | Config / default | Why | Loop impact |
|---|---|---|---|
| Build command | `LOOP_KIT_BUILD_CMD` → `make build` | Without a real build/typecheck, broken work reaches review | `verify.sh` after every maker attempt; fail → retry; pass → review |
| Test command | `LOOP_KIT_TEST_CMD` → `make test` | Acceptance must be executable, not prose-only | Same gate as build |
| Require-human-review paths (regex) | `LOOP_KIT_REQUIRE_HUMAN_REVIEW_PATHS` | Secrets/deploy/CI must not auto-merge because two models agreed | Matching diffs → `queue/blocked/` **before** review; checker never runs |
| Require-human-review paths label | Prompt-only (not in config) | Reviewers need plain language, not only a regex | Baked into `{{REQUIRE_HUMAN_REVIEW_PATHS_LABEL}}` in review templates — **not** the gate |
| Principles doc | `LOOP_KIT_PRINCIPLES_DOC` → `AGENTS.md` | Fresh-context agents need one authoritative TDD/architecture file | Every task + review prompt points here |
| Roadmap doc | `LOOP_KIT_ROADMAP_DOC` → `docs/roadmap.md` (`none` = off) | Keeps the queue tied to real roadmap work | `new_task.sh` rejects unknown `milestone:` values |
| Harnesses ring | `LOOP_KIT_HARNESSES` (≥2; `harness` or `harness:model`) | No model grades its own homework | Order = review ring; bare built-ins also ask for a default model |
| Council members | `LOOP_KIT_COUNCIL_HARNESSES` | ADRs benefit from parallel disagreement | Only `council.sh` — unused by `run.sh` |

Default require-human regex covers `deploy/`, `secrets`, `.github/workflows/` —
add your own schema-of-record paths. The **label** is only for prompt wording;
only the **regex** blocks auto-merge. (Older name `LOOP_KIT_SENSITIVE_PATTERN`
still works as a fallback until `--update` renames it.)

### SkillOpt-Sleep (install + `--update`)

Optional. Interactive fresh install leans toward installing the package and
writing `~/.skillopt-sleep/config.json` if missing. On `--update`, existing
`LOOP_KIT_SKILLOPT_*` values are the defaults; package install defaults to **no**.

| Prompt | Config / flag | Why | Loop impact |
|---|---|---|---|
| Install package? | `--with-skillopt` / `--no-skillopt` | Without it, `skillopt_sleep.sh` cannot run | Optional; `run.sh` only nudges when TRIGGER is set |
| Source | `pip` or `git` | Handoff landed after PyPI 0.2.0 — use `git` for Cursor/Copilot/opencode | Which Sleep features work (subscription CLIs; no API keys) |
| Backend | `LOOP_KIT_SKILLOPT_BACKEND` → `mock\|claude\|codex\|handoff` | Prefer logged-in CLIs over API keys | Default `--backend` for manual + auto dry-run/run |
| Activity trigger | `LOOP_KIT_SKILLOPT_TRIGGER` → `remind` | Easy to forget; remind surfaces it without spend | `skillopt_trigger.sh` after done thresholds; **never auto-adopts** |
| Every N done | `LOOP_KIT_SKILLOPT_TRIGGER_EVERY_DONE` → `10` | Relative watermark matches real usage | `0` = never fire |
| Trigger backend | `LOOP_KIT_SKILLOPT_TRIGGER_BACKEND` → `mock` | Auto paths should stay cheap until you opt in | Ignored for `remind` / `off` |
| Handoff harness | `LOOP_KIT_SKILLOPT_HANDOFF_HARNESS` | Cursor/Copilot/opencode aren't native Sleep backends | Used when backend is `handoff` |
| Engine config | `~/.skillopt-sleep/config.json` | Sleep reads home-dir config | Does not change `loop.config.sh` |

### Not prompted (edit by hand)

**Red-team mandate** — `loop/review_mandate.partial.md` ships generic.
Sharpen it after real bugs slip through. SkillOpt can propose gated edits to
the LEARNED block of `.claude/skills/project-loop/SKILL.md` (human adopt
only) — see `loop/README.md` → SkillOpt-Sleep.

## Layout of this kit

```
install.sh                 the installer described above
loop/                       copied into a target repo's loop/ verbatim (post-substitution)
  run.sh                    the maker/checker driver — no per-harness logic
  render.sh                  shared template renderer, sourced by run.sh and review_pr.sh
  verify.sh                 the automated gate
  review_pr.sh               review a GitHub PR through the same checker machinery
  council.sh                the independent multi-model advisory fan-out (+ optional --synthesize)
  queue_graph.sh             prints the depends_on task DAG (text or --mermaid)
  new_task.sh                scaffolds a new queue task file
  new_harness.sh             scaffolds a new loop/harnesses/<name>.sh adapter
  skillopt_export.sh         export loop/log + queue outcomes → SkillOpt-Sleep tasks JSON
  skillopt_sleep.sh          wrapper: export → skillopt-sleep (claude/codex/handoff)
  skillopt_handoff.sh        answer Sleep handoff prompts via harness_council_run
  skillopt_trigger.sh        activity triggers from run.sh (remind/dry-run/run; never auto-adopt)
  skillopt-sleep.config.json.example   optional ~/.skillopt-sleep/config.json starter
  loop.config.sh.example     documents every LOOP_KIT_* setting
  task_prompt.tpl.md          single maker prompt template, shared by every harness
  review_prompt.tpl.md        review prompt for queue tasks
  pr_review_prompt.tpl.md     review prompt for review_pr.sh
  review_mandate.partial.md   shared red-team / verdict block (injected into both review templates)
  council_prompt.tpl.md      council member prompt template
  council_synthesis_prompt.tpl.md   council.sh --synthesize's prompt
  harnesses/
    codex.sh, claude.sh, cursor.sh   built-in maker/checker/council adapters
    copilot.sh, opencode.sh          multi-model maker/checker/council adapters
    TEMPLATE.sh.example              the adapter interface, documented
  README.md                  operational docs, copied into the target repo as loop/README.md
skills/
  council/SKILL.md           Claude Code skill, thin pointer to council.sh
  new-task/SKILL.md          Claude Code skill, thin pointer to new_task.sh
  skillopt-sleep/SKILL.md    Claude Code skill, thin pointer to skillopt_sleep.sh
  project-loop/SKILL.md      trainable project skill (SkillOpt-Sleep LEARNED target)
```

`loop/README.md` is the full operational writeup (queue, retry/backoff,
review cycle, what this does and doesn't remove from your review burden).
Read it once installed — or from this kit before installing.

## What this is not

Not a hosted service, not an `npm` package, not a versioned API — a
**copy-and-own** starter kit. After `install.sh`, the copy in your target
repo is yours.

```sh
./install.sh /path/to/your-repo --update    # or --upgrade
```

| `--update` keeps | `--update` refreshes |
|---|---|
| `loop/loop.config.sh` | Scripts, templates, built-in harnesses, docs |
| `queue/` / `log/` / `state/` | Thin skills (`council`, `new-task`, `skillopt-sleep`) |
| Existing `review_mandate.partial.md` | Install-time `{{PLACEHOLDER}}` substitution |
| Existing `project-loop/SKILL.md` | Missing `LOOP_KIT_*` keys (appended) |
| Custom `loop/harnesses/<name>.sh` | — |

Use `--force` only when you intentionally want a regenerated config (then
restore tuned settings from git).

## Loop, or graph? (skip this if you're just getting started)

Nothing above requires reading this — it only matters if the term "graph
engineering" ([Peter Steinberger](https://x.com/steipete) framing it as
loop engineering's successor, mid-2026) means something to you already and
you're wondering how this kit relates. Short version: this kit's *unit* is
still a loop — one maker, one checker, one stop condition — but the pieces
around that unit already compose into a graph, not a single chain:

| Graph-engineering term | What it is here |
|---|---|
| **Node** | Each maker/checker/council call is a separate node: its own prompt template, fresh context (no contamination from the prior call's transcript), isolated `git worktree`. |
| **Edge / explicit routing** | Not emergent from one agent's judgment — `reviewer_for()` in `run.sh` and the adjudication table (`approve` / `request_changes` / `block_human`) are plain, inspectable, config-driven routing. |
| **State handoff, not raw transcript** | A checker gets the task file (Why/Scope/Acceptance) plus the diff — a defined handoff schema, never the maker's raw conversation. |
| **Task graph (DAG)** | `depends_on:` frontmatter across `loop/queue/*/`, visualized with `loop/queue_graph.sh`. |
| **Fan-out / fan-in** | Fan-out: parallel maker lanes per turn, and `council.sh`'s parallel dispatch. Fan-in: a `depends_on: [A, B]` task joining after *both* land in `done/`, and `council.sh --synthesize` reconciling N independent opinions into one. |
| **Policy node** | `verify.sh` and the require-human-review path gate both run *before* the checker and can route straight to `blocked/` without any model in the loop. |
| **Failure isolation** | A backed-off checker no longer stalls the whole task — `reviewer_for()` tries the next healthy ring member first. |

We considered renaming the kit to chase the new vocabulary and decided
against it: "loop" still accurately names the atomic unit (maker → checker
→ stop condition) that every graph-shaped piece above is *built from*, not
a replacement for — and a term barely a few weeks old is a shaky
foundation for a name that has to outlive its own hype cycle. This section
exists so the mapping is on record instead.

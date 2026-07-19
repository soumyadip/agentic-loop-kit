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
- Governance-sensitive paths
- Principles + roadmap docs
- Which harnesses/models sit in the maker/checker ring

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
- Pinned model: `cursor:grok-4.5-high`
- One multi-model CLI can fill multiple seats, e.g.  
  `LOOP_KIT_HARNESSES="cursor:grok-4.5-high cursor:claude-4.5-sonnet"`
- Need ≥2 members total (not necessarily ≥2 distinct harnesses)
- No two members may be identical (that would be self-review)

**Built-ins:** Codex, Claude Code, Cursor. Drop any subset, reorder, pin
different models, or add a harness with `loop/new_harness.sh <name>`.

**Council** reuses the same adapters via `harness_council_run`, but is
configured separately (`LOOP_KIT_COUNCIL_HARNESSES`). Different job: parallel
opinions, no ring, no ≥2 rule — the two lists need not match.

## Prerequisites

Install and authenticate only the CLIs you put in your rotation:

| CLI | Role |
|---|---|
| [`codex`](https://github.com/openai/codex) | Built-in maker/checker |
| [`claude`](https://claude.com/claude-code) | Built-in maker/checker |
| [`cursor-agent`](https://cursor.com/cli) | Built-in maker/checker |
| [`opencode`](https://opencode.ai) | Optional; council-only adapter by default (maker/checker are stubs — see `loop/README.md`) |

Also required: `python3`, `git` (worktrees — load-bearing), `bash` 4+.

A 2-harness rotation (e.g. `codex claude`) only needs those two CLIs.
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

### Core loop

| Prompt | Config / default | Why | Loop impact |
|---|---|---|---|
| Build command | `LOOP_KIT_BUILD_CMD` → `make build` | Without a real build/typecheck, broken work reaches review | `verify.sh` after every maker attempt; fail → retry; pass → review |
| Test command | `LOOP_KIT_TEST_CMD` → `make test` | Acceptance must be executable, not prose-only | Same gate as build |
| Sensitive-path regex | `LOOP_KIT_SENSITIVE_PATTERN` | Secrets/deploy/CI must not auto-merge because two models agreed | Matching diffs → `queue/blocked/` regardless of VERDICT |
| Sensitive-path description | Prompt-only (not in config) | Reviewers need plain language, not only a regex | Baked into `{{SENSITIVE_DESC}}` in review templates |
| Principles doc | `LOOP_KIT_PRINCIPLES_DOC` → `AGENTS.md` | Fresh-context agents need one authoritative TDD/architecture file | Every task + review prompt points here |
| Roadmap doc | `LOOP_KIT_ROADMAP_DOC` → `docs/roadmap.md` (`none` = off) | Keeps the queue tied to real roadmap work | `new_task.sh` rejects unknown `milestone:` values |
| Harnesses ring | `LOOP_KIT_HARNESSES` (≥2; `harness` or `harness:model`) | No model grades its own homework | Order = review ring; bare built-ins also ask for a default model |
| Council members | `LOOP_KIT_COUNCIL_HARNESSES` | ADRs benefit from parallel disagreement | Only `council.sh` — unused by `run.sh` |

Default sensitive regex covers `deploy/`, `secrets`, `.github/workflows/` —
add your own schema-of-record paths.

### SkillOpt-Sleep (install + `--update`)

Optional. Interactive fresh install leans toward installing the package and
writing `~/.skillopt-sleep/config.json` if missing. On `--update`, existing
`LOOP_KIT_SKILLOPT_*` values are the defaults; package install defaults to **no**.

| Prompt | Config / flag | Why | Loop impact |
|---|---|---|---|
| Install package? | `--with-skillopt` / `--no-skillopt` | Without it, `skillopt_sleep.sh` cannot run | Optional; `run.sh` only nudges when TRIGGER is set |
| Source | `pip` or `git` | Handoff landed after PyPI 0.2.0 — use `git` for Cursor/opencode | Which Sleep features work (subscription CLIs; no API keys) |
| Backend | `LOOP_KIT_SKILLOPT_BACKEND` → `mock\|claude\|codex\|handoff` | Prefer logged-in CLIs over API keys | Default `--backend` for manual + auto dry-run/run |
| Activity trigger | `LOOP_KIT_SKILLOPT_TRIGGER` → `remind` | Easy to forget; remind surfaces it without spend | `skillopt_trigger.sh` after done thresholds; **never auto-adopts** |
| Every N done | `LOOP_KIT_SKILLOPT_TRIGGER_EVERY_DONE` → `10` | Relative watermark matches real usage | `0` = never fire |
| Trigger backend | `LOOP_KIT_SKILLOPT_TRIGGER_BACKEND` → `mock` | Auto paths should stay cheap until you opt in | Ignored for `remind` / `off` |
| Handoff harness | `LOOP_KIT_SKILLOPT_HANDOFF_HARNESS` | Cursor/opencode aren't native Sleep backends | Used when backend is `handoff` |
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
  council.sh                the independent multi-model advisory fan-out
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

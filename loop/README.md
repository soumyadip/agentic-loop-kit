# The loop

A "loop engineering" setup: a written spec + a stop condition, run by a
script, with a **maker** and a separate **checker** so the implementer never
grades its own homework. (Term popularized by [Peter Steinberger](https://x.com/steipete)
and [Addy Osmani](https://addyosmani.com/blog/loop-engineering/), writing
about putting AI coding agents on repeat.)

## Glossary

New to this vocabulary? Skim this once before the tables below.

| Term | Plain-English meaning |
|---|---|
| **Maker** | The agent that writes the diff for one task. |
| **Checker** | A *different* agent that reviews that diff before it can merge — never the same one that wrote it. |
| **Harness** | The adapter script (`loop/harnesses/<name>.sh`) wrapping one CLI (Codex, Claude Code, Cursor, …) so `run.sh` can call it generically as maker, checker, or council member. |
| **Ring** | The review rotation: `LOOP_KIT_HARNESSES` order decides who checks whom (each member is checked by the next, wrapping around). |
| **Worktree** | An isolated `git worktree` + branch created per task, so a bad run never touches your main branch directly. |
| **Backoff** | A recorded cooldown when a harness looks rate-limited, so the loop stops hammering it. |
| **Adjudication** | The policy that turns the checker's bug reports into a verdict (`approve` / `request_changes` / `block_human`) — folded into the same reviewer call, not a separate step. |
| **Council** | A read-only, parallel fan-out of one question to several models for independent opinions — no maker/checker relationship, just `loop/council.sh`. |
| **Require-human-review path** | A path pattern that always routes to a human, regardless of what maker/checker conclude. |

Coming from the "graph engineering" conversation and looking for terms
like *node*, *DAG*, or *fan-out/fan-in*? The root README's "Loop, or
graph?" section maps those onto this list — not needed to use the kit,
just a translation for a specific audience.

## Concepts

### Harnesses

Which CLIs (and models) sit in the rotation is **config**, not code:
`LOOP_KIT_HARNESSES` in `loop.config.sh` (default `codex claude cursor`).

| Syntax | Meaning |
|---|---|
| `cursor` | Bare harness — uses that harness's project default model |
| `cursor:grok-4.5-high` | Pin a specific model (same for `copilot:…` / `opencode:…`) |
| ≥2 members | Required (not necessarily ≥2 distinct harnesses) |
| Identical members | Forbidden (genuine self-review) |

One multi-model CLI can fill multiple seats:

```sh
LOOP_KIT_HARNESSES="cursor:grok-4.5-high cursor:claude-4.5-sonnet"
LOOP_KIT_HARNESSES="copilot:gpt-5.4 copilot:claude-sonnet-4.6"
```

Each harness is `loop/harnesses/<name>.sh`. Built-ins: `codex`, `claude`,
`cursor`, `copilot`, `opencode`. Add your own via `loop/new_harness.sh <name>` /
`TEMPLATE.sh.example`.

- One atomic task per run, fresh context every time
- State lives on disk + git — never in the model's head
- Downstream of the maker (verify → require-human-review gate → review →
  merge) is identical for every harness; only the attempt step differs

**Sandbox note (built-ins):** Codex runs inside an OS-level sandbox
(`-s workspace-write`) that restricts what it can touch outside the
worktree, even before a human looks at the diff. Claude / Cursor / Copilot
/ opencode have no such restriction — they can run any command the worktree
allows, same as a normal terminal session — so they lean entirely on
worktree isolation plus the checker step for safety. Reserve those makers
for well-scoped, non-sensitive work.

### Maker complexity tiers

Optional task frontmatter `complexity: quick|default|gnarly` picks
model+effort for the maker step. Each adapter maps this via its own
`LOOP_KIT_<NAME>_MAKER_MODEL_*` / `_MAKER_EFFORT_*` vars — see
`loop.config.sh.example`.

### Checker (review ring)

Order of `LOOP_KIT_HARNESSES` is the ring: each member is checked by the
next (wraps around). Default `codex claude cursor` → Codex→Claude→Cursor→Codex.

- Same template for everyone: `review_prompt.tpl.md`
- Only difference: one-line `{{REVIEWER_MODE_NOTE}}` from the adapter
- Must end with: `VERDICT: approve|request_changes|block_human`
- That verdict is the only step that can merge or block a task
- If the primary next-in-ring reviewer's harness is currently backed off
  (see "Usage-limit backoff" below), `reviewer_for()` walks the rest of the
  ring for the first healthy member instead of blocking immediately — one
  rate-limited harness no longer stalls every task made by the member right
  before it. Only blocks if *every* other member is also backed off.
- There is deliberately no path→specific-reviewer routing here (no "always
  send `src/auth/` diffs to member X"). See SkillOpt-Sleep's "Domain-specific
  review guidance" below for the model-agnostic alternative this kit uses
  instead.

### Red-teaming + adjudication

The checker actively tries to break the diff (mandate in
`review_mandate.partial.md`). Sharpen it with your project's recurring
failure modes. `LOOP_REVIEW_BREAK_ATTEMPTS` (default 1, max 3) bounds how
many break attempts run per review.

Adjudication is **folded into the same reviewer call** (no separate
coordinator — that would reintroduce self-grading):

| Bug report | Routes to |
|---|---|
| Confirmed + high/critical | `request_changes` → back to maker |
| Unconfirmed or low/medium | `block_human` → you decide |

### Multi-model CLIs (cursor / copilot / opencode)

These adapters front several model families through one CLI/account. Use
`harness:model` to fill multiple ring seats (or council seats) without a
second CLI:

| Harness | CLI | Default model config | Maker mode | Reviewer / council |
|---|---|---|---|---|
| `cursor` | `cursor-agent` | `LOOP_KIT_CURSOR_MODEL` | write (`--force`) | `--mode plan` |
| `copilot` | `copilot` (GitHub Copilot CLI) | `LOOP_KIT_COPILOT_MODEL` | `--allow-all-tools` | `--plan` |
| `opencode` | `opencode` | `LOOP_KIT_OPENCODE_MODEL` | `--agent build --auto` | `--agent plan --auto` |

Examples:

```sh
LOOP_KIT_HARNESSES="copilot:gpt-5.4 copilot:claude-sonnet-4.6"
LOOP_KIT_HARNESSES="opencode:nvidia/z-ai/glm-5.2 opencode:opencode/big-pickle"
LOOP_KIT_COUNCIL_HARNESSES="codex copilot:gpt-5.4 opencode"
LOOP_KIT_SKILLOPT_HANDOFF_HARNESS="copilot"   # or copilot:claude-sonnet-4.6
```

Model ids for Copilot vary by plan — check `copilot /model` interactively.
opencode models: `opencode models` (provider/model format).

### Usage-limit backoff

No CLI exposes remaining quota. When output looks like a rate-limit hit,
`run.sh` records a cooldown in `loop/state/backoff.txt`
(`<harness> <until-epoch>`). Keyed by **harness**, not member — a Cursor
or Copilot limit blocks every `cursor:…` / `copilot:…` seat. Clear early by
deleting the file or that harness's line.

A backed-off harness skips straight to blocked/ when it's picked as a
**maker** (nothing else to try — that task is routed to it specifically).
As a **checker**, a backed-off harness is instead skipped in favor of the
next healthy ring member — see "Checker (review ring)" above.

### State

Queue dirs + `loop/log/<task-id>/` + `loop/state/backoff.txt` + git
history. Delete this directory and `git log` and you can still reconstruct
what happened — that's the point.

## Layout

```
loop/queue/pending/      not started (filename order: T001 before T002)
loop/queue/in_progress/  current task (crash detection)
loop/queue/blocked/      failed twice, or require-human-review path / sensitive:true — needs you
loop/queue/done/         merged
loop/log/<task-id>/      maker / verify / review transcripts
loop/state/backoff.txt   usage-limit cooldowns
loop/state/skillopt-tasks.json    SkillOpt export
loop/state/skillopt-trigger.json  activity-trigger watermark
loop/loop.config.sh      per-repo settings
loop/run.sh              driver (no per-harness logic)
loop/verify.sh           automated gate
loop/queue_graph.sh      prints the depends_on task DAG (text or --mermaid)
loop/skillopt_*.sh       SkillOpt-Sleep helpers
loop/task_prompt.tpl.md / review_prompt.tpl.md / council_prompt.tpl.md
loop/council_synthesis_prompt.tpl.md   council.sh --synthesize's prompt
loop/harnesses/<name>.sh + TEMPLATE.sh.example + new_harness.sh
loop/council.sh          parallel design opinions (+ optional --synthesize)
```

## Running it

```sh
./loop/run.sh                         # up to LOOP_MAX_ITERATIONS tasks (default 5)
LOOP_MAX_ITERATIONS=1 ./loop/run.sh   # one task — good first run
```

Each task gets its own `git worktree` on `loop/<task-id>` — bad runs never
touch your main branch directly.

## What actually happens per task

1. **Pick** oldest `queue/pending/` file; read `maker:` (default: first
   `LOOP_KIT_HARNESSES` entry). If that harness is in backoff → block
   immediately. Unknown maker → warn at startup.
2. **Claim** → `in_progress/`; create worktree + branch.
3. **Make** — render `task_prompt.tpl.md` → `harness_maker_run`. Rate-limit
   → backoff.
4. **Verify** — `loop/verify.sh` in the worktree.
5. **Retry on verify fail** — up to `LOOP_MAX_RETRIES` (default 2); fresh
   maker prompt each time (reads failure off disk).
6. **Require-human-review paths** — if any changed path matches
   `LOOP_KIT_REQUIRE_HUMAN_REVIEW_PATHS`, skip review and → `blocked/` for you
   (never auto-merge). Separate from the optional prompt **label**.
7. **Review** — next member in the ring; `harness_reviewer_run` (read-only).
   - `approve` → merge to `main`, → `done/`
   - `request_changes` → retry (step 5) with checker comments
   - `block_human` → `blocked/` with notes
8. **Stop condition** — 3 blocks in a row → loop stops (usually ambiguous
   specs or a harness stuck in backoff).

## When a task is blocked

A file in `loop/queue/blocked/` means the loop stopped and is waiting on
you — nothing auto-retries it. That file is just the task spec; the actual
diff, commit(s), and branch are left untouched for inspection at
`.loop-worktrees/<task-id>` (branch `loop/<task-id>`) — `run.sh` never
deletes a blocked task's worktree the way it does for a merged one. Start
there and in `loop/log/<task-id>/`, then pick based on the cause:

| Why it's blocked | What to do |
|---|---|
| `request_changes` exhausted retries (still failing after `LOOP_MAX_RETRIES`) | Read the last checker verdict in `loop/log/<task-id>/`. If the fix is small, make it yourself in the preserved worktree and merge by hand — or edit the task's Scope/Acceptance criteria to reflect what actually needs doing, move the file back to `queue/pending/`, and let the loop retry from a clean attempt. |
| `block_human` verdict (checker found something ambiguous, or only unconfirmed/low-severity issues) | Read the checker's reasoning in the log. If it's a real judgment call (spec ambiguity, an architecture tradeoff), resolve it yourself — either fix and merge by hand, or tighten the task file and requeue to `pending/`. |
| Require-human-review path match (`LOOP_KIT_REQUIRE_HUMAN_REVIEW_PATHS` or `sensitive: true`) | This diff was never reviewed by the checker at all — review it yourself like any other PR before merging. There's no "requeue and let it through" here; it always needs your sign-off. |
| Maker wrote `<task-id>.NEEDS_INPUT.md` inside the worktree (hit scope it wasn't allowed to expand into) | Read that file. Decide whether to widen the task's Scope, split off a new task for the extra work, or clarify the Acceptance criteria — then requeue to `pending/`. |
| Maker's harness stuck in `backoff` at claim time | Not a content problem — see "Usage-limit backoff" below. Clear the cooldown (or wait it out) and requeue. |
| 3 blocks in a row (loop-level stop condition) | Work through the individual blocked tasks above first — this is usually a symptom of one of the other rows repeating, not a new problem. |

Once you've resolved a task by hand (merged it yourself, or decided it
needs no further loop attempt), clean up its worktree with
`git worktree remove -f .loop-worktrees/<task-id>` so it doesn't linger.

There is no auto-unblock path by design — a blocked task always needs a
human decision, however small.

## What this does not do

**This does not remove your review burden — it moves it.**

You're not watching every maker turn, but you should periodically:

- Read `loop/log/`
- Skim merged diffs
- Notice when "approve" is rubber-stamping plausible-but-wrong work

Two different models can still agree and both be wrong. Treat verify +
checker as raising the bar, not replacing you reading the code.

Start with short supervised batches (`LOOP_MAX_ITERATIONS=2` or `3`) —
not unattended overnight from day one.

## Adding tasks

```sh
loop/new_task.sh <slug> <milestone> [sensitive] [depends_on]
# or drop Txxx-short-name.md into queue/pending/ by hand
```

Keep tasks **atomic** — one PR-sized unit. Coarser work belongs in the
roadmap; this queue is the cut-down pieces.

`loop/new_task.sh` only writes the frontmatter and a `TODO:` skeleton for
Why/Scope/Acceptance criteria — you still write the actual content, and a
fresh-context maker gets exactly this file as its *entire* scope, so
under-specifying it is the single most common way a task goes sideways.
`loop/queue/done/` accumulates real examples over time, but there's nothing
there on a fresh install — so here's one that was actually taken through
`new_task.sh` → hand-implemented TDD-style → `loop/verify.sh` → merge on a
throwaway demo project, to calibrate against:

```markdown
---
id: T001
milestone: M1
sensitive: false
depends_on: []
---

# Add X-RateLimit-Remaining header to /health

## Why

M1 ("Health endpoint hardening", docs/roadmap.md) requires /health to be
suitable for a real load balancer to poll. A load balancer needs to know
its own budget before it gets throttled, so /health should expose a
rate-limit counter the same way the rest of the service will once
rate limiting lands — this task adds the header contract now, backed by a
simple fixed-window counter, so later work only has to swap the counter
implementation.

## Scope

Touch only `src/health.py` and `src/test_health.py`. Do not add a
general-purpose rate-limiting middleware or touch any other route — there
is only one route today.

## Acceptance criteria

- [ ] `GET /health` responds with an `X-RateLimit-Remaining` header whose
      value is an integer that decrements by 1 on each request within a
      60-second window, floors at 0, and resets after the window elapses.
- [ ] A test in `src/test_health.py` asserts the header is present and
      numeric on a normal request, and asserts it decrements after a
      second request within the same window (not just that the route
      still returns 200).
- [ ] `make build` and `make test` pass.
```

Notice what makes this specific enough to hand to a fresh-context agent:
Scope names the exact files to touch *and* the exact adjacent thing not to
build (a general middleware); each acceptance criterion says what a
reviewer should be able to see or run (a header value, a specific test
assertion), not just "works correctly." A second task in the same demo,
`T002-add-request-count-metric.md`, used `depends_on: [T001]` for a follow-on
that reuses T001's window-tracking state — `new_task.sh`'s fourth argument
writes that field for you: `loop/new_task.sh add-request-count-metric M1
false T001`.

Every `depends_on` link across `loop/queue/*/` forms a real dependency
graph — `loop/queue_graph.sh` prints it (plain text, or `--mermaid` for a
flowchart you can paste into any markdown viewer) instead of you tracing
`depends_on:` fields by hand across files:

```text
$ loop/queue_graph.sh
T001 [done] Add X-RateLimit-Remaining header to /health
T002 [pending] Expose request_count in /health response body — needs: T001 (done)  [ready to claim]
T003 [pending] Rotate the demo API key referenced in README  [ready to claim]
```

(That's real output from this exact queue — see "Adding tasks" above.)
`loop/queue_graph.sh --self-test` checks the ready/blocked-on-dependency
logic and the mermaid output against a throwaway fixture.

| Frontmatter | Purpose |
|---|---|
| `milestone:` | Required if `LOOP_KIT_ROADMAP_DOC` is set — must match a `## <id> — …` heading |
| `maker:` | Route to a specific ring member (must be in `LOOP_KIT_HARNESSES`) |
| `sensitive: true` | Always → `blocked/` for human sign-off (same outcome as `LOOP_KIT_REQUIRE_HUMAN_REVIEW_PATHS` matching the diff; use for one-off tasks) |
| `network_access: true` | Allow live local services (only adapters with a sandbox network toggle honor this; Codex is the built-in example) |
| `depends_on: [T001, …]` | Claim only after listed ids are in `done/` |
| `complexity:` | `quick` / `default` / `gnarly` — maker model tier |

### Require-human-review path gate

`LOOP_KIT_REQUIRE_HUMAN_REVIEW_PATHS` is an extended regex of path prefixes. After
verify succeeds, if **any** path in the diff matches, the task goes to
`queue/blocked/` and the checker is skipped — two models cannot auto-merge
those paths.

The install-time **label** (`--require-human-review-paths-label`) only appears in
review prompts (`{{REQUIRE_HUMAN_REVIEW_PATHS_LABEL}}`). It does not enforce the
gate. Prefer the regex for recurring directories (deploy, secrets, ADRs);
use `sensitive: true` on a task for one-offs.

## Reviewing a GitHub pull request

```sh
loop/review_pr.sh <pr-number> [--reviewer <member>] [--post-comment]
```

Same checker job, for a PR that never came from `queue/`:

1. Check out the PR into its own worktree
2. Render `pr_review_prompt.tpl.md` (shares `review_mandate.partial.md`
   with the queue review template)
3. Run `harness_reviewer_run` for the chosen member

`--reviewer` defaults to the first `LOOP_KIT_HARNESSES` entry. Prints
locally by default; `--post-comment` uses `gh pr comment`. See the
script header for full usage and the known limitation around branches
already checked out elsewhere.

## Council

```sh
loop/council.sh <question-file.md>
loop/council.sh --synthesize <question-file.md>
```

Read-only counterpart to the maker/checker loop: fan one question to
several models in parallel; save answers under
`loop/council/log/<timestamp>-<slug>/`. **Nothing writes to tracked docs** —
reconciling into a decision is a separate step.

| Config | Notes |
|---|---|
| `LOOP_KIT_COUNCIL_HARNESSES` | Same `harness` / `harness:model` syntax (default `codex opencode claude`) |
| Distinct / ≥2 | **Not** required — no self-review adjacency |
| `COUNCIL_SKIP="a b"` | Skip members for one run without editing config |
| `--synthesize` | One more council call: reads every member's answer and writes `synthesis.md` (convergence, an explicit call on divergence, a compact recommendation) — see `council_synthesis_prompt.tpl.md`. Still advisory only; still worth a skeptical read, same as any single model's take. |
| `--synthesizer MEMBER` / `LOOP_KIT_COUNCIL_SYNTHESIZER` | Who does the synthesizing. Default: the first member that actually got launched — meaning it may be reconciling its own answer among the others (no self-review adjacency rule applies to council, unlike the ring). Pick a distinct member explicitly when that matters. |

Each member needs `harness_council_run` in its adapter (codex, claude,
cursor, copilot, opencode all ship one). `loop/council.sh --self-test`
exercises fan-out and `--synthesize` against a stub harness (no real model
calls).

## SkillOpt-Sleep

**Optional, and off by default in every way that matters.** This is a
separate, off-loop companion — `loop/run.sh` behaves identically whether or
not you ever touch it. Skip this whole section if you just want the core
maker/checker loop; nothing here is required reading for that.

**Verified, not assumed:** `--non-interactive` installs default to
`--no-skillopt` (package install skipped entirely — see `install.sh`'s
`skillopt_do_install=0 # 0 unless --with-skillopt or interactive yes`), and
both places `run.sh` touches SkillOpt (`skillopt_trigger.sh after-done` /
`run-end`) are called with `|| true` — if the package was never installed,
or the trigger fails for any reason, the loop logs nothing and continues.
An *interactive* install leans toward offering the pip install (so new
users discover the feature), but the default trigger it wires up is
`remind`: a printed reminder after enough tasks land in `done/`, with zero
model calls and nothing staged.

### What it actually does, in plain language

Every task the loop runs leaves evidence behind: what the maker tried, what
the checker caught, whether it passed clean or needed retries. SkillOpt-Sleep
(an offline tool from [Microsoft SkillOpt](https://github.com/microsoft/SkillOpt),
`pip install skillopt`) mines that evidence and proposes small, bounded text
edits to your project's own playbook — the `LEARNED` block inside
`.claude/skills/project-loop/SKILL.md`, the file future maker/checker runs
read for project-specific procedure. It's a retro that drafts its own notes
from real outcomes, instead of relying on you to remember to write them down.

It never touches model weights, never writes anywhere else in your repo, and
never applies anything automatically:

- Edits are bounded — `LOOP_KIT_SKILLOPT_EDIT_BUDGET` (default `4`) caps how
  much text can change in one cycle.
- A candidate edit is only *staged* if replaying past tasks under it scores
  measurably better, on held-out tasks it wasn't tuned against, than the
  current skill — the "held-out gate." Below that bar, it's discarded, not
  staged weaker.
- Staged proposals sit inert until you run `skillopt_sleep.sh adopt`
  yourself. Nothing reaches `SKILL.md` without that explicit step.

### A real worked example (mock backend — no login, no API cost)

This ran for real, end to end, in a throwaway demo project with one
completed task in `loop/log/T001/` (maker attempt + checker approval, same
shape `run.sh` writes) and `LOOP_KIT_SKILLOPT_BACKEND=mock`:

```text
$ loop/skillopt_sleep.sh dry-run --backend mock
[skillopt_export] wrote 1 task(s) → loop/state/skillopt-tasks.json
[skillopt_sleep] running: skillopt-sleep dry-run --backend mock --project ... \
  --target-skill-path .claude/skills/project-loop/SKILL.md --edit-budget 4 \
  --max-tasks 40 --tasks-file loop/state/skillopt-tasks.json
[sleep] night 2: 0 sessions -> 1 tasks
[sleep] held-out 0.993 -> 0.993 => reject (accepted=False)

$ loop/skillopt_sleep.sh status
[sleep] nights so far: 1
[sleep] no staged proposals yet.
```

That rejection is the gate working as designed, not a broken example:
`mock` is deliberately plumbing-only (see the Backends table below) — it
never proposes a real edit, so held-out scores can't improve, so nothing
gets staged. It's the same code path a real backend (`claude`, `codex`,
`handoff`) goes through, minus an actual model call, which is exactly why
`mock` is safe to run against a real project to sanity-check the wiring
before pointing a paid backend at it. With a real backend, a genuinely
useful proposal instead shows up in `skillopt_sleep.sh status`, and only
reaches `.claude/skills/project-loop/SKILL.md` after you run `adopt`.

**Kit philosophy:** frozen target agents, bounded text edits, held-out
validation, **human adopt** — nothing live until you say so.

**Subscription-first:** use logged-in `claude` / `codex`, or `handoff`
(Claude / Codex / **Cursor** / **Copilot** / **opencode** via
`harness_council_run`). No API keys required for those paths. SkillLens
(research benchmark pipeline) is out of scope.

```text
loop/log + queue outcomes
  → loop/skillopt_export.sh          (tasks JSON, reviewed:false)
  → inspect / redact
  → loop/skillopt_sleep.sh run --backend claude --i-reviewed
     (or --backend handoff --handoff-harness copilot)
  → staged proposal (LEARNED block only)
  → loop/skillopt_sleep.sh adopt
```

### Backends

| Backend | Auth | Notes |
|---|---|---|
| `mock` | none | Plumbing / deterministic; default install value |
| `claude` | Claude Code login | `claude -p` — no API key |
| `codex` | Codex login | `codex exec` |
| `handoff` | kit harness | Sleep writes prompts; `skillopt_handoff.sh` answers via `harness_council_run` (claude / codex / cursor / copilot / opencode). Needs SkillOpt newer than PyPI 0.2.0 |

Azure / OpenAI-compatible API backends exist upstream; not kit defaults.

### Setup

`install.sh` (fresh or `--update`) can install the package, write
`LOOP_KIT_SKILLOPT_*`, and copy the engine starter to
`~/.skillopt-sleep/config.json` if missing — see `install.sh --help`.

Manual equivalent:

```sh
pip install skillopt
# For handoff / latest CLI flags until the next PyPI cut:
#   pip install "git+https://github.com/microsoft/SkillOpt.git"
mkdir -p ~/.skillopt-sleep
cp loop/skillopt-sleep.config.json.example ~/.skillopt-sleep/config.json
# evolve_memory=false, gate on, auto_adopt off
```

Knobs: `LOOP_KIT_SKILLOPT_*` in `loop.config.sh` — see
`loop.config.sh.example`.

### Activity triggers (from `run.sh`)

Default: **remind** when enough tasks land in `done/` — no model calls,
no adopt.

| Variable | Default | Meaning |
|---|---|---|
| `LOOP_KIT_SKILLOPT_TRIGGER` | `remind` | `off` \| `remind` \| `dry-run` \| `run` |
| `LOOP_KIT_SKILLOPT_TRIGGER_EVERY_DONE` | `10` | New `done/` tasks since last fire (`0` = never) |
| `LOOP_KIT_SKILLOPT_TRIGGER_ON_RUN_END` | `1` | Evaluate at end of `run.sh` (`0` = after each merge to done) |
| `LOOP_KIT_SKILLOPT_TRIGGER_BACKEND` | `mock` | Backend for auto `dry-run`/`run` |

Watermark: `loop/state/skillopt-trigger.json`. Escalate to `dry-run` /
`run` to auto-export and stage; **adopt stays manual**. Sensitive repos:
`TRIGGER=off`. Nightly cron (`skillopt_sleep.sh schedule`) is the separate
time-based path.

### Commands

| Command | What it does |
|---|---|
| `skillopt_sleep.sh export` | Write `loop/state/skillopt-tasks.json` |
| `skillopt_sleep.sh dry-run --backend mock` | Export + replay, no model calls |
| `skillopt_sleep.sh run --backend claude --i-reviewed` | Full cycle via Claude Code |
| `skillopt_sleep.sh run --backend handoff --handoff-harness cursor --i-reviewed` | Full cycle via kit harness |
| `skillopt_sleep.sh run --backend handoff --handoff-harness copilot --i-reviewed` | Full cycle via Copilot CLI |
| `skillopt_sleep.sh run --backend handoff --handoff-harness opencode --i-reviewed` | Full cycle via opencode |
| `skillopt_sleep.sh status` | Latest staged proposal + night report |
| `skillopt_sleep.sh adopt` | Apply staged edits (backs up prior skill) |
| `skillopt_sleep.sh schedule` | Install nightly cron for this project |
| `skillopt_trigger.sh --self-test` | Watermark logic |
| `skillopt_handoff.sh --self-test` | Pending→answer wiring (no real model) |
| `skillopt_export.sh --self-test` | Exporter without `skillopt` installed |

### Data boundary

- Export is local + read-only over `loop/log/` / `loop/queue/`
- `mock` makes no model calls
- `claude` / `codex` send truncated task content through your logged-in CLI;
  wrapper **refuses** until `"reviewed": true` (`--i-reviewed` after
  inspect/redact)
- `handoff` keeps model calls inside the chosen kit harness
- Prefer loop-native `--tasks-file` (default) over harvesting
  `~/.claude` / `~/.codex` transcripts

### What gets trained

Managed skill: `LOOP_KIT_SKILLOPT_SKILL_PATH` (default
`.claude/skills/project-loop/SKILL.md`).

SkillOpt only mutates the protected `<!-- SKILLOPT-SLEEP:LEARNED -->`
block. Standing procedures + quality bar above that block stay yours.

### Domain-specific review guidance, without routing by path

If a domain in your codebase (auth, billing, a migration-prone schema)
keeps needing sharper review than the rest, the fix this kit is built
for is **not** hardcoding "always route `src/auth/` to member X because
it's better at this" — that preference goes stale the moment models
change, and different projects would want different answers anyway. The
fix is encoding the domain knowledge itself as a durable, model-agnostic
instruction, so *whichever* member the ring happens to route to applies
it. Two levers, with different reach:

| Lever | Reach | Evolves via |
|---|---|---|
| `review_mandate.partial.md` (numbered adversarial items) | Every harness, every review — this text is rendered directly into the prompt every reviewer receives, regardless of CLI. | Hand-edit only; SkillOpt never touches it. |
| `.claude/skills/project-loop/SKILL.md` (Standing procedures + `LEARNED` block) | **Claude Code only** — loaded automatically when `claude` is the acting harness (its `description` frontmatter is written to match "implementing or reviewing loop queue tasks"), or during an interactive Claude Code session in the repo. Codex/Cursor/Copilot/opencode never read it. | Standing procedures: hand-edit. `LEARNED` block: SkillOpt-Sleep, from real loop/log evidence, gated by held-out validation + your `adopt`. |

For guidance that must apply no matter which ring member reviews the
diff (e.g. "diffs touching `src/auth/` must verify session tokens are
never logged"), add it as a numbered item to `review_mandate.partial.md`
— same place you'd add any other recurring failure mode, per "Not
prompted (edit by hand)" in the root README.

To have SkillOpt-Sleep *discover and propose* that kind of domain-specific
rule instead of writing it by hand: accumulate real `done/`/`blocked/`
tasks that touch the domain, then run `skillopt_sleep.sh run --backend
claude` (or another real backend). The mined evidence already carries
each task's file paths (via its Scope) and outcome, so a domain that
keeps producing `request_changes`/`blocked` outcomes is exactly the
pattern the held-out gate is designed to surface as a proposal — one you
review and `adopt`, not a routing rule you maintain by hand.

That said, an adopted rule still only reaches Claude Code, per the table
above. If it needs to reach every harness, copy it into
`review_mandate.partial.md` yourself once you've adopted it.

Claude Code also gets a thin `.claude/skills/skillopt-sleep/` pointer
(same pattern as `council` / `new-task`).

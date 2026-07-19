# The loop

A "loop engineering" setup (Steinberger / Osmani): written spec + stop
condition, run by a script, with a **maker** and a separate **checker** so
the implementer never grades its own homework.

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
- Downstream of the maker (verify → sensitive gate → review → merge) is
  identical for every harness; only the attempt step differs

**Sandbox note (built-ins):** Codex runs with OS sandbox
(`-s workspace-write`). Claude / Cursor / Copilot / opencode have no
equivalent here — lean on worktree isolation + review; reserve those makers
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

### State

Queue dirs + `loop/log/<task-id>/` + `loop/state/backoff.txt` + git
history. Delete this directory and `git log` and you can still reconstruct
what happened — that's the point.

## Layout

```
loop/queue/pending/      not started (filename order: T001 before T002)
loop/queue/in_progress/  current task (crash detection)
loop/queue/blocked/      failed twice, or sensitive path — needs you
loop/queue/done/         merged
loop/log/<task-id>/      maker / verify / review transcripts
loop/state/backoff.txt   usage-limit cooldowns
loop/state/skillopt-tasks.json    SkillOpt export
loop/state/skillopt-trigger.json  activity-trigger watermark
loop/loop.config.sh      per-repo settings
loop/run.sh              driver (no per-harness logic)
loop/verify.sh           automated gate
loop/skillopt_*.sh       SkillOpt-Sleep helpers
loop/task_prompt.tpl.md / review_prompt.tpl.md / council_prompt.tpl.md
loop/harnesses/<name>.sh + TEMPLATE.sh.example + new_harness.sh
loop/council.sh          parallel design opinions
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
6. **Sensitive paths** — matching diffs always → `blocked/` (human), even
   if verify + review would pass.
7. **Review** — next member in the ring; `harness_reviewer_run` (read-only).
   - `approve` → merge to `main`, → `done/`
   - `request_changes` → retry (step 5) with checker comments
   - `block_human` → `blocked/` with notes
8. **Stop condition** — 3 blocks in a row → loop stops (usually ambiguous
   specs or a harness stuck in backoff).

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

| Frontmatter | Purpose |
|---|---|
| `milestone:` | Required if `LOOP_KIT_ROADMAP_DOC` is set — must match a `## <id> — …` heading |
| `maker:` | Route to a specific ring member (must be in `LOOP_KIT_HARNESSES`) |
| `sensitive: true` | Always → `blocked/` for human sign-off |
| `network_access: true` | Allow live local services (only adapters with a sandbox network toggle honor this; Codex is the built-in example) |
| `depends_on: [T001, …]` | Claim only after listed ids are in `done/` |
| `complexity:` | `quick` / `default` / `gnarly` — maker model tier |

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

Each member needs `harness_council_run` in its adapter (codex, claude,
cursor, copilot, opencode all ship one).

## SkillOpt-Sleep

Optional offline companion: refine `.claude/skills/project-loop/SKILL.md`
from this loop's scored evidence via
[Microsoft SkillOpt-Sleep](https://github.com/microsoft/SkillOpt)
(`pip install skillopt`).

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

For recurring *reviewer* failure modes, prefer numbered items in
`review_mandate.partial.md` (injected into every review prompt). The
project skill is the durable procedure layer around the ring.

Claude Code also gets a thin `.claude/skills/skillopt-sleep/` pointer
(same pattern as `council` / `new-task`).

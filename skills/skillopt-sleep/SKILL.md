---
description: >
  Refine this project's loop skill from maker/checker evidence via Microsoft
  SkillOpt-Sleep using subscription CLIs (Claude Code / Codex) or kit handoff
  (Cursor / Copilot / opencode). Use when the user wants to export loop/log,
  run a dry-run or sleep cycle, inspect a staged proposal, adopt gated skill
  edits, or schedule offline self-evolution of
  .claude/skills/project-loop/SKILL.md. User-invoked — must not auto-adopt.
  Does not require Anthropic/OpenAI API keys for claude/codex/handoff backends.
argument-hint: [export | dry-run | run | status | adopt | schedule]
disable-model-invocation: true
---

This project wires Microsoft SkillOpt-Sleep into the maker/checker loop.
Logic lives in `loop/skillopt_sleep.sh`, `loop/skillopt_export.sh`, and
`loop/skillopt_handoff.sh` — this skill is a thin pointer so Codex/Cursor/
Copilot users can run the same commands from a terminal.

Read `loop/README.md`'s "SkillOpt-Sleep" section if you haven't: it covers
subscription backends, export → review → gate → adopt, and the data boundary.

**SkillLens** (Microsoft's research benchmark toolkit) is out of scope — do
not install or run it for this workflow.

## What to do

1. Decide the action from $ARGUMENTS (default to explaining status if unclear):

   | Intent | Command |
   |---|---|
   | Export loop evidence only | `loop/skillopt_sleep.sh export` |
   | Plumbing check (no model) | `loop/skillopt_sleep.sh dry-run --backend mock` |
   | Real cycle (Claude subscription) | `loop/skillopt_sleep.sh run --backend claude --i-reviewed` |
   | Real cycle (Codex subscription) | `loop/skillopt_sleep.sh run --backend codex --i-reviewed` |
   | Real cycle via Cursor harness | `loop/skillopt_sleep.sh run --backend handoff --handoff-harness cursor --i-reviewed` |
   | Real cycle via Copilot harness | `loop/skillopt_sleep.sh run --backend handoff --handoff-harness copilot --i-reviewed` |
   | Real cycle via opencode harness | `loop/skillopt_sleep.sh run --backend handoff --handoff-harness opencode --i-reviewed` |
   | See staged proposal | `loop/skillopt_sleep.sh status` |
   | Apply staged proposal | `loop/skillopt_sleep.sh adopt` |
   | Nightly cron | `loop/skillopt_sleep.sh schedule` |

2. For a real backend (`claude` / `codex` / `handoff`):

   a. Run `loop/skillopt_sleep.sh export` (writes
      `loop/state/skillopt-tasks.json`, `reviewed: false`).
   b. Open that JSON; redact secrets / sensitive paths.
   c. Re-run with `--i-reviewed` (or `export --reviewed`) only after the user
      confirms the file is safe to send through their logged-in CLI / harness.
   d. Show the staged proposal from `status`; **do not** `adopt` unless the
      user explicitly asks. Adoption backs up the prior skill file first.

3. Prefer loop-native `--tasks-file` evidence (the wrapper default) over
   harvesting `~/.claude` / `~/.codex` chat transcripts. Pass `--no-tasks-file`
   only if the user explicitly wants transcript harvest instead.

4. Target skill path defaults to `LOOP_KIT_SKILLOPT_SKILL_PATH` (usually
   `.claude/skills/project-loop/SKILL.md`). Sleep may only edit the protected
   `SKILLOPT-SLEEP:LEARNED` block — leave hand-written sections alone.

5. Note: `loop/run.sh` may already *remind* (or auto dry-run/run, if configured)
   when enough tasks have landed in `done/` since the last trigger — see
   `LOOP_KIT_SKILLOPT_TRIGGER*` in `loop.config.sh`. Adopt is never automatic.
   Auto backends may be `mock|claude|codex|handoff` (subscription CLIs).

6. If `skillopt-sleep` / `skillopt_sleep` is missing, tell the user to
   `pip install skillopt` (or `uv tool install skillopt`). For `--backend
   handoff`, prefer
   `pip install "git+https://github.com/microsoft/SkillOpt.git"` until PyPI
   includes handoff. Optionally copy
   `loop/skillopt-sleep.config.json.example` → `~/.skillopt-sleep/config.json`.

7. Run the chosen command via Bash. Summarize the report (baseline → candidate,
   accepted/rejected edits, staging path). Do not invent adopt approval.
   Do not ask the user for API keys for claude/codex/handoff — those use
   logged-in CLIs / kit harnesses.

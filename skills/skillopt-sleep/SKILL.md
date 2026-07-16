---
description: >
  Refine this project's loop skill from maker/checker evidence via Microsoft
  SkillOpt-Sleep. Use when the user wants to export loop/log into a Sleep tasks
  file, run a dry-run or nightly sleep cycle, inspect a staged proposal, adopt
  gated skill edits, or schedule offline self-evolution of
  .claude/skills/project-loop/SKILL.md. User-invoked — spends API budget on real
  backends and must not auto-adopt.
argument-hint: [export | dry-run | run | status | adopt | schedule]
disable-model-invocation: true
---

This project wires Microsoft SkillOpt-Sleep into the maker/checker loop.
Logic lives in `loop/skillopt_sleep.sh` and `loop/skillopt_export.sh` — this
skill is a thin pointer so Codex/Cursor users can run the same commands from a
terminal.

Read `loop/README.md`'s "SkillOpt-Sleep" section if you haven't: it covers the
export → review → gate → adopt contract and the data boundary for real backends.

## What to do

1. Decide the action from $ARGUMENTS (default to explaining status if unclear):

   | Intent | Command |
   |---|---|
   | Export loop evidence only | `loop/skillopt_sleep.sh export` |
   | Plumbing check (no API) | `loop/skillopt_sleep.sh dry-run --backend mock` |
   | Real optimization cycle | `loop/skillopt_sleep.sh run --backend claude` (or `codex`) **after** review |
   | See staged proposal | `loop/skillopt_sleep.sh status` |
   | Apply staged proposal | `loop/skillopt_sleep.sh adopt` |
   | Nightly cron | `loop/skillopt_sleep.sh schedule` |

2. For a real backend (`claude` / `codex` / `handoff`):

   a. Run `loop/skillopt_sleep.sh export` (writes
      `loop/state/skillopt-tasks.json`, `reviewed: false`).
   b. Open that JSON; redact secrets / sensitive paths.
   c. Re-run with `--i-reviewed` (or `export --reviewed`) only after the user
      confirms the file is safe to send to the provider.
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

6. If `skillopt-sleep` / `skillopt_sleep` is missing, tell the user to
   `pip install skillopt` (or `uv tool install skillopt`) and optionally copy
   `loop/skillopt-sleep.config.json.example` → `~/.skillopt-sleep/config.json`.

7. Run the chosen command via Bash. Summarize the report (baseline → candidate,
   accepted/rejected edits, staging path). Do not invent adopt approval.

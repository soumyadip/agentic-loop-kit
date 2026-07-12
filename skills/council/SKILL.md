---
description: Get independent scope/spec opinions on a design or roadmap question from several separate LLMs (default: Codex, an opencode-hosted open model, and Claude — configurable via LOOP_KIT_COUNCIL_HARNESSES), gathered in parallel, then synthesize them. User-invoked only — it takes several minutes and multiple model calls.
argument-hint: [question or topic to scope]
disable-model-invocation: true
---

This project has its own council mechanism: `loop/council.sh` (see
`loop/README.md`'s "Council" section for the full explanation and
`loop/council_prompt.tpl.md` for the wrapper each member receives). This
skill is a thin pointer to it, not a reimplementation — the actual logic
lives in the script so contributors using other agentic tools (Codex,
etc.) can run it directly from a terminal too.

Once this project has used the council a few times to settle real design
questions, note a worked example or two here (which past ADR/decision doc
was produced this way) — it's the fastest way for a new question to see
what "good" looks like.

## What to do

1. Turn this into a real question if it isn't already one:

   $ARGUMENTS

   A good question names the exact docs/files each member should read
   before answering (this project's equivalent of a vision/architecture/
   roadmap/decisions doc, plus whatever's specifically relevant), asks for
   a real position under concrete headings, and says "don't hedge, this is
   read-only." Write it to a scratch file — don't hand-type it three
   times.

2. Run `loop/council.sh <your-question-file.md>` via Bash with
   `run_in_background: true` — it takes several minutes. Who's asked is
   `LOOP_KIT_COUNCIL_HARNESSES` in `loop.config.sh` (default `codex
   opencode claude`); read `loop/council.sh`'s own usage header for the
   current env vars (`COUNCIL_SKIP` to skip specific members for one run,
   per-harness `LOOP_KIT_<NAME>_COUNCIL_MODEL`/`LOOP_KIT_COUNCIL_TIMEOUT`
   in `loop.config.sh.example`) if you need to tune it.

3. Once notified, read the output files it reports (one per configured
   member) and synthesize: note where members converged unprompted
   (strongest signal), make an explicit call wherever they split and say
   why, and present the synthesis compactly before writing anything into
   the project's own docs/specs. Only write those files if asked to, or
   after the user confirms the synthesis — a council run that only
   informs the conversation is a valid outcome on its own.

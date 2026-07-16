---
name: project-loop
description: >
  Project-level operating procedures for this repo's maker/checker agentic loop.
  Use when implementing or reviewing loop queue tasks, writing acceptance criteria,
  deciding scope boundaries, or consolidating recurring failure modes into durable
  rules. SkillOpt-Sleep may append validated lessons inside the LEARNED block only.
---

# Project loop skill

This skill steers agents working inside this repository's agentic maker/checker
loop (`loop/`). Hand-written rules live outside the LEARNED markers. SkillOpt-Sleep
only edits the protected LEARNED block after a held-out gate accepts the change.

## How this project runs agents

1. Work comes from atomic task files in `loop/queue/pending/` (scaffold with
   `loop/new_task.sh` / the `new-task` skill).
2. A maker harness attempts the task in a git worktree; `loop/verify.sh` gates it.
3. A *different* harness reviews the diff against `loop/review_mandate.partial.md`
   and must end with `VERDICT: approve|request_changes|block_human`.
4. State lives on disk (`loop/log/`, queue dirs, git) — never in conversation memory.

## Skill quality bar (SkillLens)

When adding or adopting learned rules, prefer content that scores well on these
dimensions — SkillLens found surface-plausible advice does **not** predict utility:

1. **Failure-mechanism encoding** — name the exact failure mode (symptom + cause),
   not a vague “be careful with X.”
2. **Actionable specificity** — state a concrete remedy the agent can execute
   (“run command Y”, “assert Z before merging”), not generic guidance.
3. **High-risk action blacklist** — call out actions that repeatedly caused
   negative transfer (touching governance paths, expanding scope, rubber-stamp
   review language, etc.).

Format rewrites alone do not help. Prefer a mixed success/failure experience pool
when consolidating — all-failure pools produce worse skills.

## Standing procedures

- Read `{{PRINCIPLES_DOC}}` before changing application code; follow its TDD /
  architecture rules when stated.
- Touch only what the task Scope names. If you need more, write
  `loop/queue/in_progress/<id>.NEEDS_INPUT.md` instead of guessing.
- Do not modify `loop/` scripts/templates or governance-sensitive paths unless the
  task explicitly scopes them — those diffs always block for a human.
- After verify failures or `request_changes`, fix the cited failure; do not restart
  the task in a different shape unless the failure shows the approach was wrong.
- Reviewers: run the adversarial mandate for real; confirmed high/critical bugs →
  `request_changes`. Unconfirmed or low/medium → `block_human`, not silent approve.

## Around-loop helpers

- Scaffold tasks: `loop/new_task.sh` / skill `new-task`
- Multi-model design opinions: `loop/council.sh` / skill `council`
- Refine this skill from loop evidence: `loop/skillopt_sleep.sh` / skill `skillopt-sleep`

<!-- SKILLOPT-SLEEP:LEARNED START -->
## Learned preferences & procedures

_This block is maintained by SkillOpt-Sleep. Edits here are proposed offline,
validated against held-out loop tasks, and adopted only after you approve them.
Hand-edits outside this block are never touched._

- Prefer checkable acceptance criteria that `loop/verify.sh` (or an equivalent
  project command) can exercise — not prose-only “done when it feels right.”
- When a review repeatedly cites the same bug class, add it as a numbered item
  near the top of `loop/review_mandate.partial.md` (human edit) rather than only
  burying it in chat.

<!-- SKILLOPT-SLEEP:LEARNED END -->

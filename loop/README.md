# The loop

This is a "loop engineering" setup in the sense Peter Steinberger and Addy Osmani describe it: a written spec plus a stop condition, run by a script, with a maker model and a separate checker model so the implementer never grades its own homework.

- **Maker**: Codex CLI (`codex exec`) by default. Gets one atomic task per run, fresh context every time. State never lives in its head — it lives in this directory and in git. A task file's `maker:` frontmatter can route that one task to a different implementer instead:
  - `maker: claude` — `claude -p --dangerously-skip-permissions`.
  - `maker: cursor` — `cursor-agent -p --force`.
  - Everything downstream (verify, the sensitive-path gate, review, merge-on-approve) is identical regardless of which maker ran — only the attempt step itself differs. One real difference to know about: Codex's attempt runs inside an OS-level sandbox (`-s workspace-write`); `claude`/`cursor`'s agents have no equivalent sandbox as far as this script can tell, so a non-Codex maker task leans more on worktree isolation and the review step than on a sandbox boundary during the attempt itself — reserve those for tasks you're comfortable with on that basis (non-sensitive, well-scoped).
- **Maker model selection is complexity-tiered**, independent of the checker models below. A task file's optional `complexity: quick` or `complexity: gnarly` frontmatter (default if unset: `default`) picks which model+effort its maker step runs at — see the `*_MAKER_MODEL_*`/`*_MAKER_EFFORT_*` variables near the top of `run.sh` for the current defaults and their `LOOP_*` env var overrides.
- **Checker**: a fixed 3-way review cycle so no model ever grades its own homework — Codex's work is checked by Claude, Claude's by Cursor, Cursor's by Codex. All three reviewers render the same `review_prompt.tpl.md`; the only thing that differs per reviewer is a one-line `{{REVIEWER_MODE_NOTE}}` describing that CLI's own read-only mode (`run.sh` fills this in per call, it's not a per-reviewer file):
  - Codex maker → **Claude** checks (`claude -p --permission-mode plan` — read/run, no edits).
  - Claude maker → **Cursor** checks (`cursor-agent -p --force --mode plan` — plan mode is read-only, verified by hand: it refuses file writes and says so).
  - Cursor maker → **Codex** checks (`codex exec review --base main`).
  - The rendered prompt always ends by asking for the same closing line, so the parsing logic downstream doesn't care which model answered: `VERDICT: approve|request_changes|block_human`. This is the only step that can actually merge or block a task.
- **Red-teaming**: the checker isn't just verifying the maker's own claims — it's instructed to actively try to break the diff, against an adversarial mandate baked into `review_prompt.tpl.md` (mocked vs. real dependencies, boundary/type-coercion bugs, authorization fail-closed behavior, audit-trail completeness, test reachability, injection, idempotency/partial-failure). Sharpen the numbered list with your own project's specific recurring failure modes as you learn them — see the TODO comment in the template. `LOOP_REVIEW_BREAK_ATTEMPTS` (default 1, clamped to [1,3]) bounds how many distinct break attempts the reviewer makes per review before concluding.
  - **Adjudication ("coordinator") is folded into the same reviewer call, not a separate model.** A genuinely separate coordinator would re-introduce the same self-grading question this whole cycle exists to avoid (who checks the coordinator?) at the cost of a 4th API call per task. Instead, the reviewer must self-adjudicate its own bug reports against a fixed policy: any bug marked **confirmed + severity high/critical** auto-routes to `request_changes` (handed back to the maker verbatim); anything **unconfirmed or low/medium severity** routes to `block_human` rather than being silently dismissed or forwarded as if it were confirmed — real human adjudication is reserved for exactly the ambiguous cases.
- **opencode** is intentionally *not* part of this maker/checker rotation — it's reserved for `loop/council.sh`'s independent third-opinion role (see "Council" below), a different job (asking three models the same question with no visibility into each other's answers) from a pipeline where each step is supposed to see the prior step's work.
- **Usage-limit backoff**: none of Codex/Claude/cursor-agent expose a "remaining quota" API — the only signal any of them gives is the error text printed once a daily/weekly limit is already hit. `run.sh` reacts to that: any maker or reviewer call whose output matches that class of message gets a cooldown recorded in `loop/state/backoff.txt` (`<model> <until-epoch>`, best-effort timestamp parsed from the message, falling back to a flat 1-hour cooldown if the wording doesn't match). Before starting a task, the loop checks whether that task's maker is currently in a recorded cooldown and, if so, blocks it immediately without spending a worktree or an attempt. Delete `loop/state/backoff.txt` (or an individual model's line) to manually clear a cooldown early.
- **State**: the queue directories below, plus `loop/log/<task-id>/`, plus `loop/state/backoff.txt`, plus git history itself. If you delete this directory and `git log`, you can still reconstruct what happened — that's the point.

## Layout

```
loop/queue/pending/      tasks not started, picked in filename order (T001 before T002)
loop/queue/in_progress/  the task currently being worked (lets you detect a crashed run)
loop/queue/blocked/      automated path failed twice, or the task touches a sensitive path — needs you
loop/queue/done/         merged
loop/log/<task-id>/      full transcript of every attempt: maker output, verify output, review
loop/state/backoff.txt   per-model usage-limit cooldowns, reactively recorded (see Checker above)
loop/loop.config.sh      per-repo settings (build/test commands, sensitive-path regex, etc.) — see loop.config.sh.example
loop/run.sh              the driver
loop/verify.sh           the automated gate — put your project's real build/lint/test/typecheck commands in loop.config.sh
loop/task_prompt.tpl.md      one template, rendered per task and handed to whichever maker CLI is running it
loop/review_prompt.tpl.md    one template, rendered per review and handed to whichever CLI is checking (claude/cursor-agent/codex)
```

## Running it

```sh
./loop/run.sh                 # processes up to LOOP_MAX_ITERATIONS pending tasks (default 5), then stops
LOOP_MAX_ITERATIONS=1 ./loop/run.sh   # do exactly one task — good for your first run, or for watching it work
```

Each task runs in its own `git worktree` on a branch named `loop/<task-id>`, so a bad run never touches your main branch directly, and several tasks could in principle run in parallel later without colliding.

## What actually happens per task

1. Take the oldest file in `queue/pending/`, read its `maker:` frontmatter. If that maker is currently in a recorded backoff cooldown (see Checker above), block the task immediately without creating a worktree or spending an attempt.
2. Move it to `queue/in_progress/`, create a worktree + branch for it.
3. Render `task_prompt.tpl.md` with the task file's contents and hand it to the task's maker (`codex exec -s workspace-write` by default; `claude -p --dangerously-skip-permissions`, or `cursor-agent -p --force` for `maker: claude`/`cursor`). A usage-limit error from the maker records a backoff cooldown for that model.
4. Run `loop/verify.sh` inside the worktree.
5. If verify fails: retry up to `LOOP_MAX_RETRIES` (default 2), feeding the failure output back into a fresh maker prompt each time — not a resumed conversation, a new one that reads the failure off disk, per the "state lives on disk, not in the model's head" principle.
6. If the task's diff touches a sensitive path (see `SENSITIVE_PATTERN` in `run.sh`, driven by `LOOP_KIT_SENSITIVE_PATTERN` in `loop.config.sh`) it always goes to `blocked/` for your sign-off, no matter what verify or the checker say.
7. Determine the reviewer from the fixed cycle (codex maker → claude reviews; claude maker → cursor reviews; cursor maker → codex reviews), render that reviewer's prompt template, and run it against the worktree read-only (`claude -p --permission-mode plan`, `cursor-agent -p --mode plan`, or `codex exec review --base main`). The checker's response must end with a line `VERDICT: approve|request_changes|block_human`. A usage-limit error from the checker records a backoff cooldown for that model and blocks the task for a human instead of misreading the error as "no verdict."
   - `approve` → merge to `main`, move task to `done/`.
   - `request_changes` → counts as a retry (step 5), with the checker's specific comments fed back to the maker.
   - `block_human` → move to `blocked/` with the checker's notes attached.
8. If 3 tasks in a row end up in `blocked/`, the loop stops itself and tells you, instead of grinding the rest of the queue into the blocked pile. That many blocks in a row usually means the spec is ambiguous (or that a maker's backoff cooldown is now blocking every task routed to it) — not that the tasks are hard.

## What this does not do

Per Osmani's caveat, which is worth keeping in view: **this does not remove your review burden, it just moves it.** You're not watching every maker turn, but you are responsible for periodically reading `loop/log/`, skimming merged diffs, and noticing when a checker's "approve" verdict is rubber-stamping something plausible-looking but wrong. The review cycle means the checker is always a different model from the maker, but two different models can still agree with each other and both be wrong. Treat the automated gate and the checker's review as raising the bar for what reaches you, not as a replacement for you reading the code.

Practically: run this in short supervised batches (`LOOP_MAX_ITERATIONS=2` or `3`) for the first few days while you build trust in the queue quality and the verify gate, rather than letting it run unattended overnight from day one.

## Adding tasks

Drop a new `Txxx-short-name.md` file in `queue/pending/`, following the frontmatter format in the seeded tasks (or run `loop/new_task.sh <slug> <milestone> [sensitive] [depends_on]` to scaffold one). Keep tasks atomic — one PR-sized unit, not "build the whole feature." Coarser work belongs in whatever this project uses for epics/roadmap; this queue is where it gets cut into pieces small enough for a fresh-context agent to do correctly in one pass.

If `LOOP_KIT_ROADMAP_DOC` is set in `loop.config.sh`, every task file's frontmatter must include a `milestone:` field matching a milestone id from that doc (a `## <id> — ...` heading). Leave that variable unset/empty to skip this check.

An optional `maker: claude` or `maker: cursor` field routes that task to a different implementer instead of Codex (see "Maker" above, and the reviewer cycle it implies) — omit it (or set `maker: codex`) for the default. Reserve non-Codex makers for non-sensitive, well-scoped tasks; `sensitive: true` tasks still go to `blocked/` for human sign-off regardless of which maker attempted them. Also optional: `network_access: true`, for tasks whose acceptance criteria require reaching a live local service rather than a mock — see `run.sh`'s own comment on it. Scoped per-task; the sandbox stays network-denied by default otherwise.

Also optional: `depends_on: [T001, T002]` (default `[]`) — the picker only claims a task once every listed id has a file in `queue/done/`, instead of grabbing the alphabetically-next pending file regardless.

## Council

`loop/council.sh <question-file.md>` is the read-only counterpart to the maker/checker loop above: it fans a single question out to three independent LLMs in parallel (Codex, an opencode-hosted model, Claude) and saves each answer to `loop/council/log/<timestamp>-<slug>/`, for a human (or a follow-up agent session) to synthesize into a design doc/decision record. Nothing here writes to your tracked docs — reconciling the three answers into an actual decision is a separate, deliberate step. See the script's own header comment for usage and env vars.

#!/usr/bin/env bash
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

log()  { echo "[loop] $*"; }
die()  { echo "[loop] STOP: $*" >&2; exit 1; }

# Per-repo settings written by install.sh (build/test commands, sensitive-path pattern, etc.) —
# see loop.config.sh.example. Safe to be absent: every var it might set has a generic fallback
# below via ${VAR:-default}.
[[ -f "$ROOT/loop/loop.config.sh" ]] && source "$ROOT/loop/loop.config.sh"

# Unlike loop.config.sh above, this one is not optional: render() silently inserts empty string
# for a missing {{RED_TEAM_MANDATE}} source, and a reviewer prompt that quietly loses its entire
# adversarial mandate is a much worse failure than a script that refuses to start.
[[ -f "$ROOT/loop/review_mandate.partial.md" ]] || die "missing loop/review_mandate.partial.md — required by review_prompt.tpl.md/pr_review_prompt.tpl.md via render()'s {{RED_TEAM_MANDATE}} token"

PENDING="$ROOT/loop/queue/pending"
IN_PROGRESS="$ROOT/loop/queue/in_progress"
BLOCKED="$ROOT/loop/queue/blocked"
DONE="$ROOT/loop/queue/done"
LOG="$ROOT/loop/log"
WORKTREES="$ROOT/.loop-worktrees"
STATE_DIR="$ROOT/loop/state"
BACKOFF_FILE="$STATE_DIR/backoff.txt"

MAX_ITERATIONS="${LOOP_MAX_ITERATIONS:-5}"
MAX_RETRIES="${LOOP_MAX_RETRIES:-2}"
BASE_BRANCH="${LOOP_BASE_BRANCH:-main}"

# --- harnesses: which maker/checker "seats" are in the rotation, and in what order -------------
#
# Each entry in this list is a *member*: either a bare harness name (`cursor`, using that
# harness's own configured default model) or `harness:model` (e.g. `cursor:grok-4.5-high`,
# pinning a specific model). This lets one multi-model-capable harness like `cursor`,
# `copilot`, or `opencode` fill several seats in the rotation by itself — e.g.
# `cursor:grok-4.5-high` / `copilot:gpt-5.4` / `opencode:nvidia/z-ai/glm-5.2` paired with a
# second pinned model on the same CLI are independent members even though they share one
# adapter and one underlying account, because a diff made under one model family is still
# meaningfully checked by a different one. Every member is used as both a maker (for tasks
# whose `maker:` frontmatter names it) and a reviewer — the review cycle is a ring over this
# exact list (see reviewer_for() below): each member is reviewed by the next one in order,
# wrapping around, so no model ever grades its own homework. Needs >=2 *members* — not
# necessarily 2 distinct harnesses, since two members of the same harness with different
# models are still independent seats — and no two members may be byte-identical (that would
# be genuine self-review).
#
# Configurable via LOOP_KIT_HARNESSES in loop.config.sh (space-separated member specs); each
# member's harness portion (before any `:model`) must have a matching loop/harnesses/<name>.sh
# adapter — see loop/harnesses/TEMPLATE.sh.example (or `loop/new_harness.sh <name>`) to add one
# that isn't built in. Every adapter owns its own model/effort selection when no model is pinned
# (reading its own LOOP_KIT_* vars); run.sh itself has no per-harness special-casing left.
#
# Default rotation is codex/claude/cursor. Built-in adapters also ship for `copilot` and
# `opencode` (full maker/checker/council) — add them to LOOP_KIT_HARNESSES when those CLIs are
# installed (multi-model-family harnesses are exactly what harness:model is for).
read -ra HARNESSES <<< "${LOOP_KIT_HARNESSES:-codex claude cursor}"
(( ${#HARNESSES[@]} >= 2 )) || die "LOOP_KIT_HARNESSES must list at least 2 members (got: ${HARNESSES[*]:-none}) — a single member can never review its own work. Use harness:model entries (e.g. 'cursor:grok-4.5-high cursor:claude-4.5-sonnet' or 'copilot:gpt-5.4 copilot:claude-sonnet-4.6') if you only want one harness/CLI."

# Splits a member spec into its harness portion (before ':') — "cursor:grok-4.5-high" -> "cursor",
# "codex" -> "codex".
member_harness() { echo "${1%%:*}"; }
# Splits a member spec into its pinned model, if any — "cursor:grok-4.5-high" -> "grok-4.5-high",
# "codex" -> "" (meaning: let that harness's adapter pick its own default/tiered model).
member_model() { [[ "$1" == *:* ]] && echo "${1#*:}" || echo ""; }

for h in "${HARNESSES[@]}"; do
  [[ -f "$ROOT/loop/harnesses/$(member_harness "$h").sh" ]] || die "no adapter at loop/harnesses/$(member_harness "$h").sh for member '$h' listed in LOOP_KIT_HARNESSES — see loop/harnesses/TEMPLATE.sh.example"
done
for (( i = 0; i < ${#HARNESSES[@]}; i++ )); do
  for (( j = i + 1; j < ${#HARNESSES[@]}; j++ )); do
    [[ "${HARNESSES[$i]}" == "${HARNESSES[$j]}" ]] && die "LOOP_KIT_HARNESSES lists '${HARNESSES[$i]}' twice — duplicate members can't review each other. Pin a different model on one of them (harness:model) if you meant two distinct seats."
  done
done

# Prints the reviewer for maker $1: the next member after it in the HARNESSES ring, wrapping
# around.
reviewer_for() {
  local maker="$1" i n
  n=${#HARNESSES[@]}
  for (( i = 0; i < n; i++ )); do
    if [[ "${HARNESSES[$i]}" == "$maker" ]]; then
      echo "${HARNESSES[$(( (i + 1) % n ))]}"
      return 0
    fi
  done
  echo "${HARNESSES[0]}"  # maker not in HARNESSES — shouldn't happen, task_maker validates against it
}

# How many distinct attempts a reviewer makes to actively break the maker's diff during its
# red-team pass (see the review prompt templates), not how many times the review itself is
# retried. Clamped to [1,3] — "ideally 1, no more than 3" per the red-teaming design: a reviewer
# that hasn't broken anything in 3 genuine attempts should say so and move on, not grind forever.
REVIEW_BREAK_ATTEMPTS="${LOOP_REVIEW_BREAK_ATTEMPTS:-1}"
if (( REVIEW_BREAK_ATTEMPTS < 1 )); then REVIEW_BREAK_ATTEMPTS=1; fi
if (( REVIEW_BREAK_ATTEMPTS > 3 )); then REVIEW_BREAK_ATTEMPTS=3; fi

# Diffs touching any of these always go to blocked/ for a human, regardless of verify or the
# checker's verdict — governance-sensitive changes don't get to self-approve. Override via
# LOOP_KIT_SENSITIVE_PATTERN in loop.config.sh (install.sh prompts for this); the default below
# covers the paths that are dangerous in nearly any repo (deploy config, secrets, CI). Add your
# own project's ADRs/provider-interface specs/schema-of-record files to the regex.
SENSITIVE_PATTERN="${LOOP_KIT_SENSITIVE_PATTERN:-^(deploy/|secrets|\.github/workflows/)}"

mkdir -p "$PENDING" "$IN_PROGRESS" "$BLOCKED" "$DONE" "$LOG" "$WORKTREES" "$STATE_DIR"
touch "$BACKOFF_FILE"

# Single-instance guard. Two `run.sh` processes running at once have no way to coordinate which
# pending task each has claimed — `mv "$task_file" "$IN_PROGRESS/..."` isn't checked for success,
# and the unconditional `git worktree remove --force "$worktree"` at the top of the per-task loop
# means a second process can rip a worktree out from under a first process still working on the
# same task_id. That's exactly what corrupted T063's logs and worktree once. `mkdir` is atomic on
# every POSIX filesystem this script runs on, so it doubles as a portable lock primitive — no
# dependency on `flock`, which macOS doesn't ship. This guards against a second *separate*
# `run.sh` invocation; it says nothing about the in-process concurrency below (one controller
# fanning its own work out to up to one task per maker per turn), which is safe by construction
# because claiming (the part that was racy) stays single-threaded — see the per-turn loop.
LOCK_DIR="$STATE_DIR/run.lock"
if ! mkdir "$LOCK_DIR" 2>/dev/null; then
  lock_pid=$(cat "$LOCK_DIR/pid" 2>/dev/null || echo "")
  if [[ -n "$lock_pid" ]] && kill -0 "$lock_pid" 2>/dev/null; then
    die "another loop/run.sh is already running (pid $lock_pid, lock $LOCK_DIR) — wait for it to finish, or remove $LOCK_DIR yourself if you're sure that pid is gone"
  fi
  log "found a stale lock (pid ${lock_pid:-unknown} not running) — reclaiming it"
  rm -rf "$LOCK_DIR"
  mkdir "$LOCK_DIR" || die "could not acquire lock at $LOCK_DIR even after clearing a stale one"
fi
echo $$ > "$LOCK_DIR/pid"
trap 'rm -rf "$LOCK_DIR"' EXIT

# None of codex/claude/cursor/opencode expose a "remaining quota" API — the only signal any of
# them give is the error text printed once a daily/weekly limit is already hit (e.g. Codex's
# "You've hit your usage limit ... try again at 3:36 AM"). So this is reactive, not predictive:
# scan a model's output for that class of message, and if found, record a until-epoch in
# $BACKOFF_FILE so later dispatches to the same model skip straight to blocked/ instead of
# burning another attempt against a wall we already know is up. Best-effort timestamp parsing;
# falls back to a flat 1-hour cooldown if the wording doesn't match a known pattern, so a
# provider changing its message format degrades to "back off for a bit" rather than "never back
# off at all."
record_backoff() {
  local model="$1" output_file="$2"
  [[ -f "$output_file" ]] || return 0
  grep -qiE 'usage limit|rate.?limit|quota exceeded|resource.?exhausted|429 ' "$output_file" || return 0
  local until_epoch
  until_epoch=$(python3 - "$output_file" <<'PY' 2>/dev/null
import re, sys, datetime
text = open(sys.argv[1], errors="replace").read()
now = datetime.datetime.now().astimezone()
m = re.search(r'(?:try again at|resets? at)\s+([A-Za-z]{0,4}\.?\s?\d{0,2}(?:st|nd|rd|th)?,?\s*\d{0,4}\s*\d{1,2}:\d{2}\s*[AP]M)', text, re.I)
parsed = None
if m:
    raw = re.sub(r'(\d+)(st|nd|rd|th)', r'\1', m.group(1)).strip()
    for fmt in ("%b %d, %Y %I:%M %p", "%I:%M %p"):
        try:
            candidate = datetime.datetime.strptime(raw, fmt)
        except ValueError:
            continue
        if fmt == "%I:%M %p":
            candidate = now.replace(hour=candidate.hour, minute=candidate.minute, second=0, microsecond=0)
            if candidate < now:
                candidate += datetime.timedelta(days=1)
        else:
            candidate = candidate.replace(tzinfo=now.tzinfo)
        parsed = candidate
        break
if parsed is None:
    parsed = now + datetime.timedelta(hours=1)
print(int(parsed.timestamp()))
PY
)
  [[ -z "$until_epoch" ]] && until_epoch=$(( $(date +%s) + 3600 ))
  # Concurrent task pipelines (one per maker, see the per-turn loop below) can each call this for
  # a different model at the same time. mkdir is atomic, so use it as a tiny mutex around the
  # shared file's read-modify-write instead of risking two writers' temp files racing each other
  # and one write silently clobbering the other.
  local backoff_lock="$STATE_DIR/backoff.lock"
  while ! mkdir "$backoff_lock" 2>/dev/null; do sleep 0.1; done
  grep -v "^$model " "$BACKOFF_FILE" > "$BACKOFF_FILE.tmp" 2>/dev/null || true
  echo "$model $until_epoch" >> "$BACKOFF_FILE.tmp"
  mv "$BACKOFF_FILE.tmp" "$BACKOFF_FILE"
  rmdir "$backoff_lock"
  log "  recorded backoff for $model until $(date -r "$until_epoch" 2>/dev/null || date -d "@$until_epoch" 2>/dev/null || echo "epoch $until_epoch")"
}

# True if $1 is currently in a recorded backoff window.
is_backed_off() {
  local model="$1" now until_epoch
  now=$(date +%s)
  until_epoch=$(awk -v m="$model" '$1==m {print $2}' "$BACKOFF_FILE" | tail -1)
  [[ -n "$until_epoch" ]] && (( until_epoch > now ))
}

# render() (used for every template in this kit) lives in loop/render.sh, sourced by both this
# script and review_pr.sh so rendering logic can't drift between the two call sites.
source "$ROOT/loop/render.sh"

# --- dependency-aware, per-maker task picking -------------------------------------------------
#
# Every task file's frontmatter carries `depends_on: [T063, T066]` (or `[]`). Previously this was
# advisory only — run.sh always grabbed the alphabetically-first pending file regardless, and a
# task with an unmet dependency (e.g. T065 needing T064) would only discover that once its maker
# actually ran and self-reported NEEDS_INPUT, burning a full attempt to learn something the queue
# already knew. `task_ready` makes that check structural instead.

# Prints the maker for a task file (default: the first entry in HARNESSES).
task_maker() {
  local f="$1" m
  m=$(sed -n 's/^maker: *//p' "$f" | head -n1)
  echo "${m:-${HARNESSES[0]}}"
}

# Warn (not fatal) about any pending task whose maker isn't a currently configured harness —
# otherwise it just sits in pending/ forever with no error, since pick_ready_task_for_maker below
# only ever looks at configured harnesses.
for f in "$PENDING"/*.md; do
  [[ -f "$f" ]] || continue
  m=$(task_maker "$f")
  known=0
  for h in "${HARNESSES[@]}"; do [[ "$h" == "$m" ]] && known=1 && break; done
  (( known )) || log "warning: $(basename "$f") has maker '$m', which is not in LOOP_KIT_HARNESSES (${HARNESSES[*]}) — it will never be picked up"
done

# Prints the task's complexity tier for maker model selection (default: default). A task file
# opts into a non-default tier with `complexity: quick` or `complexity: gnarly` in its
# frontmatter; anything else (including an unrecognized value) falls back to default rather than
# erroring, since a typo here shouldn't block a task from running.
task_complexity() {
  local f="$1" c
  c=$(sed -n 's/^complexity: *//p' "$f" | head -n1)
  case "$c" in
    quick|gnarly) echo "$c" ;;
    *) echo "default" ;;
  esac
}

# Prints the task's dependency ids, one per line (empty if none).
task_depends_on() {
  local f="$1"
  sed -n 's/^depends_on: *\[\(.*\)\]/\1/p' "$f" | tr ',' '\n' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | grep -v '^$' || true
}

# True if every dependency of $1 has a matching file in $DONE.
task_ready() {
  local f="$1" dep
  while IFS= read -r dep; do
    [[ -n "$dep" ]] || continue
    compgen -G "$DONE/${dep}-*.md" >/dev/null 2>&1 || return 1
  done < <(task_depends_on "$f")
  return 0
}

# Prints the path of the first ready pending task assigned to maker $1, or nothing if none.
pick_ready_task_for_maker() {
  local maker="$1" f
  for f in $(find "$PENDING" -maxdepth 1 -type f -name '*.md' | sort); do
    [[ "$(task_maker "$f")" == "$maker" ]] || continue
    task_ready "$f" && { echo "$f"; return 0; }
  done
  return 1
}

# Moves a claimed task file from pending into in_progress and preps its log dir. Deliberately
# synchronous and run only from the controller (never from a backgrounded task pipeline) — this
# is the part that used to race when two separate run.sh processes both tried it (see the
# single-instance guard above). Keeping it single-threaded here is what makes fanning the actual
# maker/verify/review work out to the background, below, safe.
claim_task() {
  local task_file="$1" task_name task_id
  task_name=$(basename "$task_file")
  task_id="${task_name%%-*}"
  mkdir -p "$LOG/$task_id"
  mv "$task_file" "$IN_PROGRESS/$task_name"
}

# --- per-task pipeline (worktree setup through maker/verify/review) ---------------------------
#
# Runs entirely for one already-claimed task. Safe to run concurrently with other invocations of
# this function for other task ids: each operates on its own worktree
# ($WORKTREES/$task_id) and its own log dir ($LOG/$task_id), and git worktree
# add/remove for distinct worktree names is safe to run concurrently. Does NOT merge into
# $BASE_BRANCH or move the task file out of in_progress — that stays serialized in the
# controller's merge phase, after `wait`, so only one process ever touches main at a time.
# Writes its outcome ("approved" or "blocked: <reason>") to $task_log/outcome for the controller
# to read back.
run_task_pipeline() {
  local task_id="$1" task_name="$2" maker="$3"
  local branch="loop/${task_id}"
  local task_log="$LOG/$task_id"
  local task_file="$IN_PROGRESS/$task_name"
  local worktree="$WORKTREES/$task_id"
  local outcome_file="$task_log/outcome"
  local outcome="" network_access attempt failure_file complexity

  log "=== $task_id: $task_name (maker=$maker) ==="

  # A prior run of this same task-id can leave its worktree registered (e.g. blocked, left "for
  # inspection") without the directory itself surviving. `rm -rf` alone only deletes the
  # directory — git's own metadata under .git/worktrees/ still points at it, so a later `add`
  # for the same path fails with "already used by worktree" / "missing but already registered".
  # Explicitly remove the registration (ignoring failure if it was never registered) and prune
  # before creating a fresh one.
  git -C "$ROOT" worktree remove --force "$worktree" >/dev/null 2>&1
  rm -rf "$worktree"
  git -C "$ROOT" worktree prune
  if ! git -C "$ROOT" worktree add -q -B "$branch" "$worktree" "$BASE_BRANCH" \
      && ! git -C "$ROOT" worktree add -q "$worktree" "$branch"; then
    log "  could not create worktree for $task_id at $worktree (branch $branch)"
    echo "blocked: could not create worktree — check 'git worktree list' and 'git branch --list loop/$task_id'" > "$outcome_file"
    return
  fi

  # `network_access: true` opts a task's maker step out of a network-denied sandbox, for tasks
  # whose acceptance criteria require hitting a live local service (e.g. docker-compose'd
  # containers) rather than a mock. Passed to every harness's harness_maker_run — only adapters
  # with an actual sandbox network toggle (codex's is the built-in example) honor it; others
  # no-op. Scoped per-task, not global. This does not bypass the sensitive-path gate — a task can
  # be both network_access and sensitive, and still lands in blocked/ for human sign-off.
  network_access=$(sed -n 's/^network_access: *//p' "$task_file" | head -n1)

  # Passed to harness_maker_run so each adapter can pick its own model/effort per tier (see
  # loop/harnesses/*.sh) — computed once per task, not per attempt, since a task's declared
  # complexity doesn't change across retries.
  complexity=$(task_complexity "$task_file")

  attempt=0
  failure_file=""

  while (( attempt <= MAX_RETRIES )); do
    attempt=$((attempt+1))
    local prompt_file="$task_log/attempt-$attempt-maker-prompt.md"
    render "$ROOT/loop/task_prompt.tpl.md" "$task_id" "$task_file" "$branch" "$failure_file" > "$prompt_file"

    # Source the maker's adapter immediately before calling it (see loop/harnesses/
    # TEMPLATE.sh.example) — every adapter defines the same function names, so whichever was
    # sourced most recently is the one that runs. Deliberately re-sourced every attempt rather
    # than once outside the loop: keeps this correct even though the same task_pipeline process
    # will later source a *different* adapter for the reviewer step below. $maker here is a full
    # member spec (harness or harness:model, see the HARNESSES comment near the top of this
    # file); member_harness/member_model split it into the adapter to load and the model, if
    # any, to pin.
    local maker_harness; maker_harness=$(member_harness "$maker")
    local maker_model; maker_model=$(member_model "$maker")
    source "$ROOT/loop/harnesses/$maker_harness.sh"
    local maker_final="$task_log/attempt-$attempt-maker-${maker//:/-}.log"
    log "  $task_id attempt $attempt: $maker maker"
    harness_maker_run "$worktree" "$prompt_file" "$maker_final" "$complexity" "$network_access" "$maker_model"
    local maker_status=$?

    # The maker was told to write this relative to its own cwd, i.e. inside the worktree, not $ROOT.
    if [[ -f "$worktree/loop/queue/in_progress/${task_id}.NEEDS_INPUT.md" ]]; then
      log "  $task_id: $maker flagged it needs input instead of guessing — blocking for human"
      outcome="blocked: $maker flagged NEEDS_INPUT"
      break
    fi

    if (( maker_status != 0 )); then
      # Backoff is keyed by the underlying harness/CLI, not the full member spec: a usage-limit
      # hit on the cursor-agent account blocks every model routed through it, not just the one
      # this attempt happened to pin.
      record_backoff "$maker_harness" "$maker_final"
      failure_file="$maker_final"
      log "  $task_id: $maker exited $maker_status, will retry if budget remains"
      continue
    fi

    # The maker is instructed to either commit or write NEEDS_INPUT — never neither. Catch the
    # case where it did nothing observable instead of silently reviewing a no-op diff against main.
    if [[ -z "$(git -C "$worktree" log "$BASE_BRANCH"..HEAD --oneline 2>/dev/null)" ]]; then
      echo "$maker made no commit on this attempt and did not write a NEEDS_INPUT file. Uncommitted changes, if any:" > "$task_log/attempt-$attempt-no-commit.txt"
      git -C "$worktree" status --short >> "$task_log/attempt-$attempt-no-commit.txt"
      failure_file="$task_log/attempt-$attempt-no-commit.txt"
      log "  $task_id: no commit produced — treating as a failed attempt"
      continue
    fi

    log "  $task_id attempt $attempt: verify"
    if ! (cd "$worktree" && bash loop/verify.sh > "$task_log/attempt-$attempt-verify.txt" 2>&1); then
      failure_file="$task_log/attempt-$attempt-verify.txt"
      log "  $task_id: verify failed"
      continue
    fi

    local diff_paths
    diff_paths=$(git -C "$worktree" diff --name-only "$BASE_BRANCH"...HEAD)
    if echo "$diff_paths" | grep -qE "$SENSITIVE_PATTERN"; then
      log "  $task_id: diff touches a sensitive path — skipping auto-review, blocking for human sign-off"
      echo "$diff_paths" > "$task_log/sensitive-paths.txt"
      outcome="blocked: touches a sensitive path"
      break
    fi

    # Reviewer is the next member after $maker in the HARNESSES ring (see reviewer_for() near
    # the top of this file) — generalizes what used to be a fixed codex->claude->cursor->codex
    # cycle to any ordered list of >=2 configured members, including several members that share
    # one multi-model harness.
    local reviewer; reviewer=$(reviewer_for "$maker")
    local reviewer_harness; reviewer_harness=$(member_harness "$reviewer")
    local reviewer_model; reviewer_model=$(member_model "$reviewer")

    # Source the reviewer's adapter and render the one shared review_prompt.tpl.md — the only
    # thing that differs between reviewers is the {{REVIEWER_MODE_NOTE}} line describing that
    # CLI's own read-only mode, which the adapter itself supplies.
    source "$ROOT/loop/harnesses/$reviewer_harness.sh"
    local review_prompt="$task_log/attempt-$attempt-review-prompt.md"
    local review_out="$task_log/attempt-$attempt-review-${reviewer//:/-}.log"
    local reviewer_mode_note; reviewer_mode_note=$(harness_reviewer_mode_note)
    render "$ROOT/loop/review_prompt.tpl.md" "$task_id" "$task_file" "$branch" "" "$maker" "$REVIEW_BREAK_ATTEMPTS" "$reviewer_mode_note" > "$review_prompt"
    log "  $task_id attempt $attempt: $reviewer review ($maker was the maker)"
    harness_reviewer_run "$worktree" "$review_prompt" "$review_out" "$BASE_BRANCH" "$reviewer_model"

    if grep -qiE 'usage limit|rate.?limit|quota exceeded|resource.?exhausted|429 ' "$review_out" 2>/dev/null; then
      # Keyed by underlying harness, same reasoning as the maker's record_backoff call above.
      record_backoff "$reviewer_harness" "$review_out"
      log "  $task_id: $reviewer review hit a usage/rate limit — blocking for human rather than misreading this as no verdict"
      outcome="blocked: $reviewer review hit a usage/rate limit"
      break
    fi

    local verdict
    verdict=$(grep -oE 'VERDICT: *(approve|request_changes|block_human)' "$review_out" | tail -1 | awk '{print $2}')
    case "$verdict" in
      approve)
        log "  $task_id: $reviewer approve"
        outcome="approved"
        break
        ;;
      request_changes)
        log "  $task_id: $reviewer request_changes — feeding back to $maker"
        failure_file="$review_out"
        continue
        ;;
      block_human|*)
        log "  $task_id: $reviewer ${verdict:-no parseable verdict} — blocking for human"
        outcome="blocked: ${verdict:-no parseable review verdict}"
        break
        ;;
    esac
  done

  [[ -z "$outcome" ]] && outcome="blocked: exhausted $((MAX_RETRIES+1)) attempts"
  echo "$outcome" > "$outcome_file"
}

# --- main loop: one "turn" per iteration of the outer while, up to one task per maker per turn -
#
# Previously this processed exactly one task start-to-finish (claim -> worktree -> attempts ->
# verify -> review -> merge) before even looking at the next. Since each task already has a fixed
# maker, there's no reason every member in HARNESSES can't be working on a different ready task
# at the same time instead of the rest sitting idle while one runs — even two members that share
# one underlying harness/account (see the HARNESSES comment near the top of this file) run their
# own maker/verify/review pipeline concurrently; only actual CLI calls funneled through the same
# account serialize naturally at the OS/network level, not anything this script does. Claiming
# (moving pending -> in_progress) stays synchronous in the controller, one maker lane at a time,
# before anything is backgrounded — that's what keeps this safe; only the maker/verify/review
# work itself (run_task_pipeline) runs concurrently, and merging into $BASE_BRANCH stays
# serialized in the controller after `wait`.

consecutive_blocked=0
iteration=0

while (( iteration < MAX_ITERATIONS )); do
  declare -A batch_task_id=() batch_task_name=()
  batch_size=0

  for maker in "${HARNESSES[@]}"; do
    (( iteration + batch_size >= MAX_ITERATIONS )) && break

    # Backoff is keyed by underlying harness (see record_backoff calls in run_task_pipeline), so
    # a cooldown on one member of a multi-model harness correctly sits out every member sharing
    # that harness/account, not just the one that happened to trip it.
    if is_backed_off "$(member_harness "$maker")"; then
      until_epoch=$(awk -v m="$(member_harness "$maker")" '$1==m {print $2}' "$BACKOFF_FILE" | tail -1)
      log "  $maker is in cooldown until $(date -r "$until_epoch" 2>/dev/null || date -d "@$until_epoch" 2>/dev/null || echo "epoch $until_epoch") — sitting this turn out"
      continue
    fi

    task_file=$(pick_ready_task_for_maker "$maker") || continue
    [[ -z "$task_file" ]] && continue

    task_name=$(basename "$task_file")
    task_id="${task_name%%-*}"
    claim_task "$task_file"
    batch_task_id["$maker"]="$task_id"
    batch_task_name["$maker"]="$task_name"
    batch_size=$((batch_size+1))
  done

  if (( batch_size == 0 )); then
    if [[ -z "$(find "$PENDING" -maxdepth 1 -name '*.md')" ]]; then
      log "queue/pending is empty. Nothing left to do."
    else
      log "no ready task for any maker this turn (unmet dependencies and/or cooldown) — stopping rather than spin. Check loop/queue/pending/ depends_on fields and loop/state/backoff.txt."
    fi
    unset batch_task_id batch_task_name
    break
  fi

  # Fan this turn's claimed tasks out concurrently, one per maker lane.
  for maker in "${!batch_task_id[@]}"; do
    run_task_pipeline "${batch_task_id[$maker]}" "${batch_task_name[$maker]}" "$maker" &
  done
  wait

  # Merge phase: strictly serial, fixed harness order, so only one process ever touches
  # $BASE_BRANCH at a time and results land in the log/console in a deterministic order.
  for maker in "${HARNESSES[@]}"; do
    [[ -n "${batch_task_id[$maker]:-}" ]] || continue
    task_id="${batch_task_id[$maker]}"
    task_name="${batch_task_name[$maker]}"
    branch="loop/${task_id}"
    task_log="$LOG/$task_id"
    task_file="$IN_PROGRESS/$task_name"
    worktree="$WORKTREES/$task_id"
    outcome=$(cat "$task_log/outcome" 2>/dev/null || echo "blocked: no outcome file written")

    if [[ "$outcome" == "approved" ]]; then
      if git -C "$ROOT" merge -q --no-ff "$branch" -m "Merge $task_id via loop"; then
        mv "$task_file" "$DONE/$task_name" 2>/dev/null || true
        git -C "$ROOT" worktree remove -f "$worktree"
        consecutive_blocked=0
        log "  $task_id: merged and marked done"
        # When run-end evaluation is disabled, check the SkillOpt threshold after each done.
        bash "$ROOT/loop/skillopt_trigger.sh" after-done || true
      else
        log "  $task_id: merge conflict — blocking for human instead of forcing it"
        mv "$task_file" "$BLOCKED/$task_name" 2>/dev/null || true
        consecutive_blocked=$((consecutive_blocked+1))
      fi
    else
      mv "$task_file" "$BLOCKED/$task_name" 2>/dev/null || true
      log "  $task_id: $outcome — left worktree at $worktree and branch $branch for inspection"
      consecutive_blocked=$((consecutive_blocked+1))
    fi

    iteration=$((iteration+1))

    if (( consecutive_blocked >= 3 )); then
      unset batch_task_id batch_task_name
      die "3 tasks in a row ended up blocked. That usually means the queue or the spec is ambiguous, not that the tasks are hard. Stopping for you to look at loop/queue/blocked/ before burning more budget."
    fi
  done

  unset batch_task_id batch_task_name
done

log "Stopped after $iteration task(s) this run. pending=$(find "$PENDING" -maxdepth 1 -name '*.md' | wc -l | tr -d ' ') blocked=$(find "$BLOCKED" -maxdepth 1 -name '*.md' | wc -l | tr -d ' ') done=$(find "$DONE" -maxdepth 1 -name '*.md' | wc -l | tr -d ' ')"
bash "$ROOT/loop/skillopt_trigger.sh" run-end || true

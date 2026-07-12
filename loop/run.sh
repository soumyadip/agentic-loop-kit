#!/usr/bin/env bash
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Per-repo settings written by install.sh (build/test commands, sensitive-path pattern, etc.) —
# see loop.config.sh.example. Safe to be absent: every var it might set has a generic fallback
# below via ${VAR:-default}.
[[ -f "$ROOT/loop/loop.config.sh" ]] && source "$ROOT/loop/loop.config.sh"

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

# Reviewer-step models (the fixed cycle below: codex's work is checked by claude, claude's by
# cursor, cursor's by codex). Maker-step model selection is separate and complexity-tiered — see
# below — since scaling review strength with the task's declared complexity wasn't asked for and
# keeps review predictable.
CODEX_MODEL="${LOOP_CODEX_MODEL:-}"
CLAUDE_MODEL="${LOOP_CLAUDE_MODEL:-sonnet}"

# opencode is deliberately not a maker or reviewer option in this loop — it's reserved for
# loop/council.sh's independent third-opinion role (see council.sh's own COUNCIL_OPENCODE_MODEL).
# Mixing it into the maker/checker rotation here would blur that separation: council.sh's value
# is asking three models the same question with no visibility into each other's answers, which
# is a different job from a maker/checker pipeline where each step *should* see the prior step's
# work.
#
# The three makers below (codex, claude, cursor) review each other in a fixed cycle — codex's
# work is checked by claude, claude's by cursor, cursor's by codex — so no model ever grades its
# own homework and no single vendor is a hard dependency for the whole loop to keep moving.
MAKERS=(codex claude cursor)

# --- maker-step model selection, by complexity tier -------------------------------------------
#
# A task's frontmatter can set `complexity: quick` or `complexity: gnarly` to route its maker step
# to a cheaper/faster or a stronger model+effort than the default; omitting the field (the common
# case, see task_complexity() below) uses the default tier.

# codex: reasoning effort is a separate `-c model_reasoning_effort=` config override, not baked
# into the model slug the way cursor's is (see CURSOR_MODEL below).
CODEX_MAKER_MODEL_DEFAULT="${LOOP_CODEX_MAKER_MODEL_DEFAULT:-gpt-5.6-terra}"
CODEX_MAKER_EFFORT_DEFAULT="${LOOP_CODEX_MAKER_EFFORT_DEFAULT:-high}"
CODEX_MAKER_MODEL_QUICK="${LOOP_CODEX_MAKER_MODEL_QUICK:-gpt-5.6-luna}"
CODEX_MAKER_EFFORT_QUICK="${LOOP_CODEX_MAKER_EFFORT_QUICK:-high}"
CODEX_MAKER_MODEL_GNARLY="${LOOP_CODEX_MAKER_MODEL_GNARLY:-gpt-5.6-sol}"
CODEX_MAKER_EFFORT_GNARLY="${LOOP_CODEX_MAKER_EFFORT_GNARLY:-high}"

# `maker: claude` routes a task's implementation step to `claude -p --dangerously-skip-permissions`
# instead of Codex, and its review (see the reviewer cycle above) to `cursor-agent`. `--effort` is
# a separate CLI flag from `--model`, same shape as codex's config override above.
CLAUDE_MAKER_MODEL_DEFAULT="${LOOP_CLAUDE_MAKER_MODEL_DEFAULT:-sonnet}"
CLAUDE_MAKER_EFFORT_DEFAULT="${LOOP_CLAUDE_MAKER_EFFORT_DEFAULT:-high}"
CLAUDE_MAKER_MODEL_QUICK="${LOOP_CLAUDE_MAKER_MODEL_QUICK:-sonnet}"
CLAUDE_MAKER_EFFORT_QUICK="${LOOP_CLAUDE_MAKER_EFFORT_QUICK:-medium}"
CLAUDE_MAKER_MODEL_GNARLY="${LOOP_CLAUDE_MAKER_MODEL_GNARLY:-opus}"
CLAUDE_MAKER_EFFORT_GNARLY="${LOOP_CLAUDE_MAKER_EFFORT_GNARLY:-high}"

# `maker: cursor` routes a task's implementation step to `cursor-agent -p --force`, and its
# review (see the reviewer cycle above) to `codex exec review`. No complexity tiering here —
# cursor's model slug already bakes reasoning effort in (e.g. `grok-4.5-high`), so one flat
# default covers every complexity tier.
CURSOR_MODEL="${LOOP_CURSOR_MODEL:-grok-4.5-high}"
CURSOR_MAKER_TIMEOUT="${LOOP_CURSOR_MAKER_TIMEOUT:-900}"

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

log()  { echo "[loop] $*"; }
die()  { echo "[loop] STOP: $*" >&2; exit 1; }

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

render() { # render TEMPLATE TASK_ID TASK_BODY_FILE BRANCH [FAILURE_FILE] [MAKER] [BREAK_ATTEMPTS]
  local tpl="$1" task_id="$2" body_file="$3" branch="$4" failure_file="${5:-}" maker_name="${6:-codex}" break_attempts="${7:-1}"
  local out body failure_block="" failure_content
  body=$(cat "$body_file")
  if [[ -n "$failure_file" && -s "$failure_file" ]]; then
    # Cap how much of a failed attempt's raw output gets replayed into the retry prompt. A stuck
    # maker (e.g. cursor's stream-json transcript) can produce multi-MB output; feeding all of it
    # back both buries the actual error under noise and risks the argv-size failure this comment
    # used to warn about only for TASK_BODY. Keep the tail, since that's where the error lives.
    failure_content=$(tail -c 8000 "$failure_file")
    failure_block=$'\n## Previous attempt failed\n\n```\n'"$failure_content"$'\n```\n'
  fi
  out=$(cat "$tpl")
  out="${out//\{\{TASK_ID\}\}/$task_id}"
  out="${out//\{\{BRANCH\}\}/$branch}"
  out="${out//\{\{MAKER\}\}/$maker_name}"
  out="${out//\{\{BREAK_ATTEMPTS\}\}/$break_attempts}"
  out="${out//\{\{PREVIOUS_FAILURE_BLOCK\}\}/$failure_block}"
  # TASK_BODY can contain & and other sed-hostile chars; do it last with a literal-safe approach.
  # $out goes over stdin rather than argv: even with the cap above, a single shell argument has a
  # much lower effective limit than ARG_MAX suggests, and the previous argv-based version failed
  # silently on a large $out (python errored, and the bash fallback assigned but never printed —
  # producing an empty rendered prompt instead of a visible error).
  if ! python3 -c '
import sys
out = sys.stdin.read()
body = open(sys.argv[1]).read()
sys.stdout.write(out.replace("{{TASK_BODY}}", body))
' "$body_file" <<<"$out" 2>/dev/null; then
    printf '%s' "${out/\{\{TASK_BODY\}\}/$body}"
  fi
}

# --- dependency-aware, per-maker task picking -------------------------------------------------
#
# Every task file's frontmatter carries `depends_on: [T063, T066]` (or `[]`). Previously this was
# advisory only — run.sh always grabbed the alphabetically-first pending file regardless, and a
# task with an unmet dependency (e.g. T065 needing T064) would only discover that once its maker
# actually ran and self-reported NEEDS_INPUT, burning a full attempt to learn something the queue
# already knew. `task_ready` makes that check structural instead.

# Prints the maker for a task file (default: codex).
task_maker() {
  local f="$1" m
  m=$(sed -n 's/^maker: *//p' "$f" | head -n1)
  echo "${m:-codex}"
}

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

  # `network_access: true` opts a task's codex maker step out of the default network-denied
  # sandbox — needed for tasks whose acceptance criteria require hitting a live local service
  # (e.g. docker-compose'd Lakekeeper/Postgres) rather than a mock. Scoped per-task, not global:
  # everything else still runs with network denied by default. This does not bypass the
  # sensitive-path gate — a task can be both network_access and sensitive, and still lands in
  # blocked/ for human sign-off.
  network_access=$(sed -n 's/^network_access: *//p' "$task_file" | head -n1)

  # Drives which model+effort the maker branches below select (see the CODEX_MAKER_*/
  # CLAUDE_MAKER_* tiers near the top of the file) — computed once per task, not per attempt,
  # since a task's declared complexity doesn't change across retries.
  complexity=$(task_complexity "$task_file")

  attempt=0
  failure_file=""

  while (( attempt <= MAX_RETRIES )); do
    attempt=$((attempt+1))
    local prompt_file="$task_log/attempt-$attempt-maker-prompt.md"
    render "$ROOT/loop/codex_task_prompt.tpl.md" "$task_id" "$task_file" "$branch" "$failure_file" > "$prompt_file"

    local backoff_scan_file="" maker_final maker_status
    if [[ "$maker" == "claude" ]]; then
      local claude_maker_model="$CLAUDE_MAKER_MODEL_DEFAULT" claude_maker_effort="$CLAUDE_MAKER_EFFORT_DEFAULT"
      case "$complexity" in
        quick)  claude_maker_model="$CLAUDE_MAKER_MODEL_QUICK";  claude_maker_effort="$CLAUDE_MAKER_EFFORT_QUICK" ;;
        gnarly) claude_maker_model="$CLAUDE_MAKER_MODEL_GNARLY"; claude_maker_effort="$CLAUDE_MAKER_EFFORT_GNARLY" ;;
      esac
      log "  $task_id attempt $attempt: claude maker ($claude_maker_model, effort=$claude_maker_effort, complexity=$complexity)"
      maker_final="$task_log/attempt-$attempt-claude-maker.md"
      # No OS-level sandbox equivalent to codex's -s workspace-write for claude as a maker —
      # relies on worktree isolation + the review step instead.
      (cd "$worktree" && claude -p --model "$claude_maker_model" --effort "$claude_maker_effort" --dangerously-skip-permissions --add-dir "$ROOT/.git" < "$prompt_file") > "$maker_final" 2>&1
      maker_status=$?
      backoff_scan_file="$maker_final"
    elif [[ "$maker" == "cursor" ]]; then
      log "  $task_id attempt $attempt: cursor-agent maker${CURSOR_MODEL:+ ($CURSOR_MODEL)}"
      maker_final="$task_log/attempt-$attempt-cursor-maker.jsonl"
      # Also no OS-level sandbox equivalent here — same caveat as claude above.
      # stream-json + stream-partial-output (rather than plain text, which buffers everything
      # until the process exits) so a `timeout`-killed long-running attempt still leaves a
      # readable trail of what it was doing, instead of an empty file.
      local cursor_args=(-p --force --output-format stream-json --stream-partial-output --workspace "$worktree")
      [[ -n "$CURSOR_MODEL" ]] && cursor_args+=(--model "$CURSOR_MODEL")
      (cd "$worktree" && timeout "$CURSOR_MAKER_TIMEOUT" cursor-agent "${cursor_args[@]}" < "$prompt_file") > "$maker_final" 2>&1
      maker_status=$?
      backoff_scan_file="$maker_final"
    else
      local codex_maker_model="$CODEX_MAKER_MODEL_DEFAULT" codex_maker_effort="$CODEX_MAKER_EFFORT_DEFAULT"
      case "$complexity" in
        quick)  codex_maker_model="$CODEX_MAKER_MODEL_QUICK";  codex_maker_effort="$CODEX_MAKER_EFFORT_QUICK" ;;
        gnarly) codex_maker_model="$CODEX_MAKER_MODEL_GNARLY"; codex_maker_effort="$CODEX_MAKER_EFFORT_GNARLY" ;;
      esac
      log "  $task_id attempt $attempt: codex exec ($codex_maker_model, effort=$codex_maker_effort, complexity=$complexity)"
      maker_final="$task_log/attempt-$attempt-codex-final.md"
      # --add-dir for $ROOT/.git: a worktree's index/HEAD lock lives under
      # <main-repo>/.git/worktrees/<name>/, outside the worktree's own directory tree, so
      # workspace-write alone can't write it and `git commit` fails inside the sandbox without this.
      local codex_args=(exec -s workspace-write -C "$worktree" --add-dir "$ROOT/.git" --json -o "$maker_final" \
        -m "$codex_maker_model" -c "model_reasoning_effort=\"$codex_maker_effort\"")
      [[ "$network_access" == "true" ]] && codex_args+=(-c sandbox_workspace_write.network_access=true)
      codex "${codex_args[@]}" - < "$prompt_file" > "$task_log/attempt-$attempt-codex.jsonl" 2>&1
      maker_status=$?
      # Codex's -o file only captures the last message on a clean finish; a hard failure (e.g.
      # a usage-limit error) shows up in the --json event stream instead, so scan that.
      backoff_scan_file="$task_log/attempt-$attempt-codex.jsonl"
    fi

    # The maker was told to write this relative to its own cwd, i.e. inside the worktree, not $ROOT.
    if [[ -f "$worktree/loop/queue/in_progress/${task_id}.NEEDS_INPUT.md" ]]; then
      log "  $task_id: $maker flagged it needs input instead of guessing — blocking for human"
      outcome="blocked: $maker flagged NEEDS_INPUT"
      break
    fi

    if (( maker_status != 0 )); then
      record_backoff "$maker" "$backoff_scan_file"
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

    # Fixed review cycle so no model ever grades its own homework: codex -> claude -> cursor ->
    # codex. `maker` here is who implemented; `reviewer` is the next model in the cycle.
    local reviewer
    case "$maker" in
      claude) reviewer="cursor" ;;
      cursor) reviewer="codex" ;;
      *)      reviewer="claude" ;;  # codex (default maker) is reviewed by claude
    esac

    local review_prompt review_out review_backoff_file
    if [[ "$reviewer" == "codex" ]]; then
      log "  $task_id attempt $attempt: codex review ($maker was the maker)"
      review_prompt="$task_log/attempt-$attempt-codex-review-prompt.md"
      review_out="$task_log/attempt-$attempt-codex-review.md"
      local review_events="$task_log/attempt-$attempt-codex-review.jsonl"
      render "$ROOT/loop/codex_review_prompt.tpl.md" "$task_id" "$task_file" "$branch" "" "$maker" "$REVIEW_BREAK_ATTEMPTS" > "$review_prompt"
      local codex_review_args=(exec review --base "$BASE_BRANCH" --json -o "$review_out")
      [[ -n "$CODEX_MODEL" ]] && codex_review_args+=(-m "$CODEX_MODEL")
      (cd "$worktree" && codex "${codex_review_args[@]}" - < "$review_prompt") > "$review_events" 2>&1
      review_backoff_file="$review_events"
    elif [[ "$reviewer" == "cursor" ]]; then
      log "  $task_id attempt $attempt: cursor-agent review ($maker was the maker)"
      review_prompt="$task_log/attempt-$attempt-cursor-review-prompt.md"
      review_out="$task_log/attempt-$attempt-cursor-review.md"
      render "$ROOT/loop/cursor_review_prompt.tpl.md" "$task_id" "$task_file" "$branch" "" "$maker" "$REVIEW_BREAK_ATTEMPTS" > "$review_prompt"
      local cursor_review_args=(-p --force --output-format text --mode plan --workspace "$worktree")
      [[ -n "$CURSOR_MODEL" ]] && cursor_review_args+=(--model "$CURSOR_MODEL")
      (cd "$worktree" && cursor-agent "${cursor_review_args[@]}" < "$review_prompt") > "$review_out" 2>&1
      review_backoff_file="$review_out"
    else
      log "  $task_id attempt $attempt: claude review ($maker was the maker)"
      review_prompt="$task_log/attempt-$attempt-claude-prompt.md"
      review_out="$task_log/attempt-$attempt-claude-review.md"
      render "$ROOT/loop/claude_review_prompt.tpl.md" "$task_id" "$task_file" "$branch" "" "$maker" "$REVIEW_BREAK_ATTEMPTS" > "$review_prompt"
      (cd "$worktree" && claude -p --model "$CLAUDE_MODEL" --permission-mode plan < "$review_prompt") > "$review_out" 2>&1
      review_backoff_file="$review_out"
    fi

    if grep -qiE 'usage limit|rate.?limit|quota exceeded|resource.?exhausted|429 ' "$review_backoff_file" 2>/dev/null; then
      record_backoff "$reviewer" "$review_backoff_file"
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
# maker (codex/claude/cursor) and those are three independent accounts/tools, there's no reason
# codex, claude, and cursor can't all be working on different ready tasks at the same time instead
# of two of them sitting idle while the third one runs. Claiming (moving pending -> in_progress)
# stays synchronous in the controller, one maker lane at a time, before anything is backgrounded —
# that's what keeps this safe; only the maker/verify/review work itself (run_task_pipeline) runs
# concurrently, and merging into $BASE_BRANCH stays serialized in the controller after `wait`.

consecutive_blocked=0
iteration=0

while (( iteration < MAX_ITERATIONS )); do
  declare -A batch_task_id=() batch_task_name=()
  batch_size=0

  for maker in "${MAKERS[@]}"; do
    (( iteration + batch_size >= MAX_ITERATIONS )) && break

    if is_backed_off "$maker"; then
      until_epoch=$(awk -v m="$maker" '$1==m {print $2}' "$BACKOFF_FILE" | tail -1)
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

  # Merge phase: strictly serial, fixed maker order, so only one process ever touches
  # $BASE_BRANCH at a time and results land in the log/console in a deterministic order.
  for maker in "${MAKERS[@]}"; do
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
      die "3 tasks in a row ended up blocked. That usually means the queue or the spec is ambiguous, not that the tasks are hard. Stopping for you to look at loop/queue/blocked/ before burning more Codex budget."
    fi
  done

  unset batch_task_id batch_task_name
done

log "Stopped after $iteration task(s) this run. pending=$(find "$PENDING" -maxdepth 1 -name '*.md' | wc -l | tr -d ' ') blocked=$(find "$BLOCKED" -maxdepth 1 -name '*.md' | wc -l | tr -d ' ') done=$(find "$DONE" -maxdepth 1 -name '*.md' | wc -l | tr -d ' ')"

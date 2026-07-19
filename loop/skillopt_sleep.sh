#!/usr/bin/env bash
# Thin wrapper around Microsoft SkillOpt-Sleep for this maker/checker kit.
#
# Prefer loop-native evidence (loop/log → skillopt_export.sh → --tasks-file) over
# harvesting ~/.claude / ~/.codex chat transcripts, so the sleep cycle learns from
# the same scored outcomes the ring already produced.
#
# Subscription-first backends (no Anthropic/OpenAI API key required):
#   mock     — plumbing only
#   claude   — logged-in Claude Code CLI (`claude -p`)
#   codex    — logged-in Codex CLI (`codex exec`)
#   handoff  — Sleep writes prompts; loop/skillopt_handoff.sh answers via
#              harness_council_run (claude / codex / cursor). Needs SkillOpt
#              newer than PyPI 0.2.0:
#                pip install "git+https://github.com/microsoft/SkillOpt.git"
#
# Requires: python3, and `skillopt-sleep` on PATH (or `python -m skillopt_sleep`).
#
# Usage:
#   loop/skillopt_sleep.sh export [--reviewed] [export flags...]
#   loop/skillopt_sleep.sh dry-run [--backend mock|claude|codex|handoff] [flags...]
#   loop/skillopt_sleep.sh run     [--backend ...] [--handoff-harness MEMBER] [--i-reviewed]
#   loop/skillopt_sleep.sh status|adopt|schedule|unschedule [flags...]
#
# Config (loop/loop.config.sh):
#   LOOP_KIT_SKILLOPT_SKILL_PATH      default .claude/skills/project-loop/SKILL.md
#   LOOP_KIT_SKILLOPT_BACKEND         default mock
#   LOOP_KIT_SKILLOPT_HANDOFF_HARNESS default first LOOP_KIT_HARNESSES member
#   LOOP_KIT_SKILLOPT_PREFERENCES     free-text house rules for reflection
#   LOOP_KIT_SKILLOPT_EDIT_BUDGET     default 4
#   LOOP_KIT_SKILLOPT_MAX_TASKS       default 40
#   LOOP_KIT_SKILLOPT_TASKS_FILE      default loop/state/skillopt-tasks.json
#
# Optional engine defaults: copy loop/skillopt-sleep.config.json.example to
# ~/.skillopt-sleep/config.json (evolve_memory=false, gate on, no auto-adopt).
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
[[ -f "$ROOT/loop/loop.config.sh" ]] && source "$ROOT/loop/loop.config.sh"

die() { echo "[skillopt_sleep] $*" >&2; exit 1; }
log() { echo "[skillopt_sleep] $*"; }

SKILL_PATH="${LOOP_KIT_SKILLOPT_SKILL_PATH:-}"
[[ -z "$SKILL_PATH" ]] && SKILL_PATH=".claude/skills/project-loop/SKILL.md"
BACKEND="${LOOP_KIT_SKILLOPT_BACKEND:-}"
[[ -z "$BACKEND" ]] && BACKEND="mock"
PREFERENCES="${LOOP_KIT_SKILLOPT_PREFERENCES:-}"
EDIT_BUDGET="${LOOP_KIT_SKILLOPT_EDIT_BUDGET:-}"
[[ -z "$EDIT_BUDGET" ]] && EDIT_BUDGET=4
MAX_TASKS="${LOOP_KIT_SKILLOPT_MAX_TASKS:-}"
[[ -z "$MAX_TASKS" ]] && MAX_TASKS=40
TASKS_FILE="${LOOP_KIT_SKILLOPT_TASKS_FILE:-}"
[[ -z "$TASKS_FILE" ]] && TASKS_FILE="$ROOT/loop/state/skillopt-tasks.json"
HANDOFF_HARNESS="${LOOP_KIT_SKILLOPT_HANDOFF_HARNESS:-}"

cmd="${1:-}"
[[ -n "$cmd" ]] || die "usage: loop/skillopt_sleep.sh <export|dry-run|run|status|adopt|schedule|unschedule> [flags...]"
shift || true

find_sleep_cli() {
  if command -v skillopt-sleep >/dev/null 2>&1; then
    echo "skillopt-sleep"
    return 0
  fi
  if python3 -c "import skillopt_sleep" >/dev/null 2>&1; then
    echo "python3 -m skillopt_sleep"
    return 0
  fi
  return 1
}

ensure_seed_skill() {
  local abs="$ROOT/$SKILL_PATH"
  if [[ "$SKILL_PATH" = /* ]]; then
    abs="$SKILL_PATH"
  fi
  if [[ -f "$abs" ]]; then
    return 0
  fi
  local kit_seed="$ROOT/.claude/skills/project-loop/SKILL.md"
  # During development inside the kit repo itself, seed from skills/
  if [[ ! -f "$kit_seed" && -f "$ROOT/skills/project-loop/SKILL.md" ]]; then
    mkdir -p "$(dirname "$abs")"
    cp "$ROOT/skills/project-loop/SKILL.md" "$abs"
    log "seeded missing skill from skills/project-loop/SKILL.md → $abs"
    return 0
  fi
  if [[ -f "$kit_seed" && "$abs" != "$kit_seed" ]]; then
    mkdir -p "$(dirname "$abs")"
    cp "$kit_seed" "$abs"
    log "seeded missing skill from $kit_seed → $abs"
    return 0
  fi
  die "managed skill missing at $abs — re-run install.sh or copy skills/project-loop/SKILL.md there"
}

tasks_reviewed() {
  local f="$1"
  [[ -f "$f" ]] || return 1
  python3 - "$f" <<'PY'
import json, sys
p = json.load(open(sys.argv[1]))
raise SystemExit(0 if (isinstance(p, dict) and p.get("reviewed") is True) else 1)
PY
}

run_export() {
  bash "$ROOT/loop/skillopt_export.sh" \
    -o "$TASKS_FILE" \
    --max-tasks "$MAX_TASKS" \
    --target-skill-path "$SKILL_PATH" \
    "$@"
}

# --- export only ----------------------------------------------------------------
if [[ "$cmd" == "export" ]]; then
  run_export "$@"
  exit $?
fi

# --- sleep engine commands ------------------------------------------------------
SLEEP_BIN="$(find_sleep_cli)" || die "skillopt-sleep not found. Install with: pip install skillopt   (handoff: pip install 'git+https://github.com/microsoft/SkillOpt.git')"

# Parse wrapper-owned flags; pass the rest through to skillopt-sleep / handoff driver.
pass=()
i_reviewed=0
use_tasks_file=1
explicit_tasks=""
backend="$BACKEND"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --i-reviewed) i_reviewed=1; shift ;;
    --no-tasks-file) use_tasks_file=0; shift ;;
    --tasks-file)
      explicit_tasks="$2"
      use_tasks_file=1
      shift 2
      ;;
    --backend) backend="$2"; shift 2 ;;
    --target-skill-path) SKILL_PATH="$2"; shift 2 ;;
    --handoff-harness) HANDOFF_HARNESS="$2"; shift 2 ;;
    --export-first)
      # default for dry-run/run; accepted as explicit no-op for clarity
      shift
      ;;
    --skip-export) use_tasks_file=1; SKIP_EXPORT=1; shift ;;
    *) pass+=("$1"); shift ;;
  esac
done
SKIP_EXPORT="${SKIP_EXPORT:-0}"

case "$cmd" in
  status|adopt|schedule|unschedule)
    # shellcheck disable=SC2086
    exec $SLEEP_BIN "$cmd" --project "$ROOT" "${pass[@]}"
    ;;
  dry-run|run)
    ensure_seed_skill
    if (( use_tasks_file )); then
      if [[ -n "$explicit_tasks" ]]; then
        TASKS_FILE="$explicit_tasks"
      elif (( ! SKIP_EXPORT )); then
        # Fresh export stays unreviewed unless --i-reviewed (or prior file already reviewed
        # and --skip-export). For real backends we refuse to invent reviewed=true silently.
        if (( i_reviewed )); then
          run_export --reviewed || die "export failed"
        else
          run_export || die "export failed"
        fi
      fi
      [[ -f "$TASKS_FILE" ]] || die "tasks file missing: $TASKS_FILE (run: loop/skillopt_sleep.sh export)"

      if [[ "$backend" != "mock" ]] && ! tasks_reviewed "$TASKS_FILE"; then
        if (( i_reviewed )); then
          # User asserted review; flip the flag in place.
          python3 - "$TASKS_FILE" <<'PY' || die "could not mark tasks file reviewed"
import json, sys
path = sys.argv[1]
with open(path, encoding="utf-8") as f:
    data = json.load(f)
if not isinstance(data, dict):
    raise SystemExit("tasks file must be a JSON object")
data["reviewed"] = True
with open(path, "w", encoding="utf-8") as f:
    json.dump(data, f, ensure_ascii=False, indent=2)
    f.write("\n")
print(f"[skillopt_sleep] marked reviewed=true → {path}")
PY
        else
          die "tasks file is not reviewed (backend=$backend). Inspect/redact $TASKS_FILE, then re-run with --i-reviewed (or export --reviewed after review)."
        fi
      fi
    fi

    # Common Sleep args (also passed into the handoff driver, which re-invokes Sleep).
    sleep_pass=(--project "$ROOT" --target-skill-path "$SKILL_PATH")
    if [[ "$EDIT_BUDGET" =~ ^[0-9]+$ ]] && (( EDIT_BUDGET > 0 )); then
      sleep_pass+=(--edit-budget "$EDIT_BUDGET")
    fi
    if [[ "$MAX_TASKS" =~ ^[0-9]+$ ]] && (( MAX_TASKS > 0 )); then
      sleep_pass+=(--max-tasks "$MAX_TASKS")
    fi
    if [[ -n "$PREFERENCES" ]]; then
      sleep_pass+=(--preferences "$PREFERENCES")
    fi
    if (( use_tasks_file )); then
      sleep_pass+=(--tasks-file "$TASKS_FILE")
    fi
    sleep_pass+=("${pass[@]}")

    if [[ "$backend" == "handoff" ]]; then
      handoff_args=("$cmd")
      if [[ -n "$HANDOFF_HARNESS" ]]; then
        handoff_args+=(--handoff-harness "$HANDOFF_HARNESS")
      fi
      handoff_args+=("${sleep_pass[@]}")
      log "dispatching handoff driver (subscription harness answers Sleep prompts)"
      exec bash "$ROOT/loop/skillopt_handoff.sh" "${handoff_args[@]}"
    fi

    args=("$cmd" --backend "$backend" "${sleep_pass[@]}")
    log "running: $SLEEP_BIN ${args[*]}"
    # shellcheck disable=SC2086
    exec $SLEEP_BIN "${args[@]}"
    ;;
  *)
    die "unknown command: $cmd (expected export|dry-run|run|status|adopt|schedule|unschedule)"
    ;;
esac

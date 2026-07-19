#!/usr/bin/env bash
# Activity-based SkillOpt-Sleep trigger for the maker/checker loop.
#
# Called by loop/run.sh so the feature surfaces without a hard-coded "every N"
# policy baked into code — thresholds and modes are LOOP_KIT_SKILLOPT_* config.
#
# Modes (LOOP_KIT_SKILLOPT_TRIGGER):
#   off      — do nothing
#   remind   — print an actionable one-liner (default; no API calls)
#   dry-run  — export + skillopt_sleep.sh dry-run (never adopts)
#   run      — export + skillopt_sleep.sh run (stages a proposal; never auto-adopts)
#
# When it fires (relative to loop/state/skillopt-trigger.json):
#   LOOP_KIT_SKILLOPT_TRIGGER_EVERY_DONE  — fire when this many tasks have entered
#       done/ since the last successful trigger (default 10; 0 = disable count gate)
#   LOOP_KIT_SKILLOPT_TRIGGER_ON_RUN_END  — evaluate at end of run.sh (default 1)
#   If ON_RUN_END=0 and EVERY_DONE>0, evaluate after each merge into done/ instead.
#
# Auto dry-run/run uses LOOP_KIT_SKILLOPT_TRIGGER_BACKEND (default mock). A non-mock
# backend is refused here (falls back to remind) — real providers need a reviewed
# tasks file; that stays a deliberate human step.
#
# Usage:
#   loop/skillopt_trigger.sh run-end
#   loop/skillopt_trigger.sh after-done
#   loop/skillopt_trigger.sh --self-test
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
[[ -f "$ROOT/loop/loop.config.sh" ]] && source "$ROOT/loop/loop.config.sh"

die() { echo "[skillopt_trigger] $*" >&2; exit 1; }
log() { echo "[skillopt_trigger] $*"; }

DONE="$ROOT/loop/queue/done"
STATE_DIR="$ROOT/loop/state"
STATE_FILE="$STATE_DIR/skillopt-trigger.json"

TRIGGER="${LOOP_KIT_SKILLOPT_TRIGGER:-remind}"
EVERY_DONE="${LOOP_KIT_SKILLOPT_TRIGGER_EVERY_DONE:-10}"
ON_RUN_END="${LOOP_KIT_SKILLOPT_TRIGGER_ON_RUN_END:-1}"
TRIGGER_BACKEND="${LOOP_KIT_SKILLOPT_TRIGGER_BACKEND:-}"
[[ -z "$TRIGGER_BACKEND" ]] && TRIGGER_BACKEND="mock"

count_done() {
  local n=0
  [[ -d "$DONE" ]] || { echo 0; return; }
  n=$(find "$DONE" -maxdepth 1 -name 'T*.md' 2>/dev/null | wc -l | tr -d ' ')
  echo "${n:-0}"
}

read_state() {
  python3 - "$STATE_FILE" <<'PY'
import json, sys
from pathlib import Path
path = Path(sys.argv[1])
default = {"last_done_count": 0, "last_trigger_at": "", "last_mode": "", "last_reason": "", "last_action": ""}
if not path.is_file():
    print(json.dumps(default))
    raise SystemExit(0)
try:
    data = json.loads(path.read_text(encoding="utf-8"))
except Exception:
    data = {}
out = {**default, **{k: data.get(k, default[k]) for k in default}}
print(json.dumps(out))
PY
}

write_state() {
  local done_count="$1" mode="$2" reason="$3" action="$4"
  mkdir -p "$STATE_DIR"
  python3 - "$STATE_FILE" "$done_count" "$mode" "$reason" "$action" <<'PY'
import json, sys
from datetime import datetime, timezone
from pathlib import Path
path = Path(sys.argv[1])
payload = {
    "last_done_count": int(sys.argv[2]),
    "last_trigger_at": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
    "last_mode": sys.argv[3],
    "last_reason": sys.argv[4],
    "last_action": sys.argv[5],
}
path.write_text(json.dumps(payload, indent=2) + "\n", encoding="utf-8")
PY
}

should_fire() {
  local reason="$1" done_count="$2" last_done="$3" since
  since=$((done_count - last_done))
  (( since < 0 )) && since=0

  case "$TRIGGER" in
    off|"") return 1 ;;
  esac

  # Count gate: EVERY_DONE=0 disables threshold-based firing entirely.
  if [[ ! "$EVERY_DONE" =~ ^[0-9]+$ ]]; then
    EVERY_DONE=10
  fi
  if (( EVERY_DONE == 0 )); then
    return 1
  fi
  if (( since < EVERY_DONE )); then
    return 1
  fi

  case "$reason" in
    run-end)
      [[ "$ON_RUN_END" == "1" || "$ON_RUN_END" == "true" ]] || return 1
      return 0
      ;;
    after-done)
      # Only when run-end evaluation is off — otherwise run-end owns the check.
      [[ "$ON_RUN_END" == "1" || "$ON_RUN_END" == "true" ]] && return 1
      return 0
      ;;
    *) return 1 ;;
  esac
}

remind_message() {
  local since="$1" done_count="$2"
  cat <<EOF
[skillopt_trigger] $since task(s) merged to done since last SkillOpt trigger (done total=$done_count, every=$EVERY_DONE).
[skillopt_trigger] Refine the project skill when ready (subscription CLIs — no API key):
[skillopt_trigger]   loop/skillopt_sleep.sh dry-run --backend mock
[skillopt_trigger]   loop/skillopt_sleep.sh run --backend claude --i-reviewed
[skillopt_trigger]   loop/skillopt_sleep.sh run --backend handoff --handoff-harness cursor --i-reviewed
[skillopt_trigger]   loop/skillopt_sleep.sh status / adopt
[skillopt_trigger] Set LOOP_KIT_SKILLOPT_TRIGGER=off to silence, or dry-run|run to auto-stage (never auto-adopts).
EOF
}

run_action() {
  local reason="$1" done_count="$2" since="$3"
  local action="" rc=0

  case "$TRIGGER" in
    remind)
      remind_message "$since" "$done_count"
      action="reminded"
      ;;
    dry-run|run)
      case "$TRIGGER_BACKEND" in
        mock|claude|codex|handoff)
          log "threshold met ($since since last) — auto $TRIGGER --backend $TRIGGER_BACKEND (no adopt)"
          if ! bash "$ROOT/loop/skillopt_sleep.sh" "$TRIGGER" --backend "$TRIGGER_BACKEND"; then
            rc=$?
            log "auto $TRIGGER failed (exit $rc) — not advancing trigger watermark; fix skillopt install or see logs above"
            return "$rc"
          fi
          action="auto-$TRIGGER-$TRIGGER_BACKEND"
          ;;
        *)
          log "threshold met, but TRIGGER_BACKEND=$TRIGGER_BACKEND is not mock|claude|codex|handoff — refusing; reminding instead"
          remind_message "$since" "$done_count"
          action="reminded-unsupported-backend"
          ;;
      esac
      ;;
    *)
      log "unknown LOOP_KIT_SKILLOPT_TRIGGER='$TRIGGER' — treating as off"
      return 0
      ;;
  esac

  write_state "$done_count" "$TRIGGER" "$reason" "$action"
  return 0
}

evaluate() {
  local reason="$1"
  local done_count last_done since
  local state

  done_count="$(count_done)"
  state="$(read_state)"
  last_done="$(python3 -c "import json,sys; print(json.loads(sys.argv[1])['last_done_count'])" "$state")"
  since=$((done_count - last_done))
  (( since < 0 )) && since=0

  if ! should_fire "$reason" "$done_count" "$last_done"; then
    return 0
  fi
  run_action "$reason" "$done_count" "$since"
}

if [[ "${1:-}" == "--self-test" ]]; then
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/skillopt-trigger-selftest.XXXXXX")"
  trap 'rm -rf "$tmp"' EXIT
  mkdir -p "$tmp/loop/queue/done" "$tmp/loop/state"
  ROOT="$tmp"
  DONE="$tmp/loop/queue/done"
  STATE_DIR="$tmp/loop/state"
  STATE_FILE="$STATE_DIR/skillopt-trigger.json"
  TRIGGER=remind
  EVERY_DONE=2
  ON_RUN_END=1
  for i in 1 2; do echo "x" > "$DONE/T00${i}-a.md"; done
  evaluate run-end >/tmp/skillopt-trigger-st1.txt
  grep -q 'skillopt_trigger' /tmp/skillopt-trigger-st1.txt || die "self-test: expected first remind"
  [[ -f "$STATE_FILE" ]] || die "self-test: state not written"
  out="$(evaluate run-end 2>&1 || true)"
  [[ -z "$out" ]] || die "self-test: unexpected second fire with no new done: $out"
  echo "y" > "$DONE/T003-b.md"
  out="$(evaluate run-end 2>&1 || true)"
  [[ -z "$out" ]] || die "self-test: since=1 should not fire (every=2): $out"
  echo "z" > "$DONE/T004-c.md"
  out="$(evaluate run-end 2>&1)"
  echo "$out" | grep -q 'skillopt_trigger' || die "self-test: expected remind after since>=2"
  echo "[skillopt_trigger] self-test ok"
  exit 0
fi

reason="${1:-}"
[[ "$reason" == "run-end" || "$reason" == "after-done" ]] \
  || die "usage: loop/skillopt_trigger.sh <run-end|after-done|--self-test>"

evaluate "$reason"

#!/usr/bin/env bash
# Drive SkillOpt-Sleep --backend handoff using this kit's harness adapters.
#
# Sleep writes pending model prompts under .skillopt-sleep-handoff/; this script
# answers each with harness_council_run (fresh context, subscription CLI — Claude
# Code, Codex, Cursor, Copilot, or opencode) and re-invokes Sleep until the cycle finishes.
#
# No Anthropic/OpenAI API key is required. Cursor / Copilot / opencode are supported via this
# handoff path (there is no native Sleep backend for those CLIs upstream).
#
# Usage (normally invoked by loop/skillopt_sleep.sh when backend=handoff):
#   loop/skillopt_handoff.sh <dry-run|run> [sleep args...]
#   loop/skillopt_handoff.sh --self-test
#
# Env / config:
#   LOOP_KIT_SKILLOPT_HANDOFF_HARNESS  member spec (default: first LOOP_KIT_HARNESSES)
#   SKILLOPT_SLEEP_HANDOFF_DIR         override handoff directory
#   SKILLOPT_HANDOFF_MAX_ROUNDS        default 12
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
[[ -f "$ROOT/loop/loop.config.sh" ]] && source "$ROOT/loop/loop.config.sh"

die() { echo "[skillopt_handoff] $*" >&2; exit 1; }
log() { echo "[skillopt_handoff] $*" >&2; }

member_harness() { echo "${1%%:*}"; }
member_model() { [[ "$1" == *:* ]] && echo "${1#*:}" || echo ""; }

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

default_handoff_harness() {
  local h="${LOOP_KIT_SKILLOPT_HANDOFF_HARNESS:-}"
  if [[ -n "$h" ]]; then
    echo "$h"
    return
  fi
  # First maker/checker member, else claude.
  read -ra _hs <<< "${LOOP_KIT_HARNESSES:-claude}"
  echo "${_hs[0]:-claude}"
}

# Answer every pending prompt in pending.json using harness_council_run.
# $1 = handoff dir, $2 = member spec. Returns number of answers written.
answer_pending() {
  local handoff_dir="$1" member="$2"
  local pending="$handoff_dir/pending.json"
  local answers_dir="$handoff_dir/answers"
  local hn model adapter n=0

  [[ -f "$pending" ]] || die "missing $pending"
  mkdir -p "$answers_dir"

  hn="$(member_harness "$member")"
  model="$(member_model "$member")"
  adapter="$ROOT/loop/harnesses/$hn.sh"
  [[ -f "$adapter" ]] || die "no harness adapter at $adapter for member '$member'"

  # shellcheck disable=SC1090
  source "$adapter"
  command -v harness_council_run >/dev/null 2>&1 \
    || die "$adapter does not define harness_council_run"

  # Extract ids + prompts via python (pending.json can be large).
  local tmp_list
  tmp_list="$(mktemp)"
  python3 - "$pending" "$tmp_list" <<'PY' || die "could not parse pending.json"
import json, sys
from pathlib import Path
pending = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
items = pending.get("pending") or []
out = Path(sys.argv[2])
lines = []
for item in items:
    if not isinstance(item, dict):
        continue
    pid = str(item.get("id") or "").strip()
    prompt = str(item.get("prompt") or "")
    if not pid or not prompt:
        continue
    lines.append(pid)
    # Write prompt beside list for the shell loop
    Path(sys.argv[2] + "." + pid + ".prompt").write_text(prompt, encoding="utf-8")
out.write_text("\n".join(lines) + ("\n" if lines else ""), encoding="utf-8")
PY

  local pid prompt_file out_file
  while IFS= read -r pid; do
    [[ -n "$pid" ]] || continue
    prompt_file="${tmp_list}.${pid}.prompt"
    out_file="$answers_dir/${pid}.md"
    if [[ -f "$out_file" && -s "$out_file" ]]; then
      log "skip existing answer $pid"
      rm -f "$prompt_file"
      continue
    fi
    log "answering $pid via $member (harness_council_run)"
    harness_council_run "$prompt_file" "$out_file" "$model"
    local rc=$?
    if (( rc != 0 )) || [[ ! -s "$out_file" ]]; then
      rm -f "$prompt_file" "$tmp_list"
      die "harness_council_run failed for $pid (exit $rc) — answer not written"
    fi
    # Strip a trailing VERDICT line if a review-ish harness added one — Sleep wants raw text.
    python3 - "$out_file" <<'PY'
from pathlib import Path
import re, sys
p = Path(sys.argv[1])
text = p.read_text(encoding="utf-8", errors="replace")
text = re.sub(r"(?m)^VERDICT:\s*\S+\s*$", "", text).rstrip() + "\n"
p.write_text(text, encoding="utf-8")
PY
    n=$((n + 1))
    rm -f "$prompt_file"
  done < "$tmp_list"
  rm -f "$tmp_list"
  echo "$n"
}

run_handoff_loop() {
  local cmd="$1"
  shift
  local sleep_bin member handoff_dir max_rounds round=0 rc=0

  sleep_bin="$(find_sleep_cli)" \
    || die "skillopt-sleep not found. Install with: pip install skillopt  (handoff needs main: pip install 'git+https://github.com/microsoft/SkillOpt.git')"

  member="$(default_handoff_harness)"
  # Allow --handoff-harness in remaining args (strip for Sleep).
  local sleep_args=()
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --handoff-harness) member="$2"; shift 2 ;;
      *) sleep_args+=("$1"); shift ;;
    esac
  done

  handoff_dir="${SKILLOPT_SLEEP_HANDOFF_DIR:-$ROOT/.skillopt-sleep-handoff}"
  max_rounds="${SKILLOPT_HANDOFF_MAX_ROUNDS:-12}"
  export SKILLOPT_SLEEP_HANDOFF_DIR="$handoff_dir"

  log "handoff harness=$member  dir=$handoff_dir  max_rounds=$max_rounds"

  while (( round < max_rounds )); do
    round=$((round + 1))
    log "sleep round $round/$max_rounds: $sleep_bin $cmd --backend handoff …"
    # shellcheck disable=SC2086
    set +e
    $sleep_bin "$cmd" --backend handoff "${sleep_args[@]}"
    rc=$?
    set -e

    if (( rc == 0 )); then
      log "sleep finished successfully after $round round(s)"
      return 0
    fi
    if (( rc != 3 )); then
      die "skillopt-sleep exited $rc (expected 0 or handoff-pending 3)"
    fi

    [[ -f "$handoff_dir/pending.json" ]] \
      || die "exit 3 but missing $handoff_dir/pending.json — upgrade skillopt (handoff needs newer than PyPI 0.2.0)"

    local answered
    answered="$(answer_pending "$handoff_dir" "$member")"
    log "wrote $answered new answer(s); re-invoking sleep"
    if [[ "$answered" == "0" ]]; then
      die "no new answers written but Sleep still pending — check answers/ and harness output"
    fi
  done
  die "exceeded SKILLOPT_HANDOFF_MAX_ROUNDS=$max_rounds without finishing"
}

# --- self-test: pending → answer file via a stub harness (no real model) --------
if [[ "${1:-}" == "--self-test" ]]; then
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/skillopt-handoff-selftest.XXXXXX")"
  trap 'rm -rf "$tmp"' EXIT
  mkdir -p "$tmp/loop/harnesses" "$tmp/handoff/answers"
  cat > "$tmp/loop/harnesses/stub.sh" <<'EOF'
harness_council_run() {
  local prompt_file="$1" output_file="$2"
  # Echo a deterministic answer derived from the prompt id marker if present.
  {
    echo "STUB_ANSWER"
    head -c 80 "$prompt_file"
  } > "$output_file"
  return 0
}
EOF
  ROOT="$tmp"
  cat > "$tmp/handoff/pending.json" <<'EOF'
{
  "format": "skillopt_sleep.handoff.v1",
  "answers_dir": "answers",
  "pending": [
    {
      "id": "abc123deadbeef00",
      "answer_file": "answers/abc123deadbeef00.md",
      "max_tokens": 128,
      "prompt": "Say hello for the skillopt handoff self-test."
    }
  ]
}
EOF
  n="$(answer_pending "$tmp/handoff" "stub")"
  [[ "$n" == "1" ]] || die "self-test: expected 1 answer, got $n"
  grep -q STUB_ANSWER "$tmp/handoff/answers/abc123deadbeef00.md" \
    || die "self-test: answer file missing STUB_ANSWER"
  # Second pass skips existing
  n="$(answer_pending "$tmp/handoff" "stub")"
  [[ "$n" == "0" ]] || die "self-test: expected 0 new answers on second pass, got $n"
  echo "[skillopt_handoff] self-test ok"
  exit 0
fi

cmd="${1:-}"
[[ "$cmd" == "dry-run" || "$cmd" == "run" ]] \
  || die "usage: loop/skillopt_handoff.sh <dry-run|run> [sleep args...] | --self-test"
shift
run_handoff_loop "$cmd" "$@"

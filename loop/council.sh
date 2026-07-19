#!/usr/bin/env bash
# Fan a single question out to several independent LLMs in parallel and save each answer to
# disk. This is the read-only counterpart to loop/run.sh's maker/checker loop: no merging, no
# verdicts, no state machine — it exists to gather independent opinions for a human (or a
# follow-up Claude session) to synthesize into a spec/ADR/roadmap change, the way T034-T036 and
# ADR-014/015 were produced.
#
# Usage:
#   loop/council.sh <question-file.md> [output-dir]
#
# <question-file.md> is a plain markdown file containing the question you want every member to
# answer independently — write it the way you'd write a loop/queue task file: concrete, self-
# contained, and naming exactly which repo docs the member should read before answering. See
# loop/council_prompt.tpl.md for the wrapper every member actually receives (your question file
# is substituted into it, not sent alone).
#
# Who's asked is config, not code: LOOP_KIT_COUNCIL_HARNESSES in loop.config.sh (space-separated
# *members*, same "harness" or "harness:model" syntax as LOOP_KIT_HARNESSES — see run.sh's
# HARNESSES comment). Default: codex opencode claude. Each member's harness portion needs a
# loop/harnesses/<name>.sh adapter implementing harness_council_run (see
# loop/harnesses/TEMPLATE.sh.example) — this kit's codex/claude/cursor/copilot/opencode
# adapters all do. Unlike LOOP_KIT_HARNESSES, members here don't need to be distinct or even
# >=2 of them — there's no self-review adjacency concern for an independent-opinions fan-out,
# just diminishing value in asking the same member twice.
#
# COUNCIL_SKIP="member member ..." (space-separated, matching entries in LOOP_KIT_COUNCIL_HARNESSES
# exactly) skips those members for this run without editing config, e.g. COUNCIL_SKIP="opencode".
#
# Output lands in loop/council/log/<timestamp>-<slug>/<member>.md (colons in a pinned member spec
# become dashes in the filename), or [output-dir] if given. Nothing here writes to specs/, docs/,
# or any tracked file — reconciling the answers into an ADR/spec/roadmap change is a separate,
# deliberate step, same as it was for ADR-014/015.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TPL="$ROOT/loop/council_prompt.tpl.md"

log()  { echo "[council] $*"; }
die()  { echo "[council] STOP: $*" >&2; exit 1; }

[[ -f "$ROOT/loop/loop.config.sh" ]] && source "$ROOT/loop/loop.config.sh"

read -ra COUNCIL_MEMBERS <<< "${LOOP_KIT_COUNCIL_HARNESSES:-codex opencode claude}"
(( ${#COUNCIL_MEMBERS[@]} >= 1 )) || die "LOOP_KIT_COUNCIL_HARNESSES is empty — nothing to ask"

member_harness() { echo "${1%%:*}"; }
member_model() { [[ "$1" == *:* ]] && echo "${1#*:}" || echo ""; }

for m in "${COUNCIL_MEMBERS[@]}"; do
  [[ -f "$ROOT/loop/harnesses/$(member_harness "$m").sh" ]] || die "no adapter at loop/harnesses/$(member_harness "$m").sh for member '$m' listed in LOOP_KIT_COUNCIL_HARNESSES — see loop/harnesses/TEMPLATE.sh.example"
done

read -ra SKIP <<< "${COUNCIL_SKIP:-}"
is_skipped() {
  local m="$1" s
  for s in "${SKIP[@]}"; do [[ "$s" == "$m" ]] && return 0; done
  return 1
}

question_file="${1:-}"
[[ -z "$question_file" ]] && die "usage: loop/council.sh <question-file.md> [output-dir]"
[[ -f "$question_file" ]] || die "question file not found: $question_file"

slug="$(basename "$question_file" .md)"
out_dir="${2:-$ROOT/loop/council/log/$(date +%Y%m%d-%H%M%S)-$slug}"
mkdir -p "$out_dir"

rendered="$out_dir/prompt.md"
body=$(cat "$question_file")
out=$(cat "$TPL")
python3 - "$out" "$body" > "$rendered" <<'PY'
import sys
out, body = sys.argv[1], sys.argv[2]
print(out.replace("{{QUESTION_BODY}}", body))
PY

log "question: $question_file"
log "output dir: $out_dir"
log "members: ${COUNCIL_MEMBERS[*]}"

pids=()
launched=()

for member in "${COUNCIL_MEMBERS[@]}"; do
  if is_skipped "$member"; then
    log "skipping $member (COUNCIL_SKIP)"
    continue
  fi
  harness="$(member_harness "$member")"
  model="$(member_model "$member")"
  # Re-source the right adapter immediately before each launch, same as run.sh — a background
  # subshell forked with `( ... ) &` captures the function definitions in effect at fork time, so
  # this is safe even though the next loop iteration may re-source a different adapter into the
  # same function names in this parent shell.
  source "$ROOT/loop/harnesses/$harness.sh"
  out_file="$out_dir/${member//:/-}.md"
  log "launching $member..."
  ( harness_council_run "$rendered" "$out_file" "$model" ) &
  pids+=($!)
  launched+=("$member")
done

[[ ${#pids[@]} -eq 0 ]] && die "every member was skipped — nothing to run"

fail=0
for pid in "${pids[@]}"; do
  wait "$pid" || fail=1
done

log "done (some members may have failed non-zero — check each file below regardless, a"
log "non-zero exit doesn't mean the answer is unusable, and 0 doesn't guarantee it is)"
for member in "${launched[@]}"; do
  f="$out_dir/${member//:/-}.md"
  [[ -f "$f" ]] && log "  $f"
done
log "next step is manual/Claude synthesis — this script only gathers opinions, it does not reconcile them"

exit "$fail"

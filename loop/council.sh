#!/usr/bin/env bash
# Fan a single question out to several independent LLMs in parallel and save each answer to
# disk. This is the read-only counterpart to loop/run.sh's maker/checker loop: no merging, no
# verdicts, no state machine — it exists to gather independent opinions for a human (or a
# follow-up Claude session) to synthesize into a spec/ADR/roadmap change, the way T034-T036 and
# ADR-014/015 were produced.
#
# Usage:
#   loop/council.sh [--synthesize] [--synthesizer MEMBER] <question-file.md> [output-dir]
#   loop/council.sh --self-test
#
# <question-file.md> is a plain markdown file containing the question you want every member to
# answer independently — write it the way you'd write a loop/queue task file: concrete, self-
# contained, and naming exactly which repo docs the member should read before answering. See
# loop/council_prompt.tpl.md for the wrapper every member actually receives (your question file
# is substituted into it, not sent alone).
#
# --synthesize turns the manual "read N files and reconcile them yourself" step (still the
# default without this flag) into one more council call: a synthesizer member reads the
# question plus every other member's answer and writes loop/council_prompt.tpl.md's counterpart,
# loop/council_synthesis_prompt.tpl.md, to <out-dir>/synthesis.md — naming where members
# converged (strongest signal), making an explicit call wherever they split, and giving a
# compact recommendation. It is still advisory only: nothing here writes to specs/, docs/, or
# any tracked file, same as the rest of council.sh — a human still decides what to do with it,
# and an automated synthesis is worth the same skepticism as any other single model's take.
#
# Synthesizer selection: --synthesizer MEMBER, else LOOP_KIT_COUNCIL_SYNTHESIZER in
# loop.config.sh, else the first member that actually got launched this run. That default means
# the synthesizer may be reconciling its own answer among the others — a mild bias risk (no
# self-review adjacency rule applies here, unlike LOOP_KIT_HARNESSES) worth knowing about; pass
# --synthesizer explicitly to pick a member that didn't also answer, when that matters.
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

# --- self-test: fan-out + --synthesize via a stub harness (no real model) ---------------------
# council.sh is flat top-level script, not functions to source-and-call like this kit's other
# --self-test scripts (skillopt_export.sh, skillopt_handoff.sh) — so this fixture invokes a
# fresh copy of the real script as a subprocess against a throwaway ROOT instead, exercising the
# actual flag parsing, fan-out, and synthesis logic rather than a reimplementation of it.
if [[ "${1:-}" == "--self-test" ]]; then
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/council-selftest.XXXXXX")"
  trap 'rm -rf "$tmp"' EXIT
  mkdir -p "$tmp/loop/harnesses"
  cp "$ROOT/loop/council.sh" "$tmp/loop/council.sh"
  cp "$ROOT/loop/council_prompt.tpl.md" "$tmp/loop/council_prompt.tpl.md"
  cp "$ROOT/loop/council_synthesis_prompt.tpl.md" "$tmp/loop/council_synthesis_prompt.tpl.md"
  cat > "$tmp/loop/harnesses/stub.sh" <<'EOF'
harness_council_run() {
  local prompt_file="$1" output_file="$2" model="${3:-}"
  {
    echo "STUB_ANSWER from model=${model:-default}"
    echo "position: use option A because it is simpler"
  } > "$output_file"
  return 0
}
EOF
  cat > "$tmp/question.md" <<'EOF'
# Self-test question

Pick option A or option B.
EOF

  die_st() { echo "[council] self-test FAILED: $*" >&2; exit 1; }

  out1=$(cd "$tmp" && LOOP_KIT_COUNCIL_HARNESSES="stub:a stub:b" bash loop/council.sh "$tmp/question.md" "$tmp/out1" 2>&1) \
    || die_st "plain fan-out run exited non-zero: $out1"
  [[ -f "$tmp/out1/stub-a.md" && -f "$tmp/out1/stub-b.md" ]] || die_st "expected both member answer files in out1: $out1"
  grep -q STUB_ANSWER "$tmp/out1/stub-a.md" || die_st "stub-a.md missing STUB_ANSWER"
  [[ -f "$tmp/out1/synthesis.md" ]] && die_st "synthesis.md should not exist without --synthesize"

  out2=$(cd "$tmp" && LOOP_KIT_COUNCIL_HARNESSES="stub:a stub:b" bash loop/council.sh --synthesize "$tmp/question.md" "$tmp/out2" 2>&1) \
    || die_st "--synthesize run exited non-zero: $out2"
  [[ -f "$tmp/out2/synthesis.md" ]] || die_st "expected out2/synthesis.md with --synthesize: $out2"
  grep -q STUB_ANSWER "$tmp/out2/synthesis.md" || die_st "synthesis.md should embed the member answers it reconciled"
  grep -q "synthesizing via stub:a" <<< "$out2" || die_st "expected default synthesizer to be the first launched member (stub:a): $out2"

  out3=$(cd "$tmp" && LOOP_KIT_COUNCIL_HARNESSES="stub:a stub:b" bash loop/council.sh --synthesizer stub:b "$tmp/question.md" "$tmp/out3" 2>&1) \
    || die_st "--synthesizer override run exited non-zero: $out3"
  grep -q "synthesizing via stub:b" <<< "$out3" || die_st "expected --synthesizer to override the default synthesizer: $out3"

  echo "[council] self-test ok"
  exit 0
fi

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

synthesize=0
synthesizer=""
positional=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --synthesize) synthesize=1; shift ;;
    --synthesizer) synthesizer="${2:-}"; synthesize=1; shift 2 ;;
    -h|--help) sed -n '2,48p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    --) shift; while [[ $# -gt 0 ]]; do positional+=("$1"); shift; done ;;
    -*) die "unknown option: $1 (see --help)" ;;
    *) positional+=("$1"); shift ;;
  esac
done
set -- "${positional[@]}"

question_file="${1:-}"
[[ -z "$question_file" ]] && die "usage: loop/council.sh [--synthesize] [--synthesizer MEMBER] <question-file.md> [output-dir]"
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

if (( synthesize )); then
  synth_member="${synthesizer:-${LOOP_KIT_COUNCIL_SYNTHESIZER:-${launched[0]:-}}}"
  if [[ -z "$synth_member" ]]; then
    log "no members launched — skipping synthesis"
  else
    # Gather every launched member's answer that actually produced output. A member that failed
    # or wrote nothing is noted as missing rather than silently dropped, so the synthesizer knows
    # its input set is incomplete instead of reading unanimous agreement into partial data.
    answers_body=""
    n_available=0
    for member in "${launched[@]}"; do
      f="$out_dir/${member//:/-}.md"
      if [[ -s "$f" ]]; then
        answers_body+=$'\n\n### '"$member"$'\n\n'"$(cat "$f")"
        n_available=$((n_available+1))
      else
        answers_body+=$'\n\n### '"$member"$'\n\n_(no answer file — this member produced no output or failed)_'
      fi
    done

    if (( n_available < 2 )); then
      log "fewer than 2 members produced an answer — skipping synthesis (nothing to reconcile)"
    else
      synth_harness="$(member_harness "$synth_member")"
      synth_model="$(member_model "$synth_member")"
      [[ -f "$ROOT/loop/harnesses/$synth_harness.sh" ]] || die "no adapter at loop/harnesses/$synth_harness.sh for synthesizer '$synth_member' (--synthesizer / LOOP_KIT_COUNCIL_SYNTHESIZER)"
      source "$ROOT/loop/harnesses/$synth_harness.sh"
      synth_prompt="$out_dir/synthesis-prompt.md"
      synth_out="$out_dir/synthesis.md"
      synth_tpl=$(cat "$ROOT/loop/council_synthesis_prompt.tpl.md")
      python3 - "$synth_tpl" "$body" "$answers_body" > "$synth_prompt" <<'PY'
import sys
tpl, question, answers = sys.argv[1], sys.argv[2], sys.argv[3]
print(tpl.replace("{{QUESTION_BODY}}", question).replace("{{ANSWERS_BODY}}", answers))
PY
      log "synthesizing via $synth_member (reconciling ${#launched[@]} member answer(s))..."
      harness_council_run "$synth_prompt" "$synth_out" "$synth_model" || log "synthesis call exited non-zero — check $synth_out anyway before discarding it"
      log "  $synth_out"
    fi
  fi
else
  log "next step is manual/Claude synthesis (or re-run with --synthesize) — this script only gathers opinions by default, it does not reconcile them"
fi

exit "$fail"

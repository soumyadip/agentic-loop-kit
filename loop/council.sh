#!/usr/bin/env bash
# Fan a single question out to three independent LLMs (Codex, an opencode-hosted open
# model, and Claude) in parallel and save each answer to disk. This is the read-only
# counterpart to loop/run.sh's maker/checker loop: no merging, no verdicts, no state
# machine — it exists to gather independent opinions for a human (or a follow-up Claude
# session) to synthesize into a spec/ADR/roadmap change, the way T034-T036 and ADR-014/015
# were produced.
#
# Usage:
#   loop/council.sh <question-file.md> [output-dir]
#
# <question-file.md> is a plain markdown file containing the question you want all three
# members to answer independently — write it the way you'd write a loop/queue task file:
# concrete, self-contained, and naming exactly which repo docs the member should read
# before answering. See loop/council_prompt.tpl.md for the wrapper every member actually
# receives (your question file is substituted into it, not sent alone).
#
# Output lands in loop/council/log/<timestamp>-<slug>/{codex,opencode,claude}.md (or
# [output-dir] if given). Nothing here writes to specs/, docs/, or any tracked file —
# reconciling the three answers into an ADR/spec/roadmap change is a separate, deliberate
# step, same as it was for ADR-014/015.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TPL="$ROOT/loop/council_prompt.tpl.md"

CODEX_MODEL="${COUNCIL_CODEX_MODEL:-}"
OPENCODE_MODEL="${COUNCIL_OPENCODE_MODEL:-nvidia/z-ai/glm-5.2}"
CLAUDE_MODEL="${COUNCIL_CLAUDE_MODEL:-sonnet}"
TIMEOUT="${COUNCIL_TIMEOUT:-900}"
SKIP_CODEX="${COUNCIL_SKIP_CODEX:-0}"
SKIP_OPENCODE="${COUNCIL_SKIP_OPENCODE:-0}"
SKIP_CLAUDE="${COUNCIL_SKIP_CLAUDE:-0}"

log()  { echo "[council] $*"; }
die()  { echo "[council] STOP: $*" >&2; exit 1; }

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

pids=()

if [[ "$SKIP_CODEX" != "1" ]]; then
  log "launching codex ($([[ -n "$CODEX_MODEL" ]] && echo "$CODEX_MODEL" || echo "default"))..."
  ( codex_args=(exec -s read-only -C "$ROOT")
    [[ -n "$CODEX_MODEL" ]] && codex_args+=(-m "$CODEX_MODEL")
    timeout "$TIMEOUT" codex "${codex_args[@]}" - < "$rendered" > "$out_dir/codex.md" 2>&1 ) &
  pids+=($!)
else
  log "skipping codex (COUNCIL_SKIP_CODEX=1)"
fi

if [[ "$SKIP_OPENCODE" != "1" ]]; then
  if command -v opencode > /dev/null 2>&1; then
    log "launching opencode ($OPENCODE_MODEL)..."
    ( cd "$ROOT" && timeout "$TIMEOUT" opencode run --auto --agent plan -m "$OPENCODE_MODEL" < "$rendered" > "$out_dir/opencode.md" 2>&1 ) &
    pids+=($!)
  else
    log "skipping opencode (not installed)"
  fi
else
  log "skipping opencode (COUNCIL_SKIP_OPENCODE=1)"
fi

if [[ "$SKIP_CLAUDE" != "1" ]]; then
  log "launching claude ($CLAUDE_MODEL)..."
  ( cd "$ROOT" && timeout "$TIMEOUT" claude -p --model "$CLAUDE_MODEL" --permission-mode plan < "$rendered" > "$out_dir/claude.md" 2>&1 ) &
  pids+=($!)
else
  log "skipping claude (COUNCIL_SKIP_CLAUDE=1)"
fi

[[ ${#pids[@]} -eq 0 ]] && die "all three members skipped — nothing to run"

fail=0
for pid in "${pids[@]}"; do
  wait "$pid" || fail=1
done

log "done (some members may have failed non-zero — check each file below regardless, a"
log "non-zero exit doesn't mean the answer is unusable, and 0 doesn't guarantee it is)"
for f in "$out_dir"/codex.md "$out_dir"/opencode.md "$out_dir"/claude.md; do
  [[ -f "$f" ]] && log "  $f"
done
log "next step is manual/Claude synthesis — this script only gathers opinions, it does not reconcile them"

exit "$fail"

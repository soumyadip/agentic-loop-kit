#!/usr/bin/env bash
# Shared prompt-template renderer. Sourced by run.sh and review_pr.sh so template-rendering
# logic lives in exactly one place — requires $ROOT to already be set by the caller (used to
# find loop/review_mandate.partial.md).

render() { # render TEMPLATE TASK_ID TASK_BODY_FILE BRANCH [FAILURE_FILE] [MAKER] [BREAK_ATTEMPTS] [REVIEWER_MODE_NOTE]
  local tpl="$1" task_id="$2" body_file="$3" branch="$4" failure_file="${5:-}" maker_name="${6:-codex}" break_attempts="${7:-1}" reviewer_mode_note="${8:-}"
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
  # Shared red-team/bug-report/adjudication/output-format block, reused by every review-style
  # template (review_prompt.tpl.md, pr_review_prompt.tpl.md) so that content lives in one place
  # instead of being copy-pasted per template — see loop/review_mandate.partial.md. Harmless
  # no-op for templates (like task_prompt.tpl.md) that don't reference the token.
  local mandate
  mandate=$(cat "$ROOT/loop/review_mandate.partial.md" 2>/dev/null)
  mandate="${mandate//\{\{BREAK_ATTEMPTS\}\}/$break_attempts}"

  out=$(cat "$tpl")
  out="${out//\{\{TASK_ID\}\}/$task_id}"
  out="${out//\{\{BRANCH\}\}/$branch}"
  out="${out//\{\{MAKER\}\}/$maker_name}"
  out="${out//\{\{BREAK_ATTEMPTS\}\}/$break_attempts}"
  out="${out//\{\{PREVIOUS_FAILURE_BLOCK\}\}/$failure_block}"
  out="${out//\{\{REVIEWER_MODE_NOTE\}\}/$reviewer_mode_note}"
  out="${out//\{\{RED_TEAM_MANDATE\}\}/$mandate}"
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

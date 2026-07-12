#!/usr/bin/env bash
# Harness adapter for Cursor's CLI (`cursor-agent`). See TEMPLATE.sh.example for the interface
# every adapter implements.
#
# cursor-agent fronts several model families through one CLI/account (grok, claude, gpt, ...),
# which makes it a natural fit for filling more than one seat in LOOP_KIT_HARNESSES by itself —
# e.g. `cursor:grok-4.5-high cursor:claude-4.5-sonnet` — since a diff made under one model
# family is still meaningfully checked by a different one, even though both members share this
# one adapter. See run.sh's HARNESSES comment for the harness:model member-spec syntax.
HARNESS_NAME="cursor"

# cursor-agent's model slug already bakes in reasoning effort (e.g. grok-4.5-high), so one flat
# model covers every complexity tier and both the maker and checker roles when a member doesn't
# pin its own model (harness_maker_run/harness_reviewer_run's model_override argument takes
# precedence over this whenever a member spec pins one).
CURSOR_MODEL="${LOOP_KIT_CURSOR_MODEL:-grok-4.5-high}"
CURSOR_MAKER_TIMEOUT="${LOOP_KIT_CURSOR_MAKER_TIMEOUT:-900}"

harness_maker_run() {
  local worktree="$1" prompt_file="$2" output_file="$3" complexity="$4" network_access="$5" model_override="${6:-}"
  local model="${model_override:-$CURSOR_MODEL}"
  echo "  cursor-agent maker${model:+ ($model)}" >&2
  # stream-json + stream-partial-output (rather than plain text, which buffers everything until
  # the process exits) so a timeout-killed long-running attempt still leaves a readable trail of
  # what it was doing, instead of an empty file. No OS-level sandbox equivalent to codex's
  # workspace-write here — relies on worktree isolation + the review step instead.
  local args=(-p --force --output-format stream-json --stream-partial-output --workspace "$worktree")
  [[ -n "$model" ]] && args+=(--model "$model")
  (cd "$worktree" && timeout "$CURSOR_MAKER_TIMEOUT" cursor-agent "${args[@]}" < "$prompt_file") > "$output_file" 2>&1
}

harness_reviewer_run() {
  local worktree="$1" prompt_file="$2" output_file="$3" base_branch="$4" model_override="${5:-}"
  local model="${model_override:-$CURSOR_MODEL}"
  echo "  cursor-agent review${model:+ ($model)}" >&2
  local args=(-p --force --output-format text --mode plan --workspace "$worktree")
  [[ -n "$model" ]] && args+=(--model "$model")
  (cd "$worktree" && cursor-agent "${args[@]}" < "$prompt_file") > "$output_file" 2>&1
}

harness_reviewer_mode_note() {
  echo "You are running in \`plan\` mode: you can read files, search, and run read-only commands (build, lint, test, \`git diff\`), but you cannot edit anything."
}

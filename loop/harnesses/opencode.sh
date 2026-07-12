#!/usr/bin/env bash
# Harness adapter for opencode (https://opencode.ai). See TEMPLATE.sh.example for the interface
# every adapter implements.
#
# Only harness_council_run is implemented below — that invocation (`opencode run --auto --agent
# plan -m ... < prompt`) is exactly what this kit's council.sh has run in production since before
# adapters existed, so it's proven. harness_maker_run/harness_reviewer_run are left as TODO
# stubs: opencode fronts several model families like cursor-agent does, which would make it a
# natural LOOP_KIT_HARNESSES member too, but write-mode/plan-mode flag behavior for that hasn't
# been exercised by this kit — fill in the TODOs and smoke-test before trusting it as a maker or
# checker (see loop/README.md's "opencode" bullet, and drop this comment once you have).
HARNESS_NAME="opencode"

# Model opencode-as-council-member uses, and how long council.sh waits for it.
# LOOP_KIT_COUNCIL_TIMEOUT is shared across every council member's adapter.
OPENCODE_COUNCIL_MODEL="${LOOP_KIT_OPENCODE_COUNCIL_MODEL:-nvidia/z-ai/glm-5.2}"
OPENCODE_COUNCIL_TIMEOUT="${LOOP_KIT_COUNCIL_TIMEOUT:-900}"

harness_maker_run() {
  local worktree="$1" prompt_file="$2" output_file="$3" complexity="$4" network_access="$5" model_override="${6:-}"
  echo "TODO: harness_maker_run not implemented for $HARNESS_NAME — see this file's header comment" > "$output_file"
  return 1
}

harness_reviewer_run() {
  local worktree="$1" prompt_file="$2" output_file="$3" base_branch="$4" model_override="${5:-}"
  echo "TODO: harness_reviewer_run not implemented for $HARNESS_NAME — see this file's header comment" > "$output_file"
  return 1
}

harness_reviewer_mode_note() {
  echo "TODO: harness_reviewer_run isn't implemented for $HARNESS_NAME yet, so this note is unused until it is."
}

harness_council_run() {
  local prompt_file="$1" output_file="$2" model_override="${3:-}"
  local model="${model_override:-$OPENCODE_COUNCIL_MODEL}"
  echo "  opencode council ($model)" >&2
  (cd "$ROOT" && timeout "$OPENCODE_COUNCIL_TIMEOUT" opencode run --auto --agent plan -m "$model" < "$prompt_file") > "$output_file" 2>&1
}

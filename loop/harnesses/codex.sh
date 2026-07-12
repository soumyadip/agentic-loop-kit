#!/usr/bin/env bash
# Harness adapter for OpenAI's Codex CLI (`codex exec`). See TEMPLATE.sh.example for the
# interface every adapter implements, and run.sh's reviewer_for() for how the ring of
# LOOP_KIT_HARNESSES decides who reviews whom.
HARNESS_NAME="codex"

# Model+effort per complexity tier, for codex-as-maker. Reasoning effort is a separate
# `-c model_reasoning_effort=` config override, not baked into the model slug.
CODEX_MAKER_MODEL_DEFAULT="${LOOP_KIT_CODEX_MAKER_MODEL_DEFAULT:-gpt-5.6-terra}"
CODEX_MAKER_EFFORT_DEFAULT="${LOOP_KIT_CODEX_MAKER_EFFORT_DEFAULT:-high}"
CODEX_MAKER_MODEL_QUICK="${LOOP_KIT_CODEX_MAKER_MODEL_QUICK:-gpt-5.6-luna}"
CODEX_MAKER_EFFORT_QUICK="${LOOP_KIT_CODEX_MAKER_EFFORT_QUICK:-high}"
CODEX_MAKER_MODEL_GNARLY="${LOOP_KIT_CODEX_MAKER_MODEL_GNARLY:-gpt-5.6-sol}"
CODEX_MAKER_EFFORT_GNARLY="${LOOP_KIT_CODEX_MAKER_EFFORT_GNARLY:-high}"

# Model codex-as-reviewer uses. Review strength doesn't scale with a task's declared complexity
# the way the maker tiers above do — one flat model for every review.
CODEX_CHECKER_MODEL="${LOOP_KIT_CODEX_CHECKER_MODEL:-$CODEX_MAKER_MODEL_DEFAULT}"

# Model codex-as-council-member uses, and how long council.sh waits for it. Empty model means no
# -m flag — let the codex CLI's own default decide, matching this adapter's original hardcoded
# council behavior. LOOP_KIT_COUNCIL_TIMEOUT is shared across every council member's adapter.
CODEX_COUNCIL_MODEL="${LOOP_KIT_CODEX_COUNCIL_MODEL:-}"
CODEX_COUNCIL_TIMEOUT="${LOOP_KIT_COUNCIL_TIMEOUT:-900}"

harness_maker_run() {
  local worktree="$1" prompt_file="$2" output_file="$3" complexity="$4" network_access="$5" model_override="${6:-}"
  local model effort="$CODEX_MAKER_EFFORT_DEFAULT"
  if [[ -n "$model_override" ]]; then
    # A pinned model (harness:model member spec) overrides complexity tiering entirely — the
    # member spec is an explicit choice, not something a task's complexity should second-guess.
    model="$model_override"
  else
    model="$CODEX_MAKER_MODEL_DEFAULT"
    case "$complexity" in
      quick)  model="$CODEX_MAKER_MODEL_QUICK";  effort="$CODEX_MAKER_EFFORT_QUICK" ;;
      gnarly) model="$CODEX_MAKER_MODEL_GNARLY"; effort="$CODEX_MAKER_EFFORT_GNARLY" ;;
    esac
  fi
  echo "  codex exec maker ($model, effort=$effort, complexity=$complexity)" >&2
  # --add-dir for $ROOT/.git: see this file's header comment on why a worktree needs it.
  local events_file="${output_file}.events.jsonl"
  local args=(exec -s workspace-write -C "$worktree" --add-dir "$ROOT/.git" --json -o "$output_file" \
    -m "$model" -c "model_reasoning_effort=\"$effort\"")
  [[ "$network_access" == "true" ]] && args+=(-c sandbox_workspace_write.network_access=true)
  codex "${args[@]}" - < "$prompt_file" > "$events_file" 2>&1
  local status=$?
  # -o only captures the last message on a clean finish; on a hard failure (e.g. a usage-limit
  # error) it's empty, so fall back to the raw event stream — that's where the actual error text
  # is — so both the retry prompt and run.sh's backoff text-scan have something to read.
  [[ -s "$output_file" ]] || cp "$events_file" "$output_file" 2>/dev/null
  return "$status"
}

harness_reviewer_run() {
  local worktree="$1" prompt_file="$2" output_file="$3" base_branch="$4" model_override="${5:-}"
  local model="${model_override:-$CODEX_CHECKER_MODEL}"
  echo "  codex exec review${model:+ ($model)}" >&2
  local events_file="${output_file}.events.jsonl"
  local args=(exec review --base "$base_branch" --json -o "$output_file")
  [[ -n "$model" ]] && args+=(-m "$model")
  (cd "$worktree" && codex "${args[@]}" - < "$prompt_file") > "$events_file" 2>&1
  local status=$?
  [[ -s "$output_file" ]] || cp "$events_file" "$output_file" 2>/dev/null
  return "$status"
}

harness_reviewer_mode_note() {
  echo "Treat this as a read-only review pass: you may run build/lint/test/\`git diff\` commands to verify claims, but do not edit any files or make any commits."
}

harness_council_run() {
  local prompt_file="$1" output_file="$2" model_override="${3:-}"
  local model="${model_override:-$CODEX_COUNCIL_MODEL}"
  echo "  codex exec council${model:+ ($model)}" >&2
  local args=(exec -s read-only -C "$ROOT")
  [[ -n "$model" ]] && args+=(-m "$model")
  timeout "$CODEX_COUNCIL_TIMEOUT" codex "${args[@]}" - < "$prompt_file" > "$output_file" 2>&1
}

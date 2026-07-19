#!/usr/bin/env bash
# Harness adapter for GitHub Copilot CLI (`copilot`). See TEMPLATE.sh.example for the interface
# every adapter implements.
#
# Copilot fronts several model families through one CLI/account (GPT, Claude, Gemini, …), which
# makes it a natural fit for filling more than one seat in LOOP_KIT_HARNESSES by itself — e.g.
# `copilot:gpt-5.4 copilot:claude-sonnet-4.6` — since a diff made under one model family is still
# meaningfully checked by a different one, even though both members share this one adapter.
# Same pattern works in LOOP_KIT_COUNCIL_HARNESSES and SkillOpt handoff
# (`LOOP_KIT_SKILLOPT_HANDOFF_HARNESS=copilot` or `copilot:<model>`).
#
# Auth: `copilot` login (GitHub Copilot subscription). No separate Anthropic/OpenAI API key.
# Model ids vary by plan — run `copilot /model` (interactive) or see `copilot --help` for the
# current `--model` choices on your account.
HARNESS_NAME="copilot"

# Flat default covers every complexity tier and both maker/checker roles when a member doesn't
# pin its own model. Override with LOOP_KIT_COPILOT_MODEL, or pin via harness:model.
COPILOT_MODEL="${LOOP_KIT_COPILOT_MODEL:-gpt-5.4}"
COPILOT_MAKER_TIMEOUT="${LOOP_KIT_COPILOT_MAKER_TIMEOUT:-900}"
# Optional reasoning effort when the member doesn't pin a model (and the chosen model supports
# it). Empty = omit --effort and let the CLI decide.
COPILOT_EFFORT="${LOOP_KIT_COPILOT_EFFORT:-}"
COPILOT_EFFORT_QUICK="${LOOP_KIT_COPILOT_EFFORT_QUICK:-$COPILOT_EFFORT}"
COPILOT_EFFORT_GNARLY="${LOOP_KIT_COPILOT_EFFORT_GNARLY:-high}"

COPILOT_COUNCIL_MODEL="${LOOP_KIT_COPILOT_COUNCIL_MODEL:-$COPILOT_MODEL}"
COPILOT_COUNCIL_TIMEOUT="${LOOP_KIT_COUNCIL_TIMEOUT:-900}"

# Copilot's -p/--prompt takes the prompt as an argument (not stdin). Read the file into a
# variable so long task/review prompts still work without ARG_MAX gymnastics for typical sizes.
_copilot_prompt_arg() {
  cat "$1"
}

harness_maker_run() {
  local worktree="$1" prompt_file="$2" output_file="$3" complexity="$4" network_access="$5" model_override="${6:-}"
  local model="${model_override:-$COPILOT_MODEL}"
  local effort="" prompt
  if [[ -z "$model_override" ]]; then
    case "$complexity" in
      quick)  effort="$COPILOT_EFFORT_QUICK" ;;
      gnarly) effort="$COPILOT_EFFORT_GNARLY" ;;
      *)      effort="$COPILOT_EFFORT" ;;
    esac
  fi
  prompt="$(_copilot_prompt_arg "$prompt_file")"
  echo "  copilot maker${model:+ ($model)}${effort:+ effort=$effort} complexity=$complexity" >&2
  # No OS-level sandbox equivalent to codex's workspace-write — relies on worktree isolation +
  # the review step. --allow-all-tools is required for non-interactive -p. --add-dir for the
  # main repo's .git so worktree metadata is reachable (same reason claude/codex do this).
  # network_access is a no-op: Copilot CLI has no sandbox network toggle.
  local args=(-p "$prompt" -C "$worktree" --silent --allow-all-tools --add-dir "$ROOT/.git")
  [[ -n "$model" ]] && args+=(--model "$model")
  [[ -n "$effort" ]] && args+=(--effort "$effort")
  (cd "$worktree" && timeout "$COPILOT_MAKER_TIMEOUT" copilot "${args[@]}") > "$output_file" 2>&1
}

harness_reviewer_run() {
  local worktree="$1" prompt_file="$2" output_file="$3" base_branch="$4" model_override="${5:-}"
  local model="${model_override:-$COPILOT_MODEL}" prompt
  prompt="$(_copilot_prompt_arg "$prompt_file")"
  echo "  copilot review${model:+ ($model)}" >&2
  # --plan / --mode plan: read-only agent mode. --allow-all-tools still required for -p
  # non-interactive; plan mode is what blocks edits. ($base_branch is unused — the rendered
  # review prompt tells the model to diff against the base itself.)
  local args=(-p "$prompt" -C "$worktree" --silent --plan --allow-all-tools)
  [[ -n "$model" ]] && args+=(--model "$model")
  (cd "$worktree" && copilot "${args[@]}") > "$output_file" 2>&1
}

harness_reviewer_mode_note() {
  echo "You are running in Copilot \`plan\` mode: you can read files, search, and run read-only commands (build, lint, test, \`git diff\`), but you cannot edit anything."
}

harness_council_run() {
  local prompt_file="$1" output_file="$2" model_override="${3:-}"
  local model="${model_override:-$COPILOT_COUNCIL_MODEL}" prompt
  prompt="$(_copilot_prompt_arg "$prompt_file")"
  echo "  copilot council${model:+ ($model)}" >&2
  local args=(-p "$prompt" -C "$ROOT" --silent --plan --allow-all-tools)
  [[ -n "$model" ]] && args+=(--model "$model")
  (cd "$ROOT" && timeout "$COPILOT_COUNCIL_TIMEOUT" copilot "${args[@]}") > "$output_file" 2>&1
}

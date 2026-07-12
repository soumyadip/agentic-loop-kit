#!/usr/bin/env bash
# Harness adapter for Claude Code (`claude -p`). See TEMPLATE.sh.example for the interface every
# adapter implements.
HARNESS_NAME="claude"

CLAUDE_MAKER_MODEL_DEFAULT="${LOOP_KIT_CLAUDE_MAKER_MODEL_DEFAULT:-sonnet}"
CLAUDE_MAKER_EFFORT_DEFAULT="${LOOP_KIT_CLAUDE_MAKER_EFFORT_DEFAULT:-high}"
CLAUDE_MAKER_MODEL_QUICK="${LOOP_KIT_CLAUDE_MAKER_MODEL_QUICK:-sonnet}"
CLAUDE_MAKER_EFFORT_QUICK="${LOOP_KIT_CLAUDE_MAKER_EFFORT_QUICK:-medium}"
CLAUDE_MAKER_MODEL_GNARLY="${LOOP_KIT_CLAUDE_MAKER_MODEL_GNARLY:-opus}"
CLAUDE_MAKER_EFFORT_GNARLY="${LOOP_KIT_CLAUDE_MAKER_EFFORT_GNARLY:-high}"

CLAUDE_CHECKER_MODEL="${LOOP_KIT_CLAUDE_CHECKER_MODEL:-$CLAUDE_MAKER_MODEL_DEFAULT}"

harness_maker_run() {
  local worktree="$1" prompt_file="$2" output_file="$3" complexity="$4" network_access="$5" model_override="${6:-}"
  local model effort="$CLAUDE_MAKER_EFFORT_DEFAULT"
  if [[ -n "$model_override" ]]; then
    # A pinned model (harness:model member spec) overrides complexity tiering entirely — the
    # member spec is an explicit choice, not something a task's complexity should second-guess.
    model="$model_override"
  else
    model="$CLAUDE_MAKER_MODEL_DEFAULT"
    case "$complexity" in
      quick)  model="$CLAUDE_MAKER_MODEL_QUICK";  effort="$CLAUDE_MAKER_EFFORT_QUICK" ;;
      gnarly) model="$CLAUDE_MAKER_MODEL_GNARLY"; effort="$CLAUDE_MAKER_EFFORT_GNARLY" ;;
    esac
  fi
  echo "  claude maker ($model, effort=$effort, complexity=$complexity)" >&2
  # No OS-level sandbox equivalent to codex's -s workspace-write — relies on worktree isolation
  # + the review step instead. network_access is a no-op here: claude -p has no sandbox network
  # toggle to opt in/out of.
  (cd "$worktree" && claude -p --model "$model" --effort "$effort" --dangerously-skip-permissions --add-dir "$ROOT/.git" < "$prompt_file") > "$output_file" 2>&1
}

harness_reviewer_run() {
  local worktree="$1" prompt_file="$2" output_file="$3" base_branch="$4" model_override="${5:-}"
  local model="${model_override:-$CLAUDE_CHECKER_MODEL}"
  echo "  claude review ($model)" >&2
  (cd "$worktree" && claude -p --model "$model" --permission-mode plan < "$prompt_file") > "$output_file" 2>&1
}

harness_reviewer_mode_note() {
  echo "You are running in \`plan\` permission mode: you can read files, search, and run read-only commands (build, lint, test, \`git diff\`), but you cannot edit anything."
}

#!/usr/bin/env bash
# Harness adapter for opencode (https://opencode.ai). See TEMPLATE.sh.example for the interface
# every adapter implements.
#
# opencode fronts several model families through one CLI (provider/model slugs, e.g.
# `nvidia/z-ai/glm-5.2`), which makes it a natural fit for filling more than one seat in
# LOOP_KIT_HARNESSES by itself — e.g. `opencode:nvidia/z-ai/glm-5.2 opencode:opencode/big-pickle`
# — since a diff made under one model is still meaningfully checked by a different one.
# Also used by council.sh and SkillOpt handoff (`--handoff-harness opencode` or
# `opencode:<provider/model>`).
#
# Agents used here (see `opencode agent list`):
#   build — write-capable primary agent for maker attempts
#   plan  — read-only / plan agent for reviewer + council
HARNESS_NAME="opencode"

# Default model for bare `opencode` members (maker + checker). Pin with harness:model to
# override. Format is provider/model as accepted by `opencode run -m`.
OPENCODE_MODEL="${LOOP_KIT_OPENCODE_MODEL:-nvidia/z-ai/glm-5.2}"
OPENCODE_MAKER_TIMEOUT="${LOOP_KIT_OPENCODE_MAKER_TIMEOUT:-900}"
# Optional --variant (provider-specific reasoning effort: high, max, minimal, …). Empty = omit.
OPENCODE_VARIANT="${LOOP_KIT_OPENCODE_VARIANT:-}"
OPENCODE_VARIANT_QUICK="${LOOP_KIT_OPENCODE_VARIANT_QUICK:-$OPENCODE_VARIANT}"
OPENCODE_VARIANT_GNARLY="${LOOP_KIT_OPENCODE_VARIANT_GNARLY:-high}"

# Council defaults to the same model as maker/checker unless overridden.
OPENCODE_COUNCIL_MODEL="${LOOP_KIT_OPENCODE_COUNCIL_MODEL:-$OPENCODE_MODEL}"
OPENCODE_COUNCIL_TIMEOUT="${LOOP_KIT_COUNCIL_TIMEOUT:-900}"

harness_maker_run() {
  local worktree="$1" prompt_file="$2" output_file="$3" complexity="$4" network_access="$5" model_override="${6:-}"
  local model="${model_override:-$OPENCODE_MODEL}"
  local variant=""
  if [[ -z "$model_override" ]]; then
    case "$complexity" in
      quick)  variant="$OPENCODE_VARIANT_QUICK" ;;
      gnarly) variant="$OPENCODE_VARIANT_GNARLY" ;;
      *)      variant="$OPENCODE_VARIANT" ;;
    esac
  fi
  echo "  opencode maker ($model)${variant:+ variant=$variant} complexity=$complexity" >&2
  # --auto: auto-approve permissions not explicitly denied (required for unattended maker).
  # --agent build: write-capable primary. --dir: run inside the worktree.
  # network_access is a no-op: opencode has no sandbox network toggle analogous to codex.
  local args=(run --auto --agent build --dir "$worktree" -m "$model")
  [[ -n "$variant" ]] && args+=(--variant "$variant")
  (cd "$worktree" && timeout "$OPENCODE_MAKER_TIMEOUT" opencode "${args[@]}" < "$prompt_file") > "$output_file" 2>&1
}

harness_reviewer_run() {
  local worktree="$1" prompt_file="$2" output_file="$3" base_branch="$4" model_override="${5:-}"
  local model="${model_override:-$OPENCODE_MODEL}"
  echo "  opencode review ($model)" >&2
  # --agent plan: read-only / plan mode (same as council). ($base_branch unused — the rendered
  # review prompt tells the model to diff against the base itself.)
  local args=(run --auto --agent plan --dir "$worktree" -m "$model")
  (cd "$worktree" && opencode "${args[@]}" < "$prompt_file") > "$output_file" 2>&1
}

harness_reviewer_mode_note() {
  echo "You are running as opencode's \`plan\` agent: you can read files, search, and run read-only commands (build, lint, test, \`git diff\`), but you cannot edit anything."
}

harness_council_run() {
  local prompt_file="$1" output_file="$2" model_override="${3:-}"
  local model="${model_override:-$OPENCODE_COUNCIL_MODEL}"
  echo "  opencode council ($model)" >&2
  (cd "$ROOT" && timeout "$OPENCODE_COUNCIL_TIMEOUT" opencode run --auto --agent plan -m "$model" < "$prompt_file") > "$output_file" 2>&1
}

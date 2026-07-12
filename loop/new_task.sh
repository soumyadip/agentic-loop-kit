#!/usr/bin/env bash
# Scaffold a new loop/queue/pending/Txxx-<slug>.md file with correct frontmatter, so
# neither a human nor an agent has to re-derive the next task id, the milestone-id
# convention, or the sensitive-path rule by reading run.sh/README.md every time.
#
# Usage:
#   loop/new_task.sh <slug> <milestone> [sensitive] [depends_on,comma,separated]
#
# Example:
#   loop/new_task.sh add-health-endpoint M1 false T003
#
# This only writes the frontmatter + section skeleton (Why/Scope/Acceptance criteria) —
# you still write the actual task content.  It does not touch
# loop/queue/{in_progress,blocked,done}/ or move anything.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
[[ -f "$ROOT/loop/loop.config.sh" ]] && source "$ROOT/loop/loop.config.sh"
QUEUE="$ROOT/loop/queue"

# Path to a roadmap/milestone doc, relative to $ROOT. If set (the default) and the file
# exists, a task's `milestone:` field must match a `## <milestone-id> — ...` heading in it.
# Set LOOP_KIT_ROADMAP_DOC="" in loop.config.sh to disable this check entirely — some
# projects don't track milestones as a doc, and `milestone:` frontmatter then becomes
# free text.
ROADMAP_DOC="${LOOP_KIT_ROADMAP_DOC-docs/roadmap.md}"

die() { echo "[new_task] $*" >&2; exit 1; }

slug="${1:-}"
milestone="${2:-}"
sensitive="${3:-false}"
depends_on="${4:-}"

[[ -z "$slug" || -z "$milestone" ]] && die "usage: loop/new_task.sh <slug> <milestone> [sensitive] [depends_on,comma,separated]"
[[ "$slug" =~ ^[a-z0-9-]+$ ]] || die "slug must be lowercase-kebab-case: $slug"
[[ "$sensitive" == "true" || "$sensitive" == "false" ]] || die "sensitive must be 'true' or 'false', got: $sensitive"

if [[ -n "$ROADMAP_DOC" && -f "$ROOT/$ROADMAP_DOC" ]]; then
  grep -qE "^## ${milestone} — " "$ROOT/$ROADMAP_DOC" \
    || die "milestone '$milestone' not found as '## $milestone — ...' in $ROADMAP_DOC — check the exact id, or unset LOOP_KIT_ROADMAP_DOC in loop.config.sh if this project doesn't track milestones there"
fi

next_num=1
for f in "$QUEUE"/pending/T*.md "$QUEUE"/in_progress/T*.md "$QUEUE"/blocked/T*.md "$QUEUE"/done/T*.md; do
  [[ -f "$f" ]] || continue
  n=$(basename "$f" | grep -oE '^T[0-9]+' | tr -d 'T')
  [[ -n "$n" ]] && (( 10#$n >= next_num )) && next_num=$((10#$n + 1))
done
task_id=$(printf "T%03d" "$next_num")

depends_fmt="[]"
if [[ -n "$depends_on" ]]; then
  depends_fmt="[$(echo "$depends_on" | sed 's/,/, /g')]"
fi

out="$QUEUE/pending/${task_id}-${slug}.md"
[[ -e "$out" ]] && die "already exists: $out"

cat > "$out" <<EOF
---
id: ${task_id}
milestone: ${milestone}
sensitive: ${sensitive}
depends_on: ${depends_fmt}
---

# TODO: title

## Why

TODO: what roadmap/spec/backlog need this serves, and why now — cite the
specific doc/deliverable bullet, not a generic justification. See other
files in loop/queue/done/ for the level of specificity expected here.

## Scope

TODO: exactly what to touch, and — just as important — what NOT to touch.
Keep this atomic (one PR-sized unit, per loop/README.md's "Adding tasks"
section), not "build the whole feature."

## Acceptance criteria

- [ ] TODO: concrete, checkable outcomes — "the build and test commands
      pass" is not sufficient on its own; say what a reviewer should be
      able to see/run to confirm this actually works.
EOF

echo "[new_task] wrote $out (${task_id}, milestone ${milestone}, sensitive=${sensitive})"
echo "[new_task] fill in the TODOs before moving this out of pending/ — a fresh-context agent gets exactly this file as its whole scope"

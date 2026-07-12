#!/usr/bin/env bash
# Reviews a GitHub pull request using this loop's own harness adapters and review machinery —
# the read-only counterpart to run.sh's queue-driven checker step, for a PR that never came out
# of loop/queue/ at all. Deliberately reuses harness_reviewer_run and review_mandate.partial.md
# unchanged: a PR review really is "review a diff in a worktree against a base branch, read-
# only," the exact same shape run.sh's checker step already has — no new adapter functions
# needed, just a different caller and a PR-flavored prompt template (pr_review_prompt.tpl.md).
#
# Usage:
#   loop/review_pr.sh <pr-number> [--reviewer <member>] [--post-comment]
#
# --reviewer defaults to the first entry in LOOP_KIT_HARNESSES; pass any configured member spec
# (a bare harness name or harness:model, see run.sh's HARNESSES comment) to pick a specific one,
# or --reviewer isn't restricted to LOOP_KIT_HARNESSES's own list — any name with a matching
# loop/harnesses/<name>.sh adapter works, so a reviewer-only harness that isn't part of the
# maker/checker rotation is fine too. Run this again with a different --reviewer for a second,
# independent opinion on the same PR.
#
# --post-comment posts the rendered review as a PR comment via `gh pr comment` (default: print
# locally only, nothing touches GitHub unless you pass this).
#
# Requires: `gh` CLI installed and authenticated against this repo's GitHub remote.
#
# Known limitation: this checks the PR's branch out into its own worktree via `gh pr checkout`,
# which fails if that same branch is already checked out elsewhere (e.g. you have it open in
# your main working tree too) — git doesn't allow one branch checked out in two places at once.
# Switch away from it there first if that happens.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
log()  { echo "[review_pr] $*"; }
die()  { echo "[review_pr] STOP: $*" >&2; exit 1; }

[[ -f "$ROOT/loop/loop.config.sh" ]] && source "$ROOT/loop/loop.config.sh"
[[ -f "$ROOT/loop/review_mandate.partial.md" ]] || die "missing loop/review_mandate.partial.md"
source "$ROOT/loop/render.sh"

read -ra HARNESSES <<< "${LOOP_KIT_HARNESSES:-codex claude cursor}"
member_harness() { echo "${1%%:*}"; }
member_model() { [[ "$1" == *:* ]] && echo "${1#*:}" || echo ""; }

BREAK_ATTEMPTS="${LOOP_REVIEW_BREAK_ATTEMPTS:-1}"
(( BREAK_ATTEMPTS < 1 )) && BREAK_ATTEMPTS=1
(( BREAK_ATTEMPTS > 3 )) && BREAK_ATTEMPTS=3

command -v gh > /dev/null 2>&1 || die "gh CLI not found on PATH — install and authenticate it first (https://cli.github.com)"

usage() {
  cat <<EOF
Usage: loop/review_pr.sh <pr-number> [options]

Options:
  --reviewer MEMBER   which harness/member reviews (default: first entry in LOOP_KIT_HARNESSES,
                       currently '${HARNESSES[0]:-none}')
  --post-comment       post the rendered review as a PR comment via 'gh pr comment'
  -h, --help           show this help
EOF
}

[[ $# -ge 1 ]] || { usage; exit 1; }
pr_number="$1"; shift
[[ "$pr_number" == "-h" || "$pr_number" == "--help" ]] && { usage; exit 0; }
[[ "$pr_number" =~ ^[0-9]+$ ]] || die "expected a PR number, got: '$pr_number'"

reviewer="${HARNESSES[0]:-}"
post_comment=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --reviewer) reviewer="$2"; shift 2 ;;
    --post-comment) post_comment=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown option: $1 (see --help)" ;;
  esac
done
[[ -n "$reviewer" ]] || die "no --reviewer given and LOOP_KIT_HARNESSES is empty — pass --reviewer explicitly"

reviewer_harness="$(member_harness "$reviewer")"
reviewer_model="$(member_model "$reviewer")"
adapter="$ROOT/loop/harnesses/$reviewer_harness.sh"
[[ -f "$adapter" ]] || die "no adapter at loop/harnesses/$reviewer_harness.sh for --reviewer '$reviewer'"
source "$adapter"

log "fetching PR #$pr_number metadata..."
pr_json=$(cd "$ROOT" && gh pr view "$pr_number" --json number,title,body,baseRefName,url,state 2>&1) \
  || die "gh pr view $pr_number failed (is gh authenticated? does the PR exist in this repo's remote?): $pr_json"

pr_title="" pr_body="" pr_base="" pr_url="" pr_state=""
while IFS= read -r -d '' field; do
  case "$field" in
    title=*)        pr_title="${field#title=}" ;;
    body=*)         pr_body="${field#body=}" ;;
    baseRefName=*)  pr_base="${field#baseRefName=}" ;;
    url=*)          pr_url="${field#url=}" ;;
    state=*)        pr_state="${field#state=}" ;;
  esac
done < <(python3 -c '
import json, sys
d = json.load(sys.stdin)
for k in ("title", "body", "baseRefName", "url", "state"):
    sys.stdout.write(k + "=" + (d.get(k) or "") + "\0")
' <<<"$pr_json")

[[ -n "$pr_base" ]] || die "could not parse PR metadata from gh pr view output"
log "PR #$pr_number: \"$pr_title\" ($pr_state, base=$pr_base) — reviewing with $reviewer"

worktree="$ROOT/.loop-worktrees/pr-$pr_number"
git -C "$ROOT" worktree remove --force "$worktree" > /dev/null 2>&1
rm -rf "$worktree"
git -C "$ROOT" worktree prune
git -C "$ROOT" fetch origin "$pr_base" > /dev/null 2>&1 || true
git -C "$ROOT" worktree add -q --detach "$worktree" "origin/$pr_base" \
  || git -C "$ROOT" worktree add -q --detach "$worktree" "$pr_base" \
  || die "could not create a worktree for PR #$pr_number at $worktree"
(cd "$worktree" && gh pr checkout "$pr_number") \
  || die "gh pr checkout $pr_number failed inside the worktree — see the 'known limitation' note in this script's header"

task_log="$ROOT/loop/log/pr-$pr_number-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$task_log"

pr_body_file="$task_log/pr-description.md"
{
  echo "**#$pr_number: $pr_title**"
  echo "$pr_url"
  echo
  echo "$pr_body"
} > "$pr_body_file"

reviewer_mode_note=$(harness_reviewer_mode_note)
review_prompt="$task_log/review-prompt.md"
render "$ROOT/loop/pr_review_prompt.tpl.md" "pr-$pr_number" "$pr_body_file" "$pr_base" "" "$reviewer" "$BREAK_ATTEMPTS" "$reviewer_mode_note" > "$review_prompt"

review_out="$task_log/review-${reviewer//:/-}.log"
log "running review (this can take a while)..."
harness_reviewer_run "$worktree" "$review_prompt" "$review_out" "$pr_base" "$reviewer_model"

verdict=$(grep -oE 'VERDICT: *(approve|request_changes|block_human)' "$review_out" | tail -1 | awk '{print $2}')
log "verdict: ${verdict:-none parsed — read $review_out directly}"
log "full review: $review_out"
echo
cat "$review_out"

if (( post_comment )); then
  if (cd "$ROOT" && gh pr comment "$pr_number" --body-file "$review_out"); then
    log "posted as a comment on PR #$pr_number"
  else
    log "failed to post comment — the review itself is still saved at $review_out"
  fi
fi

case "$verdict" in
  approve) exit 0 ;;
  *)       exit 1 ;;
esac

#!/usr/bin/env bash
# Automated gate run after every maker attempt, before a diff is eligible for review. An empty
# gate makes every task's "acceptance criteria met" claim unverifiable, so don't let the build/test
# commands below stay at their generic defaults long — set LOOP_KIT_BUILD_CMD/LOOP_KIT_TEST_CMD in
# loop.config.sh (install.sh prompts for these) to your project's real build/lint/typecheck/test
# commands as soon as there's real code to check.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
[[ -f "$ROOT/loop/loop.config.sh" ]] && source "$ROOT/loop/loop.config.sh"

BUILD_CMD="${LOOP_KIT_BUILD_CMD:-true}"
TEST_CMD="${LOOP_KIT_TEST_CMD:-true}"

fail() { echo "verify: FAIL - $1" >&2; exit 1; }

# No merge conflict markers left behind. Anchored to the exact marker shape (a
# bare "=======" line, or "<<<<<<< "/">>>>>>> " followed by a ref name) rather than
# "starts with 7+ of the same character". Scoped to git-tracked files (`git grep`
# over HEAD's tree, not a filesystem walk): loop/log/ transcripts can legitimately
# contain long "====...===="-style separator lines as formatting, not unresolved
# conflicts, and gitignored build output can transiently contain the same shape
# for unrelated reasons — neither is something a human ever reviews for merge
# hygiene, so scanning the tracked tree instead of the whole filesystem avoids
# both false positives.
if git -C "$ROOT" grep -Il -E '^(<<<<<<< |=======$|>>>>>>> )' -- . ':!loop/log' > /dev/null 2>&1; then
  fail "merge conflict markers found in tree"
fi

# Every git-tracked YAML file at least parses, if python3+yaml is available.
if command -v python3 > /dev/null 2>&1 && python3 -c "import yaml" > /dev/null 2>&1; then
  while IFS= read -r -d '' f; do
    [[ -f "$ROOT/$f" ]] || continue
    python3 -c "import yaml,sys; yaml.safe_load(open(sys.argv[1]))" "$ROOT/$f" || fail "invalid YAML: $f"
  done < <(git -C "$ROOT" ls-files -z -- '*.yaml' '*.yml')
fi

# Shell scripts in loop/ must at least parse.
for f in "$ROOT"/loop/*.sh; do
  bash -n "$f" || fail "shell syntax error: $f"
done

(cd "$ROOT" && eval "$BUILD_CMD") || fail "build command failed: $BUILD_CMD"
(cd "$ROOT" && eval "$TEST_CMD") || fail "test command failed: $TEST_CMD"

echo "verify: OK"

#!/usr/bin/env bash
# Scaffold a new loop/harnesses/<name>.sh adapter from TEMPLATE.sh.example, so adding a harness
# this kit doesn't ship a built-in adapter for (aider, gemini-cli, a custom script, ...) starts
# from a filled-in skeleton with the right function names instead of a blank file.
#
# Usage: loop/new_harness.sh <name>
#
# After filling in the TODOs, add <name> to LOOP_KIT_HARNESSES in loop/loop.config.sh (space-
# separated, order sets the review cycle — see run.sh's reviewer_for()). Needs at least 2
# harnesses total; a single harness can never review its own work.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
die() { echo "[new_harness] $*" >&2; exit 1; }

name="${1:-}"
[[ -z "$name" ]] && die "usage: loop/new_harness.sh <name>"
[[ "$name" =~ ^[a-z0-9_-]+$ ]] || die "name must be lowercase, digits, - or _: $name"

out="$ROOT/loop/harnesses/$name.sh"
[[ -e "$out" ]] && die "already exists: $out"
tpl="$ROOT/loop/harnesses/TEMPLATE.sh.example"
[[ -f "$tpl" ]] || die "template not found: $tpl"

sed "s/HARNESS_NAME=\"TODO\"/HARNESS_NAME=\"$name\"/" "$tpl" > "$out"
chmod +x "$out"

echo "[new_harness] wrote $out"
echo "[new_harness] fill in the TODOs (harness_maker_run, harness_reviewer_run, harness_reviewer_mode_note)"
echo "[new_harness] then add '$name' to LOOP_KIT_HARNESSES in loop/loop.config.sh"

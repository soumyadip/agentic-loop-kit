#!/usr/bin/env bash
# Copies this kit's loop/ directory and its two Claude Code skills into a target repo, then
# fills in the handful of things that are genuinely per-project (build/test commands, which
# paths are governance-sensitive, where the working-principles and roadmap docs live, and which
# harnesses/models are in the maker/checker rotation). Safe to re-run: it will not overwrite a
# target repo's existing loop/loop.config.sh unless you pass --force, so a re-run to pick up a
# kit update won't clobber settings you've already tuned.
set -uo pipefail

KIT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILTIN_HARNESSES="codex claude cursor"

die() { echo "[install] $*" >&2; exit 1; }
log() { echo "[install] $*"; }

is_builtin_harness() {
  local h="$1" b
  for b in $BUILTIN_HARNESSES; do [[ "$b" == "$h" ]] && return 0; done
  return 1
}

# --harnesses entries can be a bare harness name ("cursor") or "harness:model" ("cursor:grok-
# 4.5-high"), pinning a specific model — see run.sh's HARNESSES comment. These two helpers mirror
# run.sh's member_harness/member_model exactly, so install.sh and run.sh agree on the syntax.
member_harness() { echo "${1%%:*}"; }
member_model() { [[ "$1" == *:* ]] && echo "${1#*:}" || echo ""; }

usage() {
  cat <<EOF
Usage: install.sh <target-repo-path> [options]

Options (all optional; omitted ones are prompted for interactively when stdin is a
terminal, or fall back to the default shown when it isn't):
  --build-cmd "CMD"          command verify.sh runs to build          (default: make build)
  --test-cmd "CMD"           command verify.sh runs to test           (default: make test)
  --sensitive-pattern REGEX  extended-regex of always-blocked paths   (default: ^(deploy/|secrets|\.github/workflows/))
  --sensitive-desc "TEXT"    human description of the above, used in prompt text
                              (default: "deploy configs, secrets, CI workflows")
  --principles-doc PATH      working-principles doc the templates point at (default: AGENTS.md)
  --roadmap-doc PATH         milestone doc new_task.sh validates against; pass "" to disable
                              milestone validation entirely                (default: docs/roadmap.md)
  --harnesses "a b:m c"      space-separated maker/checker rotation, order = review cycle, need
                              >=2 entries (not necessarily >=2 distinct harnesses — an entry can
                              be "harness:model" to pin one model on a multi-model harness like
                              cursor or opencode, so e.g. "cursor:grok-4.5-high
                              cursor:claude-4.5-sonnet" is a valid 2-entry rotation using only
                              one CLI)                               (default: $BUILTIN_HARNESSES)
  --codex-model NAME         default model for bare "codex" entries  (default: gpt-5.6-terra)
  --claude-model NAME        default model for bare "claude" entries (default: sonnet)
  --cursor-model NAME        default model for bare "cursor" entries (default: grok-4.5-high)
  --non-interactive          never prompt; use flags/defaults only
  --force                    overwrite an existing loop/loop.config.sh in the target
EOF
}

[[ $# -ge 1 ]] || { usage; exit 1; }
target="$1"; shift
[[ "$target" == "-h" || "$target" == "--help" ]] && { usage; exit 0; }

build_cmd="make build"
test_cmd="make test"
sensitive_pattern='^(deploy/|secrets|\.github/workflows/)'
sensitive_desc="deploy configs, secrets, CI workflows"
principles_doc="AGENTS.md"
roadmap_doc="docs/roadmap.md"
harnesses="$BUILTIN_HARNESSES"
codex_model="gpt-5.6-terra"
claude_model="sonnet"
cursor_model="grok-4.5-high"
non_interactive=0
force=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --build-cmd) build_cmd="$2"; shift 2 ;;
    --test-cmd) test_cmd="$2"; shift 2 ;;
    --sensitive-pattern) sensitive_pattern="$2"; shift 2 ;;
    --sensitive-desc) sensitive_desc="$2"; shift 2 ;;
    --principles-doc) principles_doc="$2"; shift 2 ;;
    --roadmap-doc) roadmap_doc="$2"; shift 2 ;;
    --harnesses) harnesses="$2"; shift 2 ;;
    --codex-model) codex_model="$2"; shift 2 ;;
    --claude-model) claude_model="$2"; shift 2 ;;
    --cursor-model) cursor_model="$2"; shift 2 ;;
    --non-interactive) non_interactive=1; shift ;;
    --force) force=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown option: $1 (see --help)" ;;
  esac
done

[[ -d "$target" ]] || die "target directory does not exist: $target"
target="$(cd "$target" && pwd)"
[[ -d "$target/.git" ]] || die "target is not a git repo (no .git): $target — run 'git init' there first"

if [[ "$non_interactive" != 1 && -t 0 ]]; then
  read -rp "Build command [$build_cmd]: " ans; build_cmd="${ans:-$build_cmd}"
  read -rp "Test command [$test_cmd]: " ans; test_cmd="${ans:-$test_cmd}"
  read -rp "Sensitive-path regex [$sensitive_pattern]: " ans; sensitive_pattern="${ans:-$sensitive_pattern}"
  read -rp "Sensitive-path description [$sensitive_desc]: " ans; sensitive_desc="${ans:-$sensitive_desc}"
  read -rp "Working-principles doc [$principles_doc]: " ans; principles_doc="${ans:-$principles_doc}"
  read -rp "Roadmap/milestone doc, or 'none' to disable milestone gating [$roadmap_doc]: " ans
  if [[ -n "$ans" ]]; then
    [[ "$ans" == "none" ]] && roadmap_doc="" || roadmap_doc="$ans"
  fi
  read -rp "Harnesses/models for the maker/checker rotation (space-separated 'harness' or 'harness:model' entries, order = review cycle, need >=2) [$harnesses]: " ans
  harnesses="${ans:-$harnesses}"
  # Only prompt once per bare (no ':model') harness name — an entry that already pins its own
  # model doesn't need (or use) this project-wide default.
  prompted=""
  for h in $harnesses; do
    [[ "$h" == *:* ]] && continue
    case " $prompted " in *" $h "*) continue ;; esac
    prompted="$prompted $h"
    case "$h" in
      codex)  read -rp "  Default model for bare 'codex' entries [$codex_model]: " ans; codex_model="${ans:-$codex_model}" ;;
      claude) read -rp "  Default model for bare 'claude' entries [$claude_model]: " ans; claude_model="${ans:-$claude_model}" ;;
      cursor) read -rp "  Default model for bare 'cursor' entries [$cursor_model]: " ans; cursor_model="${ans:-$cursor_model}" ;;
      *) log "  '$h' has no built-in adapter — you'll need to run 'loop/new_harness.sh $h' in the target repo after install." ;;
    esac
  done
fi

harness_count=0
for h in $harnesses; do harness_count=$((harness_count+1)); done
(( harness_count >= 2 )) || die "--harnesses needs at least 2 entries (got: '$harnesses') — a single entry can never review its own work. Use harness:model entries (e.g. 'cursor:grok-4.5-high cursor:claude-4.5-sonnet') if you only want one harness/CLI installed."

# Reject exact-duplicate entries here too, same rule run.sh enforces at runtime — catch it at
# install time instead of leaving a config that dies the first time loop/run.sh actually starts.
harnesses_arr=($harnesses)
for (( i = 0; i < ${#harnesses_arr[@]}; i++ )); do
  for (( j = i + 1; j < ${#harnesses_arr[@]}; j++ )); do
    [[ "${harnesses_arr[$i]}" == "${harnesses_arr[$j]}" ]] && die "--harnesses lists '${harnesses_arr[$i]}' twice — duplicate entries can't review each other. Pin a different model on one of them (harness:model) if you meant two distinct seats."
  done
done

if [[ -f "$target/loop/loop.config.sh" && "$force" != 1 ]]; then
  die "$target/loop/loop.config.sh already exists — re-run with --force to overwrite it, or edit it by hand"
fi

log "installing into $target"

mkdir -p "$target/loop/queue/pending" "$target/loop/queue/in_progress" \
         "$target/loop/queue/blocked" "$target/loop/queue/done" \
         "$target/loop/log" "$target/loop/state" "$target/loop/harnesses" \
         "$target/.claude/skills/council" "$target/.claude/skills/new-task"

cp "$KIT_ROOT"/loop/*.sh "$target/loop/"
cp "$KIT_ROOT"/loop/*.tpl.md "$target/loop/"
cp "$KIT_ROOT"/loop/review_mandate.partial.md "$target/loop/review_mandate.partial.md"
cp "$KIT_ROOT"/loop/README.md "$target/loop/README.md"
cp "$KIT_ROOT"/loop/loop.config.sh.example "$target/loop/loop.config.sh.example"
cp "$KIT_ROOT"/loop/harnesses/*.sh "$target/loop/harnesses/" 2>/dev/null || true
cp "$KIT_ROOT"/loop/harnesses/TEMPLATE.sh.example "$target/loop/harnesses/TEMPLATE.sh.example"
cp "$KIT_ROOT"/skills/council/SKILL.md "$target/.claude/skills/council/SKILL.md"
cp "$KIT_ROOT"/skills/new-task/SKILL.md "$target/.claude/skills/new-task/SKILL.md"
chmod +x "$target"/loop/*.sh "$target"/loop/harnesses/*.sh

# Warn (don't fail) about any selected member whose underlying harness isn't built in and hasn't
# been scaffolded — the install still completes, but that member won't actually work until an
# adapter exists.
missing_adapters=()
for h in $harnesses; do
  [[ -f "$target/loop/harnesses/$(member_harness "$h").sh" ]] || missing_adapters+=("$h")
done

{
  echo "# Generated by agentic-loop-kit install.sh on $(date +%Y-%m-%d). Edit freely — see"
  echo "# loop.config.sh.example for what each variable does. Re-running install.sh will not"
  echo "# overwrite this file unless you pass --force."
  echo "LOOP_KIT_BUILD_CMD=\"${build_cmd}\""
  echo "LOOP_KIT_TEST_CMD=\"${test_cmd}\""
  echo "LOOP_KIT_SENSITIVE_PATTERN='${sensitive_pattern}'"
  echo "LOOP_KIT_PRINCIPLES_DOC=\"${principles_doc}\""
  echo "LOOP_KIT_ROADMAP_DOC=\"${roadmap_doc}\""
  echo "LOOP_KIT_HARNESSES=\"${harnesses}\""
  # Only write a harness's project-wide default model config if some entry actually needs it
  # (a bare entry with no ':model' of its own) — an all-pinned harness (every entry is
  # "harness:model") doesn't read these vars at all.
  written=""
  for h in $harnesses; do
    [[ "$h" == *:* ]] && continue
    hn="$(member_harness "$h")"
    case " $written " in *" $hn "*) continue ;; esac
    written="$written $hn"
    case "$hn" in
      codex)
        echo "LOOP_KIT_CODEX_MAKER_MODEL_DEFAULT=\"${codex_model}\""
        echo "LOOP_KIT_CODEX_CHECKER_MODEL=\"${codex_model}\""
        ;;
      claude)
        echo "LOOP_KIT_CLAUDE_MAKER_MODEL_DEFAULT=\"${claude_model}\""
        echo "LOOP_KIT_CLAUDE_CHECKER_MODEL=\"${claude_model}\""
        ;;
      cursor)
        echo "LOOP_KIT_CURSOR_MODEL=\"${cursor_model}\""
        ;;
    esac
  done
} > "$target/loop/loop.config.sh"

# One-shot install-time substitution of the prompt templates' {{PLACEHOLDER}} tokens. These are
# distinct from the {{TASK_ID}}/{{BRANCH}}/{{TASK_BODY}}/etc. tokens run.sh renders per task —
# this pass only touches the handful of tokens that are fixed for the life of the install.
python3 - "$target" "$sensitive_desc" "$principles_doc" "$roadmap_doc" <<'PY'
import glob
import sys

target, sensitive_desc, principles_doc, roadmap_doc = sys.argv[1:5]
repls = {
    "{{SENSITIVE_DESC}}": sensitive_desc,
    "{{PRINCIPLES_DOC}}": principles_doc,
    "{{ROADMAP_DOC}}": roadmap_doc or "(none configured)",
}
files = glob.glob(f"{target}/loop/*.tpl.md")
files += glob.glob(f"{target}/.claude/skills/**/SKILL.md", recursive=True)
for f in files:
    with open(f) as fh:
        s = fh.read()
    for k, v in repls.items():
        s = s.replace(k, v)
    with open(f, "w") as fh:
        fh.write(s)
PY

log "done. Next steps:"
log "  1. Review $target/loop/loop.config.sh"
if (( ${#missing_adapters[@]} > 0 )); then
  log "  2. LOOP_KIT_HARNESSES includes ${missing_adapters[*]}, which has no adapter yet — run"
  log "     'loop/new_harness.sh <name>' in the target repo for each and fill in the TODOs"
  log "     before the loop can actually use it (see loop/harnesses/TEMPLATE.sh.example)."
fi
log "  3. Sharpen the adversarial red-team mandate in loop/review_prompt.tpl.md (search for the"
log "     TODO comment) once you've seen a few real bugs slip through — that's where this kit's"
log "     value compounds over time."
log "  4. Make sure $target has a $principles_doc with working principles (TDD, architecture"
log "     constraints, etc.) — the templates reference it."
if [[ -n "$roadmap_doc" ]]; then
  log "  5. Make sure $target/$roadmap_doc exists with '## <milestone-id> — ...' headings;"
  log "     new_task.sh validates against it."
else
  log "  5. Milestone gating disabled — new_task.sh will skip the roadmap check."
fi
log "  6. Install prerequisite CLIs for your chosen harnesses ($harnesses), and optionally"
log "     opencode (for council.sh)."
log "  7. Seed loop/queue/pending/ (loop/new_task.sh <slug> <milestone>), then:"
log "       cd $target && LOOP_MAX_ITERATIONS=1 loop/run.sh   # first supervised run"

#!/usr/bin/env bash
# Copies this kit's loop/ directory and Claude Code skills into a target repo, then
# fills in the handful of things that are genuinely per-project (build/test commands, which
# paths are governance-sensitive, where the working-principles and roadmap docs live, and which
# harnesses/models are in the maker/checker rotation).
#
# Modes:
#   (default) fresh install — refuses if loop/loop.config.sh already exists
#   --force   fresh install that overwrites loop/loop.config.sh too
#   --update / --upgrade — refresh kit-managed files; keep loop.config.sh and
#               user-customized artifacts (see copy_kit_files)
set -uo pipefail

KIT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILTIN_HARNESSES="codex claude cursor"
# Built-in harness adapters always refreshed on --update; other harnesses/*.sh in the
# target (user-scaffolded) are left alone unless they share a built-in name.
BUILTIN_HARNESS_FILES="codex.sh claude.sh cursor.sh opencode.sh"

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

Modes:
  (default)                  fresh install; fails if loop/loop.config.sh already exists
  --update / --upgrade       refresh kit scripts/templates/skills; keep loop.config.sh
                             and leave review_mandate.partial.md + project-loop/SKILL.md
                             alone when they already exist (LEARNED / red-team customizations)
  --force                    fresh install that also overwrites loop/loop.config.sh
                             (mutually exclusive with --update)

Fresh-install options (ignored by --update except --sensitive-desc / --non-interactive):
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
  --council-harnesses "a b"  space-separated members council.sh asks independently — same
                              "harness"/"harness:model" syntax as --harnesses, but no >=2 or
                              distinctness requirement (no self-review adjacency to protect)
                                                                (default: codex opencode claude)
  --non-interactive          never prompt; use flags/defaults only
EOF
}

# Copy kit-managed files into $1. When $2 is "update", skip overwriting review_mandate and
# project-loop skill if they already exist (those accumulate project-specific value).
copy_kit_files() {
  local target="$1" mode="${2:-install}"
  local preserved=()

  mkdir -p "$target/loop/queue/pending" "$target/loop/queue/in_progress" \
           "$target/loop/queue/blocked" "$target/loop/queue/done" \
           "$target/loop/log" "$target/loop/state" "$target/loop/harnesses" \
           "$target/.claude/skills/council" "$target/.claude/skills/new-task" \
           "$target/.claude/skills/skillopt-sleep" "$target/.claude/skills/project-loop"

  cp "$KIT_ROOT"/loop/*.sh "$target/loop/"
  cp "$KIT_ROOT"/loop/*.tpl.md "$target/loop/"
  cp "$KIT_ROOT"/loop/README.md "$target/loop/README.md"
  cp "$KIT_ROOT"/loop/loop.config.sh.example "$target/loop/loop.config.sh.example"
  cp "$KIT_ROOT"/loop/skillopt-sleep.config.json.example "$target/loop/skillopt-sleep.config.json.example"
  cp "$KIT_ROOT"/loop/harnesses/TEMPLATE.sh.example "$target/loop/harnesses/TEMPLATE.sh.example"

  # Refresh built-in harness adapters only — do not delete user-scaffolded harnesses.
  local hf
  for hf in $BUILTIN_HARNESS_FILES; do
    [[ -f "$KIT_ROOT/loop/harnesses/$hf" ]] && cp "$KIT_ROOT/loop/harnesses/$hf" "$target/loop/harnesses/$hf"
  done

  if [[ "$mode" == "update" && -f "$target/loop/review_mandate.partial.md" ]]; then
    preserved+=("loop/review_mandate.partial.md")
  else
    cp "$KIT_ROOT"/loop/review_mandate.partial.md "$target/loop/review_mandate.partial.md"
  fi

  cp "$KIT_ROOT"/skills/council/SKILL.md "$target/.claude/skills/council/SKILL.md"
  cp "$KIT_ROOT"/skills/new-task/SKILL.md "$target/.claude/skills/new-task/SKILL.md"
  cp "$KIT_ROOT"/skills/skillopt-sleep/SKILL.md "$target/.claude/skills/skillopt-sleep/SKILL.md"

  if [[ "$mode" == "update" && -f "$target/.claude/skills/project-loop/SKILL.md" ]]; then
    preserved+=(".claude/skills/project-loop/SKILL.md")
  else
    cp "$KIT_ROOT"/skills/project-loop/SKILL.md "$target/.claude/skills/project-loop/SKILL.md"
  fi

  chmod +x "$target"/loop/*.sh "$target"/loop/harnesses/*.sh

  if (( ${#preserved[@]} > 0 )); then
    log "preserved (already present): ${preserved[*]}"
  fi
}

# Install-time substitution of {{SENSITIVE_DESC}} / {{PRINCIPLES_DOC}} / {{ROADMAP_DOC}}.
# Distinct from per-task tokens rendered by run.sh.
substitute_placeholders() {
  local target="$1" sensitive_desc="$2" principles_doc="$3" roadmap_doc="$4"
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
}

# Append recommended LOOP_KIT_* keys that are missing from an existing loop.config.sh
# (so --update can introduce SkillOpt knobs without rewriting tuned settings).
append_missing_config_keys() {
  local config="$1"
  python3 - "$config" <<'PY'
import re
import sys
from pathlib import Path

path = Path(sys.argv[1])
text = path.read_text(encoding="utf-8")

def has(key: str) -> bool:
    return re.search(rf"(?m)^\s*{re.escape(key)}=", text) is not None

# (key, lines to append when missing) — keep comments with the knobs they describe.
blocks = [
    (
        "LOOP_KIT_SKILLOPT_SKILL_PATH",
        [
            "",
            "# Added by install.sh --update (SkillOpt-Sleep). See loop.config.sh.example.",
            'LOOP_KIT_SKILLOPT_SKILL_PATH=".claude/skills/project-loop/SKILL.md"',
            'LOOP_KIT_SKILLOPT_BACKEND="mock"',
            'LOOP_KIT_SKILLOPT_MAX_TASKS="40"',
            'LOOP_KIT_SKILLOPT_EDIT_BUDGET="4"',
            'LOOP_KIT_SKILLOPT_TRIGGER="remind"',
            'LOOP_KIT_SKILLOPT_TRIGGER_EVERY_DONE="10"',
            'LOOP_KIT_SKILLOPT_TRIGGER_ON_RUN_END="1"',
        ],
    ),
    (
        "LOOP_KIT_SKILLOPT_TRIGGER",
        [
            "",
            "# Added by install.sh --update (SkillOpt activity triggers). See loop.config.sh.example.",
            'LOOP_KIT_SKILLOPT_TRIGGER="remind"',
            'LOOP_KIT_SKILLOPT_TRIGGER_EVERY_DONE="10"',
            'LOOP_KIT_SKILLOPT_TRIGGER_ON_RUN_END="1"',
        ],
    ),
]

added = []
for key, lines in blocks:
    if has(key):
        continue
    # If a sibling key from the same block exists, still skip to avoid partial dupes.
    siblings = [ln.split("=", 1)[0].strip() for ln in lines if ln.startswith("LOOP_KIT_")]
    if any(has(s) for s in siblings):
        continue
    text = text.rstrip() + "\n" + "\n".join(lines) + "\n"
    added.append(key)

if added:
    path.write_text(text, encoding="utf-8")
    print("appended missing config keys: " + ", ".join(added))
else:
    print("config already has known optional keys (nothing appended)")
PY
}

warn_missing_adapters() {
  local target="$1"
  shift
  local missing_adapters=()
  local h
  for h in "$@"; do
    [[ -z "$h" ]] && continue
    [[ -f "$target/loop/harnesses/$(member_harness "$h").sh" ]] || missing_adapters+=("$h")
  done
  if (( ${#missing_adapters[@]} > 0 )); then
    log "note: LOOP_KIT_HARNESSES/LOOP_KIT_COUNCIL_HARNESSES reference ${missing_adapters[*]}, which"
    log "      has no adapter yet — run 'loop/new_harness.sh <name>' in the target repo for each."
  fi
}

# --- argv -----------------------------------------------------------------------
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
council_harnesses="codex opencode claude"
non_interactive=0
force=0
mode="install"   # install | update

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
    --council-harnesses) council_harnesses="$2"; shift 2 ;;
    --non-interactive) non_interactive=1; shift ;;
    --force) force=1; shift ;;
    --update|--upgrade) mode="update"; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown option: $1 (see --help)" ;;
  esac
done

[[ -d "$target" ]] || die "target directory does not exist: $target"
target="$(cd "$target" && pwd)"
[[ -d "$target/.git" ]] || die "target is not a git repo (no .git): $target — run 'git init' there first"

if [[ "$mode" == "update" && "$force" == 1 ]]; then
  die "use either --update or --force, not both (--force rewrites loop.config.sh; --update keeps it)"
fi

# --- update path ----------------------------------------------------------------
if [[ "$mode" == "update" ]]; then
  [[ -f "$target/loop/loop.config.sh" ]] \
    || die "no loop/loop.config.sh in $target — this does not look like an installed kit copy; run a fresh install instead (omit --update)"
  [[ -d "$target/loop" ]] || die "missing $target/loop — run a fresh install first"

  # shellcheck disable=SC1091
  source "$target/loop/loop.config.sh"
  principles_doc="${LOOP_KIT_PRINCIPLES_DOC:-$principles_doc}"
  # Honor an explicit empty ROADMAP_DOC (milestone gating off); if the key is absent,
  # keep the script default for template substitution.
  if [[ -n "${LOOP_KIT_ROADMAP_DOC+x}" ]]; then
    roadmap_doc="$LOOP_KIT_ROADMAP_DOC"
  fi
  harnesses="${LOOP_KIT_HARNESSES:-$harnesses}"
  council_harnesses="${LOOP_KIT_COUNCIL_HARNESSES:-$council_harnesses}"

  # Prefer an explicit --sensitive-desc; otherwise keep the install default (not stored in config).
  if [[ "$non_interactive" != 1 && -t 0 ]]; then
    read -rp "Sensitive-path description for prompt text [$sensitive_desc]: " ans
    sensitive_desc="${ans:-$sensitive_desc}"
  fi

  log "updating kit files in $target (preserving loop/loop.config.sh)"
  copy_kit_files "$target" "update"
  append_msg="$(append_missing_config_keys "$target/loop/loop.config.sh")"
  log "$append_msg"
  substitute_placeholders "$target" "$sensitive_desc" "$principles_doc" "$roadmap_doc"
  warn_missing_adapters "$target" $harnesses $council_harnesses

  log "done. Updated scripts, templates, built-in harnesses, docs, and thin skills."
  log "  kept: loop/loop.config.sh"
  log "  kept if present: loop/review_mandate.partial.md, .claude/skills/project-loop/SKILL.md"
  log "  queue/log/state untouched; custom loop/harnesses/<name>.sh (non-built-in) untouched"
  log "  review loop/loop.config.sh.example for any new knobs; --update only appends known missing keys"
  exit 0
fi

# --- fresh install path ---------------------------------------------------------
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
  read -rp "Council members for design/scope questions (space-separated, same syntax, no >=2 requirement) [$council_harnesses]: " ans
  council_harnesses="${ans:-$council_harnesses}"
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
  die "$target/loop/loop.config.sh already exists — use --update to refresh kit files while keeping config, or --force to overwrite config too"
fi

log "installing into $target"
copy_kit_files "$target" "install"

{
  echo "# Generated by agentic-loop-kit install.sh on $(date +%Y-%m-%d). Edit freely — see"
  echo "# loop.config.sh.example for what each variable does."
  echo "# Refresh kit files later with: install.sh <this-repo> --update"
  echo "# Overwrite this config only with: install.sh <this-repo> --force"
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
  echo "LOOP_KIT_COUNCIL_HARNESSES=\"${council_harnesses}\""
  echo "# SkillOpt-Sleep: refine .claude/skills/project-loop/SKILL.md from loop/log evidence."
  echo "# See loop/README.md \"SkillOpt-Sleep\" and loop/skillopt-sleep.config.json.example."
  echo "LOOP_KIT_SKILLOPT_SKILL_PATH=\".claude/skills/project-loop/SKILL.md\""
  echo "LOOP_KIT_SKILLOPT_BACKEND=\"mock\""
  echo "LOOP_KIT_SKILLOPT_MAX_TASKS=\"40\""
  echo "LOOP_KIT_SKILLOPT_EDIT_BUDGET=\"4\""
  echo "LOOP_KIT_SKILLOPT_TRIGGER=\"remind\""
  echo "LOOP_KIT_SKILLOPT_TRIGGER_EVERY_DONE=\"10\""
  echo "LOOP_KIT_SKILLOPT_TRIGGER_ON_RUN_END=\"1\""
} > "$target/loop/loop.config.sh"

substitute_placeholders "$target" "$sensitive_desc" "$principles_doc" "$roadmap_doc"
warn_missing_adapters "$target" $harnesses $council_harnesses

log "done. Next steps:"
log "  1. Review $target/loop/loop.config.sh"
log "  2. Sharpen the adversarial red-team mandate in loop/review_mandate.partial.md once"
log "     you've seen a few real bugs slip through — that's where this kit's value compounds."
log "  3. Make sure $target has a $principles_doc with working principles (TDD, architecture"
log "     constraints, etc.) — the templates reference it."
if [[ -n "$roadmap_doc" ]]; then
  log "  4. Make sure $target/$roadmap_doc exists with '## <milestone-id> — ...' headings;"
  log "     new_task.sh validates against it."
else
  log "  4. Milestone gating disabled — new_task.sh will skip the roadmap check."
fi
log "  5. Install prerequisite CLIs for your chosen harnesses ($harnesses), and optionally"
log "     opencode (for council.sh)."
log "  6. Seed loop/queue/pending/ (loop/new_task.sh <slug> <milestone>), then:"
log "       cd $target && LOOP_MAX_ITERATIONS=1 loop/run.sh   # first supervised run"
log "  7. Optional — SkillOpt-Sleep for project skill refinement:"
log "       pip install skillopt"
log "       cp $target/loop/skillopt-sleep.config.json.example ~/.skillopt-sleep/config.json"
log "       loop/skillopt_sleep.sh dry-run --backend mock   # after a few done/blocked tasks"
log "  8. Later, pull kit updates with:"
log "       $KIT_ROOT/install.sh $target --update"

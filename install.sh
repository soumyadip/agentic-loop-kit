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
# copilot + opencode are multi-model CLIs (full maker/checker/council); not in the default
# rotation so a fresh install doesn't require those CLIs on day one.
BUILTIN_HARNESS_FILES="codex.sh claude.sh cursor.sh opencode.sh copilot.sh"

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

Interactive installs print a short "why / loop impact" blurb before each question.
Use --non-interactive plus flags to skip prompts.

── Core loop options ──────────────────────────────────────────────────────────

  --build-cmd "CMD"          verify.sh build step after every maker attempt
                              (default: make build)
                              Why: without a real build, broken compiles still reach review.
                              Loop impact: failure → retry maker with the log; pass → review.

  --test-cmd "CMD"           verify.sh test step after build
                              (default: make test)
                              Why: acceptance criteria must be checkable, not prose-only.
                              Loop impact: same as build — gates eligibility for review/merge.

  --require-human-review-paths REGEX
                             path prefixes that always require a human (never auto-merge)
                              (default: ^(deploy/|secrets|\.github/workflows/))
                              Why: secrets/deploy/CI must not self-approve via two models.
                              Loop impact: matching diffs → queue/blocked/ *before* review;
                              checker never runs. Alias: --sensitive-pattern (old name).

  --require-human-review-paths-label "TEXT"
                             plain-language label for those paths, for review prompts only
                              (default: "deploy configs, secrets, CI workflows")
                              Why: reviewers need prose; the regex alone is easy to miss.
                              Loop impact: baked into {{REQUIRE_HUMAN_REVIEW_PATHS_LABEL}} in review
                              templates — does *not* drive the gate. Not stored in
                              loop.config.sh. Alias: --sensitive-desc (old name).

  --principles-doc PATH      working-principles doc makers/reviewers must read
                              (default: AGENTS.md)
                              Why: TDD/architecture rules need one authoritative place.
                              Loop impact: task + review prompts point here every turn.

  --roadmap-doc PATH         milestone doc for new_task.sh validation; "" or none = off
                              (default: docs/roadmap.md)
                              Why: keeps queue tasks tied to real roadmap ids.
                              Loop impact: new_task.sh rejects unknown milestone: values.

  --harnesses "a b:m c"      maker/checker ring (order = who reviews whom); need >=2
                              (default: $BUILTIN_HARNESSES)
                              Why: no model grades its own homework.
                              Loop impact: maker frontmatter + reviewer_for() ring; each seat
                              needs loop/harnesses/<name>.sh.

  --codex-model / --claude-model / --cursor-model / --copilot-model / --opencode-model
                             default model for bare (unpinned) seats of that harness
                              Why: multi-model harnesses need a project default when you
                              don't write harness:model in LOOP_KIT_HARNESSES.
                              Loop impact: used for maker-default and checker unless overridden.
                              Examples: copilot:gpt-5.4 / opencode:nvidia/z-ai/glm-5.2

  --council-harnesses "a b"  independent design opinions (no ring / no >=2 rule)
                              (default: codex opencode claude)
                              Why: scope/ADR questions benefit from parallel disagreement.
                              Loop impact: only council.sh; not used by run.sh.

── SkillOpt-Sleep options ─────────────────────────────────────────────────────

  --with-skillopt            install the skillopt package (pip) during this run
  --no-skillopt              skip package install (default when --non-interactive)
  --skillopt-source pip|git  pip = PyPI skillopt; git = GitHub main (needed for handoff)
                              (default when installing: pip)
  --skillopt-backend NAME    mock|claude|codex|handoff  (default: mock)
                              Why: real refinement uses logged-in CLIs, not API keys.
                              Loop impact: loop/skillopt_sleep.sh default --backend.
  --skillopt-trigger MODE    off|remind|dry-run|run  (default: remind)
                              Why: surface skill refinement without forcing spend.
                              Loop impact: run.sh skillopt_trigger.sh after done thresholds.
  --skillopt-trigger-every N done/ tasks since last trigger before firing (default: 10; 0=off)
  --skillopt-trigger-backend mock|claude|codex|handoff  (default: mock)
                              Why: auto dry-run/run needs a backend; mock is safest.
  --skillopt-handoff-harness MEMBER
                              harness that answers handoff prompts
                              (e.g. cursor, copilot, opencode, copilot:gpt-5.4)
                              Why: Cursor/Copilot/opencode are not native Sleep backends.
                              Loop impact: --backend handoff → skillopt_handoff.sh.
  --skillopt-engine-config   copy loop/skillopt-sleep.config.json.example →
                              ~/.skillopt-sleep/config.json if missing
  --no-skillopt-engine-config  skip that copy

  --non-interactive          never prompt; use flags/defaults only
EOF
}

# Print a short explanation, then prompt. $1 = multi-line why/impact; $2 = prompt label;
# $3 = default. Sets REPLY.
ask() {
  local blurb="$1" label="$2" default="$3" ans
  printf '\n' >&2
  while IFS= read -r line; do
    [[ -n "$line" ]] && echo "[install] $line" >&2
  done <<< "$blurb"
  read -rp "[install] $label [$default]: " ans
  REPLY="${ans:-$default}"
}

ask_yn() {
  local blurb="$1" label="$2" default="$3" ans
  printf '\n' >&2
  while IFS= read -r line; do
    [[ -n "$line" ]] && echo "[install] $line" >&2
  done <<< "$blurb"
  read -rp "[install] $label [$default]: " ans
  ans="${ans:-$default}"
  case "$ans" in
    y|Y|yes|YES|true|1) REPLY=1 ;;
    *) REPLY=0 ;;
  esac
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

# Install-time substitution of {{REQUIRE_HUMAN_REVIEW_PATHS_LABEL}} / {{PRINCIPLES_DOC}} /
# {{ROADMAP_DOC}}. Also replaces legacy {{SENSITIVE_DESC}} so older preserved templates
# still get the label. Distinct from per-task tokens rendered by run.sh.
substitute_placeholders() {
  local target="$1" require_human_review_paths_label="$2" principles_doc="$3" roadmap_doc="$4"
  python3 - "$target" "$require_human_review_paths_label" "$principles_doc" "$roadmap_doc" <<'PY'
import glob
import sys

target, label, principles_doc, roadmap_doc = sys.argv[1:5]
repls = {
    "{{REQUIRE_HUMAN_REVIEW_PATHS_LABEL}}": label,
    "{{SENSITIVE_DESC}}": label,  # legacy token from before the rename
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
notes = []

def has(key: str) -> bool:
    return re.search(rf"(?m)^\s*{re.escape(key)}=", text) is not None

# Rename legacy LOOP_KIT_SENSITIVE_PATTERN → LOOP_KIT_REQUIRE_HUMAN_REVIEW_PATHS when needed.
if has("LOOP_KIT_SENSITIVE_PATTERN") and not has("LOOP_KIT_REQUIRE_HUMAN_REVIEW_PATHS"):
    text = re.sub(
        r"(?m)^(\s*)LOOP_KIT_SENSITIVE_PATTERN=",
        r"\1LOOP_KIT_REQUIRE_HUMAN_REVIEW_PATHS=",
        text,
        count=1,
    )
    notes.append("renamed LOOP_KIT_SENSITIVE_PATTERN → LOOP_KIT_REQUIRE_HUMAN_REVIEW_PATHS")

# (key, lines to append when missing) — keep comments with the knobs they describe.
blocks = [
    (
        "LOOP_KIT_SKILLOPT_SKILL_PATH",
        [
            "",
            "# Added by install.sh --update (SkillOpt-Sleep). See loop.config.sh.example.",
            'LOOP_KIT_SKILLOPT_SKILL_PATH=".claude/skills/project-loop/SKILL.md"',
            'LOOP_KIT_SKILLOPT_BACKEND="mock"',
            'LOOP_KIT_SKILLOPT_HANDOFF_HARNESS=""',
            'LOOP_KIT_SKILLOPT_MAX_TASKS="40"',
            'LOOP_KIT_SKILLOPT_EDIT_BUDGET="4"',
            'LOOP_KIT_SKILLOPT_TRIGGER="remind"',
            'LOOP_KIT_SKILLOPT_TRIGGER_EVERY_DONE="10"',
            'LOOP_KIT_SKILLOPT_TRIGGER_ON_RUN_END="1"',
            'LOOP_KIT_SKILLOPT_TRIGGER_BACKEND="mock"',
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
            'LOOP_KIT_SKILLOPT_TRIGGER_BACKEND="mock"',
        ],
    ),
    (
        "LOOP_KIT_SKILLOPT_TRIGGER_BACKEND",
        [
            "",
            "# Added by install.sh --update (SkillOpt trigger backend). See loop.config.sh.example.",
            'LOOP_KIT_SKILLOPT_TRIGGER_BACKEND="mock"',
        ],
    ),
    (
        "LOOP_KIT_SKILLOPT_HANDOFF_HARNESS",
        [
            "",
            "# Added by install.sh --update (SkillOpt handoff harness). See loop.config.sh.example.",
            'LOOP_KIT_SKILLOPT_HANDOFF_HARNESS=""',
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

if notes or added:
    path.write_text(text, encoding="utf-8")
    parts = list(notes)
    if added:
        parts.append("appended missing config keys: " + ", ".join(added))
    print("; ".join(parts))
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

# Upsert KEY="VALUE" lines in loop.config.sh (replace existing assignment or append).
upsert_config_keys() {
  local config="$1"
  shift
  python3 - "$config" "$@" <<'PY'
import re, sys
from pathlib import Path
path = Path(sys.argv[1])
pairs = sys.argv[2:]
text = path.read_text(encoding="utf-8") if path.is_file() else ""
for item in pairs:
    if "=" not in item:
        continue
    key, val = item.split("=", 1)
    line = f'{key}="{val}"'
    pat = re.compile(rf"(?m)^\s*{re.escape(key)}=.*$")
    if pat.search(text):
        text = pat.sub(line, text)
    else:
        text = text.rstrip() + f"\n\n# Set by install.sh SkillOpt configure\n{line}\n"
path.write_text(text, encoding="utf-8")
print(f"updated {path.name}: " + ", ".join(p.split("=", 1)[0] for p in pairs if "=" in p))
PY
}

install_skillopt_package() {
  local source="$1"
  local cmd
  case "$source" in
    git)
      cmd=(python3 -m pip install --user "git+https://github.com/microsoft/SkillOpt.git")
      log "installing SkillOpt from GitHub main (handoff-capable)…"
      ;;
    pip|*)
      cmd=(python3 -m pip install --user skillopt)
      log "installing SkillOpt from PyPI…"
      ;;
  esac
  if "${cmd[@]}"; then
    log "skillopt package installed"
    if command -v skillopt-sleep >/dev/null 2>&1 || python3 -c "import skillopt_sleep" >/dev/null 2>&1; then
      log "skillopt-sleep is available"
    else
      log "note: ensure your user pip bin dir is on PATH (skillopt-sleep may live under ~/.local/bin)"
    fi
  else
    log "WARNING: skillopt pip install failed — install manually later (see loop/README.md SkillOpt-Sleep)"
    return 1
  fi
}

ensure_skillopt_engine_config() {
  local target="$1"
  local dest="$HOME/.skillopt-sleep/config.json"
  local src="$target/loop/skillopt-sleep.config.json.example"
  [[ -f "$src" ]] || src="$KIT_ROOT/loop/skillopt-sleep.config.json.example"
  mkdir -p "$HOME/.skillopt-sleep"
  if [[ -f "$dest" ]]; then
    log "keeping existing $dest"
    return 0
  fi
  cp "$src" "$dest"
  log "wrote $dest (evolve_memory=false, gate on, auto_adopt off)"
}

# Interactive or flag-driven SkillOpt questions. Sets globals:
# skillopt_do_install, skillopt_source, skillopt_backend, skillopt_trigger,
# skillopt_trigger_every, skillopt_trigger_backend, skillopt_handoff_harness,
# skillopt_engine_config
prompt_skillopt_settings() {
  if [[ "$non_interactive" == 1 ]]; then
    return 0
  fi
  [[ -t 0 ]] || return 0

  ask_yn \
"SkillOpt-Sleep refines .claude/skills/project-loop/SKILL.md from loop/log evidence
(held-out gate; human adopt). Uses subscription CLIs (claude/codex) or handoff
(cursor/copilot/opencode) — no API keys required for those paths.
Why now: without the package, skillopt_sleep.sh cannot run.
Loop impact: optional; run.sh only reminds/auto-stages if TRIGGER is set." \
    "Install SkillOpt Python package now? (y/n)" \
    "$([[ "$skillopt_do_install" == 1 ]] && echo y || echo n)"
  skillopt_do_install="$REPLY"

  if (( skillopt_do_install )); then
    ask \
"pip = PyPI (fine for mock/claude/codex). git = GitHub main (needed for --backend handoff).
Why: handoff landed after PyPI 0.2.0.
Loop impact: only affects which skillopt_sleep features work." \
      "SkillOpt install source (pip|git)" "$skillopt_source"
    skillopt_source="$REPLY"
  fi

  ask \
"Default backend for loop/skillopt_sleep.sh:
  mock    — plumbing only
  claude  — Claude Code login/subscription
  codex   — Codex login/subscription
  handoff — kit harness answers Sleep prompts (cursor/copilot/opencode/…)
Why: real refinement should use logged-in CLIs, not API keys.
Loop impact: default --backend for manual + auto dry-run/run (via TRIGGER_BACKEND)." \
    "SkillOpt backend (mock|claude|codex|handoff)" "$skillopt_backend"
  skillopt_backend="$REPLY"

  ask \
"When run.sh finishes (or after each done/, per TRIGGER_ON_RUN_END):
  off     — never nudge
  remind  — print how to run SkillOpt (default; no model calls)
  dry-run — auto export + dry-run (never adopts)
  run     — auto export + stage proposal (never auto-adopts)
Why: otherwise SkillOpt is easy to forget; remind keeps it visible.
Loop impact: loop/skillopt_trigger.sh watermark in loop/state/skillopt-trigger.json." \
    "SkillOpt activity trigger (off|remind|dry-run|run)" "$skillopt_trigger"
  skillopt_trigger="$REPLY"

  ask \
"Fire after this many tasks enter done/ since the last successful trigger (0 = never).
Why: absolute queue size is wrong; relative watermark matches real usage.
Loop impact: ONLY when TRIGGER is remind|dry-run|run." \
    "SkillOpt trigger every N done" "$skillopt_trigger_every"
  skillopt_trigger_every="$REPLY"

  ask \
"Backend used when TRIGGER is dry-run|run (mock|claude|codex|handoff).
Why: auto paths should default to mock until you opt into subscription spend.
Loop impact: ignored for remind/off." \
    "SkillOpt trigger backend" "$skillopt_trigger_backend"
  skillopt_trigger_backend="$REPLY"

  ask \
"Member that answers --backend handoff prompts (empty = first LOOP_KIT_HARNESSES seat).
Examples: cursor, copilot, opencode, copilot:gpt-5.4, claude.
Why: Cursor/Copilot/opencode are not native SkillOpt backends — handoff uses harness_council_run.
Loop impact: only when backend or trigger-backend is handoff." \
    "SkillOpt handoff harness" "$skillopt_handoff_harness"
  skillopt_handoff_harness="$REPLY"

  ask_yn \
"Copy loop/skillopt-sleep.config.json.example to ~/.skillopt-sleep/config.json if missing
(engine defaults: evolve_memory=false, gate on, auto_adopt off).
Why: Sleep engine reads ~/.skillopt-sleep/; without it you get built-in defaults.
Loop impact: does not change loop.config.sh." \
    "Write ~/.skillopt-sleep/config.json if missing? (y/n)" \
    "$([[ "$skillopt_engine_config" == 1 ]] && echo y || echo n)"
  skillopt_engine_config="$REPLY"
}

# Re-validate after interactive answers (flags already validated above).
validate_skillopt_choices() {
  case "$skillopt_source" in
    pip|git) ;;
    *) die "SkillOpt source must be pip or git (got: $skillopt_source)" ;;
  esac
  case "$skillopt_backend" in
    mock|claude|codex|handoff) ;;
    *) die "SkillOpt backend must be mock|claude|codex|handoff (got: $skillopt_backend)" ;;
  esac
  case "$skillopt_trigger" in
    off|remind|dry-run|run) ;;
    *) die "SkillOpt trigger must be off|remind|dry-run|run (got: $skillopt_trigger)" ;;
  esac
  case "$skillopt_trigger_backend" in
    mock|claude|codex|handoff) ;;
    *) die "SkillOpt trigger backend must be mock|claude|codex|handoff (got: $skillopt_trigger_backend)" ;;
  esac
  [[ "$skillopt_trigger_every" =~ ^[0-9]+$ ]] || die "SkillOpt trigger every must be an integer"
  if [[ "$skillopt_backend" == "handoff" || "$skillopt_trigger_backend" == "handoff" ]]; then
    if [[ "$skillopt_source" == "pip" && "$skillopt_do_install" == 1 ]]; then
      log "note: handoff needs SkillOpt from git (PyPI 0.2.0 lacks it) — prefer --skillopt-source git"
    fi
  fi
}

apply_skillopt_choices() {
  local target="$1" config="$2"
  validate_skillopt_choices
  if (( skillopt_do_install )); then
    install_skillopt_package "$skillopt_source" || true
  fi
  if (( skillopt_engine_config )); then
    ensure_skillopt_engine_config "$target"
  fi
  upsert_config_keys "$config" \
    "LOOP_KIT_SKILLOPT_SKILL_PATH=.claude/skills/project-loop/SKILL.md" \
    "LOOP_KIT_SKILLOPT_BACKEND=${skillopt_backend}" \
    "LOOP_KIT_SKILLOPT_HANDOFF_HARNESS=${skillopt_handoff_harness}" \
    "LOOP_KIT_SKILLOPT_MAX_TASKS=40" \
    "LOOP_KIT_SKILLOPT_EDIT_BUDGET=4" \
    "LOOP_KIT_SKILLOPT_TRIGGER=${skillopt_trigger}" \
    "LOOP_KIT_SKILLOPT_TRIGGER_EVERY_DONE=${skillopt_trigger_every}" \
    "LOOP_KIT_SKILLOPT_TRIGGER_ON_RUN_END=1" \
    "LOOP_KIT_SKILLOPT_TRIGGER_BACKEND=${skillopt_trigger_backend}"
}

# --- argv -----------------------------------------------------------------------
[[ $# -ge 1 ]] || { usage; exit 1; }
target="$1"; shift
[[ "$target" == "-h" || "$target" == "--help" ]] && { usage; exit 0; }

build_cmd="make build"
test_cmd="make test"
require_human_review_paths='^(deploy/|secrets|\.github/workflows/)'
require_human_review_paths_label="deploy configs, secrets, CI workflows"
principles_doc="AGENTS.md"
roadmap_doc="docs/roadmap.md"
harnesses="$BUILTIN_HARNESSES"
codex_model="gpt-5.6-terra"
claude_model="sonnet"
cursor_model="grok-4.5-high"
copilot_model="gpt-5.4"
opencode_model="nvidia/z-ai/glm-5.2"
council_harnesses="codex opencode claude"
non_interactive=0
force=0
mode="install"   # install | update

# SkillOpt defaults (safe / remind-only until the user opts in)
skillopt_do_install=0          # 0 unless --with-skillopt or interactive yes
skillopt_source="pip"          # pip | git
skillopt_backend="mock"
skillopt_trigger="remind"
skillopt_trigger_every="10"
skillopt_trigger_backend="mock"
skillopt_handoff_harness=""
skillopt_engine_config=0       # 0 unless interactive yes or --skillopt-engine-config
skillopt_flag_set=0            # 1 if any --with/--no-skillopt flag was passed

while [[ $# -gt 0 ]]; do
  case "$1" in
    --build-cmd) build_cmd="$2"; shift 2 ;;
    --test-cmd) test_cmd="$2"; shift 2 ;;
    --require-human-review-paths|--sensitive-pattern) require_human_review_paths="$2"; shift 2 ;;
    --require-human-review-paths-label|--sensitive-desc) require_human_review_paths_label="$2"; shift 2 ;;
    --principles-doc) principles_doc="$2"; shift 2 ;;
    --roadmap-doc) roadmap_doc="$2"; shift 2 ;;
    --harnesses) harnesses="$2"; shift 2 ;;
    --codex-model) codex_model="$2"; shift 2 ;;
    --claude-model) claude_model="$2"; shift 2 ;;
    --cursor-model) cursor_model="$2"; shift 2 ;;
    --copilot-model) copilot_model="$2"; shift 2 ;;
    --opencode-model) opencode_model="$2"; shift 2 ;;
    --council-harnesses) council_harnesses="$2"; shift 2 ;;
    --with-skillopt) skillopt_do_install=1; skillopt_flag_set=1; shift ;;
    --no-skillopt) skillopt_do_install=0; skillopt_flag_set=1; shift ;;
    --skillopt-source) skillopt_source="$2"; skillopt_flag_set=1; shift 2 ;;
    --skillopt-backend) skillopt_backend="$2"; skillopt_flag_set=1; shift 2 ;;
    --skillopt-trigger) skillopt_trigger="$2"; skillopt_flag_set=1; shift 2 ;;
    --skillopt-trigger-every) skillopt_trigger_every="$2"; skillopt_flag_set=1; shift 2 ;;
    --skillopt-trigger-backend) skillopt_trigger_backend="$2"; skillopt_flag_set=1; shift 2 ;;
    --skillopt-handoff-harness) skillopt_handoff_harness="$2"; skillopt_flag_set=1; shift 2 ;;
    --skillopt-engine-config) skillopt_engine_config=1; skillopt_flag_set=1; shift ;;
    --no-skillopt-engine-config) skillopt_engine_config=0; skillopt_flag_set=1; shift ;;
    --non-interactive) non_interactive=1; shift ;;
    --force) force=1; shift ;;
    --update|--upgrade) mode="update"; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown option: $1 (see --help)" ;;
  esac
done

case "$skillopt_source" in
  pip|git) ;;
  *) die "--skillopt-source must be pip or git (got: $skillopt_source)" ;;
esac
case "$skillopt_backend" in
  mock|claude|codex|handoff) ;;
  *) die "--skillopt-backend must be mock|claude|codex|handoff (got: $skillopt_backend)" ;;
esac
case "$skillopt_trigger" in
  off|remind|dry-run|run) ;;
  *) die "--skillopt-trigger must be off|remind|dry-run|run (got: $skillopt_trigger)" ;;
esac
case "$skillopt_trigger_backend" in
  mock|claude|codex|handoff) ;;
  *) die "--skillopt-trigger-backend must be mock|claude|codex|handoff (got: $skillopt_trigger_backend)" ;;
esac
[[ "$skillopt_trigger_every" =~ ^[0-9]+$ ]] || die "--skillopt-trigger-every must be an integer"

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
  # Prefer existing SkillOpt settings as interactive defaults when the user
  # did not pass any --skillopt* / --with-skillopt flags (those win).
  if (( ! skillopt_flag_set )); then
    skillopt_backend="${LOOP_KIT_SKILLOPT_BACKEND:-$skillopt_backend}"
    skillopt_trigger="${LOOP_KIT_SKILLOPT_TRIGGER:-$skillopt_trigger}"
    skillopt_trigger_every="${LOOP_KIT_SKILLOPT_TRIGGER_EVERY_DONE:-$skillopt_trigger_every}"
    skillopt_trigger_backend="${LOOP_KIT_SKILLOPT_TRIGGER_BACKEND:-$skillopt_trigger_backend}"
    skillopt_handoff_harness="${LOOP_KIT_SKILLOPT_HANDOFF_HARNESS:-$skillopt_handoff_harness}"
  fi

  if [[ "$non_interactive" != 1 && -t 0 ]]; then
    ask \
"Plain-language label for paths that always require a human — for review prompts only
(not the gate; the regex above is the gate). Not stored in loop.config.sh.
Why: reviewers see prose, not only LOOP_KIT_REQUIRE_HUMAN_REVIEW_PATHS.
Loop impact: substituted into {{REQUIRE_HUMAN_REVIEW_PATHS_LABEL}} in review templates." \
      "Require-human-review paths label (prompt text only)" "$require_human_review_paths_label"
    require_human_review_paths_label="$REPLY"

    prompt_skillopt_settings
  fi

  log "updating kit files in $target (preserving loop/loop.config.sh)"
  copy_kit_files "$target" "update"
  append_msg="$(append_missing_config_keys "$target/loop/loop.config.sh")"
  log "$append_msg"
  # Interactive update always ran prompt_skillopt_settings; non-interactive only if
  # any --skillopt* / --with-skillopt flag was passed.
  if [[ "$non_interactive" != 1 && -t 0 ]] || (( skillopt_flag_set )); then
    apply_skillopt_choices "$target" "$target/loop/loop.config.sh"
  fi
  substitute_placeholders "$target" "$require_human_review_paths_label" "$principles_doc" "$roadmap_doc"
  warn_missing_adapters "$target" $harnesses $council_harnesses

  log "done. Updated scripts, templates, built-in harnesses, docs, and thin skills."
  log "  kept: loop/loop.config.sh (SkillOpt keys upserted if you configured SkillOpt)"
  log "  kept if present: loop/review_mandate.partial.md, .claude/skills/project-loop/SKILL.md"
  log "  queue/log/state untouched; custom loop/harnesses/<name>.sh (non-built-in) untouched"
  log "  review loop/loop.config.sh.example for any new knobs; --update appends known missing keys"
  exit 0
fi

# --- fresh install path ---------------------------------------------------------
if [[ "$non_interactive" != 1 && -t 0 ]]; then
  log "Each question below includes why it matters and how it affects normal loop runs."
  log "Press Enter to accept the default in [brackets]. Full flag docs: install.sh --help"

  ask \
"Command loop/verify.sh runs after every maker attempt (build/compile/typecheck).
Why: without a real gate, broken work still reaches the checker and can merge.
Loop impact: fail → retry maker with the log; pass → require-human-review path check then review." \
    "Build command" "$build_cmd"
  build_cmd="$REPLY"

  ask \
"Command loop/verify.sh runs after build (tests).
Why: acceptance criteria must be executable, not prose-only.
Loop impact: same as build — blocks review until green." \
    "Test command" "$test_cmd"
  test_cmd="$REPLY"

  ask \
"Regex of path prefixes that ALWAYS require a human — matching diffs skip the checker
and go to queue/blocked/ (never auto-merge), even if verify passed.
Default covers deploy/, secrets, .github/workflows/; add ADRs/schemas as needed.
Why: two models agreeing must not merge secrets/deploy/CI unsupervised.
Loop impact: hard gate after verify; see also the label prompt next (prompt text only)." \
    "Require-human-review paths (regex gate)" "$require_human_review_paths"
  require_human_review_paths="$REPLY"

  ask \
"Plain-language label for those paths — used in review prompts only, NOT the gate.
Why: reviewers need prose; the regex alone is easy to miss.
Loop impact: {{REQUIRE_HUMAN_REVIEW_PATHS_LABEL}} in review templates (not written to loop.config.sh)." \
    "Require-human-review paths label (prompt text only)" "$require_human_review_paths_label"
  require_human_review_paths_label="$REPLY"

  ask \
"Doc makers and reviewers must read first (TDD, architecture, conventions).
Why: fresh-context agents need one authoritative principles file.
Loop impact: every task_prompt / review_prompt points here (LOOP_KIT_PRINCIPLES_DOC)." \
    "Working-principles doc" "$principles_doc"
  principles_doc="$REPLY"

  ask \
"Roadmap file whose '## <id> — …' headings validate new_task.sh milestone: fields.
Type 'none' to disable milestone gating.
Why: keeps the queue tied to real roadmap work instead of free-floating tasks.
Loop impact: new_task.sh rejects unknown milestones when this file exists." \
    "Roadmap/milestone doc (or none)" "$roadmap_doc"
  if [[ "$REPLY" == "none" ]]; then
    roadmap_doc=""
  else
    roadmap_doc="$REPLY"
  fi

  ask \
"Maker/checker seats in review-ring order (space-separated). Need >=2.
Use harness or harness:model (e.g. cursor:grok-4.5-high, copilot:gpt-5.4,
opencode:nvidia/z-ai/glm-5.2). Multi-model CLIs (cursor/copilot/opencode) can
fill multiple seats alone.
Why: no model grades its own homework — each seat is reviewed by the next.
Loop impact: run.sh maker routing + reviewer_for(); each harness needs an adapter." \
    "Harnesses (maker/checker ring)" "$harnesses"
  harnesses="$REPLY"

  # Only prompt once per bare (no ':model') harness name — an entry that already pins its own
  # model doesn't need (or use) this project-wide default.
  prompted=""
  for h in $harnesses; do
    [[ "$h" == *:* ]] && continue
    case " $prompted " in *" $h "*) continue ;; esac
    prompted="$prompted $h"
    case "$h" in
      codex)
        ask \
"Default model for bare 'codex' seats (maker default + checker unless you split in config).
Why: bare 'codex' entries need a project default.
Loop impact: LOOP_KIT_CODEX_MAKER_MODEL_DEFAULT / CHECKER_MODEL." \
          "  Default model for bare 'codex' entries" "$codex_model"
        codex_model="$REPLY"
        ;;
      claude)
        ask \
"Default model for bare 'claude' seats (maker default + checker unless you split in config).
Why: bare 'claude' entries need a project default.
Loop impact: LOOP_KIT_CLAUDE_MAKER_MODEL_* / CHECKER_MODEL." \
          "  Default model for bare 'claude' entries" "$claude_model"
        claude_model="$REPLY"
        ;;
      cursor)
        ask \
"Default model for bare 'cursor' seats (cursor-agent slug, often includes effort).
Why: bare 'cursor' entries need a project default.
Loop impact: LOOP_KIT_CURSOR_MODEL for maker and checker." \
          "  Default model for bare 'cursor' entries" "$cursor_model"
        cursor_model="$REPLY"
        ;;
      copilot)
        ask \
"Default model for bare 'copilot' seats (GitHub Copilot CLI id, e.g. gpt-5.4,
claude-sonnet-4.6 — see \`copilot /model\` for your plan).
Why: bare 'copilot' entries need a project default.
Loop impact: LOOP_KIT_COPILOT_MODEL for maker and checker." \
          "  Default model for bare 'copilot' entries" "$copilot_model"
        copilot_model="$REPLY"
        ;;
      opencode)
        ask \
"Default model for bare 'opencode' seats (provider/model, e.g. nvidia/z-ai/glm-5.2).
Why: bare 'opencode' entries need a project default.
Loop impact: LOOP_KIT_OPENCODE_MODEL for maker and checker." \
          "  Default model for bare 'opencode' entries" "$opencode_model"
        opencode_model="$REPLY"
        ;;
      *) log "  '$h' has no built-in adapter — run 'loop/new_harness.sh $h' in the target repo after install." ;;
    esac
  done

  ask \
"Who council.sh asks for independent design/scope opinions (no ring, no >=2 rule).
Why: ADRs benefit from parallel disagreement without merge pressure.
Loop impact: only council.sh — not used by the maker/checker loop." \
    "Council members" "$council_harnesses"
  council_harnesses="$REPLY"

  # Interactive default: offer SkillOpt install (y) so new installs discover it.
  if (( ! skillopt_flag_set )); then
    skillopt_do_install=1
    skillopt_engine_config=1
  fi
  prompt_skillopt_settings
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
  echo "LOOP_KIT_REQUIRE_HUMAN_REVIEW_PATHS='${require_human_review_paths}'"
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
      copilot)
        echo "LOOP_KIT_COPILOT_MODEL=\"${copilot_model}\""
        ;;
      opencode)
        echo "LOOP_KIT_OPENCODE_MODEL=\"${opencode_model}\""
        ;;
    esac
  done
  echo "LOOP_KIT_COUNCIL_HARNESSES=\"${council_harnesses}\""
  echo "# SkillOpt-Sleep: refine .claude/skills/project-loop/SKILL.md from loop/log evidence."
  echo "# See loop/README.md \"SkillOpt-Sleep\" and loop/skillopt-sleep.config.json.example."
  echo "LOOP_KIT_SKILLOPT_SKILL_PATH=\".claude/skills/project-loop/SKILL.md\""
  echo "LOOP_KIT_SKILLOPT_BACKEND=\"${skillopt_backend}\""
  echo "LOOP_KIT_SKILLOPT_HANDOFF_HARNESS=\"${skillopt_handoff_harness}\""
  echo "LOOP_KIT_SKILLOPT_MAX_TASKS=\"40\""
  echo "LOOP_KIT_SKILLOPT_EDIT_BUDGET=\"4\""
  echo "LOOP_KIT_SKILLOPT_TRIGGER=\"${skillopt_trigger}\""
  echo "LOOP_KIT_SKILLOPT_TRIGGER_EVERY_DONE=\"${skillopt_trigger_every}\""
  echo "LOOP_KIT_SKILLOPT_TRIGGER_ON_RUN_END=\"1\""
  echo "LOOP_KIT_SKILLOPT_TRIGGER_BACKEND=\"${skillopt_trigger_backend}\""
} > "$target/loop/loop.config.sh"

# Package install + ~/.skillopt-sleep (config keys already written above; upsert is idempotent).
if (( skillopt_do_install || skillopt_engine_config || skillopt_flag_set )) \
   || [[ "$non_interactive" != 1 && -t 0 ]]; then
  apply_skillopt_choices "$target" "$target/loop/loop.config.sh"
fi

substitute_placeholders "$target" "$require_human_review_paths_label" "$principles_doc" "$roadmap_doc"
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
log "  5. Install prerequisite CLIs for your chosen harnesses ($harnesses)"
log "     (codex / claude / cursor-agent / copilot / opencode as applicable)."
log "  6. Seed loop/queue/pending/ (loop/new_task.sh <slug> <milestone>), then:"
log "       cd $target && LOOP_MAX_ITERATIONS=1 loop/run.sh   # first supervised run"
log "  7. SkillOpt-Sleep (configured above; TRIGGER=${skillopt_trigger}, BACKEND=${skillopt_backend}):"
log "       loop/skillopt_sleep.sh dry-run --backend ${skillopt_backend}"
log "       # after a few done/blocked tasks; human adopt only — never auto-merge skill edits"
log "       # handoff examples: --backend handoff --handoff-harness copilot|cursor|opencode"
log "  8. Later, pull kit updates (and re-prompt SkillOpt) with:"
log "       $KIT_ROOT/install.sh $target --update"

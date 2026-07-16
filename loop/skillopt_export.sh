#!/usr/bin/env bash
# Convert this project's maker/checker loop evidence (loop/log + queue outcomes)
# into a SkillOpt-Sleep tasks file (format skillopt_sleep.tasks.v1).
#
# The export is the privacy boundary: inspect/redact the JSON, set
# "reviewed": true, then feed it to loop/skillopt_sleep.sh via --tasks-file.
# Real SkillOpt-Sleep backends refuse unreviewed task files.
#
# Usage:
#   loop/skillopt_export.sh [-o PATH] [--reviewed] [--max-tasks N]
#                           [--target-skill-path PATH] [--self-test]
#
# Defaults:
#   -o loop/state/skillopt-tasks.json
#   --max-tasks from LOOP_KIT_SKILLOPT_MAX_TASKS (default 40)
#   --target-skill-path from LOOP_KIT_SKILLOPT_SKILL_PATH
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
[[ -f "$ROOT/loop/loop.config.sh" ]] && source "$ROOT/loop/loop.config.sh"

die() { echo "[skillopt_export] $*" >&2; exit 1; }

out="${LOOP_KIT_SKILLOPT_TASKS_FILE:-}"
[[ -z "$out" ]] && out="$ROOT/loop/state/skillopt-tasks.json"
reviewed=0
max_tasks="${LOOP_KIT_SKILLOPT_MAX_TASKS:-40}"
[[ -z "$max_tasks" ]] && max_tasks=40
target_skill="${LOOP_KIT_SKILLOPT_SKILL_PATH:-}"
[[ -z "$target_skill" ]] && target_skill=".claude/skills/project-loop/SKILL.md"
self_test=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    -o|--output) out="$2"; shift 2 ;;
    --reviewed) reviewed=1; shift ;;
    --max-tasks) max_tasks="$2"; shift 2 ;;
    --target-skill-path) target_skill="$2"; shift 2 ;;
    --self-test) self_test=1; shift ;;
    -h|--help)
      sed -n '2,16p' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *) die "unknown option: $1 (see --help)" ;;
  esac
done

[[ "$max_tasks" =~ ^[0-9]+$ ]] || die "--max-tasks must be a non-negative integer"

run_export() {
  local root="$1" output="$2" rev="$3" max="$4" skill="$5"
  python3 - "$root" "$output" "$rev" "$max" "$skill" <<'PY'
from __future__ import annotations

import json
import re
import sys
from pathlib import Path
from typing import Any, Dict, List, Optional, Tuple

ROOT = Path(sys.argv[1])
OUT = Path(sys.argv[2])
REVIEWED = sys.argv[3] in ("1", "true", "True", "yes")
MAX_TASKS = int(sys.argv[4])
TARGET_SKILL = sys.argv[5]

LOG = ROOT / "loop" / "log"
QUEUE = ROOT / "loop" / "queue"
BUCKETS = ("done", "blocked", "in_progress")
EXCERPT_LIMIT = 4000


def read_text(path: Path, limit: int = 0) -> str:
    try:
        text = path.read_text(encoding="utf-8", errors="replace")
    except OSError:
        return ""
    if limit and len(text) > limit:
        return text[:limit] + "\n…[truncated]…"
    return text


def find_task_file(task_id: str) -> Tuple[Optional[Path], str]:
    for bucket in BUCKETS:
        d = QUEUE / bucket
        if not d.is_dir():
            continue
        for f in sorted(d.glob(f"{task_id}-*.md")):
            return f, bucket
        exact = d / f"{task_id}.md"
        if exact.is_file():
            return exact, bucket
    return None, ""


def section(body: str, name: str) -> str:
    m = re.search(
        rf"^## {re.escape(name)}\s*\n(.*?)(?=^## |\Z)",
        body,
        flags=re.M | re.S,
    )
    return (m.group(1).strip() if m else "")


def title_and_body(task_text: str) -> Tuple[str, str]:
    if task_text.startswith("---"):
        end = task_text.find("\n---", 3)
        if end != -1:
            task_text = task_text[end + 4 :].lstrip("\n")
    title = ""
    m = re.search(r"^#\s+(.+)$", task_text, flags=re.M)
    if m:
        title = m.group(1).strip()
    return title, task_text


def latest_attempt(log_dir: Path) -> int:
    n = 0
    for p in log_dir.glob("attempt-*-maker-*.log"):
        m = re.match(r"attempt-(\d+)-maker-", p.name)
        if m:
            n = max(n, int(m.group(1)))
    for p in log_dir.glob("attempt-*-verify.txt"):
        m = re.match(r"attempt-(\d+)-verify", p.name)
        if m:
            n = max(n, int(m.group(1)))
    return n


def pick_one(log_dir: Path, pattern: str) -> Optional[Path]:
    matches = sorted(log_dir.glob(pattern))
    return matches[-1] if matches else None


def classify_outcome(outcome: str, bucket: str, verify_ok: Optional[bool]) -> str:
    o = (outcome or "").strip().lower()
    if o == "approved" or (bucket == "done" and (not o or o.startswith("approved"))):
        return "success"
    if "request_changes" in o:
        return "fail"
    if verify_ok is False:
        return "fail"
    if bucket == "blocked" or o.startswith("blocked"):
        return "fail"
    return "unknown"


def build_task(task_id: str, log_dir: Path) -> Optional[Dict[str, Any]]:
    task_file, bucket = find_task_file(task_id)
    if task_file is None:
        return None

    task_text = read_text(task_file)
    title, body = title_and_body(task_text)
    why = section(body, "Why")
    scope = section(body, "Scope")
    acceptance = section(body, "Acceptance criteria")

    outcome = read_text(log_dir / "outcome").strip()
    attempt = latest_attempt(log_dir)
    verify_path = log_dir / f"attempt-{attempt}-verify.txt" if attempt else None
    verify_txt = read_text(verify_path) if verify_path and verify_path.is_file() else ""
    verify_ok: Optional[bool] = None
    if verify_path and verify_path.is_file():
        low = verify_txt.lower()
        if any(x in low for x in ("verify failed", "error:", "failed:", "failing")):
            verify_ok = False
        elif outcome == "approved" or bucket == "done":
            verify_ok = True

    maker_log = pick_one(log_dir, f"attempt-{attempt}-maker-*.log") if attempt else None
    review_log = pick_one(log_dir, f"attempt-{attempt}-review-*.log") if attempt else None
    fail_blob = ""
    for name in (
        f"attempt-{attempt}-verify.txt",
        f"attempt-{attempt}-no-commit.txt",
    ):
        p = log_dir / name
        if p.is_file() and outcome != "approved":
            fail_blob = read_text(p, EXCERPT_LIMIT)
            break
    if not fail_blob and review_log and "request_changes" in outcome:
        fail_blob = read_text(review_log, EXCERPT_LIMIT)

    label = classify_outcome(outcome, bucket, verify_ok)
    intent_parts = [p for p in (title, why) if p]
    intent = "\n\n".join(intent_parts) if intent_parts else f"Complete loop task {task_id}"
    context_parts = []
    if scope:
        context_parts.append(f"## Scope\n{scope}")
    if acceptance:
        context_parts.append(f"## Acceptance criteria\n{acceptance}")
    if fail_blob and label != "success":
        context_parts.append(f"## Prior failure signal\n{fail_blob}")
    context = "\n\n".join(context_parts)

    solution = read_text(maker_log, EXCERPT_LIMIT) if maker_log else ""
    reference_bits = []
    if acceptance:
        reference_bits.append(acceptance)
    if review_log:
        reference_bits.append(read_text(review_log, 2000))
    reference = "\n\n".join(reference_bits)
    reference_kind = "rubric" if reference.strip() else "none"

    tags = ["loop", f"bucket:{bucket}", f"outcome:{label}"]
    if attempt:
        tags.append(f"attempts:{attempt}")

    return {
        "id": task_id,
        "project": str(ROOT),
        "intent": intent[:EXCERPT_LIMIT],
        "context_excerpt": context[:EXCERPT_LIMIT],
        "system": (
            "You are the maker in this project's agentic maker/checker loop. "
            "Satisfy the task file's Scope and Acceptance criteria. "
            "Follow the project's working-principles doc. Do not expand scope."
        ),
        "attempted_solution": solution,
        "outcome": label,
        "reference_kind": reference_kind,
        "reference": reference[:EXCERPT_LIMIT],
        "judge": {},
        "tags": tags,
        "source_sessions": [f"loop/log/{task_id}"],
        "split": "train",
        "origin": "real",
        "derived_from": "",
    }


def main() -> int:
    if not LOG.is_dir():
        print(f"[skillopt_export] no log dir at {LOG}", file=sys.stderr)
        tasks: List[Dict[str, Any]] = []
    else:
        dirs = sorted(
            [p for p in LOG.iterdir() if p.is_dir() and re.match(r"^T\d+", p.name)],
            key=lambda p: p.name,
        )
        dirs = dirs[-MAX_TASKS:] if MAX_TASKS > 0 else dirs
        tasks = []
        for d in dirs:
            task = build_task(d.name, d)
            if task:
                tasks.append(task)

    payload = {
        "format": "skillopt_sleep.tasks.v1",
        "project": str(ROOT),
        "transcript_source": "agentic-loop-kit",
        "n_sessions": len(tasks),
        "target_skill_path": TARGET_SKILL,
        "reviewed": REVIEWED,
        "tasks": tasks,
        "notes": [
            "Exported from loop/log + loop/queue by loop/skillopt_export.sh.",
            "Inspect/redact before setting reviewed=true for a real SkillOpt-Sleep backend.",
            "Real backends refuse reviewed=false task files.",
        ],
    }

    OUT.parent.mkdir(parents=True, exist_ok=True)
    OUT.write_text(json.dumps(payload, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(f"[skillopt_export] wrote {len(tasks)} task(s) → {OUT}")
    print(f"[skillopt_export] reviewed={str(REVIEWED).lower()}  target_skill_path={TARGET_SKILL}")
    if not REVIEWED:
        print(
            "[skillopt_export] next: inspect/redact the JSON, then re-run with --reviewed "
            "(or set \"reviewed\": true by hand) before a real backend sleep cycle",
            file=sys.stderr,
        )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
PY
}

if (( self_test )); then
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/skillopt-export-selftest.XXXXXX")"
  trap 'rm -rf "$tmp"' EXIT
  mkdir -p "$tmp/loop/log/T001" "$tmp/loop/log/T002" \
           "$tmp/loop/queue/done" "$tmp/loop/queue/blocked" "$tmp/loop/state"

  cat > "$tmp/loop/queue/done/T001-example.md" <<'EOF'
---
id: T001
milestone: M1
sensitive: false
depends_on: []
---

# Add health endpoint

## Why

Roadmap asks for a liveness probe.

## Scope

Add GET /health returning 200. Do not touch auth.

## Acceptance criteria

- [ ] GET /health returns 200 with {"ok": true}
EOF
  echo "approved" > "$tmp/loop/log/T001/outcome"
  echo "verify: ok" > "$tmp/loop/log/T001/attempt-1-verify.txt"
  echo "Implemented GET /health" > "$tmp/loop/log/T001/attempt-1-maker-codex.log"
  printf 'ok\nVERDICT: approve\n' > "$tmp/loop/log/T001/attempt-1-review-claude.log"

  cat > "$tmp/loop/queue/blocked/T002-broken.md" <<'EOF'
---
id: T002
milestone: M1
sensitive: false
depends_on: []
---

# Fix flaky parser

## Why

Parser drops trailing commas.

## Scope

Fix JSON parser only.

## Acceptance criteria

- [ ] Trailing commas accepted in fixtures
EOF
  echo "blocked: request_changes" > "$tmp/loop/log/T002/outcome"
  echo "verify failed: assertion error" > "$tmp/loop/log/T002/attempt-2-verify.txt"
  echo "Tried a regex hack" > "$tmp/loop/log/T002/attempt-2-maker-cursor.log"
  printf 'Bug: still drops commas\nVERDICT: request_changes\n' > "$tmp/loop/log/T002/attempt-2-review-codex.log"

  run_export "$tmp" "$tmp/out.json" "0" "10" ".claude/skills/project-loop/SKILL.md" \
    || die "self-test export failed"
  python3 - "$tmp/out.json" <<'PY' || die "self-test assertions failed"
import json, sys
p = json.load(open(sys.argv[1]))
assert p["format"] == "skillopt_sleep.tasks.v1"
assert p["reviewed"] is False
assert p["transcript_source"] == "agentic-loop-kit"
assert len(p["tasks"]) == 2
by_id = {t["id"]: t for t in p["tasks"]}
assert by_id["T001"]["outcome"] == "success"
assert by_id["T002"]["outcome"] == "fail"
assert "health" in by_id["T001"]["intent"].lower()
print("[skillopt_export] self-test ok")
PY
  exit 0
fi

[[ -d "$ROOT/loop" ]] || die "no loop/ under $ROOT — run from an installed kit copy"
run_export "$ROOT" "$out" "$reviewed" "$max_tasks" "$target_skill"

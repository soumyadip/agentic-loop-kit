#!/usr/bin/env bash
# Prints the task dependency graph built from every loop/queue/*/ file's `depends_on:`
# frontmatter — the DAG new_task.sh already lets you build (see loop/README.md's "Adding
# tasks"), otherwise only visible by reading each task file's frontmatter by hand. Read-only:
# never touches queue/ or any task file.
#
# Usage:
#   loop/queue_graph.sh              # plain-text list, one task per line
#   loop/queue_graph.sh --mermaid    # mermaid flowchart (paste into any markdown viewer)
#   loop/queue_graph.sh --self-test
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
QUEUE="$ROOT/loop/queue"

die() { echo "[queue_graph] $*" >&2; exit 1; }

format="text"
self_test=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --mermaid) format="mermaid"; shift ;;
    --text) format="text"; shift ;;
    --self-test) self_test=1; shift ;;
    -h|--help)
      sed -n '2,9p' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *) die "unknown option: $1 (see --help)" ;;
  esac
done

# Reads every loop/queue/{pending,in_progress,blocked,done}/T*.md under $1, prints the graph in
# $2 format ("text" or "mermaid"). Split out as its own function (rather than inlined below) so
# --self-test can point it at a throwaway fixture dir instead of this repo's real queue.
run_graph() {
  local queue_dir="$1" fmt="$2"
  python3 - "$queue_dir" "$fmt" <<'PY'
import re
import sys
from pathlib import Path

QUEUE = Path(sys.argv[1])
FMT = sys.argv[2]
BUCKETS = ("pending", "in_progress", "blocked", "done")

tasks = {}  # id -> {bucket, title, depends_on}
for bucket in BUCKETS:
    d = QUEUE / bucket
    if not d.is_dir():
        continue
    for f in sorted(d.glob("T*.md")):
        text = f.read_text(encoding="utf-8", errors="replace")
        m = re.search(r"^id:\s*(\S+)", text, re.M)
        task_id = m.group(1) if m else f.stem.split("-")[0]
        dep_m = re.search(r"^depends_on:\s*\[(.*?)\]", text, re.M)
        deps = [d.strip() for d in dep_m.group(1).split(",")] if dep_m else []
        deps = [d for d in deps if d]
        title_m = re.search(r"^#\s+(.+)$", text, re.M)
        title = title_m.group(1).strip() if title_m else f.stem
        tasks[task_id] = {"bucket": bucket, "title": title, "depends_on": deps}

if not tasks:
    print("[queue_graph] no task files found under loop/queue/", file=sys.stderr)
    raise SystemExit(0)


def dep_label(dep: str) -> str:
    other = tasks.get(dep)
    if other is None:
        return f"{dep} (missing!)"
    return f"{dep} ({other['bucket']})"


def readiness(task_id: str):
    t = tasks[task_id]
    if t["bucket"] != "pending":
        return None
    for dep in t["depends_on"]:
        if tasks.get(dep, {}).get("bucket") != "done":
            return False
    return True


if FMT == "mermaid":
    print("flowchart LR")
    for tid, t in sorted(tasks.items()):
        safe_title = t["title"].replace('"', "'")
        print(f'  {tid}["{tid}: {safe_title}\\n[{t["bucket"]}]"]')
    for tid, t in sorted(tasks.items()):
        for dep in t["depends_on"]:
            if dep in tasks:
                print(f"  {dep} --> {tid}")
else:
    for tid, t in sorted(tasks.items()):
        line = f"{tid} [{t['bucket']}] {t['title']}"
        if t["depends_on"]:
            line += " — needs: " + ", ".join(dep_label(d) for d in t["depends_on"])
        ready = readiness(tid)
        if ready is True:
            line += "  [ready to claim]"
        elif ready is False:
            line += "  [blocked on dependency]"
        print(line)
PY
}

if (( self_test )); then
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/queue-graph-selftest.XXXXXX")"
  trap 'rm -rf "$tmp"' EXIT
  mkdir -p "$tmp/pending" "$tmp/done"

  cat > "$tmp/done/T001-first.md" <<'EOF'
---
id: T001
depends_on: []
---

# First task
EOF

  cat > "$tmp/pending/T002-second.md" <<'EOF'
---
id: T002
depends_on: [T001]
---

# Second task
EOF

  cat > "$tmp/pending/T003-third.md" <<'EOF'
---
id: T003
depends_on: [T002]
---

# Third task
EOF

  out=$(run_graph "$tmp" "text")
  echo "$out" | grep -qE 'T002 \[pending\].*\[ready to claim\]' \
    || die "self-test: expected T002 ready (its only dependency T001 is done): $out"
  echo "$out" | grep -qE 'T003 \[pending\].*\[blocked on dependency\]' \
    || die "self-test: expected T003 blocked (its dependency T002 is still pending): $out"

  mermaid_out=$(run_graph "$tmp" "mermaid")
  echo "$mermaid_out" | grep -q "^flowchart LR$" || die "self-test: expected a mermaid flowchart header: $mermaid_out"
  echo "$mermaid_out" | grep -q "T001 --> T002" || die "self-test: expected T001 --> T002 edge: $mermaid_out"

  echo "[queue_graph] self-test ok"
  exit 0
fi

[[ -d "$QUEUE" ]] || die "no loop/queue/ under $ROOT — run from an installed kit copy"
run_graph "$QUEUE" "$format"

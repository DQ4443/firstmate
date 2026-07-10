#!/usr/bin/env bash
# Show live and recent Codex build/review workers from state/codex-workers.json.
set -euo pipefail

usage() {
  cat >&2 <<'EOF'
Usage:
  fm-codex-status.sh
  fm-codex-status.sh <task-id>
  fm-codex-status.sh --follow <task-id>
EOF
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
REGISTRY="$STATE/codex-workers.json"

if [ "$#" -eq 0 ]; then
  if [ ! -f "$REGISTRY" ]; then
    printf 'no codex workers yet\n'
    exit 0
  fi
  python3 - "$REGISTRY" <<'PY'
import json
import os
import sys
import time

path = sys.argv[1]
now = int(time.time())
try:
    with open(path, "r", encoding="utf-8") as handle:
        data = json.load(handle)
except Exception as exc:
    print(f"fm-codex-status: registry is invalid: {exc}", file=sys.stderr)
    sys.exit(1)
workers = data.get("workers", [])
if not isinstance(workers, list) or not workers:
    print("no codex workers yet")
    sys.exit(0)

def when(worker):
    return worker.get("ended_at") or worker.get("started_at") or 0

def elapsed(worker):
    started = worker.get("started_at")
    ended = worker.get("ended_at")
    if not isinstance(started, int):
        return ""
    stop = ended if isinstance(ended, int) else now
    seconds = max(0, stop - started)
    if seconds < 60:
        return f"{seconds}s"
    minutes, seconds = divmod(seconds, 60)
    if minutes < 60:
        return f"{minutes}m{seconds:02d}s"
    hours, minutes = divmod(minutes, 60)
    return f"{hours}h{minutes:02d}m"

rows = sorted(
    [worker for worker in workers if isinstance(worker, dict)],
    key=lambda worker: (worker.get("status") == "running", when(worker)),
    reverse=True,
)
headers = ["task_id", "kind", "repo", "branch", "status", "elapsed", "last_line"]
table = []
for worker in rows:
    table.append([
        str(worker.get("task_id") or ""),
        str(worker.get("kind") or ""),
        os.path.basename(str(worker.get("repo") or "")),
        str(worker.get("branch") or ""),
        str(worker.get("status") or ""),
        elapsed(worker),
        str(worker.get("last_line") or ""),
    ])
widths = [len(header) for header in headers]
for row in table:
    for idx, value in enumerate(row):
        widths[idx] = min(max(widths[idx], len(value)), 48 if idx == 6 else 24)

def cell(value, idx):
    value = value[:widths[idx]]
    return value.ljust(widths[idx])

print("  ".join(cell(header, idx) for idx, header in enumerate(headers)))
for row in table:
    print("  ".join(cell(value, idx) for idx, value in enumerate(row)))
PY
  exit 0
fi

if [ "$#" -eq 2 ] && [ "$1" = "--follow" ]; then
  task_id=$2
  [ -f "$REGISTRY" ] || { echo "fm-codex-status: no registry at $REGISTRY" >&2; exit 1; }
  log_path=$(python3 - "$REGISTRY" "$task_id" <<'PY'
import json
import sys

path, task_id = sys.argv[1:]
try:
    with open(path, "r", encoding="utf-8") as handle:
        data = json.load(handle)
except Exception as exc:
    print(f"fm-codex-status: registry is invalid: {exc}", file=sys.stderr)
    sys.exit(1)
for worker in data.get("workers", []):
    if isinstance(worker, dict) and worker.get("task_id") == task_id:
        print(worker.get("log") or "")
        sys.exit(0)
sys.exit(1)
PY
) || { echo "fm-codex-status: no worker for task_id $task_id" >&2; exit 1; }
  [ -n "$log_path" ] || { echo "fm-codex-status: worker $task_id has no log path" >&2; exit 1; }
  exec tail -f "$log_path"
fi

if [ "$#" -eq 1 ]; then
  task_id=$1
  if [ "$task_id" = "-h" ] || [ "$task_id" = "--help" ]; then usage; exit 0; fi
  [ -f "$REGISTRY" ] || { echo "fm-codex-status: no registry at $REGISTRY" >&2; exit 1; }
  python3 - "$REGISTRY" "$task_id" <<'PY'
import json
import sys

path, task_id = sys.argv[1:]
try:
    with open(path, "r", encoding="utf-8") as handle:
        data = json.load(handle)
except Exception as exc:
    print(f"fm-codex-status: registry is invalid: {exc}", file=sys.stderr)
    sys.exit(1)
for worker in data.get("workers", []):
    if isinstance(worker, dict) and worker.get("task_id") == task_id:
        print(json.dumps(worker, indent=2, sort_keys=True))
        log = worker.get("log")
        print("")
        print("last 40 log lines:")
        if not log:
            print("(no log path)")
            sys.exit(0)
        try:
            with open(log, "r", encoding="utf-8", errors="replace") as handle:
                lines = handle.readlines()[-40:]
        except OSError as exc:
            print(f"(could not read log: {exc})")
            sys.exit(0)
        for line in lines:
            print(line.rstrip("\n"))
        sys.exit(0)
print(f"fm-codex-status: no worker for task_id {task_id}", file=sys.stderr)
sys.exit(1)
PY
  exit 0
fi

usage
exit 2

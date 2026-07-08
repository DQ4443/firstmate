#!/usr/bin/env bash
# Run a read-only Codex review fan-out over a repository diff.
# Usage: fm-codex-review.sh <repo-dir> <review-brief-file> [--diff-base <ref>]
set -euo pipefail

usage() {
  cat >&2 <<'EOF'
Usage: fm-codex-review.sh <repo-dir> <review-brief-file> [--diff-base <ref>]

Runs Codex in read-only mode and emits:
{repo, diff_base, findings: [{severity, file, summary}], verdict}
EOF
}

die_usage() {
  echo "error: $1" >&2
  usage
  exit 2
}

json_escape() {
  local s=${1:-}
  s=${s//\\/\\\\}
  s=${s//\"/\\\"}
  s=${s//$'\n'/\\n}
  s=${s//$'\r'/\\r}
  s=${s//$'\t'/\\t}
  printf '%s' "$s"
}

compact_text() {
  printf '%s' "${1:-}" | tr '\r\n\t' '   '
}

codex_registry_update() {
  local status=$1 reason=$2
  [ -n "${TASK_ID:-}" ] || return 0
  [ -n "${REPO:-}" ] || return 0
  [ -n "${STDOUT_FILE:-}" ] || return 0
  python3 - "${FM_STATE:-}" "$TASK_ID" review "$REPO" "$status" "$STDOUT_FILE" "$reason" <<'PY' >/dev/null 2>&1 || true
import json
import os
import sys
import time

state, task_id, kind, repo, status, log_path, reason = sys.argv[1:]
if not state:
    sys.exit(0)
path = os.path.join(state, "codex-workers.json")
lock = os.path.join(state, ".codex-workers.lock")
now = int(time.time())
lock_stale_seconds = int(os.environ.get("FM_CODEX_REGISTRY_LOCK_STALE_SECONDS", "30"))
lock_owner = os.path.join(lock, "owner.json")
lock_token = f"{os.getpid()}-{time.time_ns()}"

def last_non_empty_line(name):
    try:
        with open(name, "r", encoding="utf-8", errors="replace") as handle:
            last = ""
            for line in handle:
                text = line.strip()
                if text:
                    last = text
            return last[:200]
    except OSError:
        return ""

record = {
    "task_id": task_id,
    "kind": kind,
    "repo": repo,
    "branch": None,
    "status": status,
    "started_at": now,
    "ended_at": None if status == "running" else now,
    "commit_sha": None,
    "log": os.path.abspath(log_path),
    "last_line": last_non_empty_line(log_path),
    "reason": reason[:200],
}

os.makedirs(state, exist_ok=True)
locked = False

def pid_alive(pid):
    try:
        os.kill(pid, 0)
        return True
    except ProcessLookupError:
        return False
    except PermissionError:
        return True
    except OSError:
        return False

def remove_stale_lock():
    try:
        lock_age = time.time() - os.stat(lock).st_mtime
    except OSError:
        return False
    if lock_age < lock_stale_seconds:
        return False
    try:
        with open(lock_owner, "r", encoding="utf-8") as handle:
            owner = json.load(handle)
        owner_pid = int(owner.get("pid") or 0)
    except Exception:
        owner_pid = 0
    if owner_pid and pid_alive(owner_pid):
        return False
    try:
        for name in os.listdir(lock):
            os.unlink(os.path.join(lock, name))
        os.rmdir(lock)
        return True
    except OSError:
        return False

for _ in range(20):
    try:
        os.mkdir(lock)
        try:
            with open(lock_owner, "w", encoding="utf-8") as handle:
                json.dump({"pid": os.getpid(), "token": lock_token, "created_at": now}, handle)
        except OSError:
            try:
                os.rmdir(lock)
            except OSError:
                pass
            sys.exit(0)
        locked = True
        break
    except FileExistsError:
        if remove_stale_lock():
            continue
        time.sleep(0.05)
if not locked:
    sys.exit(0)
try:
    try:
        with open(path, "r", encoding="utf-8") as handle:
            data = json.load(handle)
        if not isinstance(data, dict) or not isinstance(data.get("workers"), list):
            data = {"workers": []}
    except Exception:
        data = {"workers": []}
    workers = []
    prior = None
    for worker in data.get("workers", []):
        if isinstance(worker, dict) and worker.get("task_id") == task_id:
            prior = worker
        else:
            workers.append(worker)
    if prior:
        record["started_at"] = prior.get("started_at") or record["started_at"]
    workers.append(record)
    indexed = [(idx, worker) for idx, worker in enumerate(workers) if isinstance(worker, dict)]
    workers = [
        worker
        for _, worker in sorted(
            indexed,
            key=lambda item: (
                item[1].get("ended_at") is None,
                item[1].get("ended_at") or item[1].get("started_at") or 0,
                item[0],
            ),
            reverse=True,
        )
    ][:50]
    out = {"updated_at": now, "workers": workers}
    tmp = f"{path}.tmp.{os.getpid()}"
    with open(tmp, "w", encoding="utf-8") as handle:
        json.dump(out, handle, separators=(",", ":"))
        handle.write("\n")
    os.replace(tmp, path)
finally:
    try:
        with open(lock_owner, "r", encoding="utf-8") as handle:
            owner = json.load(handle)
        if owner.get("token") == lock_token:
            os.unlink(lock_owner)
            os.rmdir(lock)
    except OSError:
        pass
    except Exception:
        pass
PY
}

emit_manual_failure() {
  local severity=$1 file=$2 summary=$3
  codex_registry_update failed "$summary"
  printf '{"repo":"%s","diff_base":"%s","findings":[{"severity":"%s","file":"%s","summary":"%s"}],"verdict":"concerns"}\n' \
    "$(json_escape "${REPO:-}")" \
    "$(json_escape "${DIFF_BASE:-}")" \
    "$(json_escape "$severity")" \
    "$(json_escape "$file")" \
    "$(json_escape "$(compact_text "$summary")")"
}

canonical_dir() {
  local path=$1
  [ -d "$path" ] || return 1
  cd "$path" && pwd -P
}

canonical_file() {
  local path=$1 dir base
  [ -f "$path" ] || return 1
  dir=$(dirname "$path")
  base=$(basename "$path")
  dir=$(canonical_dir "$dir") || return 1
  printf '%s/%s\n' "$dir" "$base"
}

repo_root() {
  local path=$1 top
  top=$(git -C "$path" rev-parse --show-toplevel 2>/dev/null) || return 1
  canonical_dir "$top"
}

ref_has_safe_shape() {
  case "$1" in
    ''|-*|*[$'\n\r\t ']*)
      return 1
      ;;
  esac
  return 0
}

shell_quote() {
  printf "'"
  printf '%s' "$1" | sed "s/'/'\\\\''/g"
  printf "'"
}

make_temp_file() {
  mktemp "${TMPDIR:-/tmp}/fm-codex-review.XXXXXX"
}

make_stdout_log() {
  local dir file
  dir="$FM_STATE/codex-worker-logs"
  file="$dir/$TASK_ID.codex.stdout.log"
  if mkdir -p "$dir" 2>/dev/null && : > "$file" 2>/dev/null; then
    STDOUT_DURABLE=1
    STDOUT_FILE=$file
  else
    STDOUT_DURABLE=0
    STDOUT_FILE=$(make_temp_file)
  fi
}

cleanup() {
  [ "${STDOUT_DURABLE:-0}" = 1 ] || [ -z "${STDOUT_FILE:-}" ] || rm -f "$STDOUT_FILE"
  [ -z "${STDERR_FILE:-}" ] || rm -f "$STDERR_FILE"
  [ -z "${MSG_FILE:-}" ] || rm -f "$MSG_FILE"
}
trap cleanup EXIT

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
FM_STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

REPO_ARG=${1:-}
BRIEF_ARG=${2:-}
[ "$#" -ge 2 ] || die_usage "missing required arguments"
shift 2

DIFF_BASE=main
while [ "$#" -gt 0 ]; do
  case "$1" in
    --diff-base)
      [ "$#" -ge 2 ] || die_usage "--diff-base requires a value"
      DIFF_BASE=$2
      shift 2
      ;;
    --diff-base=*)
      DIFF_BASE=${1#--diff-base=}
      [ -n "$DIFF_BASE" ] || die_usage "--diff-base requires a value"
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      die_usage "unknown argument: $1"
      ;;
  esac
done

ref_has_safe_shape "$DIFF_BASE" || die_usage "--diff-base must be a non-empty git ref without whitespace or a leading dash"
REPO=$(canonical_dir "$REPO_ARG") || die_usage "repo-dir does not exist or is not a directory: $REPO_ARG"
REPO=$(repo_root "$REPO") || die_usage "repo-dir is not inside a git repository: $REPO_ARG"
BRIEF=$(canonical_file "$BRIEF_ARG") || die_usage "review-brief-file does not exist or is not a file: $BRIEF_ARG"
[ -r "$BRIEF" ] || die_usage "review-brief-file is not readable: $BRIEF"
BRIEF_BASE=$(basename "$BRIEF")
TASK_ID="${FM_CODEX_TASK_ID:-review-${BRIEF_BASE%.*}-$$}"
make_stdout_log
STDERR_FILE=$(make_temp_file)
MSG_FILE=$(make_temp_file)
codex_registry_update running "starting codex review"

if ! command -v jq >/dev/null 2>&1; then
  emit_manual_failure high "" "jq is required to normalize Codex review output"
  exit 1
fi
if ! command -v codex >/dev/null 2>&1; then
  emit_manual_failure high "" "codex is not installed or not on PATH"
  exit 1
fi
if ! git -C "$REPO" rev-parse --verify "$DIFF_BASE^{commit}" >/dev/null 2>&1; then
  emit_manual_failure high "" "diff base does not resolve to a commit: $DIFF_BASE"
  exit 1
fi

REVIEW_BRIEF=$(cat "$BRIEF")
DIFF_BASE_ARG=$(shell_quote "$DIFF_BASE")
PROMPT=$(cat <<EOF
You are the GPT-5.5 review parent for firstmate.
Run a read-only review of this repository diff.

Repository: $REPO
Diff base ref: $DIFF_BASE

Review brief:
$REVIEW_BRIEF

Use Codex native parallel subagents.
Spawn three read-only subagents in parallel: correctness, security, and regressions.
Each subagent should inspect the current diff with git diff --stat $DIFF_BASE_ARG...HEAD -- and git diff --no-ext-diff $DIFF_BASE_ARG...HEAD --, then read any relevant surrounding files.
Consolidate duplicate findings.
Return only JSON, with no markdown and no prose.
The JSON may be either a findings array or an object with findings and verdict.
Each finding must have severity, file, and summary.
Use verdict "pass" only when there are no findings, otherwise use "concerns".
EOF
)

# --output-last-message writes ONLY the agent's final message (the JSON we asked
# for), stripping the session/tool/token chatter that codex exec prints to stdout
# and that would otherwise make jq fail on every run (review reported as a false
# "concerns" failure). We parse that file, not raw stdout.
CODEX_RC=0
if codex exec --model gpt-5.5 -c model_reasoning_effort=xhigh --sandbox read-only \
  --skip-git-repo-check -o "$MSG_FILE" -C "$REPO" "$PROMPT" >"$STDOUT_FILE" 2>"$STDERR_FILE"; then
  CODEX_RC=0
else
  CODEX_RC=$?
fi

if [ "$CODEX_RC" -ne 0 ]; then
  STDERR_TAIL=$(tail -20 "$STDERR_FILE" 2>/dev/null || true)
  emit_manual_failure high "" "codex review failed with exit $CODEX_RC: $STDERR_TAIL"
  exit 1
fi

NORMALIZED=$(jq -c '
  def as_text: if . == null then "" else tostring end;
  if type == "array" then
    {findings: ., verdict: (if length == 0 then "pass" else "concerns" end)}
  elif type == "object" then
    {findings: (.findings // []), verdict: (.verdict // "")}
  else
    error("expected object or array")
  end
  | if (.findings | type) != "array" then error("findings must be an array") else . end
  # rawcount is the count BEFORE dropping non-object entries, so a malformed
  # non-empty findings array cannot be filtered down to empty and reported as a
  # false "pass". Any findings at all (valid or malformed) => concerns (fail closed).
  | .rawcount = (.findings | length)
  | .findings = [
      .findings[]
      | select(type == "object")
      | {
          severity: ((.severity // "medium") | as_text),
          file: ((.file // "") | as_text),
          summary: ((.summary // .message // .title // "") | as_text)
        }
    ]
  | .verdict =
      (if (.rawcount == 0 and .verdict != "concerns") then "pass" else "concerns" end)
  | del(.rawcount)
' < <(sed -e 's/^[[:space:]]*```[a-zA-Z]*[[:space:]]*$//' "$MSG_FILE") 2>/dev/null) || {
  MSG_TAIL=$(tail -20 "$MSG_FILE" 2>/dev/null || true)
  emit_manual_failure high "" "codex review returned invalid JSON: $MSG_TAIL"
  exit 1
}

codex_registry_update ok "codex review completed"
jq -c -n \
  --arg repo "$REPO" \
  --arg diff_base "$DIFF_BASE" \
  --argjson review "$NORMALIZED" \
  '{repo: $repo, diff_base: $diff_base, findings: $review.findings, verdict: $review.verdict}'

#!/usr/bin/env bash
# Run a Codex build worker in an isolated repository worktree.
# Usage: fm-codex-build.sh <task-id> <repo-dir> <brief-file> [--base <branch>]
set -euo pipefail

usage() {
  cat >&2 <<'EOF'
Usage: fm-codex-build.sh <task-id> <repo-dir> <brief-file> [--base <branch>]

Creates <repo-dir>/.claude/worktrees/<task-id> on branch feat/<task-id>,
runs Codex there, then requires at least one commit and a clean worktree.
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
  local status=$1 commit_sha=$2 reason=$3
  [ -n "${TASK_ID:-}" ] || return 0
  [ -n "${REPO:-}" ] || return 0
  [ -n "${STDOUT_LOG:-}" ] || return 0
  python3 - "${FM_STATE:-}" "$TASK_ID" build "$REPO" "${BRANCH:-}" "$status" "$commit_sha" "$STDOUT_LOG" "$reason" <<'PY' >/dev/null 2>&1 || true
import json
import os
import sys
import time

state, task_id, kind, repo, branch, status, commit_sha, log_path, reason = sys.argv[1:]
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
    "branch": branch,
    "status": status,
    "started_at": now,
    "ended_at": None if status == "running" else now,
    "commit_sha": commit_sha or None,
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

emit_result() {
  local status=$1 commit_sha=$2 reason=$3
  printf '{"task_id":"%s","status":"%s","repo":"%s","worktree":"%s","branch":"%s","base":"%s","commit_sha":"%s","reason":"%s"}\n' \
    "$(json_escape "${TASK_ID:-}")" \
    "$(json_escape "$status")" \
    "$(json_escape "${REPO:-}")" \
    "$(json_escape "${WORKTREE:-}")" \
    "$(json_escape "${BRANCH:-}")" \
    "$(json_escape "${BASE_REF:-}")" \
    "$(json_escape "$commit_sha")" \
    "$(json_escape "$(compact_text "$reason")")"
}

fail_result() {
  codex_registry_update failed "${COMMIT_SHA:-}" "$1"
  emit_result failed "${COMMIT_SHA:-}" "$1"
  exit 1
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

default_base_ref() {
  local repo=$1 origin_ref name branch
  origin_ref=$(git -C "$repo" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null || true)
  if [ -n "$origin_ref" ]; then
    name=${origin_ref#origin/}
    if git -C "$repo" show-ref --verify --quiet "refs/heads/$name"; then
      printf '%s\n' "$name"
    else
      printf '%s\n' "$origin_ref"
    fi
    return 0
  fi
  for branch in main master; do
    if git -C "$repo" show-ref --verify --quiet "refs/heads/$branch"; then
      printf '%s\n' "$branch"
      return 0
    fi
  done
  return 1
}

ref_has_safe_shape() {
  case "$1" in
    ''|-*|*[$'\n\r\t ']*)
      return 1
      ;;
  esac
  return 0
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
FM_STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

TASK_ID=${1:-}
REPO_ARG=${2:-}
BRIEF_ARG=${3:-}
[ "$#" -ge 3 ] || die_usage "missing required arguments"
shift 3

BASE_ARG=
while [ "$#" -gt 0 ]; do
  case "$1" in
    --base)
      [ "$#" -ge 2 ] || die_usage "--base requires a value"
      BASE_ARG=$2
      shift 2
      ;;
    --base=*)
      BASE_ARG=${1#--base=}
      [ -n "$BASE_ARG" ] || die_usage "--base requires a value"
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

case "$TASK_ID" in
  [A-Za-z0-9]*)
    ;;
  *)
    die_usage "task-id must start with an ASCII letter or digit"
    ;;
esac
case "$TASK_ID" in
  *[!A-Za-z0-9._-]*)
    die_usage "task-id may contain only ASCII letters, digits, dot, underscore, and dash"
    ;;
esac

REPO=$(canonical_dir "$REPO_ARG") || die_usage "repo-dir does not exist or is not a directory: $REPO_ARG"
REPO=$(repo_root "$REPO") || die_usage "repo-dir is not inside a git repository: $REPO_ARG"
BRIEF=$(canonical_file "$BRIEF_ARG") || die_usage "brief-file does not exist or is not a file: $BRIEF_ARG"
[ -r "$BRIEF" ] || die_usage "brief-file is not readable: $BRIEF"

if [ -n "$BASE_ARG" ]; then
  ref_has_safe_shape "$BASE_ARG" || die_usage "--base must be a non-empty git ref without whitespace or a leading dash"
  BASE_REF=$BASE_ARG
else
  BASE_REF=$(default_base_ref "$REPO") || die_usage "could not resolve the repo default branch"
fi
ref_has_safe_shape "$BASE_REF" || die_usage "resolved base ref is unsafe: $BASE_REF"

WORKTREES_DIR="$REPO/.claude/worktrees"
WORKTREE="$WORKTREES_DIR/$TASK_ID"
BRANCH="feat/$TASK_ID"
COMMIT_SHA=
GIT_LOG="$WORKTREES_DIR/$TASK_ID.git-worktree.log"
STDOUT_LOG="$WORKTREES_DIR/$TASK_ID.codex.stdout.log"
STDERR_LOG="$WORKTREES_DIR/$TASK_ID.codex.stderr.log"
mkdir -p "$WORKTREES_DIR" || fail_result "could not create worktrees directory: $WORKTREES_DIR"
: > "$STDOUT_LOG" 2>/dev/null || true
codex_registry_update running "" "starting codex build"

command -v codex >/dev/null 2>&1 || fail_result "codex is not installed or not on PATH"
BASE_COMMIT=$(git -C "$REPO" rev-parse --verify "$BASE_REF^{commit}" 2>/dev/null) \
  || fail_result "base ref does not resolve to a commit: $BASE_REF"
if git -C "$REPO" show-ref --verify --quiet "refs/heads/$BRANCH"; then
  fail_result "branch already exists: $BRANCH"
fi
[ ! -e "$WORKTREE" ] || fail_result "worktree path already exists: $WORKTREE"

# Use a self-contained local CLONE (not a linked worktree) as the worker
# workspace. A linked worktree's git metadata lives under the parent repo's
# .git, outside codex's workspace-write sandbox, so the worker cannot commit
# (commit-before-return fails). A clone keeps its .git inside the workspace dir,
# so committing works under the sandbox while isolation is preserved; objects are
# shared via hardlinks so the clone is cheap. firstmate fetches the branch back.
if ! git clone --quiet --local "$REPO" "$WORKTREE" >"$GIT_LOG" 2>&1; then
  fail_result "git clone (local) failed; log: $GIT_LOG"
fi
if ! git -C "$WORKTREE" checkout -q -B "$BRANCH" "origin/$BASE_REF" >>"$GIT_LOG" 2>&1 \
  && ! git -C "$WORKTREE" checkout -q -B "$BRANCH" "$BASE_REF" >>"$GIT_LOG" 2>&1; then
  fail_result "git checkout base failed in clone; log: $GIT_LOG"
fi

# Anchor the commit-count gate to the EXACT commit the worker starts from (the
# clone's HEAD after checkout), NOT the parent-resolved BASE_COMMIT. git clone
# --local maps the parent's local branches to the clone's origin/*, so a parent
# whose local branch is ahead of its own remote-tracking ref would otherwise let
# a zero-change worker pass the ">= 1 commit" gate (silent success on failure).
BASE_COMMIT=$(git -C "$WORKTREE" rev-parse --verify HEAD 2>/dev/null) \
  || fail_result "could not resolve clone HEAD after checkout of $BASE_REF"

PROMPT=$(cat "$BRIEF") || fail_result "could not read brief-file: $BRIEF"
CODEX_RC=0
if codex exec --model gpt-5.5 -c model_reasoning_effort=xhigh --sandbox workspace-write \
  --skip-git-repo-check -C "$WORKTREE" "$PROMPT" >"$STDOUT_LOG" 2>"$STDERR_LOG"; then
  CODEX_RC=0
else
  CODEX_RC=$?
fi

# codex's workspace-write sandbox makes .git read-only, so the worker can write
# files but cannot commit. The harness (firstmate, unsandboxed and trusted)
# commits the worker's output. The workspace is an isolated fresh clone that
# contains ONLY the worker's changes (firstmate's editor hooks do not fire in
# the codex sandbox, verified: the worker's tree shows only its intended files),
# so staging everything is the worker's deliverable, not ambient noise.
if [ -n "$(git -C "$WORKTREE" status --porcelain)" ]; then
  git -C "$WORKTREE" add -A >>"$GIT_LOG" 2>&1 \
    || fail_result "harness could not stage worker output; log: $GIT_LOG"
  git -C "$WORKTREE" -c user.name="firstmate-codex" -c user.email="codex@firstmate.local" \
    commit -q -m "codex worker: $TASK_ID" >>"$GIT_LOG" 2>&1 \
    || fail_result "harness could not commit worker output; log: $GIT_LOG"
fi

COMMIT_SHA=$(git -C "$WORKTREE" rev-parse --verify HEAD 2>/dev/null) \
  || fail_result "worker returned without a valid HEAD commit"
COMMIT_COUNT=$(git -C "$WORKTREE" rev-list --count "$BASE_COMMIT..HEAD" 2>/dev/null || printf '0')
case "$COMMIT_COUNT" in
  ''|*[!0-9]*)
    fail_result "could not count worker commits beyond $BASE_REF"
    ;;
esac
if [ "$COMMIT_COUNT" -lt 1 ]; then
  fail_result "worker returned without a commit beyond $BASE_REF"
fi

DIRTY=$(git -C "$WORKTREE" status --porcelain)
if [ -n "$DIRTY" ]; then
  FIRST_DIRTY=${DIRTY%%$'\n'*}
  fail_result "worker returned with a dirty tree: $FIRST_DIRTY"
fi

if [ "$CODEX_RC" -ne 0 ]; then
  fail_result "codex exec failed with exit $CODEX_RC; stdout log: $STDOUT_LOG; stderr log: $STDERR_LOG"
fi

# Bring the worker's branch back into the parent repo so firstmate can review,
# push, and PR it from there. The clone remains for teardown/inspection.
if ! git -C "$REPO" fetch --quiet "$WORKTREE" "$BRANCH:$BRANCH" >>"$GIT_LOG" 2>&1; then
  fail_result "could not fetch worker branch back into parent repo; log: $GIT_LOG"
fi

# On success the worker's commit is safely on feat/<task-id> in the parent repo,
# so the clone is disposable scratch. It is a plain clone, not a linked worktree,
# so fm-teardown.sh --worktree (which only disposes linked worktrees via the
# landed-check) does not and should not manage it; remove it here to keep clones
# from accumulating. On FAILURE the clone is deliberately left for inspection
# (fail paths never reach this line). The sibling *.log files are preserved.
rm -rf "${WORKTREE:?}" 2>/dev/null || true

codex_registry_update ok "$COMMIT_SHA" "codex exec completed; branch fetched into parent; clone removed"
emit_result ok "$COMMIT_SHA" "codex exec completed; branch fetched into parent; clone removed; stdout log: $STDOUT_LOG; stderr log: $STDERR_LOG"

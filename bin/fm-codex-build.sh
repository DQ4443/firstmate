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

command -v codex >/dev/null 2>&1 || fail_result "codex is not installed or not on PATH"
BASE_COMMIT=$(git -C "$REPO" rev-parse --verify "$BASE_REF^{commit}" 2>/dev/null) \
  || fail_result "base ref does not resolve to a commit: $BASE_REF"
if git -C "$REPO" show-ref --verify --quiet "refs/heads/$BRANCH"; then
  fail_result "branch already exists: $BRANCH"
fi
[ ! -e "$WORKTREE" ] || fail_result "worktree path already exists: $WORKTREE"
mkdir -p "$WORKTREES_DIR"

GIT_LOG="$WORKTREES_DIR/$TASK_ID.git-worktree.log"
STDOUT_LOG="$WORKTREES_DIR/$TASK_ID.codex.stdout.log"
STDERR_LOG="$WORKTREES_DIR/$TASK_ID.codex.stderr.log"

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

emit_result ok "$COMMIT_SHA" "codex exec completed; branch fetched into parent; clone removed; stdout log: $STDOUT_LOG; stderr log: $STDERR_LOG"

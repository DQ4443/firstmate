#!/usr/bin/env bash
# Smoke test for the Codex build worker primitive.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$SCRIPT_DIR/.." && pwd -P)"
TASK_ID="codex-selftest-$(date +%Y%m%d%H%M%S)-$$"
WORKTREES_DIR="$REPO/.claude/worktrees"
BRIEF="$WORKTREES_DIR/$TASK_ID.brief.md"

mkdir -p "$WORKTREES_DIR"

# The selftest exercises the real build path against the firstmate repo itself,
# which leaves a clone dir, a fetched-back feat/<task-id> branch, a brief, and
# logs. Tear all of it down on exit so repeated runs do not accumulate cruft.
cleanup() {
  rm -rf "${WORKTREES_DIR:?}/${TASK_ID:?}" 2>/dev/null || true
  git -C "$REPO" branch -D "feat/$TASK_ID" >/dev/null 2>&1 || true
  rm -f "$BRIEF" "$WORKTREES_DIR/$TASK_ID".*.log "$WORKTREES_DIR/$TASK_ID.git-worktree.log" 2>/dev/null || true
}
trap cleanup EXIT

cat > "$BRIEF" <<'EOF'
You are an isolated firstmate Codex worker running in a disposable selftest worktree.
Do not dispatch another agent.
Create a file named HELLO.txt containing exactly OK followed by a newline.
Commit the change with the message "selftest: create HELLO.txt".
Return only a short confirmation.
EOF

if OUTPUT=$("$SCRIPT_DIR/fm-codex-build.sh" "$TASK_ID" "$REPO" "$BRIEF"); then
  :
else
  RC=$?
  printf '%s\n' "$OUTPUT"
  echo "fm-codex-selftest: build command failed with exit $RC" >&2
  exit "$RC"
fi

printf '%s\n' "$OUTPUT"

command -v jq >/dev/null 2>&1 || {
  echo "fm-codex-selftest: jq is required to validate the build JSON" >&2
  exit 1
}

STATUS=$(printf '%s\n' "$OUTPUT" | jq -r '.status // empty')
COMMIT_SHA=$(printf '%s\n' "$OUTPUT" | jq -r '.commit_sha // empty')
WORKTREE=$(printf '%s\n' "$OUTPUT" | jq -r '.worktree // empty')

[ "$STATUS" = ok ] || {
  echo "fm-codex-selftest: expected status ok, got ${STATUS:-empty}" >&2
  exit 1
}
[ -n "$COMMIT_SHA" ] || {
  echo "fm-codex-selftest: missing commit_sha" >&2
  exit 1
}
[ -n "$WORKTREE" ] || {
  echo "fm-codex-selftest: missing worktree" >&2
  exit 1
}
# The build removes the clone on success and fetches the worker's branch into the
# parent repo, so verify the commit and its file content via the PARENT repo (this
# also proves the fetch-back half of the contract).
git -C "$REPO" cat-file -e "$COMMIT_SHA^{commit}" || {
  echo "fm-codex-selftest: worker commit not fetched into parent repo: $COMMIT_SHA" >&2
  exit 1
}
[ "$(git -C "$REPO" show "$COMMIT_SHA:HELLO.txt" 2>/dev/null)" = OK ] || {
  echo "fm-codex-selftest: HELLO.txt in the worker commit did not contain OK" >&2
  exit 1
}

echo "fm-codex-selftest: ok task_id=$TASK_ID commit=$COMMIT_SHA"

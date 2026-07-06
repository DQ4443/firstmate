#!/usr/bin/env bash
# tests/fm-write-fence.test.sh - the PreToolUse write fence (bin/fm-write-fence.sh).
#
# Covers the workflow-paradigm boundary: allow isolated worktrees, block David's
# ~/dev/work checkouts AND firstmate's own projects/ clones (the clones are real
# directories, not symlinks into ~/dev/work, so they need their own block), and
# fail open on unusable input. Also exercises the new-file walk-up in resolve()
# so a not-yet-existing path reached through a symlink still resolves into the
# real fenced tree.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v jq >/dev/null 2>&1 || { pass "fm-write-fence: skipped (jq not on PATH; fence fails open without it)"; exit 0; }

# fm_test_tmproot's cleanup trap fires when its command-substitution subshell
# exits, so the dir is transiently removed; recreate it, then resolve its real
# path so the fence's pwd -P comparisons match (macOS /tmp is a symlink).
TMP=$(fm_test_tmproot fm-write-fence)
mkdir -p "$TMP"
TMP=$(cd "$TMP" && pwd -P)

# A controlled firstmate home so the fence's SCRIPT_DIR/.. resolves to a projects/
# tree we own, and a controlled HOME so ~/dev/work and ~/.treehouse are ours.
HOME_T="$TMP/home"
FM="$TMP/fm"
mkdir -p \
  "$HOME_T/dev/work/repo/src" \
  "$HOME_T/dev/work/repo/.claude/worktrees/wt/src" \
  "$HOME_T/.treehouse/lease1/repo/src" \
  "$FM/bin" \
  "$FM/projects/proj/src" \
  "$FM/projects/proj/.claude/worktrees/wt/src" \
  "$FM/data"
cp "$ROOT/bin/fm-write-fence.sh" "$FM/bin/fm-write-fence.sh"
FENCE="$FM/bin/fm-write-fence.sh"

# run_fence <json-payload>; echoes nothing, returns the fence exit code.
run_fence_payload() {
  local payload=$1 rc=0
  printf '%s' "$payload" | HOME="$HOME_T" bash "$FENCE" >/dev/null 2>&1 || rc=$?
  return "$rc"
}

# run_fence_path <file_path>; returns the fence exit code for a Write to that path.
run_fence_path() {
  run_fence_payload "$(printf '{"tool_input":{"file_path":"%s"}}' "$1")"
}

# --- ALLOW cases (exit 0) ---------------------------------------------------

rc=0; run_fence_path "$HOME_T/.treehouse/lease1/repo/src/x.txt" || rc=$?
expect_code 0 "$rc" "treehouse worktree write is allowed"
pass "treehouse worktree write allowed"

rc=0; run_fence_path "$HOME_T/dev/work/repo/.claude/worktrees/wt/src/x.txt" || rc=$?
expect_code 0 "$rc" "work-repo .claude/worktrees write is allowed"
pass "work-repo agent worktree write allowed"

rc=0; run_fence_path "$FM/projects/proj/.claude/worktrees/wt/src/x.txt" || rc=$?
expect_code 0 "$rc" "project-clone .claude/worktrees write is allowed"
pass "project-clone agent worktree write allowed"

rc=0; run_fence_path "$FM/data/notes.md" || rc=$?
expect_code 0 "$rc" "firstmate's own tree write is allowed"
pass "firstmate own-tree write allowed"

# --- BLOCK cases (exit 2) ---------------------------------------------------

rc=0; run_fence_path "$HOME_T/dev/work/repo/src/main.py" || rc=$?
expect_code 2 "$rc" "direct ~/dev/work checkout write is blocked"
pass "direct work-checkout write blocked"

rc=0; run_fence_path "$FM/projects/proj/src/main.py" || rc=$?
expect_code 2 "$rc" "direct projects/ clone write is blocked (F2)"
pass "direct project-clone write blocked (F2 regression guard)"

# New file in a not-yet-existing subdir of a project clone: resolve() must walk
# up to the existing ancestor and still classify it as inside projects/.
rc=0; run_fence_path "$FM/projects/proj/src/newdir/deeper/x.txt" || rc=$?
expect_code 2 "$rc" "new-file-in-new-subdir under projects/ is blocked (F6 walk-up)"
pass "new nested file under project clone blocked (F6 walk-up)"

# A symlink whose target is inside ~/dev/work, writing to a not-yet-existing
# path through it: the old resolve() returned the literal link path and slipped
# past the case match; the walk-up now resolves the symlinked ancestor to the
# real work tree and blocks it.
ln -s "$HOME_T/dev/work/repo" "$TMP/worklink"
rc=0; run_fence_path "$TMP/worklink/src/newsub/x.txt" || rc=$?
expect_code 2 "$rc" "new file via symlink into ~/dev/work is blocked (F6)"
pass "new file via symlink into work tree blocked (F6)"

# --- FAIL-OPEN cases (exit 0) -----------------------------------------------

rc=0; run_fence_payload "" || rc=$?
expect_code 0 "$rc" "empty payload fails open"
pass "empty payload fails open"

rc=0; run_fence_payload '{"tool_input":{}}' || rc=$?
expect_code 0 "$rc" "payload with no path fails open"
pass "no-path payload fails open"

pass "fm-write-fence.test.sh: all cases passed"

#!/usr/bin/env bash
# tests/fm-teardown-worktree.test.sh - bin/fm-teardown.sh --worktree <path> mode.
#
# This is the sanctioned disposal for a worktree with no task meta (a workflow
# worktree). It must run the landed check keyed on the worktree path, refuse
# dirty or unlanded work, refuse a main checkout, and remove only on a pass or
# with --force. No state/<id>.meta is involved.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

fm_git_identity fmtest fmtest@example.invalid

TEARDOWN="$ROOT/bin/fm-teardown.sh"
# fm_test_tmproot's cleanup trap fires when its command-substitution subshell
# exits, so the dir is transiently removed; recreate it, then resolve its real
# path so git's recorded worktree paths match teardown's pwd -P resolution.
TMP=$(fm_test_tmproot fm-teardown-wt)
mkdir -p "$TMP"
TMP=$(cd "$TMP" && pwd -P)

# Isolate all firstmate state and shadow gh so the landed check never
# reaches the network (no origin remote -> the PR path returns "no PR" and the
# content check decides).
export FM_HOME="$TMP/home"
mkdir -p "$FM_HOME/state" "$FM_HOME/data" "$FM_HOME/config"
FAKEBIN=$(fm_fakebin "$TMP")
fm_fake_exit0 "$FAKEBIN" gh
export PATH="$FAKEBIN:$PATH"

# run_teardown_wt <path> [--force]; returns exit code, output on $OUT.
run_teardown_wt() {
  local rc=0
  OUT=$(bash "$TEARDOWN" --worktree "$@" 2>&1) || rc=$?
  return "$rc"
}

# --- case 1: clean, landed (no commits beyond default) -> removed ------------
repo1="$TMP/repo1"; wt1="$TMP/wt1"
fm_git_worktree "$repo1" "$wt1" feature-1   # wt1 HEAD == default branch tip
rc=0; run_teardown_wt "$wt1" || rc=$?
expect_code 0 "$rc" "landed clean worktree tears down (out: $OUT)"
assert_absent "$wt1/.git" "landed worktree directory was removed"
pass "landed clean worktree removed"

# --- case 2: clean, unlanded (new commit not in default, no remote) -> refuse -
repo2="$TMP/repo2"; wt2="$TMP/wt2"
fm_git_worktree "$repo2" "$wt2" feature-2
echo "new work" > "$wt2/feature.txt"
git -C "$wt2" add feature.txt
git -C "$wt2" -c user.name=t -c user.email=t@t commit -qm "unlanded work"
rc=0; run_teardown_wt "$wt2" || rc=$?
expect_code 1 "$rc" "unlanded worktree is refused"
assert_contains "$OUT" "has not landed" "refusal names the unlanded state"
assert_present "$wt2/feature.txt" "refused worktree is left intact"
pass "unlanded worktree refused and preserved"

# --- case 3: dirty worktree -> refuse before landed check -------------------
repo3="$TMP/repo3"; wt3="$TMP/wt3"
fm_git_worktree "$repo3" "$wt3" feature-3
echo "uncommitted" > "$wt3/dirty.txt"
rc=0; run_teardown_wt "$wt3" || rc=$?
expect_code 1 "$rc" "dirty worktree is refused"
assert_contains "$OUT" "uncommitted changes" "refusal names the dirty state"
assert_present "$wt3/dirty.txt" "refused dirty worktree is left intact"
pass "dirty worktree refused and preserved"

# --- case 4: --force discards unlanded work ---------------------------------
rc=0; run_teardown_wt "$wt2" --force || rc=$?
expect_code 0 "$rc" "--force removes unlanded worktree (out: $OUT)"
assert_absent "$wt2/feature.txt" "forced worktree was removed"
pass "--force discards unlanded worktree"

# --- case 5: refuse to remove a main checkout -------------------------------
rc=0; run_teardown_wt "$repo3" || rc=$?
expect_code 1 "$rc" "main checkout is refused"
assert_contains "$OUT" "main checkout" "refusal names the main-checkout guard"
assert_present "$repo3/.git" "main checkout is left intact"
pass "main checkout removal refused"

# --- case 6: missing path argument ------------------------------------------
rc=0; OUT=$(bash "$TEARDOWN" --worktree 2>&1) || rc=$?
expect_code 1 "$rc" "--worktree with no path errors"
assert_contains "$OUT" "requires a path" "missing-path error is explicit"
pass "--worktree with no path errors cleanly"

pass "fm-teardown-worktree.test.sh: all cases passed"

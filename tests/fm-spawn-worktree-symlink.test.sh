#!/usr/bin/env bash
# Regression test for fm-spawn.sh's treehouse-worktree wait loop path comparison.
#
# The loop waits for the pane's cwd to move from the project to the freshly-got
# worktree. The backend reports the pane's REAL cwd (tmux's #{pane_current_path}
# resolves symlinks), but PROJ_ABS was built with `pwd` and can still carry a
# symlink component (macOS /tmp -> /private/tmp, /var -> /private/var; any
# symlinked parent). Comparing the raw strings then reads as "already moved"
# on the very first poll - while the pane is STILL at the project - so the loop
# adopts the project dir as the worktree and validate_spawn_worktree aborts the
# spawn with "did not yield an isolated worktree". The fix canonicalizes both
# sides before comparing.
#
# This drives the REAL wait loop with a fake tmux whose #{pane_current_path}
# returns the project's CANONICAL path on the first read (pane not yet moved,
# symlink-mismatched vs PROJ_ABS) and the worktree on subsequent reads. An
# explicit symlink layer guarantees PROJ_ABS keeps a symlink component on every
# platform, so `pwd` and `pwd -P` genuinely differ.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SPAWN="$ROOT/bin/fm-spawn.sh"
TMP_ROOT=$(fm_test_tmproot fm-spawn-symlink)
fm_git_identity fmtest fmtest@example.invalid

# A fake tmux: session/window ops are no-ops; #{pane_current_path} is dynamic.
make_symlink_fakebin() {  # <dir>
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "$*" in
  *"#{pane_current_path}"*)
    n=$(cat "$FM_FAKE_PANE_CALLS" 2>/dev/null || echo 0)
    n=$((n + 1)); printf '%s' "$n" > "$FM_FAKE_PANE_CALLS"
    # Read 1: pane is STILL at the project, reported in canonical form (the
    # symlink-mismatch vs PROJ_ABS that triggers the bug). Read 2+: it has moved
    # into the worktree.
    if [ "$n" -le 1 ]; then printf '%s\n' "$FM_FAKE_PANE_PROJECT"
    else printf '%s\n' "$FM_FAKE_PANE_WORKTREE"; fi
    exit 0 ;;
esac
case "${1:-}" in
  display-message) printf 'firstmate\n'; exit 0 ;;
  list-windows|has-session|new-session|new-window|kill-window|send-keys) exit 0 ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  fm_fake_exit0 "$fakebin" treehouse
  printf '%s\n' "$fakebin"
}

test_symlinked_project_path_does_not_misdetect_worktree() {
  local case_dir realbase symbase home proj wt fakebin id out status meta
  case_dir="$TMP_ROOT/sym-case"
  realbase="$case_dir/real"
  symbase="$case_dir/link"
  mkdir -p "$realbase"
  # A real repo + worktree under realbase; reference them through a symlink so
  # PROJ_ABS (built with `pwd`) keeps the symlink while the pane reports canonical.
  proj="$realbase/project"
  wt="$realbase/wt"
  fm_git_worktree "$proj" "$wt" "wt-sym"
  ln -s "$realbase" "$symbase"

  home="$symbase/home"
  mkdir -p "$home/data" "$home/state" "$home/config"
  printf 'claude\n' > "$home/config/crew-harness"
  id=spawn-sym-s1
  mkdir -p "$home/data/$id"
  printf 'brief for %s\n' "$id" > "$home/data/$id/brief.md"

  fakebin=$(make_symlink_fakebin "$case_dir/fake")

  out=$(FM_ROOT_OVERRIDE='' FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SPAWN_NO_GUARD=1 TMUX="fake,1,0" \
    FM_FAKE_PANE_CALLS="$case_dir/pane.calls" \
    FM_FAKE_PANE_PROJECT="$(cd "$symbase/project" && pwd -P)" \
    FM_FAKE_PANE_WORKTREE="$(cd "$wt" && pwd -P)" \
    PATH="$fakebin:$PATH" \
    "$SPAWN" "$id" "$symbase/project" 2>&1)
  status=$?

  expect_code 0 "$status" "spawn through a symlinked project path should not misdetect the worktree"
  assert_not_contains "$out" "did not yield an isolated worktree" \
    "symlink path mismatch tripped validate_spawn_worktree (bug 4)"
  assert_contains "$out" "spawned $id" "spawn did not report success"
  meta="$home/state/$id.meta"
  assert_present "$meta" "meta was not written"
  # The recorded worktree must be the real worktree, never the project dir.
  assert_grep "worktree=$(cd "$wt" && pwd -P)" "$meta" "meta worktree is not the real worktree"
  assert_no_grep "worktree=$(cd "$symbase/project" && pwd -P)" "$meta" \
    "meta worktree was misdetected as the project dir"
  pass "fm-spawn canonicalizes paths, so a symlinked project path does not misdetect the worktree"
}

test_symlinked_project_path_does_not_misdetect_worktree

echo "# all fm-spawn-worktree-symlink tests passed"

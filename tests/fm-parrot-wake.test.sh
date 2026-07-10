#!/usr/bin/env bash
# Behavior tests for the parrot event-wake mirror (bin/fm-inject-lib.sh
# fm_inject_parrot_wake + bin/fm-poll.sh maybe_inject_parrot_wake).
#
# All cases are hermetic, fake-tmux style like tests/fm-node.test.sh: a fakebin
# tmux driven by FM_FAKE_* env shadows the real binary, and every case records a
# state/session-pane.env whose FM_SESSION_TMUX_BIN points at that fake, so the
# server-candidate walk in fm_parrot_server commits to the fake on its FIRST
# (recorded) candidate and never falls through to a real tmux server - which on
# a dev machine may hold a LIVE fm-parrot session. Coverage:
#   - delivery: fm-parrot exists -> the parrot nudge is typed into the parrot
#     pane (-l literal send + Enter) and rc is 0
#   - silent no-op: no fm-parrot session -> rc 1, zero send-keys, zero output
#   - vacated pane: fm-parrot exists but its pane runs a bare shell -> rc 1,
#     nothing typed (never inject into a pane the harness left)
#   - deferral: real pending input in the parrot composer -> rc 2, nothing typed
#   - primary unaffected: fm_inject_wake still delivers the PRIMARY prompt to
#     the primary pane in the same environment, before and after a parrot push
#     in the same process
#   - poller loop: the real bin/fm-poll.sh pushes to BOTH targets off one queue
#     seq, advances state/.wake-inject-seq.parrot independently, and stays
#     silent about the parrot when the session is absent
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

INJECT_LIB="$ROOT/bin/fm-inject-lib.sh"
POLL="$ROOT/bin/fm-poll.sh"
TMP_ROOT=$(fm_test_tmproot fm-parrot-wake)
POLL_PID=""

# fm-poll.sh traps TERM/INT only to clean its pidfile and keeps looping, so use
# SIGKILL, and ONLY on our own captured pid (a pattern kill would hit the live
# launchd poller).
kill_poller() {
  [ -n "${POLL_PID:-}" ] || return 0
  kill -KILL "$POLL_PID" 2>/dev/null || true
  wait "$POLL_PID" 2>/dev/null || true
  POLL_PID=""
}
trap 'kill_poller; fm_test_cleanup' EXIT

# Fake tmux, behavior driven by FM_FAKE_* env at call time. Panes: %1 is the
# primary session's pane, %7 the parrot's. Calls arrive as
# `tmux -S <socket> <cmd> ...` (the fm_tmux / fm_inject_run seam always passes
# the recorded socket).
make_fakebin() {  # <dir> -> echoes fakebin path
  local fb="$1/fakebin"
  mkdir -p "$fb"
  cat > "$fb/tmux" <<'SH'
#!/usr/bin/env bash
set -u
[ -z "${FM_FAKE_TMUX_LOG:-}" ] || printf '%s\n' "$*" >> "$FM_FAKE_TMUX_LOG"
if [ "${1:-}" = -S ]; then shift 2; fi
cmd=${1:-}; shift || true
case "$cmd" in
  list-panes)
    if [ "${1:-}" = -a ]; then
      # whole-server probe (fm_parrot_server / fm_inject_validate)
      printf '%%1\n'
      [ "${FM_FAKE_PARROT_EXISTS:-0}" = 1 ] && printf '%%7\n'
      exit 0
    fi
    # session-scoped (-t <session>): only the parrot session is looked up
    [ "${FM_FAKE_PARROT_EXISTS:-0}" = 1 ] || exit 1
    printf '%%7\n' ;;
  has-session)
    [ "${FM_FAKE_PARROT_EXISTS:-0}" = 1 ] && exit 0 || exit 1 ;;
  display-message)
    fmt=""
    for a in "$@"; do fmt=$a; done
    case "$fmt" in
      *cursor_y*) printf '5\n' ;;
      *pane_current_command*) printf '%s\n' "${FM_FAKE_PANE_CMD:-claude}" ;;
      *) printf '\n' ;;
    esac ;;
  capture-pane)
    printf '%s\n' "${FM_FAKE_COMPOSER:->}" ;;
  send-keys) exit 0 ;;
esac
exit 0
SH
  chmod +x "$fb/tmux"
  printf '%s\n' "$fb"
}

# A case dir with its own state/ carrying a session-pane.env that pins the fake
# tmux as the recorded (first, winning) server candidate. The recorded harness
# pid is this test process, which is alive, so primary validation passes.
new_case() {  # <name> -> echoes case dir
  local d="$TMP_ROOT/$1" fb
  mkdir -p "$d/state"
  fb=$(make_fakebin "$d")
  {
    printf 'FM_SESSION_PANE=%%1\n'
    printf 'FM_SESSION_TMUX_SOCKET=%s\n' "$d/fake.sock"
    printf 'FM_SESSION_TMUX_BIN=%s\n' "$fb/tmux"
    printf 'FM_SESSION_HARNESS_PID=%s\n' "$$"
    printf 'FM_SESSION_REGISTERED_AT=%s\n' "$(date +%s)"
  } > "$d/state/session-pane.env"
  printf '%s\n' "$d"
}

# Source the inject lib in a clean subshell against a case dir and run the named
# function(s). Extra KEY=VAL args become exported env for the fake.
run_lib() {  # <case-dir> <env KEY=VAL ...> -- <fn> [fn...]
  local d=$1; shift
  local envs=()
  while [ "${1:-}" != -- ]; do envs+=("$1"); shift; done
  shift
  (
    export FM_STATE_OVERRIDE="$d/state" FM_FAKE_TMUX_LOG="$d/tmux.log"
    [ "${#envs[@]}" -eq 0 ] || export "${envs[@]}"
    # shellcheck disable=SC2030  # PATH shadowing is deliberately subshell-local
    PATH="$d/fakebin:$PATH"
    # shellcheck source=bin/fm-inject-lib.sh
    . "$INJECT_LIB"
    rc=0
    for fn in "$@"; do "$fn" || rc=$?; done
    exit "$rc"
  )
}

PARROT_NUDGE='fm-wake: new board activity is queued. Run bin/fm-wake-drain.sh, then bash bin/fm-board-surface.sh, per your charter.'
PRIMARY_NUDGE='fm-wake: new board activity is queued. Run bin/fm-wake-drain.sh and handle it per AGENTS.md section 2.'

# --- delivery when fm-parrot exists ------------------------------------------

test_parrot_delivered() {
  local d rc=0; d=$(new_case delivered)
  run_lib "$d" FM_FAKE_PARROT_EXISTS=1 -- fm_inject_parrot_wake || rc=$?
  expect_code 0 "$rc" "parrot push returns 0 on confirmed delivery"
  assert_grep "send-keys -t %7 -l $PARROT_NUDGE" "$d/tmux.log" \
    "the parrot nudge is typed literally into the parrot pane"
  assert_grep "send-keys -t %7 Enter" "$d/tmux.log" "the parrot nudge is submitted with Enter"
  pass "fm-parrot exists: the nudge is delivered to the parrot pane"
}

# --- silent no-op when fm-parrot is absent ------------------------------------

test_parrot_absent_is_silent_noop() {
  local d rc=0 out; d=$(new_case absent)
  out=$(run_lib "$d" FM_FAKE_PARROT_EXISTS=0 -- fm_inject_parrot_wake 2>&1) || rc=$?
  expect_code 1 "$rc" "no fm-parrot session returns 1"
  [ -z "$out" ] || fail "absence must be silent, got output: $out"
  assert_no_grep "send-keys" "$d/tmux.log" "nothing is typed anywhere when fm-parrot is absent"
  pass "no fm-parrot session: silent no-op, zero keystrokes"
}

test_parrot_vacated_pane_is_noop() {
  local d rc=0; d=$(new_case vacated)
  run_lib "$d" FM_FAKE_PARROT_EXISTS=1 FM_FAKE_PANE_CMD=bash -- fm_inject_parrot_wake || rc=$?
  expect_code 1 "$rc" "a parrot pane running a bare shell returns 1"
  assert_no_grep "send-keys" "$d/tmux.log" "a vacated parrot pane is never typed into"
  pass "fm-parrot pane without a harness: no-op (vacated-pane guard holds)"
}

# --- deferral on real pending input -------------------------------------------

test_parrot_defers_on_pending_input() {
  local d rc=0; d=$(new_case pending)
  run_lib "$d" FM_FAKE_PARROT_EXISTS=1 FM_FAKE_COMPOSER='drafting a reply to david' \
    -- fm_inject_parrot_wake || rc=$?
  expect_code 2 "$rc" "pending composer input defers the parrot push"
  assert_no_grep "send-keys -t %7 -l" "$d/tmux.log" "no text is typed over pending input"
  pass "real pending input in the parrot composer: push deferred, never forced"
}

# --- the primary session's nudge is unaffected --------------------------------

test_primary_push_unaffected() {
  local d rc=0; d=$(new_case primary)
  run_lib "$d" FM_FAKE_PARROT_EXISTS=1 -- fm_inject_wake || rc=$?
  expect_code 0 "$rc" "primary push still returns 0"
  assert_grep "send-keys -t %1 -l $PRIMARY_NUDGE" "$d/tmux.log" \
    "the primary pane still gets the primary prompt"
  assert_no_grep "send-keys -t %1 -l $PARROT_NUDGE" "$d/tmux.log" \
    "the primary pane never gets the parrot prompt"
  pass "primary session nudge unaffected: same pane, same prompt"
}

test_primary_delivers_after_parrot_in_same_process() {
  local d rc=0; d=$(new_case both)
  run_lib "$d" FM_FAKE_PARROT_EXISTS=1 -- fm_inject_parrot_wake fm_inject_wake || rc=$?
  expect_code 0 "$rc" "both pushes succeed back to back in one process"
  assert_grep "send-keys -t %7 -l $PARROT_NUDGE" "$d/tmux.log" "parrot got the parrot prompt"
  assert_grep "send-keys -t %1 -l $PRIMARY_NUDGE" "$d/tmux.log" "primary still got the primary prompt after the parrot push"
  pass "a parrot push does not corrupt a following primary push (shared fm_tmux target re-committed)"
}

# --- the real poller loop pushes to both targets ------------------------------

# wait_for <secs> <cmd...>: poll until <cmd> succeeds or the deadline passes.
wait_for() {
  local secs=$1 i=0; shift
  while [ "$i" -lt "$((secs * 5))" ]; do
    "$@" && return 0
    sleep 0.2
    i=$((i + 1))
  done
  return 1
}

start_poller() {  # <case-dir> <extra env assignments...>
  local d=$1; shift
  # FM_HEADLESS_DRAIN=0: belt against ever spawning a real `claude -p` drain
  # worker from a test, even if a future worktree carries data/board-threads.
  # shellcheck disable=SC2031  # PATH is passed per-invocation via env, not mutated here
  env FM_STATE_OVERRIDE="$d/state" FM_POLL_INTERVAL=1 FM_WAKE_INJECT_DEBOUNCE=0 \
      FM_HEADLESS_DRAIN=0 \
      FM_FAKE_TMUX_LOG="$d/tmux.log" PATH="$d/fakebin:$PATH" "$@" \
      bash "$POLL" >"$d/poller.log" 2>&1 &
  POLL_PID=$!
}

test_poller_pushes_both_targets() {
  local d; d=$(new_case poll-both)
  start_poller "$d" FM_FAKE_PARROT_EXISTS=1
  # The poller's own synthetic startup wake must reach BOTH panes.
  wait_for 15 grep -qsF "send-keys -t %1 -l $PRIMARY_NUDGE" "$d/tmux.log" \
    || { cat "$d/poller.log" >&2; kill_poller; fail "poller did not push the primary nudge"; }
  wait_for 15 grep -qsF "send-keys -t %7 -l $PARROT_NUDGE" "$d/tmux.log" \
    || { cat "$d/poller.log" >&2; kill_poller; fail "poller did not push the parrot nudge"; }
  # The parrot seq marker advances independently to the queue seq.
  wait_for 5 test -s "$d/state/.wake-inject-seq.parrot" \
    || { kill_poller; fail "parrot seq marker was not written on confirmed delivery"; }
  local qseq pseq
  qseq=$(cat "$d/state/.wake-queue.seq")
  pseq=$(cat "$d/state/.wake-inject-seq.parrot")
  [ "$pseq" = "$qseq" ] || { kill_poller; fail "parrot seq $pseq != queue seq $qseq"; }
  kill_poller
  pass "the real poller pushes one queue seq to both targets and tracks the parrot seq"
}

test_poller_silent_without_parrot() {
  local d; d=$(new_case poll-absent)
  start_poller "$d" FM_FAKE_PARROT_EXISTS=0
  wait_for 15 grep -qsF "send-keys -t %1 -l $PRIMARY_NUDGE" "$d/tmux.log" \
    || { cat "$d/poller.log" >&2; kill_poller; fail "poller did not push the primary nudge with no parrot"; }
  sleep 2
  kill_poller
  assert_no_grep "send-keys -t %7" "$d/tmux.log" "no keystrokes go to a parrot pane that does not exist"
  assert_no_grep "parrot" "$d/poller.log" "a missing parrot produces no poller log line (silent no-op)"
  assert_absent "$d/state/.wake-inject-seq.parrot" "no parrot seq marker is written without a delivery"
  pass "poller with no fm-parrot: primary unaffected, parrot path fully silent"
}

test_parrot_delivered
test_parrot_absent_is_silent_noop
test_parrot_vacated_pane_is_noop
test_parrot_defers_on_pending_input
test_primary_push_unaffected
test_primary_delivers_after_parrot_in_same_process
test_poller_pushes_both_targets
test_poller_silent_without_parrot

echo "all fm-parrot-wake tests passed"

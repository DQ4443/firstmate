#!/usr/bin/env bash
# fm-poll.sh - launchd-supervised board / merge / stall poller (workflow paradigm).
#
# Replaces bin/fm-watch.sh for daily duty. Under the workflow paradigm nothing
# is armed by hand: this runs as the launchd job com.firstmate.poller
# (launchd/com.firstmate.poller.plist, KeepAlive) so "the board pollers must
# never lapse" is a property of launchd, not of a session's memory. It removes
# the dead-watcher single point of failure that fired on 2026-07-05 (a stale
# .watch.lock held by a dead pid, no live watcher, David's board messages
# unseen).
#
# Contract: it loops the same state/*.check.sh mechanism the watcher used - each
# check prints one line ONLY on a wake-worthy event and stays silent otherwise -
# and delivers every such event through the durable wake queue in
# bin/fm-wake-lib.sh (fm_wake_append). The firstmate session drains that queue
# with bin/fm-wake-drain.sh; this process only produces, never talks to a
# harness directly. On startup it injects one synthetic check event so a wake
# arriving through the queue confirms the whole delivery path end to end
# (AGENTS.md section 7).
#
# It maintains its own liveness beacon state/.last-poller-beat (distinct from
# the escape-hatch watcher's state/.last-watcher-beat, so the two never collide)
# and holds a home-scoped singleton pid guard so a hand-run copy cannot race the
# launchd instance.
#
# DO NOT wire this into a harness background task; it is launchd's job. See
# launchd/com.firstmate.poller.plist. Loading the plist is the human-verified
# cutover step, not something this script or a session does automatically.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-inject-lib.sh
. "$SCRIPT_DIR/fm-inject-lib.sh"

INTERVAL=${FM_POLL_INTERVAL:-${FM_CHECK_INTERVAL:-15}}  # seconds between sweeps
TIMEOUT=${FM_CHECK_TIMEOUT:-30}                          # seconds per *.check.sh
BEAT="$STATE/.last-poller-beat"
PIDFILE="$STATE/.poll.pid"

# Event-driven wake: after each sweep, if the durable queue holds undelivered
# wakes the session has not yet drained, push a one-line nudge into firstmate's
# own pane so it wakes in seconds instead of on its next self-scheduled poll
# (bin/fm-inject-lib.sh). FM_WAKE_INJECT=0 disables the push entirely, leaving
# the pre-existing produce-only behavior (the queue plus the session's own
# drain) untouched.
INJECT_SEQ_FILE="$STATE/.wake-inject-seq"
NOPANE_MARK="$STATE/.wake-inject-nopane"
TIMEOUT_MARK="$STATE/.wake-inject-timeout"
RECONCILE_FAIL_MARK="$STATE/.reconcile-fail"
REAP_FAIL_MARK="$STATE/.queue-reap-fail"
INJECT_DEBOUNCE=${FM_WAKE_INJECT_DEBOUNCE:-8}   # seconds; coalesce a burst
case "$INJECT_DEBOUNCE" in ''|*[!0-9]*) INJECT_DEBOUNCE=8 ;; esac
INJECT_TIMEOUT=${FM_WAKE_INJECT_TIMEOUT:-20}    # seconds; wall-clock cap on a push
case "$INJECT_TIMEOUT" in ''|*[!0-9]*) INJECT_TIMEOUT=20 ;; esac
INJECT_TIMEOUT_BACKOFF=${FM_WAKE_INJECT_TIMEOUT_BACKOFF:-300}  # seconds between push attempts after a watchdog kill
case "$INJECT_TIMEOUT_BACKOFF" in ''|*[!0-9]*) INJECT_TIMEOUT_BACKOFF=300 ;; esac
INJECT_PANE_FILE="$STATE/.wake-inject.pane.$$"

# Headless board drain (Phase 0 first-class trigger; docs/headless-drain.md). When
# there is un-drained board activity (wake-queue seq beyond .drain-attempted-seq)
# and NO interactive REPL is reachable, the poller spawns bin/fm-drain-worker.sh -
# a fresh context-loaded `claude -p` turn that answers David's unanswered thread
# messages with a holding-ack - so a board message becomes a firstmate turn
# WITHOUT the REPL volunteering. FM_HEADLESS_DRAIN=0 disables it entirely.
DRAIN_WORKER="$SCRIPT_DIR/fm-drain-worker.sh"
DRAIN_LEASE="$STATE/.drain-lease"
DRAIN_ATTEMPTED="$STATE/.drain-attempted-seq"
DRAIN_SERVICED="$STATE/.serviced-seq"
DRAIN_PRESENCE="$STATE/repl-presence.json"
DRAIN_THREADS="${FM_BOARD_THREADS_DIR:-$FM_HOME/data/board-threads}"
DRAIN_AGE_MARK="$STATE/.drain-age-breach"
PAGER_BIN="$SCRIPT_DIR/fm-pager.sh"
PRESENCE_GRACE=${FM_REPL_PRESENCE_GRACE:-90}   # seconds; a presence heartbeat older than this reads as no live REPL
case "$PRESENCE_GRACE" in ''|*[!0-9]*) PRESENCE_GRACE=90 ;; esac
DRAIN_SLA=${FM_DRAIN_SLA_SECONDS:-1800}        # seconds; oldest un-answered David message age that pages
case "$DRAIN_SLA" in ''|*[!0-9]*) DRAIN_SLA=1800 ;; esac

# Print every live descendant of <pid>, depth-first. The watchdog snapshots this
# BEFORE terminating the worker: once the worker subshell dies its children are
# reparented, so a post-mortem pkill -P would miss the very process that hangs -
# the tmux client blocked on a wedged server, usually a grandchild via command
# substitution. Without the sweep each timed-out push leaks one hung client.
descendant_pids() {
  local kid
  for kid in $(pgrep -P "$1" 2>/dev/null); do
    printf '%s\n' "$kid"
    descendant_pids "$kid"
  done
}

# run_with_timeout <seconds> <command...> - run <command> under a bash-native
# wall-clock watchdog and return its exit status, or 99 when the watchdog had
# to kill it. Stock macOS has no coreutils timeout/gtimeout and the launchd
# plist sets no PATH, so anything the poller loop runs inline must be bounded
# without them: a worker subshell records the command's rc to a result file
# while a watchdog snapshots the worker's descendants (descendant_pids above),
# TERMs the worker, then KILLs the worker and every snapshotted descendant. A
# kill (no result file) reads as rc 99. The command's stdout/stderr pass
# through to the caller. Shared by maybe_inject_wake and maybe_reconcile_board.
run_with_timeout() {
  local secs=$1; shift
  local resfile="$STATE/.run-with-timeout.rc.$$" worker watchdog rc
  rm -f "$resfile" 2>/dev/null || true
  ( "$@"; printf '%s' "$?" > "$resfile" ) &
  worker=$!
  # The watchdog is detached from the caller's stdout/stderr: when the caller
  # captures run_with_timeout in $(...), an inherited pipe fd would live on in
  # the watchdog's orphaned sleep after an early TERM and block the command
  # substitution for the full timeout even though the worker already finished.
  ( sleep "$secs"
    desc=$(descendant_pids "$worker")
    kill -TERM "$worker" 2>/dev/null
    sleep 1
    pkill -P "$worker" 2>/dev/null || true
    kill -KILL "$worker" 2>/dev/null
    printf '%s\n' "$desc" | while IFS= read -r d; do
      [ -n "$d" ] && kill -KILL "$d" 2>/dev/null
    done ) >/dev/null 2>&1 &
  watchdog=$!
  wait "$worker" 2>/dev/null
  # No result file means the watchdog is mid-kill: let it finish sweeping the
  # worker's descendants (bounded by its own sleeps) instead of TERMing it
  # between its TERM and the descendant KILLs, which would re-leak the hung
  # child. With a result the worker finished on its own, so stop the watchdog.
  if [ -f "$resfile" ]; then
    kill -TERM "$watchdog" 2>/dev/null || true
  fi
  wait "$watchdog" 2>/dev/null
  if [ -f "$resfile" ]; then
    rc=$(cat "$resfile" 2>/dev/null || echo 99)
    case "$rc" in ''|*[!0-9]*) rc=99 ;; esac
  else
    rc=99
  fi
  rm -f "$resfile" 2>/dev/null || true
  return "$rc"
}

# Worker for the guarded wake push: fm_inject_wake runs inside run_with_timeout's
# subshell, so its FM_INJECT_PANE result would be lost with its environment;
# stash it in a side file for the caller's log line.
inject_push_worker() {
  fm_inject_wake
  local rc=$?
  printf '%s' "${FM_INJECT_PANE:-}" > "$INJECT_PANE_FILE" 2>/dev/null || true
  return "$rc"
}

# maybe_inject_wake: push a nudge iff there are undelivered wakes NEWER than the
# last nudge and the debounce window has elapsed. The queue's monotonic seq
# counter (state/.wake-queue.seq) is the "newest wake" marker; INJECT_SEQ_FILE
# records the seq we last nudged about. A burst that lands within one sweep
# advances the seq once and injects once; a queue we have already nudged (same
# seq, session simply slow to drain) is not re-nudged, so the session is never
# spammed. A missing pane is logged once per outage, not every cycle.
maybe_inject_wake() {
  [ "${FM_WAKE_INJECT:-1}" = 1 ] || return 0
  [ -s "$FM_WAKE_QUEUE" ] || return 0
  local cur last age rc now
  cur=$(cat "$STATE/.wake-queue.seq" 2>/dev/null || echo 0)
  case "$cur" in ''|*[!0-9]*) cur=0 ;; esac
  last=$(cat "$INJECT_SEQ_FILE" 2>/dev/null || echo 0)
  case "$last" in ''|*[!0-9]*) last=0 ;; esac
  [ "$cur" -gt "$last" ] || return 0
  if [ -f "$INJECT_SEQ_FILE" ]; then
    now=$(date +%s)
    age=$(( now - $(fm_path_mtime "$INJECT_SEQ_FILE" 2>/dev/null || echo 0) ))
    [ "$age" -ge "$INJECT_DEBOUNCE" ] || return 0
  fi
  # Timeout backoff: a push the watchdog had to kill (rc 99, wedged tmux server)
  # is not retried every cycle - each attempt costs one hung client until the
  # server recovers. Hold off until the backoff window elapses; the marker is
  # cleared on the next confirmed delivery.
  if [ -f "$TIMEOUT_MARK" ]; then
    now=$(date +%s)
    age=$(( now - $(fm_path_mtime "$TIMEOUT_MARK" 2>/dev/null || echo 0) ))
    [ "$age" -ge "$INJECT_TIMEOUT_BACKOFF" ] || return 0
  fi
  # Guard the injection with run_with_timeout. fm_inject_wake makes repeated tmux
  # client calls (which can hang on a wedged server), sleeps/retries in the submit,
  # and walks process trees in discovery; run inline and unguarded, one hang would
  # stall the whole poller - no checks, no wakes, no reconcile. It is safe to
  # kill: it never mutates the queue, and the seq marker only advances on a
  # confirmed delivery below. rc 99 (watchdog kill) = not delivered. The pane id
  # travels through a side file because the worker runs in a subshell.
  local pane
  rm -f "$INJECT_PANE_FILE" 2>/dev/null || true
  run_with_timeout "$INJECT_TIMEOUT" inject_push_worker
  rc=$?
  pane=$(cat "$INJECT_PANE_FILE" 2>/dev/null || true)
  rm -f "$INJECT_PANE_FILE" 2>/dev/null || true
  case "$rc" in
    0)
      printf '%s\n' "$cur" > "$INJECT_SEQ_FILE"
      rm -f "$NOPANE_MARK" "$TIMEOUT_MARK" 2>/dev/null || true
      echo "fm-poll: pushed board wake to pane $pane (seq $cur) $(date '+%Y-%m-%dT%H:%M:%S%z')"
      ;;
    1)
      if [ ! -f "$NOPANE_MARK" ]; then
        touch "$NOPANE_MARK" 2>/dev/null || true
        echo "fm-poll: no firstmate pane to push to; degraded to queue + session poll (seq $cur) $(date '+%Y-%m-%dT%H:%M:%S%z')" >&2
      fi
      ;;
    99)
      if [ ! -f "$TIMEOUT_MARK" ]; then
        echo "fm-poll: wake push killed at ${INJECT_TIMEOUT}s (wedged tmux server?); backing off ${INJECT_TIMEOUT_BACKOFF}s between attempts (seq $cur) $(date '+%Y-%m-%dT%H:%M:%S%z')" >&2
      fi
      touch "$TIMEOUT_MARK" 2>/dev/null || true
      ;;
    *)
      [ "${FM_POLL_DEBUG:-0}" = 1 ] && echo "fm-poll: wake push deferred/unconfirmed rc=$rc (seq $cur)" >&2
      ;;
  esac
  return 0
}

# Liveness-derived board: rewrite state/board.json each cycle so In progress =
# exactly the items with a live agent (bin/fm-board-reconcile.sh). It is a fast
# no-op until firstmate adopts the registry (state/item-agents.json) and whenever
# nothing changed, so running it every cycle is cheap. Guarded by a per-cycle
# timeout so a wedged board lock can never stall the poller, and by
# FM_BOARD_RECONCILE=0 to disable entirely. Deterministic and side-effect-scoped
# to board.json; it never touches the wake queue.
maybe_reconcile_board() {
  [ "${FM_BOARD_RECONCILE:-1}" = 1 ] || return 0
  local rec="$SCRIPT_DIR/fm-board-reconcile.sh" err rc
  [ -f "$rec" ] || return 0
  # Capture stderr (stdout stays silent by design) so a PERSISTENT failure - e.g.
  # a corrupt item-agents.json, which exits 1 on purpose - is not invisible while
  # the board silently stops self-correcting. Surface it once per outage with the
  # same marker pattern as the missing pane, and clear the marker on recovery.
  # A warning on stderr with rc 0 (e.g. thread-file contract drift blinding the
  # message-live scan, or the reconcile skipping a cycle on its bounded board-lock
  # wait) counts as a failing cycle too; the reconcile only emits it once per
  # outage, so the marker clears on its next silent cycle. run_with_timeout is
  # the belt to the reconcile's own braces (its board-lock wait is bounded by
  # FM_BOARD_LOCK_WAIT): neither depends on a coreutils timeout binary, which
  # stock macOS does not have.
  err=$(run_with_timeout "$TIMEOUT" bash "$rec" 2>&1 >/dev/null); rc=$?
  if [ "$rc" -ne 0 ] || [ -n "$err" ]; then
    if [ ! -f "$RECONCILE_FAIL_MARK" ]; then
      touch "$RECONCILE_FAIL_MARK" 2>/dev/null || true
      echo "fm-poll: board reconcile failing (rc=$rc): $(printf '%s' "$err" | head -1) $(date '+%Y-%m-%dT%H:%M:%S%z')" >&2
    fi
  else
    rm -f "$RECONCILE_FAIL_MARK" 2>/dev/null || true
  fi
}

# Sharded-executors claim reaper: re-home claims whose owning executor died or
# whose lease expired, back to ready/ (attempts++) or to failed/ past the max
# (bin/fm-queue.sh reap). Mirrors maybe_reconcile_board exactly - same
# run_with_timeout belt, same once-per-outage stderr marker - so a wedged queue
# can never stall the poller. STRICT ADOPTION SWITCH: a COMPLETE no-op while the
# queue dir (default state/queue) does not exist, so this changes NOTHING about
# the current live poller until the queue is adopted by hand. Disable entirely
# with FM_QUEUE_REAP=0. Side-effect-scoped to the queue dir; never touches the
# board or the wake queue.
maybe_reap_claims() {
  [ "${FM_QUEUE_REAP:-1}" = 1 ] || return 0
  local q="${FM_QUEUE_DIR:-$STATE/queue}"
  [ -d "$q" ] || return 0
  local reaper="$SCRIPT_DIR/fm-queue.sh" err rc
  [ -f "$reaper" ] || return 0
  err=$(run_with_timeout "$TIMEOUT" bash "$reaper" reap 2>&1 >/dev/null); rc=$?
  if [ "$rc" -ne 0 ] || [ -n "$err" ]; then
    if [ ! -f "$REAP_FAIL_MARK" ]; then
      touch "$REAP_FAIL_MARK" 2>/dev/null || true
      echo "fm-poll: claim reaper failing (rc=$rc): $(printf '%s' "$err" | head -1) $(date '+%Y-%m-%dT%H:%M:%S%z')" >&2
    fi
  else
    rm -f "$REAP_FAIL_MARK" 2>/dev/null || true
  fi
}

# --- headless board drain (Phase 0) -----------------------------------------

drain_read_seq() {  # <file> - non-negative integer, or 0
  local v
  v=$(cat "$1" 2>/dev/null || echo 0)
  case "$v" in ''|*[!0-9]*) v=0 ;; esac
  printf '%s' "$v"
}

# Worker (under run_with_timeout) that resolves firstmate's interactive pane; rc 0
# means a live REPL is attached. Guarded because fm_resolve_session_pane makes
# tmux calls that can hang on a wedged server.
resolve_pane_worker() { fm_resolve_session_pane >/dev/null 2>&1; }

# repl_reachable: is a live interactive firstmate REPL present to handle the wake?
# Fast-path on a fresh presence heartbeat (bin/fm-repl-presence.sh), else a
# timeout-guarded pane resolution. A stale/absent presence AND no resolvable pane
# reads as "no REPL" - which is exactly when the headless drain must fire.
repl_reachable() {
  local status age
  if [ -f "$DRAIN_PRESENCE" ]; then
    status=$(sed -n 's/.*"status"[[:space:]]*:[[:space:]]*"\([a-z]*\)".*/\1/p' "$DRAIN_PRESENCE" 2>/dev/null | head -n1)
    age=$(( $(date +%s) - $(fm_path_mtime "$DRAIN_PRESENCE" 2>/dev/null || echo 0) ))
    if { [ "$status" = idle ] || [ "$status" = busy ]; } && [ "$age" -lt "$PRESENCE_GRACE" ]; then
      return 0
    fi
  fi
  run_with_timeout "$INJECT_TIMEOUT" resolve_pane_worker
}

# maybe_drain_headless: when the queue has advanced past the last serviced drain
# and no REPL is reachable, spawn the headless drain worker. Single-flight is the
# worker's pid-live lease (state/.drain-lease); the poller only skips spawning
# when a live drain already holds it, to avoid churn. The worker is spawned
# DETACHED (nohup, double-forked) so a multi-second `claude -p` turn never stalls
# the poll loop - the lease, not the loop, bounds concurrency.
maybe_drain_headless() {
  [ "${FM_HEADLESS_DRAIN:-1}" = 1 ] || return 0
  [ -f "$DRAIN_WORKER" ] || return 0
  local cur att hpid
  cur=$(drain_read_seq "$STATE/.wake-queue.seq")
  att=$(drain_read_seq "$DRAIN_ATTEMPTED")
  [ "$cur" -gt "$att" ] || return 0
  if repl_reachable; then
    [ "${FM_POLL_DEBUG:-0}" = 1 ] && echo "fm-poll: board activity (seq $cur) but REPL reachable; leaving to the interactive fast path" >&2
    return 0
  fi
  if [ -d "$DRAIN_LEASE" ]; then
    hpid=$(cat "$DRAIN_LEASE/pid" 2>/dev/null || true)
    if fm_pid_alive "$hpid"; then
      [ "${FM_POLL_DEBUG:-0}" = 1 ] && echo "fm-poll: a headless drain already holds the lease (pid $hpid); not spawning" >&2
      return 0
    fi
  fi
  ( nohup bash "$DRAIN_WORKER" >/dev/null 2>&1 & ) 2>/dev/null || true
  echo "fm-poll: spawned headless board drain (seq $cur > attempted $att; no reachable REPL) $(date '+%Y-%m-%dT%H:%M:%S%z')" >&2
}

# maybe_pager: heartbeat the off-box dead-man's switch every cycle, and page once
# per outage when the oldest un-answered David message breaches the age SLA. Both
# are clean no-ops until config/pager.env is filled in (bin/fm-pager.sh). The SLA
# scan only runs when serviced-seq lags the queue, so a fully-serviced board costs
# nothing. "Un-answered" = a thread whose newest *.md file is a David message with
# a body (the contract in docs/headless-drain.md, shared with fm-drain-worker.sh).
oldest_unanswered_age() {
  local now dd f newest ms base hdr author body m age max=""
  now=$(date +%s)
  [ -d "$DRAIN_THREADS" ] || return 0
  for dd in "$DRAIN_THREADS"/*/; do
    [ -d "$dd" ] || continue
    newest=""; ms=0
    for f in "$dd"*.md; do
      [ -e "$f" ] || continue
      base=$(basename "$f" .md)
      case "${base%%-*}" in ''|*[!0-9]*) continue ;; esac
      if [ "${base%%-*}" -ge "$ms" ]; then ms="${base%%-*}"; newest="$f"; fi
    done
    [ -n "$newest" ] || continue
    hdr=$(head -n 1 "$newest" 2>/dev/null || true)
    author=$(printf '%s' "$hdr" | jq -r '.author // ""' 2>/dev/null || true)
    [ "$author" = david ] || continue
    body=$(sed '1,2d' "$newest" 2>/dev/null | tr -d '[:space:]')
    [ -n "$body" ] || continue
    m=$(fm_path_mtime "$newest" 2>/dev/null || echo "$now")
    age=$(( now - m ))
    if [ -z "$max" ] || [ "$age" -gt "$max" ]; then max=$age; fi
  done
  [ -n "$max" ] && printf '%s' "$max"
}

maybe_pager() {
  [ -x "$PAGER_BIN" ] && "$PAGER_BIN" ping >/dev/null 2>&1 || true
  local cur srv oldest
  cur=$(drain_read_seq "$STATE/.wake-queue.seq")
  srv=$(drain_read_seq "$DRAIN_SERVICED")
  if [ "$cur" -le "$srv" ]; then
    rm -f "$DRAIN_AGE_MARK" 2>/dev/null || true
    return 0
  fi
  oldest=$(oldest_unanswered_age)
  if [ -n "$oldest" ] && [ "$oldest" -ge "$DRAIN_SLA" ]; then
    if [ ! -f "$DRAIN_AGE_MARK" ]; then
      touch "$DRAIN_AGE_MARK" 2>/dev/null || true
      [ -x "$PAGER_BIN" ] && "$PAGER_BIN" page "un-answered David board message ${oldest}s old (SLA ${DRAIN_SLA}s)" >/dev/null 2>&1 || true
      echo "fm-poll: board SLA breach: oldest un-answered David message ${oldest}s old (SLA ${DRAIN_SLA}s) $(date '+%Y-%m-%dT%H:%M:%S%z')" >&2
    fi
  else
    rm -f "$DRAIN_AGE_MARK" 2>/dev/null || true
  fi
}

mkdir -p "$STATE"

# Home-scoped singleton with PID-reuse safety: the pidfile records the poller's
# pid on line 1 and its process identity (start time + command, from
# fm_pid_identity) on line 2. A live pid whose identity still matches the record
# is a genuine second poller, so exit quietly and let it own the home. A pid that
# is dead OR has been recycled by an unrelated process (identity mismatch) is
# treated as stale, so this instance takes over. Without the identity check a
# bare kill -0 on a reused pid would read as "already running" and, under the
# plist's KeepAlive + 10s throttle, wedge the poller in a silent respawn loop
# that never actually polls the board. Mirrors the watcher lock's identity check.
if [ -f "$PIDFILE" ]; then
  other=$(sed -n '1p' "$PIDFILE" 2>/dev/null || true)
  other_id=$(sed -n '2,$p' "$PIDFILE" 2>/dev/null || true)
  if [ -n "$other" ] && [ "$other" != "${BASHPID:-$$}" ] && fm_pid_alive "$other"; then
    cur_id=$(fm_pid_identity "$other" 2>/dev/null || true)
    if [ -n "$other_id" ] && [ "$cur_id" = "$other_id" ]; then
      echo "fm-poll: already running (pid $other) for $FM_HOME" >&2
      exit 0
    fi
  fi
fi
SELF=${BASHPID:-$$}
{ printf '%s\n' "$SELF"; fm_pid_identity "$SELF" 2>/dev/null || true; } > "$PIDFILE"
trap 'rm -f "$PIDFILE" 2>/dev/null || true' EXIT INT TERM

run_check() {  # <path> - run one check with a hard timeout, never let it hang
  local c=$1
  if command -v timeout >/dev/null 2>&1; then
    timeout "$TIMEOUT" bash "$c" 2>/dev/null || true
  elif command -v gtimeout >/dev/null 2>&1; then
    gtimeout "$TIMEOUT" bash "$c" 2>/dev/null || true
  else
    # No coreutils timeout (default on stock macOS): fall back to a perl
    # process-group alarm, the same pattern bin/fm-watch.sh uses, so one hung
    # check.sh cannot wedge the launchd poller.
    # shellcheck disable=SC2016  # single quotes are deliberate: Perl expands its own variables.
    perl -e 'my $t = shift; my $pid = fork; die "fork failed" unless defined $pid; if (!$pid) { setpgrp(0, 0); exec @ARGV } local $SIG{ALRM} = sub { kill "TERM", -$pid; select undef, undef, undef, 0.2; kill "KILL", -$pid; exit 124 }; alarm $t; waitpid $pid, 0; exit($? >> 8)' "$TIMEOUT" bash "$c" 2>/dev/null || true
  fi
}

# Synthetic startup event: proves check output -> fm_wake_append -> durable
# queue -> fm-wake-drain works, so a silent poller after a launchd restart is a
# real failure, not a "nothing happened" ambiguity. Rate-limited to at most once
# per FM_POLLER_STARTUP_WAKE_MIN_INTERVAL seconds (default 300) so a launchd
# crash-respawn loop (KeepAlive + 10s throttle) cannot flood the durable wake
# queue and repeatedly wake the session; a genuine restart still emits it.
STARTUP_MARK="$STATE/.poller-startup-wake"
WAKE_MIN=${FM_POLLER_STARTUP_WAKE_MIN_INTERVAL:-300}
emit_startup_wake=1
if [ -f "$STARTUP_MARK" ]; then
  now=$(date +%s)
  last=$(date -r "$STARTUP_MARK" +%s 2>/dev/null || echo 0)
  if [ "$((now - last))" -lt "$WAKE_MIN" ]; then
    emit_startup_wake=0
  fi
fi
if [ "$emit_startup_wake" = 1 ]; then
  touch "$STARTUP_MARK"
  fm_wake_append check "poller-start" "check: poller-start: synthetic startup wake $(date '+%Y-%m-%dT%H:%M:%S%z')" || true
fi

while :; do
  touch "$BEAT"
  for c in "$STATE"/*.check.sh; do
    [ -e "$c" ] || continue
    out=$(run_check "$c")
    [ -n "$out" ] || continue
    fm_wake_append check "$c" "check: $c: $out" || true
  done
  maybe_inject_wake
  maybe_drain_headless
  maybe_pager
  maybe_reconcile_board
  maybe_reap_claims
  sleep "$INTERVAL"
done

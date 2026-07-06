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

INTERVAL=${FM_POLL_INTERVAL:-${FM_CHECK_INTERVAL:-15}}  # seconds between sweeps
TIMEOUT=${FM_CHECK_TIMEOUT:-30}                          # seconds per *.check.sh
BEAT="$STATE/.last-poller-beat"
PIDFILE="$STATE/.poll.pid"

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
  sleep "$INTERVAL"
done

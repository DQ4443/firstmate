#!/usr/bin/env bash
# fm-session-register.sh - record this firstmate session's tmux coordinates so
# the launchd poller can PUSH a wake into the running session instead of the
# session polling for board events on a timer.
#
# THE PROBLEM THIS SOLVES: bin/fm-poll.sh (launchd) detects David's board
# messages within seconds and appends them to the durable wake queue, but
# nothing delivers that queue into the live `claude` session - it only acts when
# re-invoked (terminal input, an agent finishing, a ScheduleWakeup it set
# itself). So the session polls on a multi-minute timer to notice board
# activity, which is the root of the "messages pile up / stale board" lag. The
# fix is for the poller to `tmux send-keys` a short nudge into firstmate's own
# pane the instant a board event lands (bin/fm-inject-lib.sh). To do that from a
# launchd job with a minimal environment (no $TMUX, no homebrew on PATH), the
# poller needs firstmate's pane id, the tmux server socket, and the absolute
# tmux binary path recorded somewhere it can read. That is this file's job.
#
# WHY HERE AND NOW: this script runs as a real subprocess of the live session
# (called from bin/fm-session-start.sh on the locked path), so its environment
# is the session's environment: $TMUX_PANE names the pane the harness is drawing
# into, $TMUX carries the server socket, and `command -v tmux` resolves the real
# binary with the session's full PATH. A launchd job has none of these, so they
# must be captured here and handed across in a file. Subagents run in-process and
# share the same pane, so $TMUX_PANE is stable for the session's whole life.
#
# It writes state/session-pane.env as a small sourceable KEY=VALUE file:
#   FM_SESSION_PANE          - tmux pane id, e.g. %114 (stable per session)
#   FM_SESSION_TMUX_SOCKET   - tmux server socket path (first field of $TMUX)
#   FM_SESSION_TMUX_BIN      - absolute path to the tmux binary
#   FM_SESSION_HARNESS_PID   - the harness pid holding the session lock
#   FM_SESSION_REGISTERED_AT - epoch seconds of this registration
#
# Outside tmux (no $TMUX) it is a no-op that prints why and exits 0: registration
# is a best-effort optimization, never a gate. The durable wake queue and the
# session's own drain still work with no pane recorded; the poller simply falls
# back to producing wakes without pushing them (bin/fm-poll.sh).
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
OUT="$STATE/session-pane.env"

mkdir -p "$STATE"

# $TMUX is "socketpath,serverpid,sessionid"; the socket is the first field. An
# empty $TMUX means this session is not running inside tmux, so there is no pane
# to push into and nothing to record.
tmux_env="${TMUX:-}"
pane="${TMUX_PANE:-}"
if [ -z "$tmux_env" ] || [ -z "$pane" ]; then
  echo "fm-session-register: not inside tmux (\$TMUX/\$TMUX_PANE unset); no pane recorded. Poller push is disabled; the durable wake queue still works." >&2
  exit 0
fi

socket="${tmux_env%%,*}"

# Resolve the real tmux binary with the session's PATH. The poller's launchd
# environment does not include homebrew, so a bare "tmux" would not resolve
# there; record the absolute path the session sees instead.
tmux_bin="$(command -v tmux 2>/dev/null || true)"
if [ -z "$tmux_bin" ]; then
  echo "fm-session-register: tmux binary not found on PATH; cannot record a usable pane target." >&2
  exit 0
fi

# The harness pid holding the lock, written by fm-lock.sh which runs before this
# on the session-start path. Used only as a fallback discovery key by the
# resolver (bin/fm-inject-lib.sh) when the recorded pane can no longer be
# validated; absence here is not fatal.
harness_pid="$(cat "$STATE/.lock" 2>/dev/null || true)"
case "$harness_pid" in
  ''|*[!0-9]*) harness_pid="" ;;
esac

now="$(date +%s)"

TMP="$OUT.tmp.$$"
trap 'rm -f "$TMP" 2>/dev/null || true' EXIT
{
  printf 'FM_SESSION_PANE=%s\n' "$pane"
  printf 'FM_SESSION_TMUX_SOCKET=%s\n' "$socket"
  printf 'FM_SESSION_TMUX_BIN=%s\n' "$tmux_bin"
  printf 'FM_SESSION_HARNESS_PID=%s\n' "$harness_pid"
  printf 'FM_SESSION_REGISTERED_AT=%s\n' "$now"
} > "$TMP"
mv "$TMP" "$OUT"

echo "fm-session-register: pane=$pane socket=$socket tmux=$tmux_bin harness=${harness_pid:-unknown} -> $OUT"

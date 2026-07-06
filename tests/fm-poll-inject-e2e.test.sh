#!/usr/bin/env bash
# tests/fm-poll-inject-e2e.test.sh - end-to-end proof of the event-driven wake
# push through the REAL launchd poller (bin/fm-poll.sh), the way David actually
# experiences it: a wake lands in the durable queue and the running poller pushes
# a nudge into firstmate's own pane within seconds, with no session re-invoke.
#
# It launches the real poller against a throwaway state dir whose session-pane.env
# points at a private-socket tmux pane. The poller's own synthetic startup wake
# (AGENTS.md section 7) plus an explicitly appended board wake must both surface
# as submitted nudge lines in the pane. A second identical append with no new
# queue seq must NOT re-nudge (debounce / seq-tracking), and disabling the push
# (FM_WAKE_INJECT=0) must deliver nothing while the queue still fills.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
POLL="$ROOT/bin/fm-poll.sh"

fail() { printf 'not ok - %s\n' "$1" >&2; cleanup_all; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }

REAL_TMUX=$(command -v tmux 2>/dev/null || true)
command -v tmux >/dev/null 2>&1 || { echo "skip: tmux not found"; exit 0; }

STATE_DIR=$(mktemp -d "${TMPDIR:-/tmp}/fm-poll-inject.XXXXXX")
SOCKET="$STATE_DIR/tmux.sock"
LOG_FILE="$STATE_DIR/submitted.log"
LOOP_SCRIPT="$STATE_DIR/loop.sh"
POLL_PID=""

# Point the wake library (sourced below) at the throwaway state dir BEFORE
# sourcing it: fm-wake-lib.sh computes $STATE / $FM_WAKE_QUEUE once at source
# time, so a per-call FM_STATE_OVERRIDE prefix would not redirect it.
export FM_STATE_OVERRIDE="$STATE_DIR"

# grep -c prints 0 and EXITS 1 when there are no matches, so a `|| echo 0` guard
# would emit a second 0; capture cleanly and default only a missing file to 0.
count_lines() { local n; n=$(grep -c . "$1" 2>/dev/null); [ -n "$n" ] || n=0; printf '%s' "$n"; }

# fm-poll.sh traps SIGTERM/INT (only to clean its pidfile) and keeps looping, so
# a plain kill never stops it and `wait` would hang. Use SIGKILL, and ONLY ever
# on our own captured POLL_PID - never a pattern kill, which would also hit the
# live launchd poller (com.firstmate.poller).
kill_poller() {
  [ -n "${POLL_PID:-}" ] || return 0
  kill -KILL "$POLL_PID" 2>/dev/null || true
  wait "$POLL_PID" 2>/dev/null || true
  POLL_PID=""
}

cleanup_all() {
  kill_poller
  [ -n "${REAL_TMUX:-}" ] && [ -S "$SOCKET" ] && "$REAL_TMUX" -S "$SOCKET" kill-server 2>/dev/null || true
  rm -rf "$STATE_DIR" 2>/dev/null || true
}
trap cleanup_all EXIT

# shellcheck source=bin/fm-wake-lib.sh
. "$ROOT/bin/fm-wake-lib.sh"

# Private pane running a composer loop that logs every submitted line.
cat > "$LOOP_SCRIPT" <<'LOOP'
#!/usr/bin/env bash
LOG="$1"
OLD_STTY=$(stty -g 2>/dev/null || true)
[ -z "$OLD_STTY" ] || stty -echo -icanon min 1 time 0 2>/dev/null || true
trap '[ -z "$OLD_STTY" ] || stty "$OLD_STTY" 2>/dev/null || true' EXIT INT TERM
_buf=
redraw() { printf '\r\033[K%s' "$_buf"; }
redraw
while IFS= read -r -n 1 _ch; do
  case "$_ch" in
    ''|$'\r'|$'\n') printf '%s\n' "$_buf" >> "$LOG"; _buf=; printf '\r\033[K\n'; redraw ;;
    $'\177'|$'\b') _buf=${_buf%?}; redraw ;;
    *) _buf="${_buf}${_ch}"; redraw ;;
  esac
done
LOOP
chmod +x "$LOOP_SCRIPT"
: > "$LOG_FILE"

"$REAL_TMUX" -S "$SOCKET" new-session -d -s fm -x 200 -y 50
PANE=$("$REAL_TMUX" -S "$SOCKET" display-message -p -t fm '#{pane_id}')
PANE_PID=$("$REAL_TMUX" -S "$SOCKET" display-message -p -t fm '#{pane_pid}')
"$REAL_TMUX" -S "$SOCKET" send-keys -t "$PANE" "bash '$LOOP_SCRIPT' '$LOG_FILE'" Enter
sleep 1

{
  printf 'FM_SESSION_PANE=%s\n' "$PANE"
  printf 'FM_SESSION_TMUX_SOCKET=%s\n' "$SOCKET"
  printf 'FM_SESSION_TMUX_BIN=%s\n' "$REAL_TMUX"
  printf 'FM_SESSION_HARNESS_PID=%s\n' "$PANE_PID"
  printf 'FM_SESSION_REGISTERED_AT=%s\n' "$(date +%s)"
} > "$STATE_DIR/session-pane.env"

# wait_for_lines <count> <seconds>: poll the log until it has >= count non-empty
# lines or the deadline passes. Returns 0 on reaching the count.
wait_for_lines() {
  local want=$1 secs=$2 i=0 have
  while [ "$i" -lt "$((secs * 5))" ]; do
    have=$(count_lines "$LOG_FILE")
    [ "$have" -ge "$want" ] && return 0
    sleep 0.2
    i=$((i + 1))
  done
  return 1
}

start_poller() {  # extra env assignments as args
  FM_STATE_OVERRIDE="$STATE_DIR" \
  FM_POLL_INTERVAL=1 \
  FM_WAKE_INJECT_DEBOUNCE=0 \
  "$@" \
  bash "$POLL" >"$STATE_DIR/poller.log" 2>&1 &
  POLL_PID=$!
}

stop_poller() { kill_poller; }

# --- push enabled: startup wake + a board wake both reach the pane -----------
start_poller
# The synthetic startup wake alone must be pushed into the pane.
wait_for_lines 1 10 || { echo "poller.log:"; cat "$STATE_DIR/poller.log" >&2; fail "startup wake was not pushed into the pane"; }
pass "poller pushes its synthetic startup wake into the pane (delivery path proven)"

# A real board wake appended to the durable queue must be pushed too.
before=$(count_lines "$LOG_FILE")
fm_wake_append check board-threads "check: board-threads: 1 new"
wait_for_lines "$((before + 1))" 10 || fail "a board wake in the queue was not pushed"
grep -q "fm-wake:" "$LOG_FILE" || fail "pushed line is not the wake nudge"
pass "a board wake appended to the durable queue is pushed within seconds"

# Draining and no new wake must NOT re-nudge (seq-tracking / debounce).
bash "$ROOT/bin/fm-wake-drain.sh" >/dev/null 2>&1 || true
stable=$(count_lines "$LOG_FILE")
sleep 3
now=$(count_lines "$LOG_FILE")
[ "$now" -eq "$stable" ] || fail "poller re-nudged with no new wake (seq-tracking broken): $stable -> $now"
pass "no new queue seq -> no repeat nudge (burst coalescing holds)"
stop_poller

# --- push disabled: queue still fills, nothing is injected -------------------
: > "$LOG_FILE"
rm -f "$STATE_DIR/.wake-inject-seq" "$STATE_DIR/.poller-startup-wake"
start_poller FM_WAKE_INJECT=0
sleep 3
fm_wake_append check board-threads "check: board-threads: 2 new"
sleep 3
[ "$(count_lines "$LOG_FILE")" -eq 0 ] \
  || fail "FM_WAKE_INJECT=0 still injected into the pane"
[ -s "$STATE_DIR/.wake-queue" ] || fail "FM_WAKE_INJECT=0 should leave the wake in the durable queue"
pass "FM_WAKE_INJECT=0 disables the push; the durable queue still carries the wake"
stop_poller

echo "all fm-poll-inject-e2e tests passed"

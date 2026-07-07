#!/usr/bin/env bash
# tests/fm-inject-wake.test.sh - event-driven wake delivery (bin/fm-inject-lib.sh).
#
# Proves the operator-visible contracts of the poller-to-session push:
#
#   A (delivery): with a recorded, valid session-pane.env, fm_inject_wake types
#     the wake nudge into the pane and it is submitted exactly once.
#   B (deferral): when the composer holds real unsubmitted input, fm_inject_wake
#     defers (rc 2) and submits nothing, so it can never corrupt a line David is
#     typing. After the pane goes idle a later push delivers cleanly.
#   C (no pane -> graceful degrade): with no recorded pane and no discoverable
#     one, fm_inject_wake returns 1 and submits nothing (the durable queue and
#     the session's own drain still carry the event).
#   D (vacated pane rejected): a recorded pane whose harness pid is dead AND whose
#     foreground is no longer a harness does not inject (the session vacated it).
#   D2 (resume-in-place delivers): a recorded pane whose harness pid is dead but
#     whose foreground is still a live harness DOES inject - firstmate resumed in
#     the same pane with a new pid and the stale recorded pid must not blind the
#     push. This is the regression that left resumed sessions unwoken.
#   E (discovery fallback): with no recorded file, the pane is found by matching
#     the lock's harness pid to the pane whose pane_pid is its ancestor.
#
# Plus pure-logic units (envget parsing, pid-ancestry) that need no tmux.
#
# Isolation: a private tmux server on an explicit socket path under a throwaway
# state dir. Nothing touches the live fleet. Assert on submitted CONTENT logged
# verbatim by the pane loop, never on pane appearance (terminal wrapping lies).
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB="$ROOT/bin/fm-inject-lib.sh"

fail() { printf 'not ok - %s\n' "$1" >&2; cleanup_all; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }

REAL_TMUX=$(command -v tmux 2>/dev/null || true)
STATE_DIR=$(mktemp -d "${TMPDIR:-/tmp}/fm-inject-e2e.XXXXXX")
SOCKET="$STATE_DIR/tmux.sock"
PANE=""
LOG_FILE="$STATE_DIR/submitted.log"
LOOP_SCRIPT="$STATE_DIR/loop.sh"

cleanup_all() {
  if [ -n "${REAL_TMUX:-}" ] && [ -S "$SOCKET" ]; then
    "$REAL_TMUX" -S "$SOCKET" kill-server 2>/dev/null || true
  fi
  rm -rf "$STATE_DIR" 2>/dev/null || true
}
trap cleanup_all EXIT

# --- pure-logic units (no tmux needed) --------------------------------------

# Source the library against the throwaway state dir so its resolver reads our
# fixtures, never the live fleet.
export FM_STATE_OVERRIDE="$STATE_DIR"
# shellcheck source=bin/fm-inject-lib.sh
. "$LIB"

# envget: extract a fixed key without executing the file.
{
  printf 'FM_SESSION_PANE=%%9\n'
  printf 'FM_SESSION_TMUX_SOCKET=/x/y.sock\n'
  printf 'FM_SESSION_HARNESS_PID=4242\n'
} > "$STATE_DIR/parse.env"
[ "$(fm_inject_envget "$STATE_DIR/parse.env" FM_SESSION_PANE)" = "%9" ] \
  || fail "envget: pane id not parsed"
[ "$(fm_inject_envget "$STATE_DIR/parse.env" FM_SESSION_HARNESS_PID)" = "4242" ] \
  || fail "envget: harness pid not parsed"
[ -z "$(fm_inject_envget "$STATE_DIR/parse.env" FM_SESSION_MISSING)" ] \
  || fail "envget: absent key should be empty"
pass "envget parses recorded keys and returns empty for absent keys"

# pid-ancestry: self is under self; a bogus ancestor is not.
mypid=$$
fm_inject_pid_under "$mypid" "$mypid" || fail "pid_under: a pid is under itself"
if fm_inject_pid_under "$mypid" 999999; then fail "pid_under: unrelated ancestor matched"; fi
if fm_inject_pid_under abc "$mypid"; then fail "pid_under: non-numeric child accepted"; fi
pass "pid_under walks ancestry and rejects non-numeric / unrelated pids"

# No pane recorded and nothing discoverable: graceful non-zero, nothing typed.
rm -f "$STATE_DIR/session-pane.env" "$STATE_DIR/.lock"
if fm_resolve_session_pane; then fail "resolve: unexpectedly resolved a pane with no record"; fi
fm_inject_wake; rc=$?
[ "$rc" -eq 1 ] || fail "no-pane: expected rc 1, got $rc"
pass "no recorded/discoverable pane -> resolve fails and inject returns 1 (degraded)"

# Everything below needs a real tmux server.
if [ -z "$REAL_TMUX" ]; then
  echo "skip (tmux not found): e2e delivery/deferral/discovery scenarios"
  echo "all fm-inject-wake pure-logic tests passed"
  exit 0
fi

# --- private-socket pane with a deterministic composer loop -----------------

cat > "$LOOP_SCRIPT" <<'LOOP'
#!/usr/bin/env bash
LOG="$1"
OLD_STTY=$(stty -g 2>/dev/null || true)
[ -z "$OLD_STTY" ] || stty -echo -icanon min 1 time 0 2>/dev/null || true
cleanup() { [ -z "$OLD_STTY" ] || stty "$OLD_STTY" 2>/dev/null || true; }
trap cleanup EXIT INT TERM
_buf=
redraw() { printf '\r\033[K%s' "$_buf"; }
submit_line() {
  printf '%s\n' "$_buf" >> "$LOG"
  _buf=
  printf '\r\033[K\n'
  redraw
}
redraw
while IFS= read -r -n 1 _ch; do
  if [ -z "$_ch" ]; then submit_line; continue; fi
  case "$_ch" in
    $'\r'|$'\n') submit_line ;;
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

# Point the resolver's fm_tmux calls at this private server for the whole run.
record_env() {  # <harness-pid>
  {
    printf 'FM_SESSION_PANE=%s\n' "$PANE"
    printf 'FM_SESSION_TMUX_SOCKET=%s\n' "$SOCKET"
    printf 'FM_SESSION_TMUX_BIN=%s\n' "$REAL_TMUX"
    printf 'FM_SESSION_HARNESS_PID=%s\n' "$1"
    printf 'FM_SESSION_REGISTERED_AT=%s\n' "$(date +%s)"
  } > "$STATE_DIR/session-pane.env"
}

# Environment self-check: can composer-state see typed text here? The deferral
# scenario depends on it; skip only that scenario if the CI terminal cannot.
record_env "$PANE_PID"
fm_resolve_session_pane || fail "resolve: valid recorded env did not resolve"
"$REAL_TMUX" -S "$SOCKET" send-keys -t "$PANE" -l "selfcheck-xyz"
sleep 0.5
PENDING_DETECTABLE=0
if [ "$(fm_tmux_composer_state "$PANE")" = pending ]; then PENDING_DETECTABLE=1; fi
"$REAL_TMUX" -S "$SOCKET" send-keys -t "$PANE" Enter
sleep 0.4
: > "$LOG_FILE"

# --- A: delivery -------------------------------------------------------------
record_env "$PANE_PID"
FM_WAKE_PROMPT="INJECT-WAKE-ALPHA" fm_inject_wake
rc=$?
[ "$rc" -eq 0 ] || fail "delivery: expected rc 0, got $rc"
sleep 0.4
grep -qx "INJECT-WAKE-ALPHA" "$LOG_FILE" || fail "delivery: wake nudge not submitted"
[ "$(grep -c . "$LOG_FILE")" -eq 1 ] || fail "delivery: expected exactly one submitted line"
pass "A: valid recorded pane -> wake nudge submitted exactly once"

# --- B: deferral on pending input -------------------------------------------
if [ "$PENDING_DETECTABLE" -eq 1 ]; then
  : > "$LOG_FILE"
  "$REAL_TMUX" -S "$SOCKET" send-keys -t "$PANE" -l "david is typing"
  sleep 0.4
  FM_WAKE_PROMPT="INJECT-WAKE-BETA" fm_inject_wake
  rc=$?
  [ "$rc" -eq 2 ] || fail "deferral: expected rc 2 (deferred), got $rc"
  grep -q "INJECT-WAKE-BETA" "$LOG_FILE" && fail "deferral: nudge submitted over pending input"
  # Clear the human line, then a later push must deliver cleanly.
  "$REAL_TMUX" -S "$SOCKET" send-keys -t "$PANE" Enter
  sleep 0.4
  : > "$LOG_FILE"
  FM_WAKE_PROMPT="INJECT-WAKE-BETA2" fm_inject_wake
  rc=$?
  [ "$rc" -eq 0 ] || fail "deferral: post-idle push expected rc 0, got $rc"
  sleep 0.4
  grep -qx "INJECT-WAKE-BETA2" "$LOG_FILE" || fail "deferral: post-idle nudge not delivered"
  pass "B: pending composer defers the push (rc 2), then delivers once idle"
else
  echo "skip (composer pending-detection unavailable in this terminal): deferral scenario"
fi

# --- D: vacated pane (dead pid AND non-harness foreground) is rejected -------
# The pane's foreground here is the loop's bash, which the default harness regex
# does not match, so a dead recorded pid reads as a truly vacated pane.
: > "$LOG_FILE"
dead=99998
while kill -0 "$dead" 2>/dev/null; do dead=$((dead - 1)); done
record_env "$dead"
rm -f "$STATE_DIR/.lock"   # no discovery escape hatch
FM_WAKE_PROMPT="INJECT-WAKE-DELTA" fm_inject_wake
rc=$?
[ "$rc" -eq 1 ] || fail "vacated-pane: expected rc 1 (no live pane), got $rc"
grep -q "INJECT-WAKE-DELTA" "$LOG_FILE" && fail "vacated-pane: injected into a vacated pane"
pass "D: dead recorded pid AND non-harness foreground is rejected (no injection)"

# --- D2: resume-in-place (dead pid, live harness foreground) still delivers ---
# Same dead recorded pid as D, but now the pane's foreground counts as a harness
# (firstmate resumed in place: same pane, new pid, stale recorded pid). The stale
# pid must NOT blind the push; validation falls through to the foreground-command
# check and delivery proceeds. Widen the harness regex to accept the loop's bash
# as the stand-in harness, since we cannot rename the pane's real foreground.
: > "$LOG_FILE"
record_env "$dead"
rm -f "$STATE_DIR/.lock"   # recorded env only; no discovery escape hatch
_saved_harness_re="$FM_INJECT_HARNESS_RE"
FM_INJECT_HARNESS_RE="bash|$FM_INJECT_HARNESS_RE"
fm_inject_validate "$REAL_TMUX" "$SOCKET" "$PANE" "$dead" \
  || fail "resume-in-place: dead recorded pid + live harness pane should validate"
FM_WAKE_PROMPT="INJECT-WAKE-DELTA2" fm_inject_wake
rc=$?
FM_INJECT_HARNESS_RE="$_saved_harness_re"
[ "$rc" -eq 0 ] || fail "resume-in-place: expected rc 0 (delivered), got $rc"
sleep 0.4
grep -qx "INJECT-WAKE-DELTA2" "$LOG_FILE" \
  || fail "resume-in-place: nudge not delivered to the resumed pane"
pass "D2: dead recorded pid but live harness foreground still delivers (resume survives)"

# --- E: discovery fallback by lock harness pid ------------------------------
: > "$LOG_FILE"
rm -f "$STATE_DIR/session-pane.env"
# The loop's bash is a child of the pane shell (pane_pid); use it as the lock's
# harness pid so discovery must walk ancestry to find this pane.
loop_pid=$(pgrep -P "$PANE_PID" 2>/dev/null | head -n1)
[ -n "$loop_pid" ] || loop_pid="$PANE_PID"
printf '%s\n' "$loop_pid" > "$STATE_DIR/.lock"
export FM_INJECT_TMUX_BIN_HINT="$REAL_TMUX" FM_INJECT_SOCKET_HINT="$SOCKET"
if fm_resolve_session_pane; then
  [ "$FM_INJECT_PANE" = "$PANE" ] || fail "discovery: resolved the wrong pane ($FM_INJECT_PANE)"
  FM_WAKE_PROMPT="INJECT-WAKE-EPS" fm_inject_wake
  rc=$?
  [ "$rc" -eq 0 ] || fail "discovery: inject after discovery expected rc 0, got $rc"
  sleep 0.4
  grep -qx "INJECT-WAKE-EPS" "$LOG_FILE" || fail "discovery: nudge not delivered after fallback"
  pass "E: no recorded file -> pane discovered via lock harness-pid ancestry, delivers"
else
  fail "discovery: fallback failed to resolve a live pane"
fi

echo "all fm-inject-wake tests passed"

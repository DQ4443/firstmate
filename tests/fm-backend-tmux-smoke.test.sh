#!/usr/bin/env bash
# tests/fm-backend-tmux-smoke.test.sh - real tmux smoke test for the tmux
# session-provider adapter (bin/backends/tmux.sh), the P1 checklist item
# "run a real tmux smoke test (create session, send text + Enter, capture,
# list, kill)" from data/fm-backend-design-d7/report.md. Every other suite in
# this repo fakes tmux; this one is the one place that talks to a REAL tmux
# server, isolated on a private socket (`-L`) so it never touches the host's
# actual sessions.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fail() { printf 'not ok - %s\n' "$1" >&2; cleanup_all; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }

command -v tmux >/dev/null 2>&1 || { echo "skip: tmux not found"; exit 0; }
REAL_TMUX=$(command -v tmux)
SOCKET="fm-backend-smoke-$$"
SHIM_DIR=
trap cleanup_all EXIT

cleanup_all() {
  "$REAL_TMUX" -L "$SOCKET" kill-server >/dev/null 2>&1 || true
  [ -n "${SHIM_DIR:-}" ] && rm -rf "$SHIM_DIR"
}

# A `tmux` shim on PATH that transparently redirects every call to the private
# socket, so bin/backends/tmux.sh's bare `tmux ...` invocations never touch the
# host's real sessions.
SHIM_DIR=$(mktemp -d "${TMPDIR:-/tmp}/fm-backend-smoke.XXXXXX")
cat > "$SHIM_DIR/tmux" <<SH
#!/usr/bin/env bash
exec "$REAL_TMUX" -L "$SOCKET" "\$@"
SH
chmod +x "$SHIM_DIR/tmux"
PATH="$SHIM_DIR:$PATH"
export PATH

# shellcheck source=bin/fm-backend.sh
. "$ROOT/bin/fm-backend.sh"
fm_backend_source tmux || fail "fm_backend_source tmux failed"

SESSION="smoke"
WINDOW="fm-smoke1"
TARGET="$SESSION:$WINDOW"

# --- create session ----------------------------------------------------------

tmux new-session -d -s "$SESSION" -x 200 -y 50 \
  || fail "real tmux: new-session failed"
fm_backend_tmux_create_task "$SESSION" "$WINDOW" "$HOME" \
  || fail "fm_backend_tmux_create_task failed to create the task window"
tmux list-windows -t "$SESSION" -F '#{window_name}' | grep -qx "$WINDOW" \
  || fail "created window is not visible in the real session"

# A second create for the SAME window name must refuse (mirrors fm-spawn.sh's
# duplicate-window guard).
if fm_backend_tmux_create_task "$SESSION" "$WINDOW" "$HOME" 2>/dev/null; then
  fail "fm_backend_tmux_create_task should refuse an existing window name"
fi
pass "real tmux: fm_backend_tmux_create_task creates a window and refuses a duplicate"

# --- new-window target form (bug 3) ------------------------------------------
# A bare `-t <session>` target resolves to the session's CURRENT window, so tmux
# inserts next-up-from-current; on tmux >= 3.7 with `renumber-windows on` that can
# land on an occupied index and fail "index in use". The adapter must target
# "<session>:" so tmux picks the next free index unambiguously (this also replaces
# the external PATH shim that used to rewrite bare session targets).
#
# Guard 1 (build-independent): capture the new-window invocation and assert the
# trailing-colon session target, never the bare session name. A `tmux` function
# shadows the PATH shim just for these calls (an `if`, not a `case`, and defined
# at top level - bash 3.2 cannot parse a function containing `case` inside $(...)),
# then it is unset so the rest of the suite uses the real socketed tmux again.
CAP_LOG="$SHIM_DIR/newwindow.args"
: > "$CAP_LOG"
# shellcheck disable=SC2329  # invoked indirectly by fm_backend_tmux_create_task
tmux() {
  if [ "${1:-}" = new-window ]; then shift; printf '%s\n' "$*" >> "$CAP_LOG"; return 0; fi
  return 0   # list-windows etc: empty output -> the duplicate check finds nothing
}
fm_backend_tmux_create_task "capture-ses" "fm-cap" "/tmp"
unset -f tmux
newwin_args=$(cat "$CAP_LOG")
case "$newwin_args" in
  *"-t capture-ses: "*) : ;;
  *"-t capture-ses "*) fail "create_task used a BARE session target (bug 3): $newwin_args" ;;
  *) fail "create_task new-window args were not as expected: $newwin_args" ;;
esac
pass "fm_backend_tmux_create_task targets '<session>:' (next free index), not the bare session"

# Guard 2 (real tmux behavioral): with renumber-windows on and a non-last active
# window, create_task must still succeed and the window must appear.
RENUM_SES="renum"
tmux new-session -d -s "$RENUM_SES" -x 200 -y 50 || fail "real tmux: new-session (renum) failed"
tmux set-option -t "$RENUM_SES" renumber-windows on
tmux set-option -t "$RENUM_SES" base-index 0
fm_backend_tmux_create_task "$RENUM_SES" "fm-r1" "$HOME" || fail "create_task fm-r1 failed under renumber-windows"
fm_backend_tmux_create_task "$RENUM_SES" "fm-r2" "$HOME" || fail "create_task fm-r2 failed under renumber-windows"
fm_backend_tmux_create_task "$RENUM_SES" "fm-r3" "$HOME" || fail "create_task fm-r3 failed under renumber-windows"
# Select a MIDDLE (non-last) window active, so a bare `-t <session>` would target
# an occupied index; create_task must still succeed via the trailing-colon form.
tmux select-window -t "$RENUM_SES:1" 2>/dev/null || tmux select-window -t "$RENUM_SES"
fm_backend_tmux_create_task "$RENUM_SES" "fm-r4" "$HOME" \
  || fail "create_task fm-r4 failed with a non-last active window under renumber-windows (bug 3)"
for w in fm-r1 fm-r2 fm-r3 fm-r4; do
  tmux list-windows -t "$RENUM_SES" -F '#{window_name}' | grep -qx "$w" \
    || fail "window $w not visible after create_task under renumber-windows"
done
tmux kill-session -t "$RENUM_SES" 2>/dev/null || true
pass "real tmux: create_task succeeds under renumber-windows with a non-last active window"

# --- send text + Enter -------------------------------------------------------

tmux send-keys -t "$TARGET" "cd /tmp && PS1='smoke\$ '" Enter
sleep 0.3
tmux send-keys -t "$TARGET" -l "clear" ; tmux send-keys -t "$TARGET" Enter
sleep 0.3

fm_backend_tmux_send_text_line "$TARGET" "echo captain-on-deck-line" \
  || fail "fm_backend_tmux_send_text_line failed"
sleep 0.5
out=$(fm_backend_tmux_capture "$TARGET" 20) || fail "fm_backend_tmux_capture failed after send_text_line"
case "$out" in
  *captain-on-deck-line*) : ;;
  *) fail "real tmux: fm_backend_tmux_send_text_line did not submit and echo the line"$'\n'"$out" ;;
esac
pass "real tmux: fm_backend_tmux_send_text_line sends literal text and submits with Enter"

# --- send_literal + send_key(Enter), the two-step form fm-spawn.sh uses for the
# harness launch command (literal send, settle, then a separate Enter) --------

fm_backend_tmux_send_literal "$TARGET" 'echo literal-then-key-captain' \
  || fail "fm_backend_tmux_send_literal failed"
sleep 0.2
fm_backend_tmux_send_key "$TARGET" Enter || fail "fm_backend_tmux_send_key Enter failed"
sleep 0.5
out=$(fm_backend_tmux_capture "$TARGET" 20) || fail "fm_backend_tmux_capture failed after send_literal+send_key"
case "$out" in
  *literal-then-key-captain*) : ;;
  *) fail "real tmux: send_literal + send_key(Enter) did not submit and echo the line"$'\n'"$out" ;;
esac
pass "real tmux: fm_backend_tmux_send_literal + fm_backend_tmux_send_key Enter submit as two separate steps"

# --- capture bounds -----------------------------------------------------------
# Print enough numbered lines to overflow the pane's visible height, then
# confirm a small capture window (-S -N) surfaces only the RECENT tail (the
# earliest lines scroll out of a small window) while a large one reaches back
# far enough to still see the earliest line - the same -S -N bounding fm-peek.sh
# and fm-watch.sh rely on for a bounded, cheap pane read.
fm_backend_tmux_send_text_line "$TARGET" "for i in \$(seq 1 80); do echo tag-line-\$i; done"
sleep 0.6
small=$(fm_backend_tmux_capture "$TARGET" 3) || fail "fm_backend_tmux_capture (small window) failed"
case "$small" in
  *tag-line-1$'\n'*) fail "a 3-line capture should not still see the very first numbered line"$'\n'"$small" ;;
esac
case "$small" in
  *tag-line-80*) : ;;
  *) fail "a 3-line capture should still contain the most recent output"$'\n'"$small" ;;
esac
large=$(fm_backend_tmux_capture "$TARGET" 200) || fail "fm_backend_tmux_capture (large window) failed"
case "$large" in
  *tag-line-1$'\n'*) : ;;
  *) fail "a 200-line capture should reach back far enough to see the first numbered line"$'\n'"$large" ;;
esac
pass "real tmux: fm_backend_tmux_capture's -S -N bound trims old history for a small window and reaches it for a large one"

# --- resolve_bare_selector (live-window-listing) -----------------------------

resolved=$(fm_backend_tmux_resolve_bare_selector "$WINDOW") \
  || fail "fm_backend_tmux_resolve_bare_selector failed to find the live window"
[ "$resolved" = "$TARGET" ] || fail "fm_backend_tmux_resolve_bare_selector resolved to '$resolved', expected '$TARGET'"
pass "real tmux: fm_backend_tmux_resolve_bare_selector (list-live) finds the created window by name"

if fm_backend_tmux_resolve_bare_selector "no-such-window-xyz" 2>/dev/null; then
  fail "fm_backend_tmux_resolve_bare_selector should fail for a nonexistent window"
fi
pass "real tmux: fm_backend_tmux_resolve_bare_selector fails for a window that does not exist"

# --- kill ---------------------------------------------------------------------

fm_backend_tmux_kill "$TARGET"
if tmux list-windows -t "$SESSION" -F '#{window_name}' 2>/dev/null | grep -qx "$WINDOW"; then
  fail "fm_backend_tmux_kill did not remove the window"
fi
# Best-effort contract: killing an already-gone window must not error.
fm_backend_tmux_kill "$TARGET" || fail "fm_backend_tmux_kill on an already-dead target must stay best-effort (never fail)"
pass "real tmux: fm_backend_tmux_kill removes the window and is idempotent/best-effort"

cleanup_all
trap - EXIT

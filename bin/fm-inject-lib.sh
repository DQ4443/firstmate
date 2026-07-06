#!/usr/bin/env bash
# fm-inject-lib.sh - resolve firstmate's tmux pane and PUSH a wake into it.
#
# This is the delivery half of event-driven wake (bin/fm-session-register.sh
# records the pane; this pushes into it). The launchd poller (bin/fm-poll.sh)
# sources this and, the instant a board event lands in the durable wake queue,
# types a one-line nudge into firstmate's own pane with tmux send-keys - exactly
# as if David typed it - so the running session wakes in seconds and drains the
# queue, instead of waiting minutes for its next self-scheduled poll.
#
# It reuses bin/fm-tmux-lib.sh for the hard part (ghost-aware composer detection
# and a verify-and-retry-Enter submit) so the injection can never corrupt real
# input: if the composer holds unsubmitted text (David mid-typing, or a prior
# swallowed injection) the push is deferred, not forced. It targets a specific
# tmux server via FM_TMUX_BIN / FM_TMUX_SOCKET (the fm_tmux seam), because the
# poller's launchd environment has neither $TMUX nor homebrew on PATH.
#
# Everything is best-effort and degrades cleanly: if no live pane can be
# resolved, the push is simply skipped and the durable wake queue plus the
# session's own drain carry the event exactly as they do today. This library
# never mutates the queue.

FM_INJECT_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-tmux-lib.sh
. "$FM_INJECT_LIB_DIR/fm-tmux-lib.sh"

FM_INJECT_STATE="${FM_STATE_OVERRIDE:-${STATE:-$(cd "$FM_INJECT_LIB_DIR/.." && pwd)/state}}"

# Harness command names, matched against a pane's foreground command as a soft
# liveness signal. Mirrors fm-lock.sh's HARNESS_RE. claude reports as
# "claude"/"claude_exe" (or a bare "node" launcher), so both are accepted.
FM_INJECT_HARNESS_RE='claude|codex|opencode|grok|node|^pi$'

# The nudge typed into the pane. A single plain line: it names itself as a
# machine wake (not a David message) and points at the exact next action so
# firstmate handles it deterministically. Overridable for tests.
FM_WAKE_PROMPT_DEFAULT='fm-wake: new board activity is queued. Run bin/fm-wake-drain.sh and handle it per AGENTS.md section 2.'

# Read one KEY=VALUE from the recorded pane file without sourcing it (the keys
# are fixed and the values are simple tokens, but parsing beats executing).
fm_inject_envget() {  # <file> <key>
  sed -n "s/^$2=//p" "$1" 2>/dev/null | head -n 1
}

# Run tmux against an explicit binary + socket (used during validation and
# discovery before FM_TMUX_BIN/FM_TMUX_SOCKET are committed for fm_tmux).
fm_inject_run() {  # <bin> <socket> <tmux-args...>
  local b=$1 s=$2
  shift 2
  [ -n "$b" ] || b=tmux
  if [ -n "$s" ]; then
    command "$b" -S "$s" "$@"
  else
    command "$b" "$@"
  fi
}

# True if <child> is <ancestor> or a descendant of it, walking the process tree
# upward a bounded number of hops. A harness (e.g. claude 87153) is a child of
# its pane's shell (the pane_pid), so this maps a recorded harness pid back to
# its owning pane during fallback discovery.
fm_inject_pid_under() {  # <child-pid> <ancestor-pid>
  local pid=$1 ancestor=$2 i=0 pp
  case "$pid$ancestor" in *[!0-9]*) return 1 ;; esac
  while [ "$i" -lt 12 ]; do
    [ "$pid" = "$ancestor" ] && return 0
    pp=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')
    case "$pp" in ''|*[!0-9]*) return 1 ;; esac
    [ "$pp" -gt 1 ] || return 1
    pid=$pp
    i=$((i + 1))
  done
  return 1
}

# Validate a recorded (bin, socket, pane, harness-pid) tuple: the pane must
# still exist on that server AND the session must still be live there. Liveness
# is the recorded harness pid being alive (authoritative), or, if that pid is
# unknown, the pane's foreground command still looking like a harness. A pane
# that exists but whose harness died (now a bare shell) fails, so we never inject
# into a pane the session has vacated.
fm_inject_validate() {  # <bin> <socket> <pane> <harness-pid>
  local b=$1 s=$2 pane=$3 hpid=$4 ids cmd
  [ -n "$pane" ] || return 1
  ids=$(fm_inject_run "$b" "$s" list-panes -a -F '#{pane_id}' 2>/dev/null) || return 1
  printf '%s\n' "$ids" | grep -qxF "$pane" || return 1
  if [ -n "$hpid" ] && printf '%s' "$hpid" | grep -qE '^[0-9]+$'; then
    kill -0 "$hpid" 2>/dev/null && return 0
    return 1
  fi
  cmd=$(fm_inject_run "$b" "$s" display-message -p -t "$pane" '#{pane_current_command}' 2>/dev/null) || return 1
  printf '%s' "$cmd" | grep -qiE "$FM_INJECT_HARNESS_RE"
}

# Fallback: no valid recorded pane, so find firstmate's pane by matching the
# lock's harness pid to a pane whose pane_pid is one of its ancestors. Bounded
# best-effort across a few plausible tmux binaries and sockets, since without the
# recorded file we do not know the server for certain.
fm_inject_discover() {  # sets FM_INJECT_PANE/FM_TMUX_BIN/FM_TMUX_SOCKET on success
  local hpid b s uid line pane ppid
  hpid=$(cat "$FM_INJECT_STATE/.lock" 2>/dev/null || true)
  case "$hpid" in ''|*[!0-9]*) return 1 ;; esac
  kill -0 "$hpid" 2>/dev/null || return 1
  uid=$(id -u 2>/dev/null || echo "")
  for b in "${FM_INJECT_TMUX_BIN_HINT:-}" "$(command -v tmux 2>/dev/null || true)" \
           /opt/homebrew/bin/tmux /usr/local/bin/tmux /usr/bin/tmux; do
    [ -n "$b" ] && [ -x "$b" ] || continue
    for s in "${FM_INJECT_SOCKET_HINT:-}" "" "/tmp/tmux-$uid/default" "/private/tmp/tmux-$uid/default"; do
      fm_inject_run "$b" "$s" list-panes -a -F '#{pane_id} #{pane_pid}' >/dev/null 2>&1 || continue
      while IFS= read -r line; do
        pane=${line%% *}
        ppid=${line##* }
        case "$ppid" in ''|*[!0-9]*) continue ;; esac
        if fm_inject_pid_under "$hpid" "$ppid"; then
          FM_INJECT_PANE=$pane
          FM_TMUX_BIN=$b
          FM_TMUX_SOCKET=$s
          export FM_TMUX_BIN FM_TMUX_SOCKET
          return 0
        fi
      done <<EOF
$(fm_inject_run "$b" "$s" list-panes -a -F '#{pane_id} #{pane_pid}' 2>/dev/null)
EOF
    done
  done
  return 1
}

# Resolve firstmate's pane, committing FM_INJECT_PANE and the fm_tmux target
# (FM_TMUX_BIN/FM_TMUX_SOCKET). Prefers the recorded file; falls back to
# discovery. Returns 1 (with FM_INJECT_PANE empty) when no live pane is found.
fm_resolve_session_pane() {
  local envf="$FM_INJECT_STATE/session-pane.env" pane socket bin hpid
  FM_INJECT_PANE=""
  if [ -f "$envf" ]; then
    pane=$(fm_inject_envget "$envf" FM_SESSION_PANE)
    socket=$(fm_inject_envget "$envf" FM_SESSION_TMUX_SOCKET)
    bin=$(fm_inject_envget "$envf" FM_SESSION_TMUX_BIN)
    hpid=$(fm_inject_envget "$envf" FM_SESSION_HARNESS_PID)
    if fm_inject_validate "$bin" "$socket" "$pane" "$hpid"; then
      FM_INJECT_PANE=$pane
      FM_TMUX_BIN=${bin:-tmux}
      FM_TMUX_SOCKET=$socket
      export FM_TMUX_BIN FM_TMUX_SOCKET
      return 0
    fi
    # Seed discovery with the recorded server so the fallback tries it first.
    FM_INJECT_TMUX_BIN_HINT=$bin
    FM_INJECT_SOCKET_HINT=$socket
  fi
  fm_inject_discover && return 0
  return 1
}

# Push the wake nudge into firstmate's pane. Return codes let the poller decide
# whether to advance its injected-seq marker:
#   0 - delivered and the composer cleared (advance; do not re-nudge these wakes)
#   1 - no live pane resolved (skip; the queue still holds the wakes)
#   2 - deferred: the composer holds real input, retry on a later cycle
#   3 - attempted but the submit was not confirmed empty, retry on a later cycle
# A retry that double-delivers is harmless: draining an already-empty queue is a
# no-op, so this errs toward re-nudging rather than dropping a wake.
fm_inject_wake() {
  local prompt="${FM_WAKE_PROMPT:-$FM_WAKE_PROMPT_DEFAULT}" state verdict
  fm_resolve_session_pane || return 1
  state=$(fm_tmux_composer_state "$FM_INJECT_PANE")
  [ "$state" = pending ] && return 2
  verdict=$(fm_tmux_submit_core "$FM_INJECT_PANE" "$prompt" 3 0.3 0.15)
  [ "$verdict" = empty ] && return 0
  return 3
}

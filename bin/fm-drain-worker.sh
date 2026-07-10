#!/usr/bin/env bash
# fm-drain-worker.sh - the headless board drain (Phase 0 of the first-class
# board-message trigger; see docs/headless-drain.md).
#
# THE PROBLEM THIS SOLVES: today a queued board wake only becomes a firstmate
# turn if the launchd poller can push a tmux nudge into the live interactive REPL
# (bin/fm-inject-lib.sh). If no REPL is attached, or its pane is unresolvable, or
# tmux is wedged, the wake sits in the durable queue until a human happens to run
# a turn. That makes "a David board message reliably wakes firstmate" depend on
# the REPL volunteering. This worker removes that dependency: the poller spawns it
# when there is un-drained board activity and no reachable REPL, and it runs a
# fresh, context-loaded, throwaway `claude -p` turn that reads every unanswered
# David thread message and posts a holding-ack (Phase 0 never auto-closes from
# headless - the safe first cut). That turn runs with a TIGHT tool allowlist (the
# Bash tool scoped to bin/fm-board-reply.sh alone, NOT --dangerously-skip-
# permissions), so an unattended, prompt-confused turn is structurally capped at
# posting a board reply - see the SECURITY note at the claude invocation below and
# docs/headless-drain.md "Capability scoping".
#
# WHY A THROWAWAY `claude -p` AND NOT `--resume`: resuming the interactive
# session's own session_id while the live REPL owns that file forks it. Phase 0
# feeds a deterministic on-disk preamble to a fresh turn instead, so the headless
# path holds ZERO load-bearing state in any context window and a compaction of the
# interactive session cannot lose a board message. Same-session --resume is a
# later phase, gated behind a single-holder lock.
#
# SINGLE-FLIGHT: a mkdir(2) lease at state/.drain-lease carrying the drain pid and
# its process identity. The lease is free ONLY after the recorded pid is confirmed
# dead (not on elapsed time), so a legitimately long coalesced drain never lets a
# second drain start. The poller checks the lease before spawning to avoid churn,
# but this worker re-acquires it atomically and exits if it loses the race.
#
# TWO SEQ MARKERS (see docs/headless-drain.md for the full contract):
#   state/.drain-attempted-seq - highest wake-queue seq a drain has SUCCESSFULLY
#     serviced (ack or close-out). Advanced here on success. The poller only
#     spawns a drain when the queue seq exceeds it, so a holding-ack does not make
#     the poller re-spawn every cycle.
#   state/.serviced-seq - highest wake-queue seq fully CLOSED OUT (a real answer,
#     never a holding-ack). Phase 0 posts only holding-acks, so this stays behind
#     and the pager SLA (bin/fm-pager.sh, driven from the poller) keeps escalating
#     an un-answered item until the live orchestrator resolves it.
#
# DEAD-LETTER: after FM_DRAIN_MAX_FAILURES genuine failures (claude missing, turn
# error, or a turn that posted nothing) the batch is written to state/.dead-letter
# and paged via bin/fm-pager.sh, and attempted-seq is advanced so the worker stops
# spinning on a batch a human now owns.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
THREADS="${FM_BOARD_THREADS_DIR:-$FM_HOME/data/board-threads}"

# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"

LEASE="$STATE/.drain-lease"
ATTEMPTED="$STATE/.drain-attempted-seq"
# state/.serviced-seq is advanced ONLY on a real close-out; Phase 0 posts holding-
# acks only, so this worker never touches it. The poller reads it for the pager
# SLA. A later phase that auto-closes trivial asks advances it here.
FAILFILE="$STATE/.drain-failures"
DEADLETTER="$STATE/.dead-letter"
SEQFILE="$STATE/.wake-queue.seq"
REPLY="$SCRIPT_DIR/fm-board-reply.sh"
PAGER="$SCRIPT_DIR/fm-pager.sh"

MAX_FAILURES=${FM_DRAIN_MAX_FAILURES:-3}
case "$MAX_FAILURES" in ''|*[!0-9]*) MAX_FAILURES=3 ;; esac
DRAIN_TIMEOUT=${FM_DRAIN_TIMEOUT:-180}
case "$DRAIN_TIMEOUT" in ''|*[!0-9]*) DRAIN_TIMEOUT=180 ;; esac

mkdir -p "$STATE"

log() { echo "fm-drain-worker: $* $(date '+%Y-%m-%dT%H:%M:%S%z')" >&2; }

read_seq() {  # <file> - a non-negative integer, or 0
  local v
  v=$(cat "$1" 2>/dev/null || echo 0)
  case "$v" in ''|*[!0-9]*) v=0 ;; esac
  printf '%s' "$v"
}

# --- lease ------------------------------------------------------------------
LEASE_HELD=0
release_lease() {
  [ "$LEASE_HELD" = 1 ] || return 0
  local owner
  owner=$(cat "$LEASE/pid" 2>/dev/null || true)
  if [ "$owner" = "${BASHPID:-$$}" ]; then
    rm -rf "$LEASE" 2>/dev/null || true
  fi
  LEASE_HELD=0
}
trap release_lease EXIT INT TERM

# acquire_lease: atomic mkdir. If it exists and the recorded pid is a genuinely
# live drain (pid alive AND identity matches, guarding against pid reuse), lose.
# A dead/recycled holder is reclaimed.
acquire_lease() {
  local hpid hid cur
  if mkdir "$LEASE" 2>/dev/null; then
    { printf '%s\n' "${BASHPID:-$$}" > "$LEASE/pid"; } 2>/dev/null || return 1
    fm_pid_identity "${BASHPID:-$$}" > "$LEASE/identity" 2>/dev/null || true
    : > "$LEASE/beat" 2>/dev/null || true
    LEASE_HELD=1
    return 0
  fi
  hpid=$(cat "$LEASE/pid" 2>/dev/null || true)
  hid=$(cat "$LEASE/identity" 2>/dev/null || true)
  if fm_pid_alive "$hpid"; then
    cur=$(fm_pid_identity "$hpid" 2>/dev/null || true)
    if [ -z "$hid" ] || [ "$cur" = "$hid" ]; then
      return 1
    fi
  fi
  rm -rf "$LEASE" 2>/dev/null || true
  if mkdir "$LEASE" 2>/dev/null; then
    { printf '%s\n' "${BASHPID:-$$}" > "$LEASE/pid"; } 2>/dev/null || return 1
    fm_pid_identity "${BASHPID:-$$}" > "$LEASE/identity" 2>/dev/null || true
    : > "$LEASE/beat" 2>/dev/null || true
    LEASE_HELD=1
    return 0
  fi
  return 1
}

# --- unanswered-thread scan (mirrors bin/fm-board-surface.sh) ----------------
# Prints one "<item-id>\t<one-line body>" per thread whose newest *.md file is
# authored by david with a non-empty body. Pure filesystem + jq, no board.json.
unanswered_threads() {
  local dd it newest ms base f hdr author body
  [ -d "$THREADS" ] || return 0
  for dd in "$THREADS"/*/; do
    [ -d "$dd" ] || continue
    it=$(basename "$dd")
    newest=""
    ms=0
    for f in "$dd"*.md; do
      [ -e "$f" ] || continue
      base=$(basename "$f" .md)
      case "${base%%-*}" in ''|*[!0-9]*) continue ;; esac
      if [ "${base%%-*}" -ge "$ms" ]; then ms="${base%%-*}"; newest="$f"; fi
    done
    [ -n "$newest" ] || continue
    hdr=$(head -n 1 "$newest" 2>/dev/null || true)
    author=$(printf '%s' "$hdr" | jq -r '.author // ""' 2>/dev/null || true)
    [ "$author" = "david" ] || continue
    body=$(sed '1,2d' "$newest" 2>/dev/null | tr '\n' ' ' | sed 's/[[:space:]]\{1,\}/ /g; s/^ //; s/ $//')
    [ -n "$body" ] || continue
    printf '%s\t%s\n' "$it" "$body"
  done
}

# --- claude resolution + bounded run ----------------------------------------
resolve_claude() {  # echoes an executable claude path, or nothing
  local c
  for c in "${FM_DRAIN_CLAUDE_BIN:-}" "$(command -v claude 2>/dev/null || true)" \
           "$HOME"/.nvm/versions/node/*/bin/claude \
           /opt/homebrew/bin/claude /usr/local/bin/claude; do
    [ -n "$c" ] && [ -x "$c" ] && { printf '%s' "$c"; return 0; }
  done
  return 1
}

# run_bounded <seconds> <cmd...> - run under a wall-clock cap without depending on
# coreutils (stock macOS has none; the launchd env has no PATH). Prefers
# timeout/gtimeout, falls back to a perl process-group alarm (the same pattern
# bin/fm-poll.sh's run_check uses).
run_bounded() {
  local secs=$1; shift
  if command -v timeout >/dev/null 2>&1; then
    timeout "$secs" "$@"
  elif command -v gtimeout >/dev/null 2>&1; then
    gtimeout "$secs" "$@"
  else
    # shellcheck disable=SC2016  # single quotes deliberate: Perl expands its own vars.
    perl -e 'my $t = shift; my $pid = fork; die "fork failed" unless defined $pid; if (!$pid) { setpgrp(0, 0); exec @ARGV } local $SIG{ALRM} = sub { kill "TERM", -$pid; select undef, undef, undef, 0.2; kill "KILL", -$pid; exit 124 }; alarm $t; waitpid $pid, 0; exit($? >> 8)' "$secs" "$@"
  fi
}

# --- failure accounting ------------------------------------------------------
fail_count() { read_seq "$FAILFILE"; }
bump_failures() {
  local n
  n=$(( $(fail_count) + 1 ))
  printf '%s\n' "$n" > "$FAILFILE" 2>/dev/null || true
  printf '%s' "$n"
}
clear_failures() { rm -f "$FAILFILE" 2>/dev/null || true; }

dead_letter() {  # <cur-seq> <reason>
  local cur=$1 reason=$2 ts
  ts=$(date '+%Y-%m-%dT%H:%M:%S%z')
  {
    printf '%s\tseq=%s\t%s\n' "$ts" "$cur" "$reason"
    unanswered_threads | sed 's/^/  unanswered: /'
  } >> "$DEADLETTER" 2>/dev/null || true
  if [ -x "$PAGER" ]; then "$PAGER" page "headless drain dead-lettered at seq $cur: $reason" >/dev/null 2>&1 || true; fi
  log "DEAD-LETTER seq=$cur ($reason); paged and advancing attempted-seq"
}

# ============================================================================
main() {
  local cur att pending claude_bin promptfile rc landed it body

  cur=$(read_seq "$SEQFILE")
  att=$(read_seq "$ATTEMPTED")
  # Nothing new since the last successful drain: no-op (the poller's own gate
  # usually catches this, but re-check so a stray manual invocation is cheap).
  [ "$cur" -gt "$att" ] || { log "nothing to drain (seq $cur <= attempted $att)"; return 0; }

  acquire_lease || { log "another drain holds the lease; exiting"; return 0; }

  pending=$(unanswered_threads)
  if [ -z "$pending" ]; then
    # The wake fired but no David message is actually outstanding (e.g. a check
    # other than a new David message, or firstmate already answered in-session).
    printf '%s\n' "$cur" > "$ATTEMPTED" 2>/dev/null || true
    clear_failures
    log "no unanswered David messages; advanced attempted-seq to $cur"
    return 0
  fi

  claude_bin=$(resolve_claude) || {
    local n; n=$(bump_failures)
    log "claude not found (failure $n/$MAX_FAILURES)"
    if [ "$n" -ge "$MAX_FAILURES" ]; then
      dead_letter "$cur" "claude binary not resolvable"
      printf '%s\n' "$cur" > "$ATTEMPTED" 2>/dev/null || true
      clear_failures
    fi
    return 0
  }

  # Build the deterministic on-disk preamble: the operating contract plus a
  # machine-readable snapshot of every unanswered David message. The UNANSWERED_ITEM
  # lines are the stable contract the turn (and the test stub) act on.
  promptfile=$(mktemp "${TMPDIR:-/tmp}/fm-drain-prompt.XXXXXX")
  {
    [ -f "$FM_HOME/AGENTS.md" ] && cat "$FM_HOME/AGENTS.md"
    [ -f "$FM_HOME/CLAUDE.md" ] && cat "$FM_HOME/CLAUDE.md"
    printf '\n===== HEADLESS BOARD DRAIN (Phase 0) =====\n'
    printf 'You are a throwaway headless firstmate turn spawned by the launchd poller because\n'
    printf 'a David board message is unanswered and no interactive session is reachable.\n\n'
    printf 'For EACH item below, post a brief context-aware HOLDING ACKNOWLEDGEMENT to its\n'
    printf 'thread with exactly this command (do NOT close the item, do NOT invent a final\n'
    printf 'answer, do NOT run any other work):\n'
    printf '  %s <item-id> "<your holding ack>" --your-court --once\n\n' "$REPLY"
    printf 'That command is the ONLY tool you are permitted to run: your Bash tool is scoped\n'
    printf 'to it alone and every other tool is denied, so do not attempt anything else.\n\n'
    printf 'A holding ack tells David the message is captured and the live orchestrator will\n'
    printf 'pick it up. Keep it to one or two plain sentences, no markdown, no emojis.\n\n'
    while IFS=$'\t' read -r it body; do
      [ -n "$it" ] || continue
      printf 'UNANSWERED_ITEM: %s\n' "$it"
      printf '  David said: %s\n' "$body"
    done <<EOF
$pending
EOF
  } > "$promptfile"

  # SECURITY - scoped capability, NOT --dangerously-skip-permissions. This is an
  # unattended, human-absent trigger loaded with the full operating contract (whose
  # autonomy grant lets firstmate merge non-project code, push to main, and dispatch
  # workflows), so the ONLY structural thing keeping the turn to "just post an ack"
  # must be a real permission boundary, not the prompt text. The turn runs with a
  # tight tool allowlist - the Bash tool restricted to bin/fm-board-reply.sh alone -
  # and default (non-bypass) permission mode, so in headless -p mode every OTHER
  # tool (arbitrary Bash, Edit/Write, git, network, MCP, sub-agents) is denied with
  # no prompt to satisfy. A prompt-confused or off-script turn is structurally
  # capped at posting a board reply; it cannot do arbitrary destructive things. The
  # residual capability is exactly "post any text as a board thread reply to an
  # existing item", which is the acceptable Phase-0 blast radius (see
  # docs/headless-drain.md "Capability scoping"). FM_DRAIN_CLAUDE_MODEL pins the
  # model when set (the real-binary acceptance test uses it to dodge a rate-limited
  # default); unset means the account default.
  log "invoking headless claude -p (scoped to $REPLY) for $(printf '%s\n' "$pending" | grep -c .) unanswered item(s)"
  if [ -n "${FM_DRAIN_CLAUDE_MODEL:-}" ]; then
    run_bounded "$DRAIN_TIMEOUT" "$claude_bin" -p \
      --allowedTools "Bash($REPLY:*)" --model "$FM_DRAIN_CLAUDE_MODEL" \
      < "$promptfile" >/dev/null 2>&1
  else
    run_bounded "$DRAIN_TIMEOUT" "$claude_bin" -p \
      --allowedTools "Bash($REPLY:*)" \
      < "$promptfile" >/dev/null 2>&1
  fi
  rc=$?
  rm -f "$promptfile" 2>/dev/null || true

  # Post-condition: success means the turn actually posted. Re-scan; every item
  # that was unanswered must now be answered (its newest file is no longer a
  # bare David message). A turn that returned 0 but posted nothing is a failure.
  landed=1
  while IFS=$'\t' read -r it body; do
    [ -n "$it" ] || continue
    if printf '%s\n' "$(unanswered_threads)" | cut -f1 | grep -qxF "$it"; then
      landed=0
    fi
  done <<EOF
$pending
EOF

  if [ "$rc" -eq 0 ] && [ "$landed" -eq 1 ]; then
    # Success: the batch is serviced by an ack. Advance attempted-seq so the
    # poller stops re-spawning; leave serviced-seq behind so the pager SLA stays
    # armed (Phase 0 acks are not close-outs).
    printf '%s\n' "$cur" > "$ATTEMPTED" 2>/dev/null || true
    clear_failures
    log "headless drain posted acks; advanced attempted-seq to $cur (serviced-seq left armed)"
    return 0
  fi

  local n; n=$(bump_failures)
  log "headless drain incomplete (rc=$rc landed=$landed; failure $n/$MAX_FAILURES)"
  if [ "$n" -ge "$MAX_FAILURES" ]; then
    dead_letter "$cur" "turn rc=$rc, posted=$landed"
    printf '%s\n' "$cur" > "$ATTEMPTED" 2>/dev/null || true
    clear_failures
  fi
  return 0
}

main "$@"

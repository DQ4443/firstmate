#!/usr/bin/env bash
# fm-executor.sh - a pool-pinned drain-loop harness for the sharded-executors
# queue (Phase 1 MVP). SHIPS DORMANT: the task-execution step is a clearly
# marked stub, so `run` refuses to drain in production until a real build hook is
# wired. Nothing here is launched by the current paradigm; it is additive,
# inert code.
#
# WHAT AN EXECUTOR IS (Fork A of the design): a persistent process pinned to one
# capacity pool that competes with its peers to claim tasks from the shared
# queue (bin/fm-queue.sh). Several executors draining in parallel is what
# removes firstmate's single-serial-inference bottleneck; pinning distinct
# executors to distinct pools (subscription vs pay-per-token) is what spreads the
# token-rate ceiling. Executors are NOT firstmate: they never write board.json
# or backlog.md, and they skip the single-session fleet lock (bin/fm-lock.sh),
# which exists to make a SECOND firstmate read-only. The only board-adjacent
# calls an executor makes are fm-item-agent.sh start/done (already
# concurrency-safe) so the board's In progress lights up through the UNCHANGED
# reconcile path. This boundary is a hard rule: an executor that wrote board.json
# directly would corrupt firstmate's single-writer invariant.
#
# state/executors.json (schema; created at register time, never committed):
#   { "executors": { "<exec-id>": {
#       "pool":  "<capacity pool: subscription|paypertoken|codex|...>",
#       "pid":   <harness pid, for liveness>,
#       "since": <epoch of registration>,
#       "beat":  <epoch of last drain cycle>,
#       "claims": <count of tasks claimed this lifetime> } } }
# It is maintained under a lock (state/.executors.json.lock) with the same
# temp-then-rename read-modify-write as state/item-agents.json, so concurrent
# executors registering/beating cannot last-writer-wins away each other.
#
# THE TASK-EXECUTION HOOK IS DORMANT (Phase 1). Activation depends on two things
# still gated on David: a pay-per-token capacity pool, and the terminal
# autonomous build workflow (build in an isolated worktree -> verify ->
# no-mistakes + Bugbot -> PR, all WITHOUT returning to firstmate). Until both
# land, `run` with no injected hook prints the dormancy notice and exits without
# claiming anything. The queue mechanics below (register, claim, heartbeat,
# done, fail, and the poller's reclaim) are REAL and tested; only the build step
# is stubbed. A test or a future activation injects a real hook via
# FM_EXECUTOR_TASK_HOOK="<command>"; the command receives <task-id> and the
# claimed file path, and must exit 0 (built; may print a sha on stdout) or
# nonzero (failed).
#
# Every single-quoted jq program references jq's own variables, not shell
# parameters, so SC2016 is disabled file-wide.
# shellcheck disable=SC2016
#
# Usage:
#   fm-executor.sh register  <exec-id> --pool P [--pid PID]
#   fm-executor.sh beat       <exec-id>
#   fm-executor.sh unregister <exec-id>
#   fm-executor.sh list
#   fm-executor.sh run        <exec-id> --pool P   # drain loop (DORMANT without a hook)
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"

QUEUE="${FM_QUEUE_DIR:-$STATE/queue}"
FILE="$STATE/executors.json"
REG_LOCK="$STATE/.executors.json.lock"
QUEUE_SH="$SCRIPT_DIR/fm-queue.sh"
ITEM_AGENT_SH="$SCRIPT_DIR/fm-item-agent.sh"

IDLE="${FM_EXECUTOR_IDLE:-15}"          # seconds to sleep when the queue is empty
MAX_ITER="${FM_EXECUTOR_MAX_ITER:-0}"   # 0 = drain forever; >0 bounds the loop (tests)
case "$IDLE" in ''|*[!0-9]*) IDLE=15 ;; esac
case "$MAX_ITER" in ''|*[!0-9]*) MAX_ITER=0 ;; esac

# Lease knob mirrors bin/fm-queue.sh so the mid-task claim-heartbeat interval can
# be derived from it. INVARIANT: the heartbeat interval must be << LEASE_TTL, or
# the reaper re-homes an actively-building task (finding 2). We beat the claim
# every LEASE_TTL/4, giving four heartbeats per lease of margin.
LEASE_TTL="${FM_QUEUE_LEASE_TTL:-${FM_AGENT_LIVE_TTL:-1800}}"
case "$LEASE_TTL" in ''|*[!0-9]*) LEASE_TTL=1800 ;; esac

ID_RE='^[a-z0-9][a-z0-9-]{0,63}$'

die() { echo "fm-executor: $1" >&2; exit 2; }
command -v jq >/dev/null 2>&1 || die "jq is required"
valid_id() { printf '%s' "$1" | grep -qE "$ID_RE"; }

mkdir -p "$STATE"

load() {
  if [ -f "$FILE" ]; then
    if ! jq -e . "$FILE" >/dev/null 2>&1; then
      die "existing $FILE is not valid JSON; refusing to overwrite it (fix or remove it by hand)"
    fi
    cat "$FILE"
  else
    printf '{"executors":{}}\n'
  fi
}

# Atomic read-modify-write under the registry lock, mirroring
# bin/fm-item-agent.sh: concurrent executors touching executors.json cannot
# clobber each other.
write_transform() {
  local prog=$1; shift
  local cur tmp
  fm_lock_acquire_wait "$REG_LOCK"
  cur=$(load) || { fm_lock_release "$REG_LOCK"; exit 2; }
  tmp="$STATE/.executors.json.tmp.$$"
  if printf '%s' "$cur" | jq "$@" "$prog" > "$tmp"; then
    mv "$tmp" "$FILE"
    fm_lock_release "$REG_LOCK"
  else
    rm -f "$tmp" 2>/dev/null || true
    fm_lock_release "$REG_LOCK"
    die "jq transform failed"
  fi
}

now=$(date +%s)
cmd=${1:-}
[ -n "$cmd" ] || die "usage: register|beat|unregister|list|run (see --help / header)"
shift || true

case "$cmd" in
  register)
    exec_id=${1:-}; shift || true
    valid_id "$exec_id" || die "invalid executor id: '${exec_id:-}'"
    pool=""; pid=${BASHPID:-$$}
    while [ $# -gt 0 ]; do
      case "$1" in
        --pool) pool=${2:-}; shift 2 ;;
        --pid) pid=${2:-}; shift 2 ;;
        *) die "register: unknown flag '$1'" ;;
      esac
    done
    [ -n "$pool" ] || die "register requires --pool"
    case "$pid" in ''|*[!0-9]*) die "invalid --pid" ;; esac
    write_transform \
      '.executors[$id] = ((.executors[$id] // {claims:0}) + {pool:$pool, pid:$pid, since:(.executors[$id].since // $now), beat:$now})' \
      --arg id "$exec_id" --arg pool "$pool" --argjson pid "$pid" --argjson now "$now"
    echo "registered executor: $exec_id (pool=$pool pid=$pid)"
    ;;

  beat)
    exec_id=${1:-}
    valid_id "$exec_id" || die "invalid executor id: '${exec_id:-}'"
    write_transform 'if .executors[$id] then .executors[$id].beat = $now else . end' \
      --arg id "$exec_id" --argjson now "$now"
    ;;

  unregister)
    exec_id=${1:-}
    valid_id "$exec_id" || die "invalid executor id: '${exec_id:-}'"
    write_transform 'del(.executors[$id])' --arg id "$exec_id"
    echo "unregistered executor: $exec_id"
    ;;

  list)
    load | jq '.executors'
    ;;

  run)
    exec_id=${1:-}; shift || true
    valid_id "$exec_id" || die "invalid executor id: '${exec_id:-}'"
    pool=""
    while [ $# -gt 0 ]; do
      case "$1" in
        --pool) pool=${2:-}; shift 2 ;;
        *) die "run: unknown flag '$1'" ;;
      esac
    done
    [ -n "$pool" ] || die "run requires --pool"

    # ADOPTION SWITCH: no queue dir -> nothing to drain, exit clean.
    if [ ! -d "$QUEUE" ]; then
      echo "fm-executor: queue $QUEUE absent; nothing to drain (adoption switch)" >&2
      exit 0
    fi

    # DORMANCY GUARD: the terminal-autonomous build workflow is not wired yet.
    # Without an injected hook, refuse to claim anything - this is the expected
    # Phase 1 state, gated on David (pay-per-token pool + terminal-autonomous
    # workflow). The queue mechanics are exercised via an injected hook in tests.
    if [ -z "${FM_EXECUTOR_TASK_HOOK:-}" ]; then
      echo "fm-executor: DORMANT (Phase 1) - no task-execution hook wired; refusing to drain." >&2
      echo "fm-executor: activation is gated on David (pay-per-token pool + terminal-autonomous workflow)." >&2
      exit 0
    fi

    self_pid=${BASHPID:-$$}
    "$0" register "$exec_id" --pool "$pool" --pid "$self_pid" >/dev/null
    # Best-effort deregistration on exit so a crashed executor ages out cleanly.
    trap '"$0" unregister "$exec_id" >/dev/null 2>&1 || true' EXIT INT TERM

    iter=0
    while :; do
      "$0" beat "$exec_id" >/dev/null 2>&1 || true
      claimed_id=$("$QUEUE_SH" claim "$exec_id" --pool "$pool" --owner-pid "$self_pid" 2>/dev/null) || claimed_id=""
      if [ -n "$claimed_id" ]; then
        claim_file="$QUEUE/claimed/$exec_id/$claimed_id.json"
        board_item=$(jq -r '.board_item // ""' "$claim_file" 2>/dev/null || echo "")
        # Light the board through the ONLY sanctioned board-adjacent call.
        [ -n "$board_item" ] && "$ITEM_AGENT_SH" start "$board_item" "$exec_id" >/dev/null 2>&1 || true

        # ===== DORMANT task-execution HOOK (Phase 1) =====================
        # The real build (isolated worktree -> verify -> no-mistakes -> PR) is
        # NOT implemented here; a hook is injected for tests/activation only.
        # While the (possibly >30min) hook runs, heartbeat the CLAIM every
        # LEASE_TTL/4 so the reaper's lease never expires under an active build
        # (the missing mid-task heartbeat that let the reaper re-home a live
        # task, finding 2). The loop is torn down the instant the hook returns.
        hb_interval=$((LEASE_TTL / 4)); [ "$hb_interval" -ge 1 ] || hb_interval=1
        ( while :; do
            sleep "$hb_interval"
            "$QUEUE_SH" beat "$exec_id" "$claimed_id" >/dev/null 2>&1 || true
          done ) &
        hb_pid=$!
        sha=""; hook_rc=0
        sha=$("$FM_EXECUTOR_TASK_HOOK" "$claimed_id" "$claim_file" 2>/dev/null) || hook_rc=$?
        kill "$hb_pid" 2>/dev/null || true
        wait "$hb_pid" 2>/dev/null || true
        # =================================================================

        if [ "$hook_rc" -eq 0 ]; then
          "$QUEUE_SH" "done" "$exec_id" "$claimed_id" --sha "$sha" >/dev/null 2>&1 || true
        else
          "$QUEUE_SH" fail "$exec_id" "$claimed_id" --reason "task hook rc=$hook_rc" >/dev/null 2>&1 || true
        fi
        [ -n "$board_item" ] && "$ITEM_AGENT_SH" "done" "$board_item" >/dev/null 2>&1 || true
        # Count the claim in executors.json.
        write_transform 'if .executors[$id] then .executors[$id].claims = ((.executors[$id].claims // 0) + 1) else . end' \
          --arg id "$exec_id" || true
      else
        sleep "$IDLE"
      fi
      iter=$((iter + 1))
      [ "$MAX_ITER" -gt 0 ] && [ "$iter" -ge "$MAX_ITER" ] && break
    done
    ;;

  -h|--help|help)
    sed -n '2,55p' "$0"
    ;;

  *)
    die "unknown command: $cmd"
    ;;
esac

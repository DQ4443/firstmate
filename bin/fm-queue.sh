#!/usr/bin/env bash
# fm-queue.sh - the sharded-executors task queue (Phase 1 MVP, DORMANT).
#
# WHAT THIS IS: the file-based work queue a pool of executor processes drains in
# parallel, so throughput is no longer bounded by firstmate's single serial
# inference. It is the substrate of the sharded-executors design (move 3:
# "shard by workstream, coordinate through files"). It ships DORMANT: nothing
# creates state/queue/ in the live state dir and no executor is launched, so the
# merged code cannot disturb the current poller (see the ADOPTION SWITCH below
# and maybe_reap_claims in bin/fm-poll.sh).
#
# SUBSTRATE - a directory of claim files under $FM_QUEUE_DIR (default
# $STATE/queue):
#   ready/<id>.json                 intake writes here; the claimable set is ls ready/
#   claimed/<exec-id>/<id>.json     claim = atomic mv from ready/ (the rename IS the lock)
#   done/<id>.json                  carries sha + pr (the idempotency anchor)
#   failed/<id>.json                poison / past max_attempts (a dead-letter row)
#
# TASK RECORD (one json object per file):
#   { id, board_item, repo, scope_paths[], deps[], autonomy, pool_pref,
#     owner, owner_pid, started, beat, attempts, sha, pr }
# scope_paths/deps are recorded now but NOT enforced in Phase 1 (scope-conflict
# serialization is Phase 3); they are carried so the record does not have to
# change shape later.
#
# CLAIM PROTOCOL: claim wins the lock by renaming ready/<id>.json to a HIDDEN,
# timestamped staging name `claimed/<exec>/.<id>.json.claiming.<epoch>.<pid>`;
# rename(2) is atomic on a single local filesystem, so exactly one concurrent
# claimer wins (the losers' source is already gone and their mv fails). It then
# stamps owner_pid/beat in the staging file and PUBLISHES it under
# claimed/<exec>/<id>.json, so the reaper (which globs *.json) never sees an
# unstamped claim - closing the claim/reap TOCTOU (a reap in the old
# mv-then-stamp gap re-homed a just-claimed task -> duplicate execution). The
# rename is still the lock; this is lockless by construction. Everything else is
# a temp-then-rename content write, matching bin/fm-board-checkin.sh /
# bin/fm-item-agent.sh. This atomicity assumes single-machine local disk; it
# would break on NFS/multi-host, which is out of scope for Phase 1.
#
# HEARTBEAT + RECLAIM: a claiming executor stamps owner_pid + beat, and (via
# bin/fm-executor.sh) heartbeats the claim's beat on a background loop while its
# build hook runs, so a long build never lets the lease expire. The `reap`
# subcommand (run each cycle by the poller, bin/fm-poll.sh maybe_reap_claims)
# re-homes a claim whose owner PID is dead (kill -0 via fm-wake-lib's
# fm_pid_alive) or whose beat is older than the lease TTL: back to ready/ with
# attempts++ , or to failed/ once attempts reach the max. A claim whose task
# already has a done/<id>.json is dropped (idempotency: it finished). A hidden
# .claiming.<epoch> staging file (a claim that crashed mid-publish) is re-homed
# only once older than CLAIM_GRACE, so a fresh mid-stamp claim is never touched.
#
# ADOPTION SWITCH: `reap` is a COMPLETE no-op when $FM_QUEUE_DIR does not exist,
# so wiring it into the live poller changes nothing until the queue is adopted
# by hand (mkdir state/queue). Mirrors bin/fm-board-reconcile.sh's registry
# adoption switch.
#
# Every single-quoted jq program here references jq's own variables, not shell
# parameters, so SC2016 is disabled file-wide.
# shellcheck disable=SC2016
#
# Usage:
#   fm-queue.sh enqueue <id> [--board-item ID] [--repo NAME] [--scope a,b]
#                            [--deps x,y] [--autonomy passive|active] [--pool P]
#   fm-queue.sh claim   <exec-id> [--pool P] [--owner-pid PID]   # prints claimed id; exit 1 if none
#   fm-queue.sh beat    <exec-id> <id>                            # bump a claim's heartbeat
#   fm-queue.sh done    <exec-id> <id> [--sha SHA] [--pr URL]
#   fm-queue.sh fail    <exec-id> <id> [--reason TEXT]
#   fm-queue.sh reap                                              # re-home dead/expired claims (no-op if queue absent)
#   fm-queue.sh list    [ready|claimed|done|failed|all]
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

# fm_pid_alive (kill -0 liveness) for the reaper; the queue itself is lockless.
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"

QUEUE="${FM_QUEUE_DIR:-$STATE/queue}"
RQ="$QUEUE/ready"
CQ="$QUEUE/claimed"
DQ="$QUEUE/done"
FQ="$QUEUE/failed"

# Lease + retry knobs reuse the FM_AGENT_LIVE_TTL convention (default 1800s).
LEASE_TTL="${FM_QUEUE_LEASE_TTL:-${FM_AGENT_LIVE_TTL:-1800}}"
MAX_ATTEMPTS="${FM_QUEUE_MAX_ATTEMPTS:-3}"
case "$LEASE_TTL" in ''|*[!0-9]*) LEASE_TTL=1800 ;; esac
case "$MAX_ATTEMPTS" in ''|*[!0-9]*) MAX_ATTEMPTS=3 ;; esac

# CLAIM_GRACE - the window that protects a just-won, not-yet-stamped claim from
# the reaper (the claim/reap TOCTOU guard). `claim` wins the ready->claimed
# rename, then stamps owner_pid/beat in a second step; a reap firing in that gap
# must never re-home the claim. Two guards use this constant: (1) a claim is
# published under its <id>.json name only AFTER it is stamped - the pre-stamp
# record lives under a hidden .claiming.<epoch> staging name the reaper's *.json
# glob ignores - so an unstamped <id>.json is never visible; (2) the reaper
# re-homes a crash-orphaned staging file only once it is older than this grace,
# so a claim being stamped RIGHT NOW is never touched. Must exceed the
# sub-second stamp duration with wide margin.
CLAIM_GRACE="${FM_QUEUE_CLAIM_GRACE:-30}"
case "$CLAIM_GRACE" in ''|*[!0-9]*) CLAIM_GRACE=30 ;; esac

# Same strict slug the board server enforces (board-v2 lib/store.ts ID_RE), so a
# typo cannot register a ghost task or escape the queue directory.
ID_RE='^[a-z0-9][a-z0-9-]{0,63}$'

die() { echo "fm-queue: $1" >&2; exit 2; }

command -v jq >/dev/null 2>&1 || die "jq is required"

valid_id() { printf '%s' "$1" | grep -qE "$ID_RE"; }

# csv_to_json_array <csv> -> a JSON array, dropping empty fields. Empty in -> [].
csv_to_json_array() {
  if [ -z "$1" ]; then printf '[]'; return; fi
  printf '%s' "$1" | jq -R 'split(",") | map(select(length > 0))'
}

ensure_dirs() { mkdir -p "$RQ" "$CQ" "$DQ" "$FQ"; }

# write_json_atomic <dest-file> < json-on-stdin: temp in the dest dir + rename, so
# a concurrent reader never sees a half-written file (the repo's state-write idiom).
write_json_atomic() {
  local dest=$1 dir tmp
  dir=$(dirname "$dest")
  mkdir -p "$dir"
  tmp="$dir/.$(basename "$dest").tmp.$$"
  if cat > "$tmp"; then
    mv "$tmp" "$dest"
  else
    rm -f "$tmp" 2>/dev/null || true
    die "failed to write $dest"
  fi
}

# file_mtime <path> - epoch of last content modification, portable across
# BSD/macOS (stat -f %m) and GNU/Linux (stat -c %Y). 0 if unreadable.
file_mtime() { stat -f %m "$1" 2>/dev/null || stat -c %Y "$1" 2>/dev/null || echo 0; }

# reap_rehome <src-file> <id> - re-home a reaped claim (or crash-orphaned staging
# file): attempts++, to failed/ once it reaches the max else back to ready/ with
# owner cleared, then remove <src-file>. Shared by the staging-orphan sweep and
# the main claim loop so both dead-letter identically.
reap_rehome() {
  local src=$1 id=$2 attempts
  attempts=$(jq -r '.attempts // 0' "$src" 2>/dev/null || echo 0)
  case "$attempts" in ''|*[!0-9]*) attempts=0 ;; esac
  attempts=$((attempts + 1))
  if [ "$attempts" -ge "$MAX_ATTEMPTS" ]; then
    jq --argjson n "$attempts" --arg reason "max-attempts ($MAX_ATTEMPTS) exceeded" \
       '.attempts = $n | .owner = "" | .owner_pid = 0 | .fail_reason = $reason' \
       "$src" | write_json_atomic "$FQ/$id.json"
  else
    jq --argjson n "$attempts" '.attempts = $n | .owner = "" | .owner_pid = 0 | .started = 0' \
       "$src" | write_json_atomic "$RQ/$id.json"
  fi
  rm -f "$src" 2>/dev/null || true
}

now=$(date +%s)
cmd=${1:-}
[ -n "$cmd" ] || die "usage: enqueue|claim|beat|done|fail|reap|list (see --help / header)"
shift || true

case "$cmd" in
  enqueue)
    id=${1:-}; shift || true
    valid_id "$id" || die "invalid task id: '${id:-}'"
    board_item=""; repo=""; scope=""; deps=""; autonomy="passive"; pool="any"
    while [ $# -gt 0 ]; do
      case "$1" in
        --board-item) board_item=${2:-}; shift 2 ;;
        --repo) repo=${2:-}; shift 2 ;;
        --scope) scope=${2:-}; shift 2 ;;
        --deps) deps=${2:-}; shift 2 ;;
        --autonomy) autonomy=${2:-}; shift 2 ;;
        --pool) pool=${2:-}; shift 2 ;;
        *) die "enqueue: unknown flag '$1'" ;;
      esac
    done
    case "$autonomy" in
      passive|active) ;;
      *) die "invalid autonomy: '$autonomy' (must be passive or active)" ;;
    esac
    ensure_dirs
    [ -f "$RQ/$id.json" ] && die "task $id already in ready/"
    scope_json=$(csv_to_json_array "$scope")
    deps_json=$(csv_to_json_array "$deps")
    jq -n --arg id "$id" --arg bi "$board_item" --arg repo "$repo" \
       --argjson scope "$scope_json" --argjson deps "$deps_json" \
       --arg autonomy "$autonomy" --arg pool "$pool" '{
         id: $id, board_item: $bi, repo: $repo,
         scope_paths: $scope, deps: $deps,
         autonomy: $autonomy, pool_pref: $pool,
         owner: "", owner_pid: 0, started: 0, beat: 0,
         attempts: 0, sha: "", pr: ""
       }' | write_json_atomic "$RQ/$id.json"
    echo "enqueued: $id -> ready/ (autonomy=$autonomy pool=$pool)"
    ;;

  claim)
    exec_id=${1:-}; shift || true
    [ -n "$exec_id" ] || die "claim requires an executor id"
    valid_id "$exec_id" || die "invalid executor id: '$exec_id'"
    pool=""; owner_pid=${PPID:-0}
    while [ $# -gt 0 ]; do
      case "$1" in
        --pool) pool=${2:-}; shift 2 ;;
        --owner-pid) owner_pid=${2:-0}; shift 2 ;;
        *) die "claim: unknown flag '$1'" ;;
      esac
    done
    case "$owner_pid" in ''|*[!0-9]*) owner_pid=0 ;; esac
    [ -d "$RQ" ] || exit 1
    mkdir -p "$CQ/$exec_id"
    # FIFO by filename; try each until one rename wins. A file that vanishes
    # between the pool read and the mv was claimed by a peer: mv fails, move on.
    for f in "$RQ"/*.json; do
      [ -e "$f" ] || continue
      id=$(basename "$f" .json)
      if [ -n "$pool" ]; then
        pp=$(jq -r '.pool_pref // "any"' "$f" 2>/dev/null || echo any)
        [ "$pp" = any ] || [ "$pp" = "$pool" ] || continue
      fi
      # CLAIM/REAP TOCTOU FIX: win the lock by renaming ready -> a HIDDEN,
      # timestamped staging name (never matched by the reaper's *.json glob),
      # stamp owner_pid/beat there, then PUBLISH under <id>.json. The reaper
      # therefore never sees an unstamped <id>.json (the owner_pid:0/beat:0 gap
      # the old mv-then-stamp exposed), so it can never re-home a mid-stamp
      # claim. The rename is STILL the single-winner lock: exactly one claimer's
      # mv of ready/<id>.json succeeds; the losers get ENOENT and move on. The
      # staging name carries the claim epoch so the reaper can re-home a
      # crash-orphaned staging file after CLAIM_GRACE (convergence preserved)
      # while never touching a fresh one.
      stage="$CQ/$exec_id/.$id.json.claiming.$now.$$"
      if mv "$f" "$stage" 2>/dev/null; then
        dst="$CQ/$exec_id/$id.json"
        tmp="$CQ/$exec_id/.$id.json.tmp.$$"
        if jq --arg exec "$exec_id" --argjson pid "$owner_pid" --argjson now "$now" \
             '.owner = $exec | .owner_pid = $pid | .started = (if .started > 0 then .started else $now end) | .beat = $now' \
             "$stage" > "$tmp" 2>/dev/null; then
          mv "$tmp" "$dst"          # publish: <id>.json exists only once stamped
          rm -f "$stage" 2>/dev/null || true
          echo "$id"
          exit 0
        else
          # Stamp failed (pathological, e.g. jq broke): restore the task to
          # ready/ and fail the claim rather than publish an unstamped claim.
          rm -f "$tmp" 2>/dev/null || true
          mv "$stage" "$f" 2>/dev/null || true
          exit 1
        fi
      fi
    done
    exit 1
    ;;

  beat)
    # Freshen a live claim's lease. An executor calls this on a background loop
    # while its (possibly >30min) build hook runs, at an interval << LEASE_TTL
    # (see bin/fm-executor.sh), so the reaper never re-homes an actively-building
    # task. Without it the claim's beat is stamped once at claim time and the
    # lease expires mid-build - the missing mid-task heartbeat (finding 2).
    exec_id=${1:-}; id=${2:-}
    valid_id "$exec_id" 2>/dev/null || die "invalid executor id: '${exec_id:-}'"
    valid_id "$id" || die "invalid task id: '${id:-}'"
    src="$CQ/$exec_id/$id.json"
    [ -f "$src" ] || die "no claimed task $id for executor $exec_id"
    tmp="$CQ/$exec_id/.$id.json.tmp.$$"
    if jq --argjson now "$now" '.beat = $now' "$src" > "$tmp"; then
      mv "$tmp" "$src"
    else
      rm -f "$tmp" 2>/dev/null || true
      die "beat write failed"
    fi
    echo "beat: $id at $now"
    ;;

  done)
    exec_id=${1:-}; id=${2:-}; shift 2 2>/dev/null || true
    valid_id "$exec_id" 2>/dev/null || die "invalid executor id: '${exec_id:-}'"
    valid_id "$id" || die "invalid task id: '${id:-}'"
    sha=""; pr=""
    while [ $# -gt 0 ]; do
      case "$1" in
        --sha) sha=${2:-}; shift 2 ;;
        --pr) pr=${2:-}; shift 2 ;;
        *) die "done: unknown flag '$1'" ;;
      esac
    done
    src="$CQ/$exec_id/$id.json"
    [ -f "$src" ] || die "no claimed task $id for executor $exec_id"
    # Create the done/ anchor first, then drop the claim: a crash between the two
    # leaves a claim the reaper harmlessly drops (done/ already present).
    jq --arg sha "$sha" --arg pr "$pr" --argjson now "$now" \
       '.sha = $sha | .pr = $pr | .beat = $now' "$src" | write_json_atomic "$DQ/$id.json"
    rm -f "$src" 2>/dev/null || true
    echo "done: $id -> done/"
    ;;

  fail)
    exec_id=${1:-}; id=${2:-}; shift 2 2>/dev/null || true
    valid_id "$exec_id" 2>/dev/null || die "invalid executor id: '${exec_id:-}'"
    valid_id "$id" || die "invalid task id: '${id:-}'"
    reason=""
    while [ $# -gt 0 ]; do
      case "$1" in
        --reason) reason=${2:-}; shift 2 ;;
        *) die "fail: unknown flag '$1'" ;;
      esac
    done
    src="$CQ/$exec_id/$id.json"
    [ -f "$src" ] || die "no claimed task $id for executor $exec_id"
    jq --arg reason "$reason" --argjson now "$now" \
       '.fail_reason = $reason | .beat = $now' "$src" | write_json_atomic "$FQ/$id.json"
    rm -f "$src" 2>/dev/null || true
    echo "failed: $id -> failed/ (${reason:-no reason})"
    ;;

  reap)
    # ADOPTION SWITCH: no queue dir -> COMPLETE no-op, so wiring this into the
    # live poller cannot disturb current operation.
    [ -d "$CQ" ] || exit 0
    reaped=0
    for exec_dir in "$CQ"/*/; do
      [ -d "$exec_dir" ] || continue

      # Crash-orphaned mid-claim sweep: a hidden .claiming.<epoch> staging file
      # is a claim that won the ready->claimed rename but crashed before it could
      # publish <id>.json. Re-home it ONLY once it is older than CLAIM_GRACE
      # (epoch parsed from the staging name), so a claim being stamped RIGHT NOW
      # (a fresh staging file) is never re-homed - this is the TOCTOU guard - while
      # a genuine crash orphan converges back to ready/.
      for s in "$exec_dir".*.json.claiming.*; do
        [ -e "$s" ] || continue
        sbase=$(basename "$s"); srest=${sbase#.}
        sid=${srest%%.json.claiming.*}
        stail=${srest#*.json.claiming.}
        sts=${stail%%.*}
        case "$sts" in ''|*[!0-9]*) sts=0 ;; esac
        # Already published or finished: a post-publish staging leftover; drop it.
        if [ -f "$exec_dir$sid.json" ] || [ -f "$DQ/$sid.json" ]; then
          rm -f "$s" 2>/dev/null || true
          continue
        fi
        [ "$((now - sts))" -ge "$CLAIM_GRACE" ] || continue
        reap_rehome "$s" "$sid"
        reaped=$((reaped + 1))
      done

      for f in "$exec_dir"*.json; do
        [ -e "$f" ] || continue
        id=$(basename "$f" .json)
        # Already finished elsewhere (crash between done-write and claim-drop):
        # the done/ anchor wins; just drop the orphan claim.
        if [ -f "$DQ/$id.json" ]; then
          rm -f "$f" 2>/dev/null || true
          continue
        fi
        opid=$(jq -r '.owner_pid // 0' "$f" 2>/dev/null || echo 0)
        beat=$(jq -r '.beat // 0' "$f" 2>/dev/null || echo 0)
        case "$opid" in ''|*[!0-9]*) opid=0 ;; esac
        case "$beat" in ''|*[!0-9]*) beat=0 ;; esac
        # DEFENSE IN DEPTH: a published <id>.json is always stamped (owner_pid>0)
        # in normal operation thanks to the staging-publish protocol, but if an
        # unstamped one ever appears, treat it as a fresh mid-stamp claim until it
        # is older than CLAIM_GRACE (by mtime) - the reaper still never re-homes a
        # just-claimed task.
        if [ "$opid" -le 0 ] && [ "$((now - $(file_mtime "$f")))" -lt "$CLAIM_GRACE" ]; then
          continue
        fi
        dead=0
        # owner_pid <= 0 is never a live owner; treat as dead (pid 0 is a group).
        if [ "$opid" -le 0 ] || ! fm_pid_alive "$opid"; then
          dead=1
        fi
        expired=0
        if [ "$((now - beat))" -ge "$LEASE_TTL" ]; then
          expired=1
        fi
        [ "$dead" = 1 ] || [ "$expired" = 1 ] || continue
        # Re-home FIRST (converges on a crash: a leftover claim is re-reaped next
        # cycle; nothing is lost), then drop the claim - reap_rehome does both.
        reap_rehome "$f" "$id"
        reaped=$((reaped + 1))
      done
      rmdir "$exec_dir" 2>/dev/null || true
    done
    [ "$reaped" -gt 0 ] && echo "reaped $reaped claim(s)"
    exit 0
    ;;

  list)
    sect=${1:-all}
    print_dir() { # <label> <dir>
      local label=$1 dir=$2 f
      for f in "$dir"/*.json; do
        [ -e "$f" ] || continue
        printf '%s\t%s\n' "$label" "$(basename "$f" .json)"
      done
    }
    print_claimed() {
      local exec_dir
      for exec_dir in "$CQ"/*/; do
        [ -d "$exec_dir" ] || continue
        print_dir "claimed:$(basename "$exec_dir")" "$exec_dir"
      done
    }
    case "$sect" in
      ready) print_dir ready "$RQ" ;;
      claimed) print_claimed ;;
      done) print_dir "done" "$DQ" ;;
      failed) print_dir failed "$FQ" ;;
      all)
        print_dir ready "$RQ"
        print_claimed
        print_dir "done" "$DQ"
        print_dir failed "$FQ"
        ;;
      *) die "list: unknown section '$sect' (ready|claimed|done|failed|all)" ;;
    esac
    ;;

  -h|--help|help)
    sed -n '2,60p' "$0"
    ;;

  *)
    die "unknown command: $cmd"
    ;;
esac

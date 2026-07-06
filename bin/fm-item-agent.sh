#!/usr/bin/env bash
# fm-item-agent.sh - the item -> agent registration that makes the board's
# In progress section liveness-derived instead of hand-maintained.
#
# THE PROBLEM THIS SOLVES: firstmate used to hand-edit board sections, so In
# progress drifted from reality - it showed false spinners for work that had
# already finished, because moving a row out of In progress was a separate manual
# step that raced the board and got forgotten. The fix is to stop hand-editing In
# progress at all and DERIVE it: firstmate records here which board item each
# dispatched agent is working, and bin/fm-board-reconcile.sh rewrites the board so
# In progress = exactly the items with a live agent. This script owns the one
# small state file that makes that possible: state/item-agents.json.
#
# THE CONTRACT firstmate follows (documented in full in docs/liveness-board.md):
#   - When it dispatches an agent for a board item:
#       fm-item-agent.sh start <item-id> <agent-id> [rest-section]
#     rest-section is where the item belongs once the agent is gone (the section
#     it "rests" in): your_word (default, waiting on David) or landed. It is
#     recorded now so the reconcile can demote deterministically later.
#   - Long agents keep the item live past the staleness TTL by checking in at
#     phase boundaries; bin/fm-board-checkin.sh already stamps that heartbeat, so
#     no extra call is usually needed. `beat` is here for agents that do not.
#   - When the agent returns (or the item is otherwise no longer being worked):
#       fm-item-agent.sh done <item-id>
#     which flips the item to not-live so the next reconcile demotes it to its
#     rest section. `remove` deletes the record outright.
#
# state/item-agents.json shape:
#   { "items": { "<item-id>": {
#       "agent": "<agent name or id>",
#       "since": <epoch>, "beat": <epoch>, "done": <bool>, "rest": "<section>" } } }
#
# Liveness is NOT decided here - it is computed by the reconcile from done +
# freshness (this file's `beat`/`since` and state/board-checkins.json) against
# FM_AGENT_LIVE_TTL. This script only records facts; the reconcile is the one
# owner of the live/not-live decision.
#
# Every single-quoted jq program below references jq's own $id/$now/$rest/$ttl
# variables, never shell parameters, so SC2016 is disabled file-wide here.
# shellcheck disable=SC2016
#
# Usage:
#   fm-item-agent.sh start  <item-id> <agent-id> [rest-section]
#   fm-item-agent.sh beat   <item-id>
#   fm-item-agent.sh done   <item-id>
#   fm-item-agent.sh remove <item-id>
#   fm-item-agent.sh get    <item-id>
#   fm-item-agent.sh list
#   fm-item-agent.sh prune  [ttl-seconds]   # drop done or stale-beyond-ttl records
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
FILE="$STATE/item-agents.json"

# Item ids are board row ids: the same strict slug the board server enforces
# (board-v2 lib/store.ts ID_RE), so a typo cannot register a ghost item.
ID_RE='^[a-z0-9][a-z0-9-]{0,63}$'

die() { echo "fm-item-agent: $1" >&2; exit 2; }

command -v jq >/dev/null 2>&1 || die "jq is required to maintain $FILE"

valid_id() { printf '%s' "$1" | grep -qE "$ID_RE"; }

mkdir -p "$STATE"

# Load the current object, or {} for a missing file. A PRESENT but unparseable
# file is a hard error: silently starting from {} would wipe every live
# registration and let the reconcile demote the whole board. Refusing to write
# is the safe failure.
load() {
  if [ -f "$FILE" ]; then
    if ! jq -e . "$FILE" >/dev/null 2>&1; then
      die "existing $FILE is not valid JSON; refusing to overwrite it (fix or remove it by hand)"
    fi
    cat "$FILE"
  else
    printf '{"items":{}}\n'
  fi
}

# Atomically replace the file with the jq program's output applied to the
# current contents. Extra --argjson/--arg pairs are passed through.
write_transform() {
  local prog=$1
  shift
  local cur tmp
  cur=$(load)
  tmp="$STATE/.item-agents.json.tmp.$$"
  if printf '%s' "$cur" | jq "$@" "$prog" > "$tmp"; then
    mv "$tmp" "$FILE"
  else
    rm -f "$tmp" 2>/dev/null || true
    die "jq transform failed"
  fi
}

now=$(date +%s)
cmd=${1:-}
[ -n "$cmd" ] || die "usage: start|beat|done|remove|get|list|prune (see --help / header)"

case "$cmd" in
  start)
    id=${2:-}; agent=${3:-}; rest=${4:-your_word}
    valid_id "$id" || die "invalid item id: '${id:-}'"
    [ -n "$agent" ] || die "start requires an agent id"
    prog='.items[$id] = ((.items[$id] // {}) + {agent:$agent, since:(.items[$id].since // $now), beat:$now, done:false, rest:$rest})'
    write_transform "$prog" --arg id "$id" --arg agent "$agent" --arg rest "$rest" --argjson now "$now"
    echo "registered: $id -> agent $agent (rest=$rest)"
    ;;
  beat)
    id=${2:-}
    valid_id "$id" || die "invalid item id: '${id:-}'"
    write_transform 'if .items[$id] then .items[$id].beat = $now else . end' \
      --arg id "$id" --argjson now "$now"
    echo "beat: $id at $now"
    ;;
  done)
    id=${2:-}
    valid_id "$id" || die "invalid item id: '${id:-}'"
    write_transform 'if .items[$id] then .items[$id].done = true | .items[$id].beat = $now else . end' \
      --arg id "$id" --argjson now "$now"
    echo "done: $id (will demote to its rest section on next reconcile)"
    ;;
  remove)
    id=${2:-}
    valid_id "$id" || die "invalid item id: '${id:-}'"
    write_transform 'del(.items[$id])' --arg id "$id"
    echo "removed: $id"
    ;;
  get)
    id=${2:-}
    valid_id "$id" || die "invalid item id: '${id:-}'"
    load | jq -e --arg id "$id" '.items[$id] // empty' || { echo "(no record for $id)"; exit 1; }
    ;;
  list)
    load | jq '.items'
    ;;
  prune)
    ttl=${2:-${FM_AGENT_LIVE_TTL:-1800}}
    case "$ttl" in ''|*[!0-9]*) die "prune ttl must be integer seconds" ;; esac
    prog='.items |= with_entries(select(((.value.done // false) | not) and ($now - ([.value.since // 0, .value.beat // 0] | max) < $ttl)))'
    write_transform "$prog" --argjson now "$now" --argjson ttl "$ttl"
    echo "pruned done/stale records (ttl=${ttl}s)"
    ;;
  -h|--help|help)
    sed -n '2,60p' "$0"
    ;;
  *)
    die "unknown command: $cmd"
    ;;
esac

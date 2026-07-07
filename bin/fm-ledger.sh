#!/usr/bin/env bash
# fm-ledger.sh - a resumable loop-ledger for a long autonomous run.
#
# Mechanical pinning (AGENTS.md section 4): rules that fire late in a run are
# compacted out of a long session's context, so run state that a late step
# depends on must live in a file, not in conversation. This helper is that file:
# one JSON ledger per run under state/ledgers/<run>.json, carrying the objective,
# the current phase, the decisions taken so far, the next contract-critical
# action, and a status. A resuming or post-compaction firstmate reads the ledger
# to recover where a run is and what it must do next, rather than reconstructing
# it from a window that no longer holds it.
#
# Fields: run, objective, phase, decisions[], next, status, created_at,
# updated_at. create seeds objective (and optional --next); update sets any of
# --phase/--next/--status and appends each --decision; read prints the JSON.
#
# Usage:
#   fm-ledger.sh create <run-id> <objective> [--next <text>]
#   fm-ledger.sh update <run-id> [--phase P] [--next N] [--status S] \
#                                 [--decision "text"] ...
#   fm-ledger.sh read   <run-id>
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
LEDGERS="$STATE/ledgers"

usage() {
  echo "usage: fm-ledger.sh create <run-id> <objective> [--next <text>]" >&2
  echo "       fm-ledger.sh update <run-id> [--phase P] [--next N] [--status S] [--decision T] ..." >&2
  echo "       fm-ledger.sh read   <run-id>" >&2
  exit 2
}

if ! command -v jq >/dev/null 2>&1; then
  echo "fm-ledger: jq is required to read and write state/ledgers/<run>.json" >&2
  exit 1
fi

[ "$#" -ge 2 ] || usage
CMD=$1
RUN=$2
shift 2

# Reject anything that could escape the ledgers dir; a run id is a flat name.
case "$RUN" in
  ''|*/*|.|..|*..*) echo "fm-ledger: invalid run id '$RUN'" >&2; exit 2 ;;
esac
FILE="$LEDGERS/$RUN.json"

now() { date +%s; }

write_atomic() {  # <json-on-stdin>
  mkdir -p "$LEDGERS"
  local tmp="$LEDGERS/.$RUN.json.tmp.$$"
  trap 'rm -f "$tmp" 2>/dev/null || true' EXIT
  cat > "$tmp"
  mv "$tmp" "$FILE"
}

case "$CMD" in
  create)
    [ "$#" -ge 1 ] || usage
    OBJECTIVE=$1
    shift
    NEXT=""
    while [ "$#" -gt 0 ]; do
      case "$1" in
        --next) NEXT=${2:-}; shift 2 ;;
        *) echo "fm-ledger: unknown create option '$1'" >&2; exit 2 ;;
      esac
    done
    TS=$(now)
    jq -n \
      --arg run "$RUN" \
      --arg objective "$OBJECTIVE" \
      --arg next "$NEXT" \
      --argjson ts "$TS" \
      '{run: $run, objective: $objective, phase: "", decisions: [],
        next: $next, status: "active", created_at: $ts, updated_at: $ts}' \
      | write_atomic
    echo "ledger created: $FILE"
    ;;
  update)
    [ -f "$FILE" ] || { echo "fm-ledger: no ledger for run '$RUN' (create it first)" >&2; exit 1; }
    SET_PHASE=0; PHASE=""
    SET_NEXT=0;  NEXT=""
    SET_STATUS=0; STATUS=""
    DECISIONS=()
    while [ "$#" -gt 0 ]; do
      case "$1" in
        --phase)    SET_PHASE=1; PHASE=${2:-}; shift 2 ;;
        --next)     SET_NEXT=1; NEXT=${2:-}; shift 2 ;;
        --status)   SET_STATUS=1; STATUS=${2:-}; shift 2 ;;
        --decision) DECISIONS+=("${2:-}"); shift 2 ;;
        *) echo "fm-ledger: unknown update option '$1'" >&2; exit 2 ;;
      esac
    done
    # Build the added-decisions JSON array from the collected --decision values.
    ADD=$(printf '%s\n' "${DECISIONS[@]:-}" | jq -R . | jq -s 'map(select(. != ""))')
    jq \
      --argjson set_phase "$SET_PHASE" --arg phase "$PHASE" \
      --argjson set_next "$SET_NEXT" --arg next "$NEXT" \
      --argjson set_status "$SET_STATUS" --arg status "$STATUS" \
      --argjson add "$ADD" \
      --argjson ts "$(now)" \
      '(if $set_phase == 1 then .phase = $phase else . end)
       | (if $set_next == 1 then .next = $next else . end)
       | (if $set_status == 1 then .status = $status else . end)
       | .decisions = (.decisions + $add)
       | .updated_at = $ts' \
      "$FILE" | write_atomic
    echo "ledger updated: $FILE"
    ;;
  read)
    [ -f "$FILE" ] || { echo "fm-ledger: no ledger for run '$RUN'" >&2; exit 1; }
    jq . "$FILE"
    ;;
  *)
    usage
    ;;
esac

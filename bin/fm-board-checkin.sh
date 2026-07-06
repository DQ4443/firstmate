#!/usr/bin/env bash
# fm-board-checkin.sh - write a real per-item last-checked stamp.
#
# The board shows a "last checked Xm ago" stamp per In-progress item, read from
# state/board-checkins.json. Under the workflow paradigm the orchestration
# script calls this deterministically at every phase boundary and log()
# checkpoint (AGENTS.md section 4), so the stamp is a real fact rather than
# decoration - the failure the 2026-07-05 directive names, where
# board-checkins.json sat at {} while David asked whether anyone was checking.
#
# It sets board-checkins.json[<item-id>] to the given epoch (default now),
# merging into the existing object and writing atomically so a concurrent read
# by the board never sees a half-written file.
#
# Usage: fm-board-checkin.sh <item-id> [<epoch-seconds>]
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

if [ "$#" -lt 1 ] || [ -z "${1:-}" ]; then
  echo "usage: fm-board-checkin.sh <item-id> [<epoch-seconds>]" >&2
  exit 2
fi
ID=$1
EPOCH=${2:-$(date +%s)}
case "$EPOCH" in
  ''|*[!0-9]*) echo "fm-board-checkin: epoch must be integer seconds, got '$EPOCH'" >&2; exit 2 ;;
esac

if ! command -v jq >/dev/null 2>&1; then
  echo "fm-board-checkin: jq is required to update state/board-checkins.json" >&2
  exit 1
fi

mkdir -p "$STATE"
FILE="$STATE/board-checkins.json"
[ -f "$FILE" ] || printf '{}\n' > "$FILE"

TMP="$STATE/.board-checkins.json.tmp.$$"
trap 'rm -f "$TMP" 2>/dev/null || true' EXIT
# Tolerate a corrupt/empty existing file by starting from {} on parse failure.
if ! jq --arg id "$ID" --argjson ts "$EPOCH" '. + {($id): $ts}' "$FILE" > "$TMP" 2>/dev/null; then
  jq -n --arg id "$ID" --argjson ts "$EPOCH" '{($id): $ts}' > "$TMP"
fi
mv "$TMP" "$FILE"
echo "checked in: $ID at $EPOCH"

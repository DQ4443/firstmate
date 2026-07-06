#!/usr/bin/env bash
# fm-board-reconcile.sh - make the board's In progress section a computed fact.
#
# WHAT IT DOES: rewrites state/board.json so In progress = EXACTLY the board
# items that have a live agent, and every other row rests in its correct section.
# It runs every poller cycle (bin/fm-poll.sh), so the board self-corrects with no
# hand editing - killing the false-spinner problem where finished work sat in In
# progress because moving it out was a manual step that got forgotten.
#
# LIVENESS: an item is live iff its state/item-agents.json record is not `done`
# and its freshness is within FM_AGENT_LIVE_TTL (default 1800s). Freshness is the
# newest of the record's `since`/`beat` and the item's stamp in
# state/board-checkins.json (which the workflow orchestration already bumps at
# every phase boundary, AGENTS.md section 4). So a healthy long run stays live via
# its check-ins; a crashed or forgotten agent ages out of In progress on its own;
# and an explicit `fm-item-agent.sh done` demotes immediately. The registration
# contract firstmate follows lives in fm-item-agent.sh and docs/liveness-board.md.
#
# THE TRANSFORM (idempotent):
#   - Promote into In progress every row (from any section) whose item is live.
#   - Demote out of In progress every row whose item is NOT live, into its rest
#     section: the record's `rest` (your_word default, or landed), converting a
#     row to a landed item when landing. holding is never an auto-rest target
#     (dependency-blocking is a human judgment), so it falls back to your_word.
#   - Leave your_word / holding / landed rows otherwise untouched, only removing a
#     row that got promoted so no item appears twice.
#   A live item that has no row anywhere cannot be shown; the reconcile moves rows,
#   it does not invent them.
#
# SAFETY:
#   - ADOPTION SWITCH: if state/item-agents.json does not exist, this is a NO-OP.
#     The board stays exactly as firstmate left it until the registry is adopted,
#     so turning the script on cannot wipe a hand-maintained board.
#   - A missing or unparseable board.json is left untouched (never clobbered).
#   - An unparseable item-agents.json aborts with no write: demoting the whole
#     board on a parse error would be the worst possible failure.
#   - The write is atomic (temp + rename) under a lock (state/.board.json.lock),
#     and is skipped entirely when the result equals the current board, so the
#     poller cycle is a cheap no-op whenever nothing changed.
#
# Usage: fm-board-reconcile.sh          reconcile once; silent unless it changed
#        fm-board-reconcile.sh --verbose  also print a one-line summary
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"

BOARD="${FM_BOARD_DATA:-$STATE/board.json}"
AGENTS="$STATE/item-agents.json"
CHECKS="$STATE/board-checkins.json"
LOCK="$STATE/.board.json.lock"
TTL="${FM_AGENT_LIVE_TTL:-1800}"
DEFAULT_REST="${FM_RECONCILE_DEFAULT_REST:-your_word}"

VERBOSE=0
[ "${1:-}" = "--verbose" ] && VERBOSE=1

note() { [ "$VERBOSE" -eq 1 ] && echo "fm-board-reconcile: $1" || true; }

command -v jq >/dev/null 2>&1 || { echo "fm-board-reconcile: jq required" >&2; exit 1; }
case "$TTL" in ''|*[!0-9]*) TTL=1800 ;; esac

# Adoption switch: no registry means the liveness-derived board is not adopted
# yet; leave the board exactly as it is.
if [ ! -f "$AGENTS" ]; then
  note "registry $AGENTS absent; reconcile inactive (no-op)"
  exit 0
fi

# Board must be readable and an object; otherwise leave it untouched.
if [ ! -f "$BOARD" ]; then
  note "board $BOARD absent; nothing to reconcile"
  exit 0
fi
if ! jq -e 'type == "object"' "$BOARD" >/dev/null 2>&1; then
  echo "fm-board-reconcile: $BOARD is missing/unparseable; leaving it untouched" >&2
  exit 0
fi

# Registry must parse; a parse error must NOT demote the whole board.
if ! jq -e 'type == "object"' "$AGENTS" >/dev/null 2>&1; then
  echo "fm-board-reconcile: $AGENTS is unparseable; refusing to reconcile (would demote everything)" >&2
  exit 1
fi

# board-checkins.json is advisory freshness only; tolerate its absence/corruption.
checks_json='{}'
if [ -f "$CHECKS" ] && jq -e 'type == "object"' "$CHECKS" >/dev/null 2>&1; then
  checks_json=$(cat "$CHECKS")
fi

now=$(date +%s)

# --- stage 1: compute the live-id set and the id -> rest map ------------------
live_json=$(jq -n \
  --argjson agents "$(cat "$AGENTS")" \
  --argjson checks "$checks_json" \
  --argjson now "$now" \
  --argjson ttl "$TTL" '
  ($agents.items // {}) | to_entries
  | map(select((.value.done // false) | not))
  | map(. + {fresh: ([.value.since // 0, .value.beat // 0, ($checks[.key] // 0)] | max)})
  | map(select(($now - .fresh) < $ttl))
  | map(.key)
') || { echo "fm-board-reconcile: live-set computation failed" >&2; exit 1; }

rest_json=$(jq -n --argjson agents "$(cat "$AGENTS")" '
  ($agents.items // {}) | to_entries
  | map({key: .key, value: (.value.rest // "your_word")}) | from_entries
') || { echo "fm-board-reconcile: rest-map computation failed" >&2; exit 1; }

# --- stage 2: transform the board -------------------------------------------
# shellcheck disable=SC2016  # the jq program references jq variables, not shell.
TRANSFORM='
  ($live | map({key: ., value: true}) | from_entries) as $L
  | def islive($id): ($L[$id] // false);
  # convert a landed item into a row (for the rare live-again landed item)
  def landed_to_row: {id: .id, stamp: "do", rid: (.title // .id), what: (.what // ""), links: (.links // [])};
  # convert a demoted in-progress row into a landed item
  def row_to_landed:
    {id: .id, title: (.rid // .id)}
    + (if ((.what | type) == "string") and ((.what | length) > 0) then {what: .what} else {} end)
    + (if (.links | type) == "array" then {links: .links} else {} end);
  def dedup_by_id: reduce .[] as $r ([]; if (map(.id) | index($r.id)) then . else . + [$r] end);

  (.your_word // []) as $yw
  | (.in_progress // []) as $ip
  | (.holding // []) as $hg
  | (.landed // []) as $ld
  | ([ $hg[].rows[]? ]) as $hrows
  # In-progress rows that stay (preserve their order).
  | ($ip | map(select(islive(.id)))) as $kept
  | ($kept | map(.id)) as $keptids
  # Promote live rows from other sections, skipping ids already kept.
  | (($yw + $hrows) | map(select(islive(.id) and ((.id) as $i | ($keptids | index($i)) | not)))) as $prom_rows
  | ($ld | map(select(islive(.id))) | map(landed_to_row)
        | map(select((.id) as $i | ($keptids | index($i)) | not))) as $prom_landed
  | ($kept + $prom_rows + $prom_landed) as $new_ip
  | ($new_ip | map(.id)) as $ipids
  # Non-live rows currently in In progress get demoted.
  | ($ip | map(select(islive(.id) | not))) as $demoted
  | ($demoted | map(select((($R[.id]) // $D) == "landed"))) as $dem_landed
  | ($demoted | map(select((($R[.id]) // $D) != "landed"))) as $dem_yw
  # Rebuild each section, stripping any id promoted into In progress.
  | ($yw | map(select((.id) as $i | ($ipids | index($i)) | not))) as $yw_keep
  | ($ld | map(select((.id) as $i | ($ipids | index($i)) | not))) as $ld_keep
  | ($hg | map(.rows |= map(select((.id) as $i | ($ipids | index($i)) | not)))
        | map(select((.rows | length) > 0))) as $hg_keep
  | .in_progress = $new_ip
  | .your_word = (($yw_keep + $dem_yw) | dedup_by_id)
  | .landed = (($ld_keep + ($dem_landed | map(row_to_landed))) | dedup_by_id)
  | .holding = $hg_keep
'

new_board=$(jq \
  --argjson live "$live_json" \
  --argjson R "$rest_json" \
  --arg D "$DEFAULT_REST" \
  "$TRANSFORM" "$BOARD") || { echo "fm-board-reconcile: board transform failed" >&2; exit 1; }

# Idempotence / no-churn: only write when the canonical form actually changed.
if [ "$(jq -S . "$BOARD")" = "$(printf '%s' "$new_board" | jq -S .)" ]; then
  note "no change"
  exit 0
fi

# Atomic write under the board lock (serializes with any other board writer that
# takes the same lock). temp + rename so a concurrent board read never sees a
# half-written file.
if ! printf '%s' "$new_board" | jq -e 'type == "object"' >/dev/null 2>&1; then
  echo "fm-board-reconcile: refused to write a non-object result" >&2
  exit 1
fi
fm_lock_acquire_wait "$LOCK"
tmp="$STATE/.board.json.reconcile.$$"
if printf '%s\n' "$new_board" > "$tmp"; then
  mv "$tmp" "$BOARD"
  fm_lock_release "$LOCK"
  note "board reconciled: in_progress now $(printf '%s' "$new_board" | jq '.in_progress | length') live item(s)"
  exit 0
fi
rm -f "$tmp" 2>/dev/null || true
fm_lock_release "$LOCK"
echo "fm-board-reconcile: failed to write temp file" >&2
exit 1

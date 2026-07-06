#!/usr/bin/env bash
# fm-board-reconcile.sh - make the board's In progress section a computed fact.
#
# WHAT IT DOES: rewrites state/board.json so In progress = EXACTLY the board
# items that have a live agent, and every other row rests in its correct section.
# It runs every poller cycle (bin/fm-poll.sh), so the board self-corrects with no
# hand editing - killing the false-spinner problem where finished work sat in In
# progress because moving it out was a manual step that got forgotten.
#
# LIVENESS: In progress means "the ball is with firstmate", which is either of
# two signals, and an item is live iff EITHER holds:
#   1. Agent-live: its state/item-agents.json record is not `done` and its
#      freshness is within FM_AGENT_LIVE_TTL (default 1800s). Freshness is the
#      newest of the record's `since`/`beat` and the item's stamp in
#      state/board-checkins.json (which the workflow orchestration bumps at every
#      phase boundary, AGENTS.md section 4). So a healthy long run stays live via
#      its check-ins; a crashed or forgotten agent ages out of In progress on its
#      own; an explicit `fm-item-agent.sh done` demotes immediately.
#   2. Message-live: the NEWEST message file in the item's thread is authored by
#      david - a fresh unanswered David message (AGENTS.md section 2). This is
#      derived from the thread itself with no hand bookkeeping; a firstmate reply
#      becomes the newest file and clears it, demoting the item to Your word. It
#      is the same signal board-v2's auto-flip-on-send uses, so reconcile agrees
#      with the board rather than fighting it.
# The registration contract firstmate follows lives in fm-item-agent.sh and
# docs/liveness-board.md.
#
# CROSS-REPO CONTRACT (message-live): thread message files are written by
# board-v2 (lib/store.ts, a separate repo): data/board-threads/<item-id>/
# <epoch-ms>[-N].md, whose FIRST line is a single-line JSON object carrying
# .author. Message-live parses exactly that. If the format ever drifts, the
# scan counts each newest thread file whose first line does not parse to an
# object with a string .author and surfaces the count once per outage via
# state/.thread-author-parse-fail (cleared on a clean cycle), instead of
# silently reading every item as not-david and demoting unanswered-David rows.
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
#   - The lock wait is BOUNDED (FM_BOARD_LOCK_WAIT, default 10s): a live but
#     stuck lock holder cannot be stolen (the steal path is dead-pid only), so
#     past the deadline the cycle is skipped with one stderr line and exit 0,
#     leaving the board unchanged for the next poller cycle to retry. Stock
#     macOS has no coreutils timeout for the poller to wrap this script in, so
#     the reconcile must be inherently unable to block forever.
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
THREADS="${FM_BOARD_THREADS_DIR:-$FM_HOME/data/board-threads}"
LOCK="$STATE/.board.json.lock"
AUTHOR_FAIL_MARK="$STATE/.thread-author-parse-fail"
TTL="${FM_AGENT_LIVE_TTL:-1800}"
DEFAULT_REST="${FM_RECONCILE_DEFAULT_REST:-your_word}"
LOCK_WAIT="${FM_BOARD_LOCK_WAIT:-10}"

VERBOSE=0
[ "${1:-}" = "--verbose" ] && VERBOSE=1

note() { [ "$VERBOSE" -eq 1 ] && echo "fm-board-reconcile: $1" || true; }

command -v jq >/dev/null 2>&1 || { echo "fm-board-reconcile: jq required" >&2; exit 1; }
case "$TTL" in ''|*[!0-9]*) TTL=1800 ;; esac
case "$LOCK_WAIT" in ''|*[!0-9]*) LOCK_WAIT=10 ;; esac

# Adoption switch: no registry means the liveness-derived board is not adopted
# yet; leave the board exactly as it is.
if [ ! -f "$AGENTS" ]; then
  note "registry $AGENTS absent; reconcile inactive (no-op)"
  exit 0
fi

# Board must be readable; otherwise leave it untouched.
if [ ! -f "$BOARD" ]; then
  note "board $BOARD absent; nothing to reconcile"
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

# Acquire the board lock BEFORE reading the board at all, and read it exactly
# once: the same snapshot enumerates the message-live candidate ids AND feeds
# the transform, and the live sets are computed under the lock too. A prior
# version computed liveness from a pre-lock read and transformed a fresh
# under-lock read, so a row added or a thread answered between the two reads
# could be mis-sectioned for a cycle (and an even earlier version kept only the
# final mv under the lock - the board-toctou race). The wait is bounded: a live
# but stuck holder cannot be stolen (fm_lock_try_acquire steals dead pids only),
# so past LOCK_WAIT seconds this cycle is skipped with one stderr line, exit 0,
# and the board untouched; the next poller cycle retries. The trap releases the
# lock on every exit path (no-change, error, success) and is armed only once
# the lock is actually held.
LOCK_HELD=0
lock_deadline=$(( $(date +%s) + LOCK_WAIT ))
until fm_lock_try_acquire "$LOCK"; do
  if [ "$(date +%s)" -ge "$lock_deadline" ]; then
    echo "fm-board-reconcile: board lock $LOCK still held by live pid ${FM_LOCK_HELD_PID:-unknown} after ${LOCK_WAIT}s; skipping this cycle" >&2
    exit 0
  fi
  sleep 0.1
done
LOCK_HELD=1
trap 'if [ "$LOCK_HELD" = 1 ]; then fm_lock_release "$LOCK"; LOCK_HELD=0; fi' EXIT

board_json=$(cat "$BOARD" 2>/dev/null || true)
if ! printf '%s' "$board_json" | jq -e 'type == "object"' >/dev/null 2>&1; then
  echo "fm-board-reconcile: $BOARD is missing/unparseable; leaving it untouched" >&2
  exit 0
fi

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

# --- message-live: items whose ball is with firstmate because David spoke last -
# The board's meaning of In progress is "the ball is with firstmate", which is a
# live agent OR a fresh unanswered David message (AGENTS.md section 2). The second
# half is derived here, with no hand bookkeeping, from the real signal: an item is
# message-live iff the NEWEST message file in its thread is authored by david (a
# firstmate reply becomes the newest file and clears it, so the item then demotes
# to Your word). This is the same signal board-v2's auto-flip-on-send uses, so the
# reconcile agrees with the board instead of fighting it.
ids=$(printf '%s\n' "$board_json" | jq -r '[(.your_word // []), (.in_progress // []),
              [ (.holding // [])[].rows[]? ], (.landed // [])]
             | add | map(.id) | .[]' 2>/dev/null)
message_live_json='[]'
author_parse_fails=0
while IFS= read -r id; do
  [ -n "$id" ] || continue
  tdir="$THREADS/$id"
  [ -d "$tdir" ] || continue
  # Newest thread file = highest epoch-ms filename prefix (store.ts naming).
  newest=$(
    for f in "$tdir"/*.md; do
      [ -e "$f" ] || continue
      base=$(basename "$f" .md)
      printf '%s\t%s\n' "${base%%-*}" "$f"
    done | sort -n -k1,1 | tail -1 | cut -f2
  )
  [ -n "$newest" ] || continue
  # The first line must parse to a JSON object with a string .author (the
  # cross-repo contract in the header). Anything else is contract drift, not
  # not-david: count it so it gets surfaced instead of silently demoting.
  author=$(head -1 "$newest" 2>/dev/null \
    | jq -r 'select(type == "object") | .author | select(type == "string")' 2>/dev/null) || author=""
  if [ -z "$author" ]; then
    author_parse_fails=$((author_parse_fails + 1))
    continue
  fi
  if [ "$author" = david ]; then
    message_live_json=$(printf '%s' "$message_live_json" | jq --arg id "$id" '. + [$id]')
  fi
done <<EOF
$ids
EOF
if [ "$author_parse_fails" -gt 0 ]; then
  if [ ! -f "$AUTHOR_FAIL_MARK" ]; then
    touch "$AUTHOR_FAIL_MARK" 2>/dev/null || true
    echo "fm-board-reconcile: $author_parse_fails newest thread file(s) lack a parseable JSON .author first line; message-live is blind to them (board-v2 store.ts contract drift?)" >&2
  fi
else
  rm -f "$AUTHOR_FAIL_MARK" 2>/dev/null || true
fi
# Union the two live sources into one set the transform treats as live.
live_json=$(jq -n --argjson a "$live_json" --argjson b "${message_live_json:-[]}" \
  '($a + $b) | unique') || { echo "fm-board-reconcile: live-set union failed" >&2; exit 1; }

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
  | .in_progress = ($new_ip | dedup_by_id)
  | .your_word = (($yw_keep + $dem_yw) | dedup_by_id)
  | .landed = (($ld_keep + ($dem_landed | map(row_to_landed))) | dedup_by_id)
  | .holding = $hg_keep
'

new_board=$(printf '%s' "$board_json" | jq \
  --argjson live "$live_json" \
  --argjson R "$rest_json" \
  --arg D "$DEFAULT_REST" \
  "$TRANSFORM") || { echo "fm-board-reconcile: board transform failed" >&2; exit 1; }

# Idempotence / no-churn: only write when the canonical form actually changed.
if [ "$(printf '%s' "$board_json" | jq -S .)" = "$(printf '%s' "$new_board" | jq -S .)" ]; then
  note "no change"
  exit 0
fi
if ! printf '%s' "$new_board" | jq -e 'type == "object"' >/dev/null 2>&1; then
  echo "fm-board-reconcile: refused to write a non-object result" >&2
  exit 1
fi
# temp + rename so a concurrent board read never sees a half-written file.
tmp="$STATE/.board.json.reconcile.$$"
if printf '%s\n' "$new_board" > "$tmp"; then
  mv "$tmp" "$BOARD"
  note "board reconciled: in_progress now $(printf '%s' "$new_board" | jq '.in_progress | length') live item(s)"
  exit 0
fi
rm -f "$tmp" 2>/dev/null || true
echo "fm-board-reconcile: failed to write temp file" >&2
exit 1

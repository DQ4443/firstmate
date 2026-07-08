#!/usr/bin/env bash
# fm-board-reply.sh - close the loop on the board by posting firstmate's outcome
# to the item's THREAD, not just in chat.
#
# THE PROBLEM THIS SOLVES: firstmate answers David in chat and never posts the
# reply on the board thread. The board's In progress is message-live derived
# (fm-board-reconcile.sh): an item is In progress while the NEWEST message file
# in its thread is authored by david. A chat-only answer never becomes the
# newest thread file, so the item's newest author stays `david` and the row
# spins in In progress forever - the board over-counts and firstmate loses
# track. This helper makes closing the loop one command: append a
# firstmate-authored message to the thread (making firstmate the newest author),
# then reconcile, so the item demotes to its rest section on its own.
#
# WHAT IT DOES:
#   1. Appends data/board-threads/<item-id>/<epoch-ms>.md, whose FIRST line is
#      the single-line JSON header board-v2 writes
#      ({"thread_id","parent_ref":null,"author":"firstmate","ts":<iso8601Z>}),
#      a blank line, then the message text. This matches lib/store.ts naming and
#      the newest-file tie-break in fm-board-reconcile.sh: the epoch-ms filename
#      is forced strictly newer than any existing file in the thread, so the
#      reply always wins the "who spoke last" comparison even when the coarse
#      clock would collide with a same-second david message.
#   2. With --done, also runs `bin/fm-item-agent.sh done <item-id>`, flipping the
#      agent record so an item kept live by a still-registered agent also
#      demotes (to its registered rest section: your_word or landed).
#   3. On a your_word move (--your-court or the bare default, i.e. NOT --done) it
#      also writes an `effort` integer 1..5 onto the item's row in board.json,
#      under the same state/.board.json.lock the reconcile uses. effort is how
#      hard the pending decision is for David (1 = a yes/no or one-word pick,
#      5 = a real design decision); the board sorts Your word ascending by it so
#      the quickest-to-answer items surface first. --effort <1-5> sets the value;
#      absent, effort defaults to 3 without clobbering an existing value. The
#      write happens BEFORE the reconcile, so a row demoted out of In progress
#      carries the effort with it (the reconcile preserves row fields on a move).
#   4. Runs bin/fm-board-reconcile.sh so the demotion lands immediately rather
#      than on the next poller cycle.
#
# --your-court is the default intent (the ball goes back to David: your_word).
# Posting the reply clears the message-live signal, so absent a live agent the
# item rests in your_word with no further bookkeeping. --done is for a finished
# workstream and additionally closes the agent record.
#
# Usage:
#   fm-board-reply.sh <item-id> "<message>" [--done | --your-court] [--effort <1-5>] [--once]
#
# --once makes the post IDEMPOTENT against the newest David message in the thread,
# so the headless drain (bin/fm-drain-worker.sh) and the interactive session can
# both try to answer the same David message without double-posting. It derives a
# key from (item-id, newest-david-authored-filename) and takes an atomic claim
# under state/.reply-claims/<key> BEFORE writing; a second call with the same key
# is a clean no-op. Interactive callers omit --once (they may legitimately post
# several replies to one thread); only the auto-drain uses it. Residual: a crash
# after the claim but before the write suppresses that one auto-ack, but the
# David message file persists and serviced-seq stays un-advanced, so the pager
# SLA (docs/headless-drain.md) still escalates it - the message is never lost.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
THREADS="${FM_BOARD_THREADS_DIR:-$FM_HOME/data/board-threads}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
BOARD="${FM_BOARD_DATA:-$STATE/board.json}"
LOCK="$STATE/.board.json.lock"
REPLY_CLAIMS="$STATE/.reply-claims"
# Bounded lock wait, mirroring fm-board-reconcile.sh: a live-but-stuck holder is
# never stolen, so past the deadline the effort write is skipped (reconcile still
# runs) rather than blocking this call forever.
LOCK_WAIT="${FM_BOARD_LOCK_WAIT:-10}"
case "$LOCK_WAIT" in ''|*[!0-9]*) LOCK_WAIT=10 ;; esac
# Set to 1 only while this process holds LOCK; an EXIT trap (armed when the lock
# is taken) releases it on any exit path so a mid-write failure under set -e can
# never orphan the lock, mirroring fm-board-reconcile.sh.
LOCK_HELD=0

# The portable lock helpers (fm_lock_try_acquire / fm_lock_release), the same
# ones the reconcile uses to serialize board.json writes.
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"

# Item ids are board row ids: the same strict slug fm-item-agent.sh and
# board-v2 lib/store.ts enforce, so a typo cannot post to a ghost thread.
ID_RE='^[a-z0-9][a-z0-9-]{0,63}$'

die() { echo "fm-board-reply: $1" >&2; exit 2; }
usage() {
  echo 'usage: fm-board-reply.sh <item-id> "<message>" [--done | --your-court] [--effort <1-5>]' >&2
  exit 2
}

item=${1:-}
msg=${2:-}

[ -n "$item" ] || usage
[ -n "$msg" ] || die "message is required (nothing to post)"
printf '%s' "$item" | grep -qE "$ID_RE" || die "invalid item id: '$item'"
# A message that starts with -- is almost always a forgotten message with the
# flag slid into its slot (fm-board-reply.sh item --done). Posting "--done" as
# the outcome and skipping the flag is silently the wrong thing, so refuse it:
# the message is positional and comes before any flag.
case "$msg" in
  --*) die "message looks like a flag ('$msg'); the message is the 2nd argument, before --done/--your-court" ;;
esac
# A whitespace-only message would render as an empty outcome, and once the
# reconcile's empty-body view-event filter lands it would NOT clear message-live
# (the reply would count as a bodyless view), so the item would never demote.
# Require real content.
[ -n "$(printf '%s' "$msg" | tr -d '[:space:]')" ] || die "message is only whitespace (nothing to post)"

# Flags after the two positionals, in any order: at most one intent
# (--done | --your-court, default your-court) and an optional --effort <1-5>.
# effort stays empty when not given, which the write path reads as "default to 3
# without clobbering an existing value".
done_flag=0
court_seen=0
effort=""
once_flag=0
validate_effort() {  # <value>
  case "$1" in
    ''|*[!0-9]*) die "--effort needs an integer 1-5 (got '$1')" ;;
  esac
  { [ "$1" -ge 1 ] && [ "$1" -le 5 ]; } || die "--effort out of range 1-5 (got '$1')"
}
shift 2 2>/dev/null || true
while [ "$#" -gt 0 ]; do
  case "$1" in
    --done) done_flag=1 ;;
    --your-court) court_seen=1 ;;
    --once) once_flag=1 ;;
    --effort)
      shift
      [ "$#" -gt 0 ] || die "--effort needs a value (1-5)"
      effort=$1
      validate_effort "$effort"
      ;;
    --effort=*)
      effort=${1#--effort=}
      validate_effort "$effort"
      ;;
    --*) die "unknown flag: '$1' (expected --done, --your-court, --effort <1-5>, or --once)" ;;
    *) die "unexpected extra argument: '$1'" ;;
  esac
  shift
done
# --done finishes a workstream (rests to landed or the registered rest); effort
# is about a pending David decision, so it only makes sense on a your_word move.
[ "$done_flag" -eq 1 ] && [ "$court_seen" -eq 1 ] \
  && die "--done and --your-court are mutually exclusive"
[ "$done_flag" -eq 1 ] && [ -n "$effort" ] \
  && die "--effort applies to a your_word move, not --done"
# (the guards above use && without an else on purpose; each is its own line.)

# Milliseconds since the epoch. GNU date gives them via %s%3N; macOS BSD date
# has no %N and leaves a non-digit tail, so fall back to seconds*1000. The
# strictly-newer bump below makes coarse precision harmless.
now_ms() {
  local ms
  ms=$(date +%s%3N 2>/dev/null || true)
  case "$ms" in
    ''|*[!0-9]*) ms=$(( $(date +%s) * 1000 )) ;;
  esac
  printf '%s' "$ms"
}

tdir="$THREADS/$item"
mkdir -p "$tdir"

# --once: idempotency claim keyed on (item, newest-david-authored filename). The
# claim is an atomic mkdir taken BEFORE the write, so two concurrent answerers
# (headless drain + interactive session) racing the SAME David message resolve to
# one post. The newest-david filename is the message-generation marker: a NEW
# David message changes it, so the next reply is not suppressed. When no David
# message exists yet, the key falls back to <item>|none so a spurious duplicate is
# still coalesced.
if [ "$once_flag" -eq 1 ]; then
  david_gen="none"
  newest_david=0
  for f in "$tdir"/*.md; do
    [ -e "$f" ] || continue
    hdr=$(head -n 1 "$f" 2>/dev/null || true)
    author=$(printf '%s' "$hdr" | jq -r '.author // ""' 2>/dev/null || true)
    [ "$author" = "david" ] || continue
    base=$(basename "$f" .md)
    ms="${base%%-*}"
    case "$ms" in ''|*[!0-9]*) continue ;; esac
    if [ "$ms" -gt "$newest_david" ]; then newest_david="$ms"; david_gen="$base"; fi
  done
  key=$(printf '%s|%s|reply' "$item" "$david_gen" | shasum 2>/dev/null | awk '{print $1}')
  case "$key" in ''|*[!0-9a-f]*) key=$(printf '%s|%s|reply' "$item" "$david_gen" | cksum | awk '{print $1}') ;; esac
  mkdir -p "$REPLY_CLAIMS" 2>/dev/null || true
  claim="$REPLY_CLAIMS/$key"
  if ! mkdir "$claim" 2>/dev/null; then
    echo "fm-board-reply: idempotent no-op (already replied to $david_gen in $item)"
    exit 0
  fi
fi

# Force the new file strictly newer than any existing thread file so it wins the
# newest-file tie-break in the reconcile even under a coarse clock. Existing
# files are named <epoch-ms>[-<n>].md; compare on the numeric ms prefix only.
newest_ms=0
for f in "$tdir"/*.md; do
  [ -e "$f" ] || continue
  base=$(basename "$f" .md)
  ms="${base%%-*}"
  case "$ms" in
    ''|*[!0-9]*) continue ;;
  esac
  if [ "$ms" -gt "$newest_ms" ]; then newest_ms="$ms"; fi
done
stamp=$(now_ms)
if [ "$stamp" -le "$newest_ms" ]; then stamp=$((newest_ms + 1)); fi

# Never clobber an existing file: if the base name somehow exists, append -<n>
# the way store.ts does on a same-ms collision (still the later, newer write).
out="$tdir/$stamp.md"
n=1
while [ -e "$out" ]; do
  out="$tdir/$stamp-$n.md"
  n=$((n + 1))
done

ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
tmp="$out.tmp.$$"
{
  printf '{"thread_id": "%s", "parent_ref": null, "author": "firstmate", "ts": "%s"}\n' "$item" "$ts"
  printf '\n'
  printf '%s\n' "$msg"
} > "$tmp"
mv "$tmp" "$out"
echo "posted firstmate reply: $out"

# --done also closes the agent record so an item kept In progress by a still-live
# agent demotes to its rest section (your_word or landed), not just the message
# signal.
if [ "$done_flag" -eq 1 ]; then
  "$SCRIPT_DIR/fm-item-agent.sh" "done" "$item"
fi

# On a your_word move (not --done), stamp `effort` onto the item's row in
# board.json so the board can sort Your word ascending by David's decision cost.
# This must land BEFORE the reconcile: if the row is currently In progress it is
# demoted to your_word by the reconcile below, which preserves row fields on the
# move, so the effort rides along. Written under the same lock the reconcile
# uses (temp+rename), and only when the row actually changes, so it does not
# churn board.json or fight a concurrent reconcile. jq is required for the write;
# absent it (or an unreadable board), the effort stamp is skipped and the reply
# still posts and reconciles.
if [ "$done_flag" -eq 0 ] && command -v jq >/dev/null 2>&1 && [ -f "$BOARD" ]; then
  locked=0
  lock_deadline=$(( $(date +%s) + LOCK_WAIT ))
  while :; do
    if fm_lock_try_acquire "$LOCK"; then locked=1; break; fi
    if [ "$(date +%s)" -ge "$lock_deadline" ]; then break; fi
    sleep 0.1
  done
  if [ "$locked" -eq 1 ]; then
    LOCK_HELD=1
    trap 'if [ "$LOCK_HELD" = 1 ]; then fm_lock_release "$LOCK"; LOCK_HELD=0; fi' EXIT
    # $e is the given value, or null when --effort was omitted. In the null case
    # setef defaults to 3 only when the row has no effort yet (non-clobber), so a
    # plain reply never overwrites a previously-set effort; an explicit --effort
    # always sets the value. Applied to every section a your_word row can live in
    # (in_progress included, since a message/agent-live row rests to your_word),
    # guarding each key so an absent section is left as-is (no empty keys added).
    new_board=$(jq --arg id "$item" --argjson e "${effort:-null}" '
      def setef: if $e == null then .effort = (.effort // 3) else .effort = $e end;
      (if .your_word   then .your_word   |= map(if .id == $id then setef else . end) else . end)
      | (if .in_progress then .in_progress |= map(if .id == $id then setef else . end) else . end)
      | (if .backlog     then .backlog     |= map(if .id == $id then setef else . end) else . end)
      | (if .holding     then .holding     |= map(.rows |= map(if .id == $id then setef else . end)) else . end)
    ' "$BOARD" 2>/dev/null) || new_board=""
    if [ -n "$new_board" ] && printf '%s' "$new_board" | jq -e 'type == "object"' >/dev/null 2>&1; then
      if [ "$(jq -S . "$BOARD" 2>/dev/null)" != "$(printf '%s' "$new_board" | jq -S .)" ]; then
        tmp_board="$STATE/.board.json.reply.$$"
        if printf '%s\n' "$new_board" > "$tmp_board"; then
          mv "$tmp_board" "$BOARD"
          echo "stamped effort on row: $item"
        else
          rm -f "$tmp_board" 2>/dev/null || true
        fi
      fi
    fi
    fm_lock_release "$LOCK"
    LOCK_HELD=0
    trap - EXIT
  else
    echo "fm-board-reply: board lock held after ${LOCK_WAIT}s; effort not stamped (reconcile still runs)" >&2
  fi
fi

# Reconcile now so the demotion is immediate, not deferred to the next poller
# cycle. It is a cheap no-op when nothing changed.
"$SCRIPT_DIR/fm-board-reconcile.sh"

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
#   3. Runs bin/fm-board-reconcile.sh so the demotion lands immediately rather
#      than on the next poller cycle.
#
# --your-court is the default intent (the ball goes back to David: your_word).
# Posting the reply clears the message-live signal, so absent a live agent the
# item rests in your_word with no further bookkeeping. --done is for a finished
# workstream and additionally closes the agent record.
#
# Usage:
#   fm-board-reply.sh <item-id> "<message>" [--done | --your-court]
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
THREADS="${FM_BOARD_THREADS_DIR:-$FM_HOME/data/board-threads}"

# Item ids are board row ids: the same strict slug fm-item-agent.sh and
# board-v2 lib/store.ts enforce, so a typo cannot post to a ghost thread.
ID_RE='^[a-z0-9][a-z0-9-]{0,63}$'

die() { echo "fm-board-reply: $1" >&2; exit 2; }
usage() {
  echo 'usage: fm-board-reply.sh <item-id> "<message>" [--done | --your-court]' >&2
  exit 2
}

item=${1:-}
msg=${2:-}
flag=${3:-}
extra=${4:-}

[ -n "$item" ] || usage
[ -n "$msg" ] || die "message is required (nothing to post)"
[ -z "$extra" ] || die "unexpected extra argument: '$extra'"
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

done_flag=0
case "$flag" in
  '') ;;
  --done) done_flag=1 ;;
  --your-court) ;;
  *) die "unknown flag: '$flag' (expected --done or --your-court)" ;;
esac

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

# Reconcile now so the demotion is immediate, not deferred to the next poller
# cycle. It is a cheap no-op when nothing changed.
"$SCRIPT_DIR/fm-board-reconcile.sh"

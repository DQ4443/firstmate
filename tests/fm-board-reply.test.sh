#!/usr/bin/env bash
# tests/fm-board-reply.test.sh - closing the loop on the board.
#
# Proves bin/fm-board-reply.sh posts firstmate's outcome to the item thread so
# the item leaves In progress:
#   - writes a thread file with author=firstmate, the JSON header, and the body
#   - the posted file is the NEWEST in the thread even against a same-second
#     david message (the reconcile's newest-file tie-break)
#   - after posting, a message-live item (david spoke last) leaves In progress
#     and rests in your_word
#   - --done also closes the agent record so an agent-live item demotes too
#   - bad input (missing message, unknown flag, bad id) fails loudly
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

REPLY="$ROOT/bin/fm-board-reply.sh"
AGENT="$ROOT/bin/fm-item-agent.sh"
TMP_ROOT=$(fm_test_tmproot fm-board-reply)

CASE_N=0
new_case() { CASE_N=$((CASE_N + 1)); d="$TMP_ROOT/case-$CASE_N"; mkdir -p "$d/state" "$d/threads"; }

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }

# A board with one In-progress item whose thread has a fresh david message, so
# the reconcile holds it In progress until firstmate answers on the thread.
seed_msglive() {  # <state-dir> <item-id>
  mkdir -p "$1/threads/$2"
  printf '{"author":"david","ts":"t"}\nplease do the thing\n' > "$1/threads/$2/1000.md"
  cat > "$1/state/board.json" <<JSON
{
  "meta": {"title": "cc"},
  "your_word": [],
  "in_progress": [{"id": "$2", "stamp": "do", "rid": "IT", "what": "chat-answered, spins here"}],
  "holding": [],
  "landed": []
}
JSON
  # Empty registry present so the reconcile is adopted (not a no-op).
  printf '{"items":{}}\n' > "$1/state/item-agents.json"
}

run_reply() {  # <state-dir> <args...>
  local sd=$1; shift
  FM_STATE_OVERRIDE="$sd/state" FM_BOARD_THREADS_DIR="$sd/threads" \
    "$REPLY" "$@"
}

# --- posts a firstmate-authored file with header + body ----------------------
new_case
seed_msglive "$d" item
run_reply "$d" item "handled it, over to you" --your-court >/dev/null \
  || fail "post: reply exited non-zero"
# Newest thread file = highest epoch-ms filename (glob, not ls, per shellcheck).
newest=""; newest_ms=-1
for f in "$d/threads/item"/*.md; do
  ms=$(basename "$f" .md); ms="${ms%%-*}"
  if [ "$ms" -gt "$newest_ms" ]; then newest_ms="$ms"; newest="$f"; fi
done
author=$(head -1 "$newest" | jq -r '.author')
[ "$author" = firstmate ] || fail "post: newest thread file author should be firstmate (got '$author')"
[ "$(head -1 "$newest" | jq -r '.thread_id')" = item ] \
  || fail "post: header thread_id should be the item id"
[ -z "$(sed -n '2p' "$newest")" ] || fail "post: second line should be blank"
grep -q "handled it, over to you" "$newest" || fail "post: body text missing"
pass "posts a firstmate-authored thread file (JSON header, blank line, body)"

# --- the posted file is newest even vs a same-second david message -----------
# The reconcile picks the newest file by epoch-ms; a coarse clock must not let a
# same-second david message out-sort firstmate's later reply.
[ "$(basename "$newest" .md | sed 's/-.*//')" -gt 1000 ] \
  || fail "newest: posted file ms prefix should exceed the david 1000.md"
pass "posted file is forced strictly newer than the existing david message"

# --- message-live item leaves In progress after the reply --------------------
ip=$(jq -r '.in_progress | map(.id) | join(",")' "$d/state/board.json")
[ -z "$ip" ] || fail "close: item should have left in_progress (still: '$ip')"
jq -e '.your_word | map(.id) | index("item")' "$d/state/board.json" >/dev/null \
  || fail "close: item should rest in your_word after the reply"
pass "a message-live item leaves In progress and rests in your_word after the reply"

# --- --done also closes an agent-live record ---------------------------------
new_case
seed_msglive "$d" item
# Register a live agent so agent-live (not just message-live) holds it up.
FM_STATE_OVERRIDE="$d/state" "$AGENT" start item agent-xyz your_word >/dev/null
run_reply "$d" item "shipped, marking done" --done >/dev/null \
  || fail "done: reply --done exited non-zero"
[ "$(FM_STATE_OVERRIDE="$d/state" "$AGENT" get item | jq -r '.done')" = true ] \
  || fail "done: --done should have flipped the agent record to done"
[ -z "$(jq -r '.in_progress | map(.id) | join(",")' "$d/state/board.json")" ] \
  || fail "done: item should have left in_progress after --done"
pass "--done closes the agent record so an agent-live item also demotes"

# --- bad input fails loudly --------------------------------------------------
new_case
seed_msglive "$d" item
run_reply "$d" item >/dev/null 2>&1 && fail "input: missing message should fail" || true
run_reply "$d" item "hi" --bogus >/dev/null 2>&1 && fail "input: unknown flag should fail" || true
run_reply "$d" "Bad_Id" "hi" >/dev/null 2>&1 && fail "input: invalid id should fail" || true
# A forgotten message with the flag in its slot must not post "--done" as the body.
run_reply "$d" item --done >/dev/null 2>&1 && fail "input: a flag-shaped message should fail" || true
# A whitespace-only message would not clear message-live under the empty-body filter.
run_reply "$d" item "   " >/dev/null 2>&1 && fail "input: whitespace-only message should fail" || true
pass "missing/flag-shaped/whitespace message, unknown flag, and invalid id all fail loudly"

echo "all fm-board-reply tests passed"

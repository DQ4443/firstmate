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

# --- --effort stamps the row and rides the demotion into your_word -----------
# The item starts message-live in in_progress; the reply demotes it to your_word.
# The effort write lands on the in_progress row BEFORE the reconcile, and the
# reconcile preserves row fields on the move, so the your_word row carries it.
new_case
seed_msglive "$d" item
run_reply "$d" item "over to you, quick pick" --your-court --effort 1 >/dev/null \
  || fail "effort: reply --effort 1 exited non-zero"
[ "$(jq -r '.your_word[0].effort' "$d/state/board.json")" = 1 ] \
  || fail "effort: your_word row should carry effort=1 after the demotion"
pass "--effort <n> stamps effort on the row and it survives the demotion to your_word"

# --- a plain your_word reply defaults effort to 3 without a flag --------------
new_case
seed_msglive "$d" item
run_reply "$d" item "over to you" --your-court >/dev/null \
  || fail "effort-default: reply exited non-zero"
[ "$(jq -r '.your_word[0].effort' "$d/state/board.json")" = 3 ] \
  || fail "effort-default: a your_word move with no --effort should default effort to 3"
pass "a your_word move defaults effort to 3 when --effort is not given"

# --- bare --effort (no intent flag; your-court is the default) stamps too -----
new_case
seed_msglive "$d" item
run_reply "$d" item "quick one for you" --effort 2 >/dev/null \
  || fail "effort-bare: reply --effort with no intent flag exited non-zero"
[ "$(jq -r '.your_word[0].effort' "$d/state/board.json")" = 2 ] \
  || fail "effort-bare: bare --effort (default your-court intent) should stamp effort"
pass "--effort with no intent flag stamps effort on the default your_word move"

# --- explicit --effort overrides; a later plain reply does not clobber it -----
# Seed a your_word row that already carries effort=4.
new_case
mkdir -p "$d/threads/item"
cat > "$d/state/board.json" <<'JSON'
{
  "meta": {"title": "cc"},
  "your_word": [{"id": "item", "stamp": "decide", "rid": "IT", "what": "waiting", "effort": 4}],
  "in_progress": [],
  "holding": [],
  "landed": []
}
JSON
printf '{"items":{}}\n' > "$d/state/item-agents.json"
run_reply "$d" item "still yours, more context" --your-court >/dev/null \
  || fail "effort-noclobber: reply exited non-zero"
[ "$(jq -r '.your_word[0].effort' "$d/state/board.json")" = 4 ] \
  || fail "effort-noclobber: a plain reply must not overwrite an existing effort"
run_reply "$d" item "actually a trivial yes/no now" --your-court --effort 1 >/dev/null \
  || fail "effort-override: reply --effort 1 exited non-zero"
[ "$(jq -r '.your_word[0].effort' "$d/state/board.json")" = 1 ] \
  || fail "effort-override: explicit --effort should overwrite the existing effort"
pass "a plain reply preserves an existing effort; explicit --effort overrides it"

# --- --done leaves effort untouched (effort is a your_word concept) -----------
# A finished workstream resting in your_word must not gain a spurious effort=3.
new_case
seed_msglive "$d" item
FM_STATE_OVERRIDE="$d/state" "$AGENT" start item agent-xyz your_word >/dev/null
run_reply "$d" item "shipped" --done >/dev/null || fail "done-effort: reply --done exited non-zero"
[ "$(jq -r '.your_word[0].effort // "none"' "$d/state/board.json")" = none ] \
  || fail "done-effort: --done should not stamp an effort"
pass "--done does not stamp effort"

# --- bad --effort values fail loudly -----------------------------------------
new_case
seed_msglive "$d" item
if run_reply "$d" item "hi" --effort 0 >/dev/null 2>&1; then fail "effort-range: 0 should fail"; fi
if run_reply "$d" item "hi" --effort 6 >/dev/null 2>&1; then fail "effort-range: 6 should fail"; fi
if run_reply "$d" item "hi" --effort x >/dev/null 2>&1; then fail "effort-range: non-numeric should fail"; fi
if run_reply "$d" item "hi" --effort >/dev/null 2>&1; then fail "effort-range: missing value should fail"; fi
if run_reply "$d" item "hi" --done --effort 2 >/dev/null 2>&1; then fail "effort-range: --effort with --done should fail"; fi
pass "out-of-range, non-numeric, valueless --effort, and --effort+--done all fail loudly"

# --- bad input fails loudly --------------------------------------------------
new_case
seed_msglive "$d" item
# Each bad input must exit non-zero. Explicit if-blocks, not `A && fail || true`
# (that pattern trips shellcheck SC2015 and is not real if-then-else).
if run_reply "$d" item >/dev/null 2>&1; then fail "input: missing message should fail"; fi
if run_reply "$d" item "hi" --bogus >/dev/null 2>&1; then fail "input: unknown flag should fail"; fi
if run_reply "$d" "Bad_Id" "hi" >/dev/null 2>&1; then fail "input: invalid id should fail"; fi
# A forgotten message with the flag in its slot must not post "--done" as the body.
if run_reply "$d" item --done >/dev/null 2>&1; then fail "input: a flag-shaped message should fail"; fi
# A whitespace-only message would not clear message-live under the empty-body filter.
if run_reply "$d" item "   " >/dev/null 2>&1; then fail "input: whitespace-only message should fail"; fi
pass "missing/flag-shaped/whitespace message, unknown flag, and invalid id all fail loudly"

echo "all fm-board-reply tests passed"

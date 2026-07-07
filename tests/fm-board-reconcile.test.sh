#!/usr/bin/env bash
# tests/fm-board-reconcile.test.sh - the liveness-derived board.
#
# Proves bin/fm-board-reconcile.sh makes In progress a computed fact:
#   - adoption switch: no registry -> exact no-op (never clobbers a hand board)
#   - live item stays in / is promoted to In progress from any section
#   - a not-live In-progress item is demoted to its rest section (your_word/landed)
#   - liveness = done flag AND freshness vs TTL; a stale record demotes, but a
#     recent board-checkins.json stamp keeps an otherwise-stale item live
#   - idempotent (a second run makes no change) and atomic (always valid JSON)
#   - fail-safe: unparseable registry aborts with NO write; unparseable board is
#     left untouched
# Together with the fm-item-agent.sh registration contract, this is the whole
# item -> agent -> board pipeline.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

REC="$ROOT/bin/fm-board-reconcile.sh"
AGENT="$ROOT/bin/fm-item-agent.sh"
TMP_ROOT=$(fm_test_tmproot fm-reconcile)

CASE_N=0
new_case() { CASE_N=$((CASE_N + 1)); d="$TMP_ROOT/case-$CASE_N"; mkdir -p "$d"; }

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }

# ids_in <state-dir> <section-jq>: comma-joined row ids of a section.
ids_in() { jq -r "$2 | map(.id) | join(\",\")" "$1/board.json"; }

seed_board() {  # <state-dir>
  cat > "$1/board.json" <<'JSON'
{
  "meta": {"title": "cc"},
  "your_word": [{"id": "aa", "stamp": "do", "rid": "AA", "what": "waiting on david"}],
  "in_progress": [
    {"id": "live1", "stamp": "build", "rid": "L1", "what": "has a live agent"},
    {"id": "dead1", "stamp": "build", "rid": "D1", "what": "finished, stuck in progress"},
    {"id": "landme", "stamp": "build", "rid": "LM", "what": "ship it", "links": [{"label": "pr", "href": "http://x"}]}
  ],
  "holding": [{"unlock": "dep", "rows": [
    {"id": "promo", "stamp": "do", "rid": "PR", "what": "live but parked in holding"},
    {"id": "blocked", "stamp": "do", "rid": "BL", "what": "genuinely blocked"}
  ]}],
  "landed": [{"id": "old", "title": "OLD"}]
}
JSON
}

# --- adoption switch: no registry -> exact no-op ----------------------------
new_case
seed_board "$d"
before=$(jq -S . "$d/board.json")
FM_STATE_OVERRIDE="$d" "$REC" >/dev/null 2>&1 || fail "adoption: reconcile errored with no registry"
[ "$(jq -S . "$d/board.json")" = "$before" ] || fail "adoption: board changed with no registry present"
pass "no registry present -> reconcile is an exact no-op (board untouched)"

# --- core movement (live/dead/land/promote) ---------------------------------
new_case
seed_board "$d"
now=$(date +%s)
cat > "$d/item-agents.json" <<JSON
{"items":{
  "live1":{"agent":"a1","since":$now,"beat":$now,"done":false,"rest":"your_word"},
  "promo":{"agent":"a2","since":$now,"beat":$now,"done":false,"rest":"your_word"},
  "dead1":{"agent":"a3","since":$now,"beat":$now,"done":true,"rest":"your_word"},
  "landme":{"agent":"a4","since":$now,"beat":$now,"done":true,"rest":"landed"}
}}
JSON
FM_STATE_OVERRIDE="$d" "$REC" >/dev/null 2>&1 || fail "core: reconcile errored"
[ "$(ids_in "$d" '.in_progress')" = "live1,promo" ] \
  || fail "core: in_progress should be exactly live1,promo (got '$(ids_in "$d" '.in_progress')')"
jq -e '.your_word | map(.id) | index("dead1")' "$d/board.json" >/dev/null \
  || fail "core: dead1 (done) not demoted to your_word"
jq -e '.landed | map(.id) | index("landme")' "$d/board.json" >/dev/null \
  || fail "core: landme (done, rest=landed) not moved to landed"
jq -e '.landed[] | select(.id=="landme") | .title == "LM" and .what == "ship it"' "$d/board.json" >/dev/null \
  || fail "core: landme not converted to a landed item with title/what"
[ "$(jq '.holding | length' "$d/board.json")" = "1" ] \
  || fail "core: holding group with a remaining blocked row should survive"
[ "$(ids_in "$d" '.holding[0].rows')" = "blocked" ] \
  || fail "core: promo should be removed from holding, blocked kept"
jq -e 'type=="object" and (.in_progress|type=="array")' "$d/board.json" >/dev/null \
  || fail "core: result is not a valid board object"
pass "live items -> in_progress (incl. promotion); done items demote to rest section"

# idempotence: a second run must not change anything.
snap=$(jq -S . "$d/board.json")
FM_STATE_OVERRIDE="$d" "$REC" >/dev/null 2>&1 || fail "idempotence: second run errored"
[ "$(jq -S . "$d/board.json")" = "$snap" ] || fail "idempotence: second run changed the board"
pass "reconcile is idempotent (second run is a no-op)"

# --- TTL staleness demotes; a fresh check-in keeps alive --------------------
new_case
seed_board "$d"
now=$(date +%s); old=$((now - 100000))
# stale1: not done but since/beat far past TTL -> should demote.
# stale2: since/beat far past TTL, but a RECENT board-checkins stamp -> stays live.
cat > "$d/item-agents.json" <<JSON
{"items":{
  "live1":{"agent":"a1","since":$old,"beat":$old,"done":false,"rest":"your_word"},
  "dead1":{"agent":"a2","since":$old,"beat":$now,"done":false,"rest":"your_word"}
}}
JSON
cat > "$d/board-checkins.json" <<JSON
{"dead1":$now}
JSON
FM_AGENT_LIVE_TTL=1800 FM_STATE_OVERRIDE="$d" "$REC" >/dev/null 2>&1 || fail "ttl: reconcile errored"
jq -e '.your_word | map(.id) | index("live1")' "$d/board.json" >/dev/null \
  || fail "ttl: stale live1 (no fresh check-in) should have demoted to your_word"
[ "$(ids_in "$d" '.in_progress')" = "dead1" ] \
  || fail "ttl: dead1 kept live by a fresh check-in should be the only in_progress (got '$(ids_in "$d" '.in_progress')')"
pass "staleness demotes past TTL; a fresh board-checkins stamp keeps an item live"

# --- fail-safe: unparseable registry aborts with no write -------------------
new_case
seed_board "$d"
printf 'not json{\n' > "$d/item-agents.json"
before=$(jq -S . "$d/board.json")
FM_STATE_OVERRIDE="$d" "$REC" >/dev/null 2>&1; rc=$?
[ "$rc" -ne 0 ] || fail "fail-safe: unparseable registry should exit non-zero"
[ "$(jq -S . "$d/board.json")" = "$before" ] \
  || fail "fail-safe: board must be untouched when registry is unparseable"
pass "unparseable registry -> abort with NO write (never demotes the whole board)"

# --- fail-safe: unparseable board is left untouched -------------------------
new_case
printf 'garbage{\n' > "$d/board.json"
now=$(date +%s)
printf '{"items":{"x":{"agent":"a","since":%s,"beat":%s,"done":false,"rest":"your_word"}}}\n' "$now" "$now" > "$d/item-agents.json"
FM_STATE_OVERRIDE="$d" "$REC" >/dev/null 2>&1 || true
[ "$(cat "$d/board.json")" = "garbage{" ] \
  || fail "fail-safe: unparseable board must be left byte-for-byte untouched"
pass "unparseable board is left untouched (never clobbered)"

# --- integration with the registration helper (real verbs) ------------------
new_case
seed_board "$d"
FM_STATE_OVERRIDE="$d" "$AGENT" start live1 agent-xyz your_word >/dev/null
FM_STATE_OVERRIDE="$d" "$REC" >/dev/null 2>&1 || fail "integration: reconcile errored"
[ "$(ids_in "$d" '.in_progress')" = "live1" ] \
  || fail "integration: only the registered live item should be in_progress (got '$(ids_in "$d" '.in_progress')')"
# Mark done via the helper -> next reconcile demotes it.
FM_STATE_OVERRIDE="$d" "$AGENT" "done" live1 >/dev/null
FM_STATE_OVERRIDE="$d" "$REC" >/dev/null 2>&1 || fail "integration: second reconcile errored"
[ -z "$(ids_in "$d" '.in_progress')" ] \
  || fail "integration: in_progress should be empty after the agent is marked done"
jq -e '.your_word | map(.id) | index("live1")' "$d/board.json" >/dev/null \
  || fail "integration: live1 should rest in your_word after done"
pass "fm-item-agent.sh start/done drives in_progress through the reconcile end to end"

# --- message-live: In progress = registry-live UNION david-last-thread ------
new_case
seed_board "$d"
threads="$d/threads"
mkdir -p "$threads/msgitem" "$threads/answered" "$threads/live1"
# aa is a Your-word item; give it a fresh david-authored last message -> promote.
mkdir -p "$threads/aa"
printf '{"author":"david","ts":"t"}\nhey\n' > "$threads/aa/1000.md"
# An item David messaged then firstmate answered (firstmate authored latest) stays put.
printf '{"author":"david","ts":"t"}\nq\n'      > "$threads/answered/1000.md"
printf '{"author":"firstmate","ts":"t"}\nans\n' > "$threads/answered/2000.md"
# Board gets those two extra rows in your_word.
jq '.your_word += [{"id":"answered","stamp":"do","rid":"AN","what":"replied"}]' "$d/board.json" > "$d/b2" && mv "$d/b2" "$d/board.json"
# live1 registered live too (union with the message signal).
now=$(date +%s)
printf '{"items":{"live1":{"agent":"a","since":%s,"beat":%s,"done":false,"rest":"your_word"}}}\n' "$now" "$now" > "$d/item-agents.json"
FM_BOARD_THREADS_DIR="$threads" FM_STATE_OVERRIDE="$d" "$REC" >/dev/null 2>&1 || fail "message-live: reconcile errored"
# aa (david-last) and live1 (registered) are in_progress; answered (firstmate-last) is not.
jq -e '.in_progress | map(.id) | index("aa")' "$d/board.json" >/dev/null \
  || fail "message-live: a Your-word item with a fresh david message should promote to in_progress"
jq -e '.in_progress | map(.id) | index("live1")' "$d/board.json" >/dev/null \
  || fail "message-live: a registered live item should be in_progress (union)"
jq -e '.in_progress | map(.id) | index("answered") | not' "$d/board.json" >/dev/null \
  || fail "message-live: a firstmate-answered item must NOT be in_progress"
jq -e '.your_word | map(.id) | index("answered")' "$d/board.json" >/dev/null \
  || fail "message-live: the answered item should rest in your_word"
pass "message-live: in_progress = registry-live UNION items whose newest thread message is david-authored"

# --- same-ms collision: the -N-suffixed file (written later) wins the tie ----
# store.ts appends -N on a same-millisecond filename collision, so a firstmate
# reply arriving in the same ms as a david message becomes 1000-1.md. That
# suffixed file is the NEWER write and must be treated as newest, demoting the
# item to Your word (regression guard for the F1 sort tie-break).
new_case
seed_board "$d"
threads="$d/threads"
mkdir -p "$threads/collide"
# Same millisecond: david 1000.md, firstmate 1000-1.md (the later, suffixed write).
printf '{"author":"david","ts":"t"}\nq\n'       > "$threads/collide/1000.md"
printf '{"author":"firstmate","ts":"t"}\nans\n' > "$threads/collide/1000-1.md"
jq '.your_word += [{"id":"collide","stamp":"do","rid":"CO","what":"same-ms reply"}]' "$d/board.json" > "$d/b2" && mv "$d/b2" "$d/board.json"
printf '{"items":{}}\n' > "$d/item-agents.json"
FM_BOARD_THREADS_DIR="$threads" FM_STATE_OVERRIDE="$d" "$REC" >/dev/null 2>&1 || fail "collision: reconcile errored"
jq -e '.in_progress | map(.id) | index("collide") | not' "$d/board.json" >/dev/null \
  || fail "collision: firstmate reply 1000-1.md (same ms, written later) must count as newest, not the david 1000.md"
jq -e '.your_word | map(.id) | index("collide")' "$d/board.json" >/dev/null \
  || fail "collision: the same-ms-answered item should demote to your_word"
pass "same-ms collision: the -N-suffixed later write wins the newest-file tie-break"

# --- empty-body view-events are ignored in the message-live author check -----
# board-v2 logs an EMPTY-BODY message authored by david whenever David merely
# OPENS/VIEWS a thread. That view-event must not flip an item into In progress,
# and it must not mask an earlier real david message or an earlier firstmate
# reply. The author check uses the newest message that HAS a body.
new_case
seed_board "$d"
threads="$d/threads"
# viewonly: a Your-word item whose newest (and only) message is an empty-body
# david view-event -> NOT promoted.
mkdir -p "$threads/viewonly"
printf '{"author":"david","ts":"t"}\n\n'   > "$threads/viewonly/3000.md"
# davidthenview: [real david message] then [empty david view] -> still live,
# because the empty view is skipped and the real david message is newest-bodied.
mkdir -p "$threads/davidthenview"
printf '{"author":"david","ts":"t"}\nreal question\n' > "$threads/davidthenview/1000.md"
printf '{"author":"david","ts":"t"}\n   \n'           > "$threads/davidthenview/2000.md"
# answeredthenview: [david] [firstmate reply] then [empty david view] -> NOT
# live: the newest bodied message is the firstmate reply, view is skipped.
mkdir -p "$threads/answeredthenview"
printf '{"author":"david","ts":"t"}\nq\n'        > "$threads/answeredthenview/1000.md"
printf '{"author":"firstmate","ts":"t"}\nans\n'  > "$threads/answeredthenview/2000.md"
printf '{"author":"david","ts":"t"}\n\n'         > "$threads/answeredthenview/3000.md"
# Add rows for the new items.
jq '.your_word += [
  {"id":"viewonly","stamp":"do","rid":"VO","what":"only a view-event"},
  {"id":"davidthenview","stamp":"do","rid":"DV","what":"real msg then a view"},
  {"id":"answeredthenview","stamp":"do","rid":"AV","what":"answered then a view"}
]' "$d/board.json" > "$d/b2" && mv "$d/b2" "$d/board.json"
printf '{"items":{}}\n' > "$d/item-agents.json"
rm -f "$d/.thread-author-parse-fail"
FM_BOARD_THREADS_DIR="$threads" FM_STATE_OVERRIDE="$d" "$REC" >/dev/null 2>&1 || fail "view-event: reconcile errored"
jq -e '.in_progress | map(.id) | index("viewonly") | not' "$d/board.json" >/dev/null \
  || fail "view-event: an empty-body david view-event must NOT promote the item to in_progress"
jq -e '.in_progress | map(.id) | index("davidthenview")' "$d/board.json" >/dev/null \
  || fail "view-event: a real david message followed by an empty view-event must stay message-live"
jq -e '.in_progress | map(.id) | index("answeredthenview") | not' "$d/board.json" >/dev/null \
  || fail "view-event: a firstmate reply followed by an empty view-event must stay demoted"
jq -e '.your_word | map(.id) | index("viewonly")' "$d/board.json" >/dev/null \
  || fail "view-event: the view-only item should rest in your_word"
# A newest empty-body view-event is NOT a parse failure (it has a valid header);
# the parse-fail marker must not be raised by these threads.
[ ! -f "$d/.thread-author-parse-fail" ] \
  || fail "view-event: empty-body view-events must not be counted as author-parse failures"
pass "empty-body view-events are ignored; the author check uses the newest bodied message"

echo "all fm-board-reconcile tests passed"

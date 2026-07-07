#!/usr/bin/env bash
# tests/fm-ledger.test.sh - the resumable loop-ledger.
#
# Proves bin/fm-ledger.sh round-trips a run's pinned state through a file:
#   - create seeds objective/next and a fresh active ledger under state/ledgers/
#   - update sets phase/next/status and APPENDS each decision (never overwrites)
#   - read prints the same JSON back, so a post-compaction resume recovers it
#   - updated_at advances on update; created_at is preserved
#   - a run id that tries to escape the ledgers dir is rejected
#   - update on a missing run fails rather than creating a half-ledger
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }

LEDGER="$ROOT/bin/fm-ledger.sh"
TMP_ROOT=$(fm_test_tmproot fm-ledger)
export FM_STATE_OVERRIDE="$TMP_ROOT/state"

RUN="wf_test_01"
FILE="$FM_STATE_OVERRIDE/ledgers/$RUN.json"

# --- create -----------------------------------------------------------------
"$LEDGER" create "$RUN" "encode the autonomy model" --next "write AGENTS.md block" >/dev/null
assert_present "$FILE" "create writes state/ledgers/<run>.json"

created=$(jq -r '.created_at' "$FILE")
assert_contains "$(jq -r '.objective' "$FILE")" "encode the autonomy model" "objective seeded"
assert_contains "$(jq -r '.next' "$FILE")" "write AGENTS.md block" "next seeded"
assert_contains "$(jq -r '.status' "$FILE")" "active" "status defaults to active"
[ "$(jq -r '.decisions | length' "$FILE")" = "0" ] || fail "decisions start empty"

# updated_at must advance on a later update; force a distinct second.
sleep 1

# --- update: phase/next/status + append decisions ---------------------------
"$LEDGER" update "$RUN" \
  --phase "build" \
  --next "run tests" \
  --status "in_review" \
  --decision "chose jq for atomic writes" \
  --decision "reject path-escaping run ids" >/dev/null

assert_contains "$(jq -r '.phase' "$FILE")" "build" "update sets phase"
assert_contains "$(jq -r '.next' "$FILE")" "run tests" "update sets next"
assert_contains "$(jq -r '.status' "$FILE")" "in_review" "update sets status"
[ "$(jq -r '.decisions | length' "$FILE")" = "2" ] || fail "two decisions appended"

# A second update APPENDS, it does not overwrite the decision log.
"$LEDGER" update "$RUN" --decision "third call keeps prior decisions" >/dev/null
[ "$(jq -r '.decisions | length' "$FILE")" = "3" ] || fail "decisions accumulate across updates"

updated=$(jq -r '.updated_at' "$FILE")
new_created=$(jq -r '.created_at' "$FILE")
[ "$new_created" = "$created" ] || fail "created_at is preserved across updates"
[ "$updated" -gt "$created" ] || fail "updated_at advances past created_at"

# --- read: same JSON back ---------------------------------------------------
out=$("$LEDGER" read "$RUN")
assert_contains "$out" "encode the autonomy model" "read prints objective"
assert_contains "$out" "chose jq for atomic writes" "read prints an appended decision"
assert_contains "$out" "run tests" "read prints the pinned next step"

# --- guards -----------------------------------------------------------------
if "$LEDGER" create "../escape" "x" >/dev/null 2>&1; then
  fail "a path-escaping run id must be rejected"
fi
if "$LEDGER" update "never_created" --phase x >/dev/null 2>&1; then
  fail "update on a missing run must fail, not create a half-ledger"
fi

pass "fm-ledger: create/update/read round-trips a run's pinned loop state"

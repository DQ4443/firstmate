#!/usr/bin/env bash
# Unit test for hk-digest.sh: empty-input creates no file; populated input
# renders sections in order (notes-failure, notes, Linear grouped by issue),
# folds only digest events, and leaves blockers in place. No network.
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
DIGEST="$ROOT/bin/housekeeping/hk-digest.sh"
TMP=$(mktemp -d "${TMPDIR:-/tmp}/hk-digest.XXXXXX")
trap 'rm -rf "$TMP"' EXIT
export FM_HK_ROOT="$TMP/hk"
INCOMING="$FM_HK_ROOT/queue/incoming"
PROCESSED="$FM_HK_ROOT/queue/processed"
PENDING="$FM_HK_ROOT/digests/pending"
mkdir -p "$INCOMING"

fail() {
  echo "FAIL: $1" >&2
  exit 1
}

# Empty-input case: no digest event files -> no file created.
bash "$DIGEST" morning
[ -z "$(find "$PENDING" -type f 2>/dev/null)" ] || fail "empty input created a digest file"

# Populate incoming with synthetic events.
write_event() {
  printf '%s' "$2" >"$INCOMING/$1"
}
write_event "20260719T010000Z-gmail-f1.json" '{"v":1,"source":"gmail","id":"f1","ts":"2026-07-19T01:00:00Z","kind":"notes-failure","action":"notes-failure","actor":"meetings-noreply@google.com","title":"Problem with the notes for Tech Sync","url":"","severity":"digest","detail":""}'
write_event "20260719T020000Z-gmail-n1.json" '{"v":1,"source":"gmail","id":"n1","ts":"2026-07-19T02:00:00Z","kind":"notes","action":"notes","actor":"gemini-notes@google.com","title":"Notes: Tech Sync","url":"https://mail.google.com/x","severity":"digest","detail":"Extracted:\nDecision: ship the daemon\nAction (David): approve funnel"}'
write_event "20260719T030000Z-linear-a.json" '{"v":1,"source":"linear","id":"la","ts":"2026-07-19T03:00:00Z","kind":"Issue","action":"state-change","actor":"ziyi","title":"ENG-42 moved to In Review","url":"https://linear.app/x/issue/ENG-42","severity":"digest","detail":""}'
write_event "20260719T031000Z-linear-b.json" '{"v":1,"source":"linear","id":"lb","ts":"2026-07-19T03:10:00Z","kind":"Comment","action":"comment","actor":"yujie","title":"comment on ENG-42","url":"https://linear.app/x/issue/ENG-42#c","severity":"digest","detail":""}'
# A blocker must NOT be folded by the digest.
write_event "20260719T040000Z-linear-blk.json" '{"v":1,"source":"linear","id":"blk","ts":"2026-07-19T04:00:00Z","kind":"IssueSLA","action":"sla-breached","actor":"system","title":"ENG-7 SLA breached","url":"","severity":"blocker","detail":""}'

bash "$DIGEST" afternoon
outfile="$PENDING/$(date -u +%Y-%m-%d)-afternoon.md"
[ -f "$outfile" ] || fail "digest file was not created"

grep -q "Notes failures" "$outfile" || fail "missing Notes failures section"
grep -q "Meeting notes" "$outfile" || fail "missing Meeting notes section"
grep -q "Linear" "$outfile" || fail "missing Linear section"

# Section ordering: notes-failure before notes before Linear.
ln_fail=$(grep -n "Notes failures" "$outfile" | head -n1 | cut -d: -f1)
ln_notes=$(grep -n "Meeting notes" "$outfile" | head -n1 | cut -d: -f1)
ln_linear=$(grep -n "^Linear" "$outfile" | head -n1 | cut -d: -f1)
[ "$ln_fail" -lt "$ln_notes" ] || fail "notes-failure not sorted above notes"
[ "$ln_notes" -lt "$ln_linear" ] || fail "notes not sorted above Linear"

# Linear items grouped under their issue key.
grep -q "^ENG-42" "$outfile" || fail "Linear items not grouped by issue key"

# Extracted detail is carried into the digest.
grep -q "ship the daemon" "$outfile" || fail "extracted detail missing from digest"

# Regression: an empty url field must not shift columns and leak the timestamp
# onto the item line (the notes-failure event has no url).
if grep "Problem with the notes" "$outfile" | grep -q "T01:00:00Z"; then
  fail "empty url field shifted columns and leaked ts onto the item line"
fi

# The four digest events were folded to processed; the blocker was left behind.
[ "$(find "$PROCESSED" -name '*.json' | wc -l | tr -d ' ')" = "4" ] || fail "wrong number of events folded"
[ -f "$INCOMING/20260719T040000Z-linear-blk.json" ] || fail "blocker was wrongly folded"
[ "$(find "$INCOMING" -name '*.json' | wc -l | tr -d ' ')" = "1" ] || fail "digest events not removed from incoming"

echo "PASS hk-digest.test.sh"

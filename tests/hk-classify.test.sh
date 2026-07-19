#!/usr/bin/env bash
# Unit test for hk-classify.mjs: routing, blocker path, dedup, severity
# recompute, and the native-notification drop rule. No network.
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
CLASSIFY="$ROOT/bin/housekeeping/hk-classify.mjs"
TMP=$(mktemp -d "${TMPDIR:-/tmp}/hk-classify.XXXXXX")
trap 'rm -rf "$TMP"' EXIT
export FM_HK_ROOT="$TMP/hk"

fail() {
  echo "FAIL: $1" >&2
  exit 1
}

incoming() { find "$FM_HK_ROOT/queue/incoming" -name '*.json' 2>/dev/null | wc -l | tr -d ' '; }
alerts() { find "$FM_HK_ROOT/alerts/pending" -type f 2>/dev/null | wc -l | tr -d ' '; }
classify() { printf '%s' "$1" | node "$CLASSIFY"; }

# 1. gmail notes -> stored as digest, no alert.
classify '{"v":1,"source":"gmail","id":"m1","ts":"2026-07-19T01:00:00Z","kind":"notes","action":"notes","actor":"gemini-notes@google.com","title":"Notes: Tech Sync","url":"","severity":"digest","detail":"snippet"}'
[ "$(incoming)" = "1" ] || fail "gmail notes not stored"
[ "$(alerts)" = "0" ] || fail "gmail notes should not alert"

# 2. gmail notes-failure -> stored, kind preserved.
classify '{"v":1,"source":"gmail","id":"m2","ts":"2026-07-19T01:05:00Z","kind":"notes-failure","action":"notes-failure","actor":"meetings-noreply@google.com","title":"Problem with the notes","url":"","severity":"digest","detail":""}'
[ "$(incoming)" = "2" ] || fail "notes-failure not stored"
grep -rq '"kind": "notes-failure"' "$FM_HK_ROOT/queue/incoming" || fail "notes-failure kind not persisted"

# 3. linear SLA breached -> stored as blocker + alert whose first line is the sentence.
classify '{"v":1,"source":"linear","id":"sla1","ts":"2026-07-19T02:00:00Z","kind":"IssueSLA","action":"sla-breached","actor":"system","title":"ENG-123 SLA breached","url":"https://linear.app/x/issue/ENG-123","severity":"digest","detail":""}'
[ "$(incoming)" = "3" ] || fail "SLA blocker not stored"
[ "$(alerts)" = "1" ] || fail "SLA blocker did not raise an alert"
grep -rq '"severity": "blocker"' "$FM_HK_ROOT/queue/incoming" || fail "blocker severity not persisted"
alert_file=$(find "$FM_HK_ROOT/alerts/pending" -type f | head -n1)
head -n1 "$alert_file" | grep -q '^Blocker:' || fail "alert first line is not the alert sentence"

# 4. dedup: same blocker again does not create a second copy.
classify '{"v":1,"source":"linear","id":"sla1","ts":"2026-07-19T02:00:00Z","kind":"IssueSLA","action":"sla-breached","actor":"system","title":"ENG-123 SLA breached","url":"https://linear.app/x/issue/ENG-123","severity":"digest","detail":""}'
[ "$(incoming)" = "3" ] || fail "dedup failed on identical event"
[ "$(alerts)" = "1" ] || fail "dedup failed on alert"

# 5. dedup against processed: a folded event is not re-created.
mkdir -p "$FM_HK_ROOT/queue/processed"
mv "$FM_HK_ROOT"/queue/incoming/*-gmail-m1.json "$FM_HK_ROOT/queue/processed/"
[ "$(incoming)" = "2" ] || fail "setup for processed dedup failed"
classify '{"v":1,"source":"gmail","id":"m1","ts":"2026-07-19T01:00:00Z","kind":"notes","action":"notes","actor":"gemini-notes@google.com","title":"Notes: Tech Sync","url":"","severity":"digest","detail":"snippet"}'
[ "$(incoming)" = "2" ] || fail "processed dedup failed; event re-created"

# 6. native-notification drop: issue assigned directly to David is never stored.
before=$(incoming)
classify '{"v":1,"source":"linear","id":"assign1","ts":"2026-07-19T03:00:00Z","kind":"Issue","action":"assigned-to-david","actor":"yujie","title":"ENG-9 assigned to you","url":"https://linear.app/x/issue/ENG-9","severity":"digest","detail":""}'
[ "$(incoming)" = "$before" ] || fail "assigned-to-david was stored instead of dropped"

# 7. mention of David dropped too.
classify '{"v":1,"source":"linear","id":"mention1","ts":"2026-07-19T03:10:00Z","kind":"Comment","action":"mention-david","actor":"ziyi","title":"comment on ENG-9","url":"","severity":"digest","detail":""}'
[ "$(incoming)" = "$before" ] || fail "mention-david was stored instead of dropped"

# 8. severity recompute: a gmail event mislabelled blocker is stored as digest.
classify '{"v":1,"source":"gmail","id":"m3","ts":"2026-07-19T04:00:00Z","kind":"notes","action":"notes","actor":"gemini-notes@google.com","title":"Notes: Standup","url":"","severity":"blocker","detail":""}'
stored=$(grep -rl '"id": "m3"' "$FM_HK_ROOT/queue/incoming")
grep -q '"severity": "digest"' "$stored" || fail "gmail event not forced back to digest"
[ "$(alerts)" = "1" ] || fail "mislabelled gmail event wrongly raised an alert"

# 9. non-david linear state change is kept as a digest.
classify '{"v":1,"source":"linear","id":"state1","ts":"2026-07-19T05:00:00Z","kind":"Issue","action":"state-change","actor":"ziyi","title":"ENG-42 moved to In Review","url":"https://linear.app/x/issue/ENG-42","severity":"digest","detail":""}'
grep -rq '"id": "state1"' "$FM_HK_ROOT/queue/incoming" || fail "non-david state change should be kept as digest"

echo "PASS hk-classify.test.sh"

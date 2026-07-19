#!/usr/bin/env bash
set -eu

# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# The worker is a deterministic normalizer and classifier: no model turn, no
# board post. It folds a raw Linear webhook into the housekeeping event schema,
# drops what Linear already notifies David about, raises alerts for SLA
# blockers, and delegates to hk-classify.mjs when that router is installed.

command -v jq >/dev/null 2>&1 || { echo "ok - skipped (jq unavailable)"; exit 0; }

work=$(mktemp -d "${TMPDIR:-/tmp}/fm-linear-worker.XXXXXX")
trap 'rm -rf "$work"' EXIT
worker="$ROOT/bin/fm-linear-event-worker.sh"

run_worker() {
  # run_worker <hk_root> <event_json_file> [extra env assignments...]
  local hk=$1 ev=$2; shift 2
  env FM_HK_ROOT="$hk" "$@" "$worker" "$ev"
}

# --- digest: a state change on a David-assigned issue by another actor -------
hk="$work/hk1"; ev="$work/ev1.json"
cat > "$ev" <<'JSON'
{"type":"Issue","action":"update","actor":{"name":"Jane Dev"},
 "updatedFrom":{"stateId":"old"},
 "data":{"id":"issue-111","identifier":"ENG-42","title":"Wire the KPIs","url":"https://linear.app/x/ENG-42",
         "assignee":{"id":"448a6290-609b-4651-b416-768eb0ac9c93","name":"David"},"state":{"name":"In Progress"}},
 "webhookTimestamp":1784150000000}
JSON
run_worker "$hk" "$ev" >/dev/null
queued=$(find "$hk/queue/incoming" -type f -name '*.json')
[ -n "$queued" ] || fail "digest event did not land in queue/incoming"
jq -e '.severity == "digest"' "$queued" >/dev/null || fail "state change is a digest"
jq -e '.id == "issue-111"' "$queued" >/dev/null || fail "event carries the entity id"
jq -e '.kind == "issue"' "$queued" >/dev/null || fail "event kind is issue"
jq -e '.detail == "State: In Progress"' "$queued" >/dev/null || fail "detail names the new state"
[ "$(find "$hk/alerts/pending" -type f 2>/dev/null | wc -l | tr -d ' ')" = 0 ] || fail "digest raised an alert"
pass "state change on a David-assigned issue routes to queue as a digest"

# --- drop: issue assigned directly to David ---------------------------------
hk="$work/hk2"; ev="$work/ev2.json"
cat > "$ev" <<'JSON'
{"type":"Issue","action":"update","actor":{"name":"Jane Dev"},
 "updatedFrom":{"assigneeId":"someone-else"},
 "data":{"id":"issue-222","identifier":"ENG-43","title":"Yours now",
         "assignee":{"id":"448a6290-609b-4651-b416-768eb0ac9c93","name":"David"}},
 "webhookTimestamp":1784150000000}
JSON
run_worker "$hk" "$ev" >/dev/null
[ "$(find "$hk/queue/incoming" -type f 2>/dev/null | wc -l | tr -d ' ')" = 0 ] || fail "assignment-to-David was stored"
assert_grep "dropped issue-assigned-to-david id=issue-222" "$hk/linear/events.log" "drop is logged one line"
pass "issue assigned directly to David is dropped and logged"

# --- drop: comment that @mentions David -------------------------------------
hk="$work/hk3"; ev="$work/ev3.json"
cat > "$ev" <<'JSON'
{"type":"Comment","action":"create","actor":{"name":"Bob"},
 "data":{"id":"comment-333","body":"can you review @[David](448a6290-609b-4651-b416-768eb0ac9c93)",
         "issue":{"identifier":"ENG-42","title":"Wire the KPIs"}},
 "webhookTimestamp":1784150000000}
JSON
run_worker "$hk" "$ev" >/dev/null
[ "$(find "$hk/queue/incoming" -type f 2>/dev/null | wc -l | tr -d ' ')" = 0 ] || fail "David-mention comment was stored"
assert_grep "dropped comment-mentions-david id=comment-333" "$hk/linear/events.log" "mention drop is logged"
pass "comment that mentions David is dropped and logged"

# --- keep: comment by another that does NOT mention David -------------------
hk="$work/hk4"; ev="$work/ev4.json"
cat > "$ev" <<'JSON'
{"type":"Comment","action":"create","actor":{"name":"Bob"},
 "data":{"id":"comment-444","body":"pushed a fix, tests are green",
         "issue":{"identifier":"ENG-42","title":"Wire the KPIs","url":"https://linear.app/x/ENG-42"}},
 "webhookTimestamp":1784150000000}
JSON
run_worker "$hk" "$ev" >/dev/null
queued=$(find "$hk/queue/incoming" -type f -name '*.json')
jq -e '.severity == "digest"' "$queued" >/dev/null || fail "a non-mention comment is a digest"
jq -e '.title | contains("Comment on ENG-42")' "$queued" >/dev/null || fail "comment title names the issue"
pass "comment without a David mention is kept as a digest"

# --- blocker: SLA breach raises an alert whose first line is a sentence ------
# Fallback path: the classifier is absent, so the worker owns queue and alert
# placement itself.
hk="$work/hk5"; ev="$work/ev5.json"
cat > "$ev" <<'JSON'
{"type":"Issue","action":"update","actor":{"name":"System"},
 "data":{"id":"issue-555","identifier":"ENG-99","title":"Critical path","url":"https://linear.app/x/ENG-99","slaStatus":"breached"},
 "webhookTimestamp":1784150000000}
JSON
run_worker "$hk" "$ev" FM_HK_CLASSIFY_BIN="$work/no-such-classifier" >/dev/null
queued=$(find "$hk/queue/incoming" -type f -name '*.json')
jq -e '.severity == "blocker"' "$queued" >/dev/null || fail "SLA breach is a blocker"
jq -e '.kind == "IssueSLA"' "$queued" >/dev/null || fail "SLA breach keeps kind IssueSLA"
jq -e '.action == "breached"' "$queued" >/dev/null || fail "SLA breach carries the breached action"
alert=$(find "$hk/alerts/pending" -type f -name '*.txt')
[ -n "$alert" ] || fail "SLA blocker did not raise a pending alert"
first_line=$(head -1 "$alert")
assert_contains "$first_line" "Linear blocker: ENG-99 Critical path" "alert first line is the sentence"
assert_contains "$first_line" "SLA breached" "alert sentence names the SLA state"
pass "SLA breach raises a blocker alert with a sentence first line"

# --- blocker: the SLA handoff survives the installed classifier --------------
# The classifier recomputes severity from kind and action, so the worker must
# hand it kind IssueSLA plus the SLA action rather than issue/update.
hk="$work/hk5b"; ev="$work/ev5b.json"
cat > "$ev" <<'JSON'
{"type":"IssueSLA","action":"highRisk","actor":{"name":"System"},
 "data":{"id":"issue-556","identifier":"ENG-100","title":"Slipping","url":"https://linear.app/x/ENG-100"},
 "webhookTimestamp":1784150000000}
JSON
run_worker "$hk" "$ev" >/dev/null 2>&1
queued=$(find "$hk/queue/incoming" -type f -name '*.json')
[ -n "$queued" ] || fail "classifier did not store the SLA event"
jq -e '.severity == "blocker"' "$queued" >/dev/null || fail "classifier stored the high-risk SLA event as a blocker"
jq -e '.kind == "IssueSLA"' "$queued" >/dev/null || fail "stored SLA event keeps kind IssueSLA"
jq -e '.action == "highRisk"' "$queued" >/dev/null || fail "stored SLA event carries the highRisk action"
[ "$(find "$hk/alerts/pending" -type f 2>/dev/null | wc -l | tr -d ' ')" = 1 ] || fail "classifier did not raise the SLA alert"
pass "high-risk SLA webhook routes through the classifier as a blocker with an alert"

# --- digest: an SLA being set is not an emergency ----------------------------
hk="$work/hk5c"; ev="$work/ev5c.json"
cat > "$ev" <<'JSON'
{"type":"IssueSLA","action":"set","actor":{"name":"System"},
 "data":{"id":"issue-557","identifier":"ENG-101","title":"Fresh SLA","url":"https://linear.app/x/ENG-101"},
 "webhookTimestamp":1784150000000}
JSON
run_worker "$hk" "$ev" >/dev/null 2>&1
queued=$(find "$hk/queue/incoming" -type f -name '*.json')
[ -n "$queued" ] || fail "SLA-set event did not land in queue/incoming"
jq -e '.severity == "digest"' "$queued" >/dev/null || fail "SLA set is a digest, not a blocker"
jq -e '.kind == "IssueSLA" and .action == "set"' "$queued" >/dev/null || fail "SLA-set event keeps kind IssueSLA and the set action"
[ "$(find "$hk/alerts/pending" -type f 2>/dev/null | wc -l | tr -d ' ')" = 0 ] || fail "SLA set wrongly raised an alert"
pass "SLA set stays a digest with no alert"

# --- delegation: hk-classify.mjs owns routing when present ------------------
hk="$work/hk6"; ev="$work/ev6.json"
sink="$work/sink.txt"
classify="$work/hk-classify.mjs"
cat > "$classify" <<'JS'
#!/usr/bin/env node
import { writeFileSync } from "node:fs";
let d = "";
process.stdin.on("data", (c) => (d += c));
process.stdin.on("end", () => {
  const e = JSON.parse(d);
  writeFileSync(process.env.CLASSIFY_SINK, `${e.id}|${e.severity}|${e.kind}\n`);
});
JS
chmod +x "$classify"
cat > "$ev" <<'JSON'
{"type":"Project","action":"create","actor":{"name":"PM"},"data":{"id":"proj-1","name":"Q3 Roadmap","url":"https://linear.app/p/1"},"webhookTimestamp":1784150000000}
JSON
run_worker "$hk" "$ev" FM_HK_CLASSIFY_BIN="$classify" CLASSIFY_SINK="$sink" >/dev/null
assert_grep "proj-1|digest|project" "$sink" "classifier received the normalized event on stdin"
[ "$(find "$hk/queue/incoming" -type f 2>/dev/null | wc -l | tr -d ' ')" = 0 ] || fail "worker wrote the queue even though the classifier is present"
pass "hk-classify.mjs takes over routing when it is installed"

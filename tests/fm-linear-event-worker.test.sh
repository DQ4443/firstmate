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
event=$(cat "$queued")
assert_contains "$event" '"severity":"digest"' "state change is a digest"
assert_contains "$event" '"id":"issue-111"' "event carries the entity id"
assert_contains "$event" '"kind":"issue"' "event kind is issue"
assert_contains "$event" '"detail":"State: In Progress"' "detail names the new state"
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
event=$(cat "$(find "$hk/queue/incoming" -type f -name '*.json')")
assert_contains "$event" '"severity":"digest"' "a non-mention comment is a digest"
assert_contains "$event" 'Comment on ENG-42' "comment title names the issue"
pass "comment without a David mention is kept as a digest"

# --- blocker: SLA breach raises an alert whose first line is a sentence ------
hk="$work/hk5"; ev="$work/ev5.json"
cat > "$ev" <<'JSON'
{"type":"Issue","action":"update","actor":{"name":"System"},
 "data":{"id":"issue-555","identifier":"ENG-99","title":"Critical path","url":"https://linear.app/x/ENG-99","slaStatus":"breached"},
 "webhookTimestamp":1784150000000}
JSON
run_worker "$hk" "$ev" >/dev/null
event=$(cat "$(find "$hk/queue/incoming" -type f -name '*.json')")
assert_contains "$event" '"severity":"blocker"' "SLA breach is a blocker"
alert=$(find "$hk/alerts/pending" -type f -name '*.txt')
[ -n "$alert" ] || fail "SLA blocker did not raise a pending alert"
first_line=$(head -1 "$alert")
assert_contains "$first_line" "Linear blocker: ENG-99 Critical path" "alert first line is the sentence"
assert_contains "$first_line" "SLA breached" "alert sentence names the SLA state"
pass "SLA breach raises a blocker alert with a sentence first line"

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

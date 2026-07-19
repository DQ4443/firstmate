#!/usr/bin/env bash
set -eu

# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# The reconcile sweep is the missed-event safety net. With no API key it is a
# silent no-op. With a key it queries Linear for recently updated Engineering
# issues, synthesizes digest events only for issues not already witnessed on
# disk, dedups on a second run, and advances its cursor atomically.

command -v jq >/dev/null 2>&1 || { echo "ok - skipped (jq unavailable)"; exit 0; }

reconcile="$ROOT/bin/housekeeping/hk-linear-reconcile.sh"
work=$(mktemp -d "${TMPDIR:-/tmp}/hk-reconcile.XXXXXX")
mock_pid=""
trap '[ -n "$mock_pid" ] && kill "$mock_pid" 2>/dev/null; wait "$mock_pid" 2>/dev/null || true; rm -rf "$work"' EXIT

# --- no key: silent no-op ---------------------------------------------------
hk="$work/hk-nokey"
out=$(FM_HK_ROOT="$hk" "$reconcile" 2>&1)
expect_code 0 $? "no-key reconcile exit"
[ -z "$out" ] || fail "no-key reconcile was not silent: $out"
pass "reconcile with no API key is a silent no-op"

# --- with key: synthesize the missed issue, skip the seen one ---------------
hk="$work/hk"
mkdir -p "$hk/secrets" "$hk/linear/done" "$hk/queue/incoming" "$hk/cursors"
printf 'fake-key\n' > "$hk/secrets/linear-api-key"
chmod 600 "$hk/secrets/linear-api-key"
# issue-seen is already witnessed as a raw delivery in linear/done.
printf '%s\n' '{"type":"Issue","data":{"id":"issue-seen","identifier":"ENG-1"}}' > "$hk/linear/done/seen.json"

port=$(( 40000 + RANDOM % 20000 ))
cat > "$work/mock.mjs" <<'JS'
import { createServer } from "node:http";
const port = Number(process.argv[2]);
createServer((req, res) => {
  let b = "";
  req.on("data", (c) => (b += c));
  req.on("end", () => {
    res.writeHead(200, { "content-type": "application/json" });
    res.end(JSON.stringify({ data: { issues: {
      nodes: [
        { id: "issue-seen", identifier: "ENG-1", title: "Already have it", url: "http://x/1", updatedAt: "2026-07-19T10:00:00Z", assignee: null, state: { name: "Todo" } },
        { id: "issue-missed", identifier: "ENG-2", title: "Dropped webhook", url: "http://x/2", updatedAt: "2026-07-19T11:00:00Z", assignee: null, state: { name: "In Progress" } },
      ],
      pageInfo: { hasNextPage: false },
    } } }));
  });
}).listen(port, "127.0.0.1");
JS
node "$work/mock.mjs" "$port" &
mock_pid=$!
for _ in $(seq 1 100); do
  curl -fsS -X POST "http://127.0.0.1:$port/" -d '{}' >/dev/null 2>&1 && break
  sleep 0.05
done

out=$(FM_HK_ROOT="$hk" FM_HK_LINEAR_GRAPHQL="http://127.0.0.1:$port/graphql" "$reconcile" 2>&1)
expect_code 0 $? "reconcile exit with key"
assert_contains "$out" "synthesized 1 missed digest event" "reports the single genuine miss"

missed=$(find "$hk/queue/incoming" -type f -name '*issue-missed*.json')
[ -n "$missed" ] || fail "missed issue was not synthesized into queue/incoming"
event=$(cat "$missed")
assert_contains "$event" '"actor":"reconcile"' "synthesized event is marked as reconcile-sourced"
assert_contains "$event" '"severity":"digest"' "synthesized event is a digest"
assert_contains "$event" 'ENG-2' "synthesized event names the issue"
[ "$(find "$hk/queue/incoming" -type f -name '*issue-seen*' 2>/dev/null | wc -l | tr -d ' ')" = 0 ] || fail "already-seen issue was re-synthesized"
pass "reconcile synthesizes only the genuinely missed issue"

assert_present "$hk/cursors/linear-reconcile-cursor" "cursor file is written"
pass "cursor is advanced atomically"

# --- second run: the once-missed issue is now in the queue, so it is silent -
out=$(FM_HK_ROOT="$hk" FM_HK_LINEAR_GRAPHQL="http://127.0.0.1:$port/graphql" "$reconcile" 2>&1)
expect_code 0 $? "second reconcile exit"
[ -z "$out" ] || fail "second reconcile was not silent: $out"
[ "$(find "$hk/queue/incoming" -type f -name '*.json' | wc -l | tr -d ' ')" = 1 ] || fail "second run duplicated an event"
pass "reconcile dedups against the queue on a second run"

# --- pagination: the sweep must drain every page in one run --------------------
# A single-page fetch (first: 250, no `after` walk) that advanced the cursor to
# the page's newest updatedAt would permanently skip older un-fetched misses,
# defeating the reconcile in the exact scenario it exists for (a webhook
# auto-disabled while more than one page of issues changed in a window). The
# paginating mock only returns the second-page miss when handed the endCursor.
kill "$mock_pid" 2>/dev/null; wait "$mock_pid" 2>/dev/null || true
hk="$work/hk-pag"
mkdir -p "$hk/secrets"
printf 'fake-key\n' > "$hk/secrets/linear-api-key"
chmod 600 "$hk/secrets/linear-api-key"

port=$(( 40000 + RANDOM % 20000 ))
cat > "$work/mock-pag.mjs" <<'JS'
import { createServer } from "node:http";
const port = Number(process.argv[2]);
createServer((req, res) => {
  let b = "";
  req.on("data", (c) => (b += c));
  req.on("end", () => {
    const after = (JSON.parse(b || "{}").variables || {}).after;
    res.writeHead(200, { "content-type": "application/json" });
    if (!after) {
      res.end(JSON.stringify({ data: { issues: {
        nodes: [{ id: "issue-page1", identifier: "ENG-9", title: "Recent", url: "http://x/9", updatedAt: "2026-07-19T12:00:00Z", assignee: null, state: { name: "Todo" } }],
        pageInfo: { hasNextPage: true, endCursor: "CUR1" },
      } } }));
    } else if (after === "CUR1") {
      res.end(JSON.stringify({ data: { issues: {
        nodes: [{ id: "issue-page2", identifier: "ENG-2", title: "Older miss", url: "http://x/2", updatedAt: "2026-07-19T09:00:00Z", assignee: null, state: { name: "Done" } }],
        pageInfo: { hasNextPage: false, endCursor: "CUR2" },
      } } }));
    } else {
      res.end(JSON.stringify({ data: { issues: { nodes: [], pageInfo: { hasNextPage: false, endCursor: null } } } }));
    }
  });
}).listen(port, "127.0.0.1");
JS
node "$work/mock-pag.mjs" "$port" &
mock_pid=$!
for _ in $(seq 1 100); do
  curl -fsS -X POST "http://127.0.0.1:$port/" -d '{}' >/dev/null 2>&1 && break
  sleep 0.05
done

out=$(FM_HK_ROOT="$hk" FM_HK_LINEAR_GRAPHQL="http://127.0.0.1:$port/graphql" "$reconcile" 2>&1)
expect_code 0 $? "paginating reconcile exit"
assert_contains "$out" "synthesized 2 missed digest event" "both pages are drained in one run"
[ -n "$(find "$hk/queue/incoming" -type f -name '*issue-page1*.json')" ] || fail "first-page issue was not synthesized"
[ -n "$(find "$hk/queue/incoming" -type f -name '*issue-page2*.json')" ] || fail "second-page issue was skipped (pagination regression)"
pass "reconcile walks every page instead of dropping the second-page miss"

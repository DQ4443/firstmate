#!/usr/bin/env bash
set -eu

# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# End-to-end intake through the real worker: the server verifies a signed
# Linear webhook, the worker normalizes it, and the housekeeping event lands in
# queue/incoming. A bad signature is rejected with 401 and never queued.

command -v jq >/dev/null 2>&1 || { echo "ok - skipped (jq unavailable)"; exit 0; }

work=$(mktemp -d "${TMPDIR:-/tmp}/fm-linear-event.XXXXXX")
hk_root="$work/hk"
secret_file="$hk_root/secrets/linear-webhook-secret"
mkdir -p "$hk_root/secrets"
port=$(( 40000 + RANDOM % 20000 ))
secret='test-webhook-secret'
printf '%s\n' "$secret" > "$secret_file"
chmod 600 "$secret_file"

FM_HK_ROOT="$hk_root" \
FM_HK_LINEAR_ADDR="127.0.0.1:$port" \
node "$ROOT/bin/fm-linear-event-server.mjs" > "$work/stdout" 2> "$work/stderr" &
server_pid=$!
trap 'kill "$server_pid" 2>/dev/null || true; wait "$server_pid" 2>/dev/null || true; rm -rf "$work"' EXIT

for _ in $(seq 1 100); do
  if curl -fsS "http://127.0.0.1:$port/healthz" >/dev/null 2>&1; then break; fi
  sleep 0.05
done
curl -fsS "http://127.0.0.1:$port/healthz" >/dev/null || fail "server did not become healthy"
pass "health endpoint is reachable"

# A digest-class event: a state change on an issue by another actor. It must be
# normalized and land in queue/incoming.
now_ms=$(( $(date +%s) * 1000 ))
body=$(printf '{"type":"Issue","action":"update","organizationId":"org-test","webhookTimestamp":%s,"actor":{"name":"Jane Dev"},"updatedFrom":{"stateId":"old"},"data":{"id":"issue-e2e-1","identifier":"ENG-777","title":"Reconcile the ledger","url":"https://linear.app/x/ENG-777","state":{"name":"In Review"}}}' "$now_ms")
sig=$(printf '%s' "$body" | openssl dgst -sha256 -hmac "$secret" -hex | awk '{print $NF}')

code=$(curl -sS -o /dev/null -w '%{http_code}' -X POST "http://127.0.0.1:$port/linear" -H 'content-type: application/json' --data-binary "$body")
[ "$code" = 401 ] || fail "unsigned request returned $code"
pass "unsigned request is rejected with 401"

bad_sig=$(printf 'not-the-body' | openssl dgst -sha256 -hmac "$secret" -hex | awk '{print $NF}')
code=$(curl -sS -o /dev/null -w '%{http_code}' -X POST "http://127.0.0.1:$port/linear" -H "Linear-Signature: $bad_sig" --data-binary "$body")
[ "$code" = 401 ] || fail "wrong-signature request returned $code"
pass "wrong-signature request is rejected with 401"

response=$(curl -fsS -X POST "http://127.0.0.1:$port/linear" -H "Linear-Signature: $sig" -H 'Linear-Delivery: delivery-e2e-1' --data-binary "$body")
assert_contains "$response" '"duplicate":false' "first delivery is accepted"
pass "valid signed request is accepted"

queued=""
for _ in $(seq 1 200); do
  queued=$(find "$hk_root/queue/incoming" -type f -name '*.json' 2>/dev/null | head -1)
  [ -n "$queued" ] && break
  sleep 0.05
done
[ -n "$queued" ] || fail "no housekeeping event landed in queue/incoming"
pass "normalized event lands in queue/incoming"

jq -e '.source == "linear"' "$queued" >/dev/null || fail "queued event carries the linear source"
jq -e '.id == "issue-e2e-1"' "$queued" >/dev/null || fail "queued event carries the stable id"
jq -e '.severity == "digest"' "$queued" >/dev/null || fail "state change classifies as digest"
jq -e '.title | contains("ENG-777")' "$queued" >/dev/null || fail "queued event carries the issue identifier"
pass "queued event matches the housekeeping schema"

[ "$(find "$hk_root/linear/done" -type f -name '*.json' | wc -l | tr -d ' ')" = 1 ] || fail "raw delivery was not archived to linear/done"
pass "raw delivery is archived durably for the reconcile sweep"

[ "$(find "$hk_root/alerts/pending" -type f 2>/dev/null | wc -l | tr -d ' ')" = 0 ] || fail "digest event should not raise an alert"
pass "digest event raises no blocker alert"

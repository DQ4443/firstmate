#!/usr/bin/env bash
set -eu

# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

work=$(mktemp -d "${TMPDIR:-/tmp}/fm-linear-event.XXXXXX")
state="$work/state"
secret_file="$work/secret"
worker="$work/worker.sh"
port=$(( 46000 + ($$ % 1000) ))
secret='test-webhook-secret'
printf '%s\n' "$secret" > "$secret_file"
chmod 600 "$secret_file"

cat > "$worker" <<'SH'
#!/usr/bin/env bash
set -eu
printf '%s\n' "$1" >> "$FM_TEST_WORKER_LOG"
SH
chmod +x "$worker"

FM_LINEAR_EVENT_PORT="$port" \
FM_LINEAR_EVENT_STATE="$state" \
FM_LINEAR_EVENT_SECRET_FILE="$secret_file" \
FM_LINEAR_EVENT_WORKER="$worker" \
FM_TEST_WORKER_LOG="$work/worker.log" \
node "$ROOT/bin/fm-linear-event-server.mjs" > "$work/stdout" 2> "$work/stderr" &
server_pid=$!
trap 'kill "$server_pid" 2>/dev/null || true; wait "$server_pid" 2>/dev/null || true; rm -rf "$work"' EXIT

for _ in $(seq 1 100); do
  if curl -fsS "http://127.0.0.1:$port/healthz" >/dev/null 2>&1; then break; fi
  sleep 0.05
done
curl -fsS "http://127.0.0.1:$port/healthz" >/dev/null || fail "server did not become healthy"
pass "health endpoint is reachable"

now_ms=$(( $(date +%s) * 1000 ))
body=$(printf '{"type":"Comment","action":"create","organizationId":"org-test","webhookTimestamp":%s,"data":{"id":"comment-1","body":"done","issue":{"identifier":"ENG-1"}}}' "$now_ms")
sig=$(printf '%s' "$body" | openssl dgst -sha256 -hmac "$secret" -hex | awk '{print $NF}')

code=$(curl -sS -o /dev/null -w '%{http_code}' -X POST "http://127.0.0.1:$port/linear" -H 'content-type: application/json' --data-binary "$body")
[ "$code" = 401 ] || fail "unsigned request returned $code"
pass "unsigned request is rejected"

stale='{"type":"Comment","action":"create","organizationId":"org-test","webhookTimestamp":1,"data":{"id":"comment-stale"}}'
stale_sig=$(printf '%s' "$stale" | openssl dgst -sha256 -hmac "$secret" -hex | awk '{print $NF}')
code=$(curl -sS -o /dev/null -w '%{http_code}' -X POST "http://127.0.0.1:$port/linear" -H "Linear-Signature: $stale_sig" --data-binary "$stale")
[ "$code" = 401 ] || fail "stale request returned $code"
pass "stale signed request is rejected"

response=$(curl -fsS -X POST "http://127.0.0.1:$port/linear" -H "Linear-Signature: $sig" -H 'Linear-Delivery: delivery-1' --data-binary "$body")
assert_contains "$response" '"duplicate":false' "first delivery is accepted"
pass "valid signed request is accepted"

for _ in $(seq 1 100); do
  [ -s "$work/worker.log" ] && break
  sleep 0.05
done
[ "$(wc -l < "$work/worker.log" | tr -d ' ')" = 1 ] || fail "worker did not process exactly once"
pass "accepted event is processed"

response=$(curl -fsS -X POST "http://127.0.0.1:$port/linear" -H "Linear-Signature: $sig" -H 'Linear-Delivery: delivery-1' --data-binary "$body")
assert_contains "$response" '"duplicate":true' "duplicate delivery is acknowledged"
sleep 0.1
[ "$(wc -l < "$work/worker.log" | tr -d ' ')" = 1 ] || fail "duplicate was processed twice"
pass "duplicate delivery is not processed twice"

[ "$(find "$state/done" -type f -name '*.json' | wc -l | tr -d ' ')" = 1 ] || fail "processed event was not durably archived"
pass "processed event is archived durably"

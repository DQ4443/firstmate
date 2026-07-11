#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
ADAPTER="$ROOT/.agents/skills/pdw/scripts/report-back.sh"
PDW_SKILL="$ROOT/.agents/skills/pdw/SKILL.md"
TMP=$(mktemp -d "${TMPDIR:-/tmp}/pdw-report.XXXXXX")
trap 'rm -rf "$TMP"' EXIT
STATE="$TMP/state"
mkdir -p "$STATE"

write_config() {
  printf '{"retry_max_attempts":2,"claim_ttl_seconds":1,"lock_ttl_seconds":60,"drain_batch_size":1}\n' >"$STATE/config.json"
}

write_report() {
  local file=$1
  local task_id=$2
  jq -n --arg task_id "$task_id" '{task_id: $task_id, return_thread_id: "thread-1", return_host_id: "local", status: "COMPLETE", requested_status: "COMPLETE", effective_status: "COMPLETE", summary: "done", commands: [{command: "true", output_tail: ""}], artifacts: [], branch: "codex/test", worktree: "/repo/.claude/worktrees/test", last_commit_sha: "abc123", requested_model: "gpt-5.6-sol", effective_model: "unavailable_to_pin_in_native_subagent_api", requested_effort: "high", effective_effort: "unavailable_to_pin_in_native_subagent_api", routing_rationale: "review", identifiers: {}, child_returns: [{task_id: "child-a", status: "COMPLETE"}, {task_id: "child-b", status: "COMPLETE"}], NEXT_STEP: "independent review"}' >"$file"
}

write_config
write_report "$TMP/report.json" task-1
prepared=$($ADAPTER --state-dir "$STATE" prepare --report "$TMP/report.json")
key=$(jq -r '.report_key' <<<"$prepared")
jq -e '.status == "pending"' <<<"$prepared" >/dev/null
grep -q "REPORT_KEY: $key" "$STATE/pending/$key.json"
jq -e '.report.requested_status == "COMPLETE" and .report.effective_status == "COMPLETE" and (.report.child_returns | length == 2)' "$STATE/pending/$key.json" >/dev/null
printf 'ok - prepare writes a stable keyed pending payload\n'

prepared_again=$($ADAPTER --state-dir "$STATE" prepare --report "$TMP/report.json")
[[ $(jq -r '.report_key' <<<"$prepared_again") == "$key" ]]
printf 'ok - repeated prepare keeps the stable report key\n'

claimed=$($ADAPTER --state-dir "$STATE" claim --key "$key")
jq -e '.status == "claimed" and .attempts == 1' <<<"$claimed" >/dev/null
printf 'ok - claim leases a pending report for retry\n'

$ADAPTER --state-dir "$STATE" ack --key "$key" >/dev/null
[[ -f "$STATE/sent/$key.json" && ! -e "$STATE/inflight/$key.json" ]]
printf 'ok - ack records delivery and clears transient state\n'

already=$($ADAPTER --state-dir "$STATE" prepare --report "$TMP/report.json")
jq -e '.status == "already-acknowledged"' <<<"$already" >/dev/null
printf 'ok - acknowledged report is not requeued\n'

first_receive=$($ADAPTER --state-dir "$STATE" receive --key "$key")
second_receive=$($ADAPTER --state-dir "$STATE" receive --key "$key")
jq -e '.apply_side_effects == true' <<<"$first_receive" >/dev/null
jq -e '.status == "duplicate-suppressed" and .apply_side_effects == false' <<<"$second_receive" >/dev/null
printf 'ok - receiver suppresses duplicate side effects\n'

write_report "$TMP/report-2.json" task-2
queued=$($ADAPTER --state-dir "$STATE" prepare --report "$TMP/report-2.json" --queue)
key2=$(jq -r '.report_key' <<<"$queued")
drained=$($ADAPTER --state-dir "$STATE" drain)
jq -e 'length == 1 and .[0].attempts == 1' <<<"$drained" >/dev/null
printf 'ok - drain obeys the configured batch and claims queued work\n'

python3 - "$STATE/inflight/$key2.json" <<'PY'
import json
import sys

path = sys.argv[1]
with open(path) as handle:
    value = json.load(handle)
value["claimed_at_epoch"] = 0
with open(path, "w") as handle:
    json.dump(value, handle)
PY
recovered=$($ADAPTER --state-dir "$STATE" drain)
jq -e 'length == 1 and .[0].attempts == 2' <<<"$recovered" >/dev/null
printf 'ok - stale inflight claim returns to retry\n'

python3 - "$STATE/inflight/$key2.json" <<'PY'
import json
import sys

path = sys.argv[1]
with open(path) as handle:
    value = json.load(handle)
value["claimed_at_epoch"] = 0
with open(path, "w") as handle:
    json.dump(value, handle)
PY
exhausted=$($ADAPTER --state-dir "$STATE" drain)
jq -e 'length == 0' <<<"$exhausted" >/dev/null
[[ -f "$STATE/exhausted/$key2.json" ]]
printf 'ok - configured retry maximum exhausts the report\n'

resurrected=$($ADAPTER --state-dir "$STATE" prepare --report "$TMP/report-2.json" --queue)
jq -e '.status == "already-exhausted"' <<<"$resurrected" >/dev/null
[[ ! -e "$STATE/retry/$key2.json" && ! -e "$STATE/pending/$key2.json" ]]
printf 'ok - exhausted report cannot be resurrected by prepare\n'

write_report "$TMP/report-3.json" task-3
pending=$($ADAPTER --state-dir "$STATE" prepare --report "$TMP/report-3.json")
key3=$(jq -r '.report_key' <<<"$pending")
drained_pending=$($ADAPTER --state-dir "$STATE" drain)
jq -e --arg key "$key3" 'length == 1 and .[0].report_key == $key' <<<"$drained_pending" >/dev/null
printf 'ok - drain turns an unacknowledged native-send pending report into retry work\n'

write_report "$TMP/banana.json" task-banana
jq '.effective_effort = "banana"' "$TMP/banana.json" >"$TMP/invalid-effort.json"
if $ADAPTER --state-dir "$STATE" prepare --report "$TMP/invalid-effort.json" >/dev/null 2>&1; then
  printf 'not ok - unknown effective effort was accepted\n' >&2
  exit 1
fi
printf 'ok - unknown effective effort is rejected\n'

mv "$STATE/config.json" "$STATE/config.saved"
if $ADAPTER --state-dir "$STATE" drain >/dev/null 2>&1; then
  printf 'not ok - missing config was accepted\n' >&2
  exit 1
fi
printf 'ok - missing config fails closed\n'

mv "$STATE/config.saved" "$STATE/config.json"
write_report "$TMP/missing-destination.json" task-4
jq 'del(.return_thread_id)' "$TMP/missing-destination.json" >"$TMP/invalid.json"
if $ADAPTER --state-dir "$STATE" prepare --report "$TMP/invalid.json" >/dev/null 2>&1; then
  printf 'not ok - missing return destination was accepted\n' >&2
  exit 1
fi
printf 'ok - missing return destination is rejected\n'

lock_file="$STATE/.lock"
now=$(date +%s)
jq -n --argjson pid "$$" --argjson created_at_epoch "$((now - 120))" --arg token live-holder \
  '{pid: $pid, created_at_epoch: $created_at_epoch, token: $token}' >"$lock_file"
if $ADAPTER --state-dir "$STATE" drain >/dev/null 2>&1; then
  printf 'not ok - an expired lock owned by a live process was deleted\n' >&2
  exit 1
fi
jq -e '.token == "live-holder"' "$lock_file" >/dev/null
printf 'ok - expired live-holder lock is never deleted\n'

(trap - EXIT; sleep 30) &
dead_holder=$!
kill "$dead_holder"
wait "$dead_holder" 2>/dev/null || true
jq -n --argjson pid "$dead_holder" --argjson created_at_epoch "$(date +%s)" --arg token fresh-killed-holder \
  '{pid: $pid, created_at_epoch: $created_at_epoch, token: $token}' >"$lock_file"
if $ADAPTER --state-dir "$STATE" drain >/dev/null 2>&1; then
  printf 'not ok - a dead holder was recovered before the lock TTL elapsed\n' >&2
  exit 1
fi
jq -e '.token == "fresh-killed-holder"' "$lock_file" >/dev/null
printf 'ok - dead-holder lock remains protected until its TTL elapses\n'

jq -n --argjson pid "$dead_holder" --argjson created_at_epoch "$((now - 120))" --arg token killed-holder \
  '{pid: $pid, created_at_epoch: $created_at_epoch, token: $token}' >"$lock_file"
recovered_after_kill=$($ADAPTER --state-dir "$STATE" drain)
jq -e 'type == "array"' <<<"$recovered_after_kill" >/dev/null
[[ -f "$lock_file" && ! -s "$lock_file" ]]
printf 'ok - expired killed-holder lock is recovered\n'

write_report "$TMP/report-race.json" task-race
race_successes=0
race_failures=0
race_pids=()
for index in 1 2 3 4 5 6 7 8; do
  (
    $ADAPTER --state-dir "$STATE" prepare --report "$TMP/report-race.json" >"$TMP/race-$index.out" 2>"$TMP/race-$index.err"
  ) &
  race_pids+=("$!")
done
for race_pid in "${race_pids[@]}"; do
  if wait "$race_pid"; then
    race_successes=$((race_successes + 1))
  else
    race_failures=$((race_failures + 1))
  fi
done
((race_successes >= 1))
[[ $(find "$STATE/pending" -type f -name '*.json' | wc -l | tr -d ' ') -ge 1 ]]
[[ -f "$lock_file" && ! -s "$lock_file" ]]
printf 'ok - racing lock contenders leave one valid report and no orphan lock (%s success, %s busy)\n' "$race_successes" "$race_failures"

grep -Fq 'on every later owning-task wake while delivery remains incomplete' "$PDW_SKILL"
grep -Fq 'report-back.sh drain' "$PDW_SKILL"
printf 'ok - owning-task wake contract drives durable retries without a new runtime\n'

#!/usr/bin/env bash
# tests/fm-queue.test.sh - the sharded-executors task queue (Phase 1 MVP).
#
# Proves the queue mechanics are REAL (the build step is a separate DORMANT
# stub, out of scope here):
#   - enqueue -> claim -> done round-trip; and enqueue -> claim -> fail
#   - the claim rename is atomic: exactly ONE winner under concurrent claimers
#   - pool_pref filtering on claim (any-pool vs a specific pool)
#   - the reaper re-homes a dead-owner claim back to ready/ (attempts++)
#   - the reaper re-homes an expired-lease claim even with a LIVE owner
#   - the reaper dead-letters a claim to failed/ once attempts hit the max
#   - ADOPTION SWITCH: `reap` is a COMPLETE no-op when the queue dir is absent
#   - the executor drain loop (register -> claim -> hook -> done) with an
#     injected hook; and its DORMANT refusal to drain with no hook wired
# Every case uses a TEMP queue dir (FM_QUEUE_DIR), never the real state/queue.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

Q="$ROOT/bin/fm-queue.sh"
EX="$ROOT/bin/fm-executor.sh"
TMP_ROOT=$(fm_test_tmproot fm-queue)

CASE_N=0
new_case() {
  CASE_N=$((CASE_N + 1))
  d="$TMP_ROOT/case-$CASE_N"
  mkdir -p "$d"
  export FM_QUEUE_DIR="$d/queue"
  export FM_STATE_OVERRIDE="$d/state"
  mkdir -p "$FM_STATE_OVERRIDE"
}

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }

# rec <section> <id>: path to a queue record file.
ready_f() { echo "$FM_QUEUE_DIR/ready/$1.json"; }
done_f()  { echo "$FM_QUEUE_DIR/done/$1.json"; }
fail_f()  { echo "$FM_QUEUE_DIR/failed/$1.json"; }
claim_f() { echo "$FM_QUEUE_DIR/claimed/$1/$2.json"; }  # <exec> <id>

# --- enqueue -> claim -> done round-trip ------------------------------------
new_case
"$Q" enqueue t1 --board-item bi1 --repo core --scope a/b,c/d --autonomy passive --pool any >/dev/null \
  || fail "roundtrip: enqueue failed"
assert_present "$(ready_f t1)" "roundtrip: t1 should be in ready/ after enqueue"
jq -e '.scope_paths == ["a/b","c/d"] and .autonomy == "passive" and .attempts == 0' "$(ready_f t1)" >/dev/null \
  || fail "roundtrip: enqueued record fields wrong"
claimed=$("$Q" claim ex1 --owner-pid $$ 2>/dev/null) || fail "roundtrip: claim returned nonzero"
[ "$claimed" = t1 ] || fail "roundtrip: claim should print t1 (got '$claimed')"
assert_absent "$(ready_f t1)" "roundtrip: t1 should leave ready/ once claimed"
assert_present "$(claim_f ex1 t1)" "roundtrip: t1 should live in claimed/ex1/"
jq -e '.owner == "ex1" and .owner_pid == '"$$"' and .started > 0' "$(claim_f ex1 t1)" >/dev/null \
  || fail "roundtrip: claim did not stamp owner/owner_pid/started"
"$Q" "done" ex1 t1 --sha deadbeef --pr http://pr/1 >/dev/null || fail "roundtrip: done failed"
assert_absent "$(claim_f ex1 t1)" "roundtrip: claim file should be gone after done"
assert_present "$(done_f t1)" "roundtrip: t1 should land in done/"
jq -e '.sha == "deadbeef" and .pr == "http://pr/1"' "$(done_f t1)" >/dev/null \
  || fail "roundtrip: done record missing sha/pr"
pass "enqueue -> claim -> done round-trip carries the record with sha/pr"

# --- enqueue -> claim -> fail -----------------------------------------------
new_case
"$Q" enqueue t2 >/dev/null || fail "fail-path: enqueue failed"
"$Q" claim ex1 --owner-pid $$ >/dev/null || fail "fail-path: claim failed"
"$Q" fail ex1 t2 --reason "boom" >/dev/null || fail "fail-path: fail failed"
assert_present "$(fail_f t2)" "fail-path: t2 should land in failed/"
jq -e '.fail_reason == "boom"' "$(fail_f t2)" >/dev/null || fail "fail-path: reason not recorded"
assert_absent "$(claim_f ex1 t2)" "fail-path: claim file gone after fail"
pass "enqueue -> claim -> fail moves the task to failed/ with a reason"

# --- atomic claim: exactly ONE winner under concurrency ---------------------
new_case
"$Q" enqueue solo >/dev/null || fail "concurrency: enqueue failed"
resdir="$d/res"; mkdir -p "$resdir"
for i in 1 2 3 4 5 6 7 8; do
  ( if wid=$("$Q" claim "c$i" --owner-pid $$ 2>/dev/null); then printf '%s' "$wid" > "$resdir/win.$i"; fi ) &
done
wait
winners=$(find "$resdir" -maxdepth 1 -name 'win.*' | wc -l | tr -d ' ')
[ "$winners" = 1 ] || fail "concurrency: expected exactly 1 winner, got $winners"
assert_absent "$(ready_f solo)" "concurrency: solo must leave ready/ (claimed by the winner)"
claimed_count=$("$Q" list claimed | wc -l | tr -d ' ')
[ "$claimed_count" = 1 ] || fail "concurrency: exactly one claimed record expected, got $claimed_count"
pass "atomic claim (rename is the lock): exactly one concurrent claimer wins"

# --- pool_pref filtering on claim -------------------------------------------
new_case
"$Q" enqueue paid --pool paypertoken >/dev/null || fail "pool: enqueue failed"
"$Q" claim ex1 --pool subscription --owner-pid $$ >/dev/null 2>&1 \
  && fail "pool: a subscription executor must NOT claim a paypertoken task"
assert_present "$(ready_f paid)" "pool: task stays in ready/ when no matching pool claimed it"
got=$("$Q" claim ex2 --pool paypertoken --owner-pid $$ 2>/dev/null) || fail "pool: matching-pool claim failed"
[ "$got" = paid ] || fail "pool: paypertoken executor should claim the paid task (got '$got')"
# An "any"-pool task is claimable by any pool.
"$Q" enqueue open --pool any >/dev/null
got=$("$Q" claim ex3 --pool subscription --owner-pid $$ 2>/dev/null) || fail "pool: any-pool task should be claimable"
[ "$got" = open ] || fail "pool: subscription executor should claim the any-pool task (got '$got')"
pass "claim filters by pool_pref (specific pool required; 'any' claimable by all)"

# --- reaper re-homes a DEAD-owner claim -------------------------------------
new_case
"$Q" enqueue t3 >/dev/null
# A definitely-dead pid: start then reap a background process.
sleep 30 & deadpid=$!; kill "$deadpid" 2>/dev/null; wait "$deadpid" 2>/dev/null || true
"$Q" claim ex1 --owner-pid "$deadpid" >/dev/null || fail "reap-dead: claim failed"
assert_present "$(claim_f ex1 t3)" "reap-dead: precondition, t3 is claimed"
"$Q" reap >/dev/null || fail "reap-dead: reap errored"
assert_present "$(ready_f t3)" "reap-dead: dead-owner claim should return to ready/"
assert_absent "$(claim_f ex1 t3)" "reap-dead: the stale claim file should be removed"
jq -e '.attempts == 1 and .owner == "" and .owner_pid == 0' "$(ready_f t3)" >/dev/null \
  || fail "reap-dead: re-homed record should have attempts=1 and cleared owner"
pass "reaper re-homes a dead-owner claim to ready/ (attempts++)"

# --- reaper re-homes an EXPIRED-lease claim even with a live owner -----------
new_case
"$Q" enqueue t4 >/dev/null
"$Q" claim ex1 --owner-pid $$ >/dev/null || fail "reap-lease: claim failed"   # $$ is alive
# Backdate the beat so the lease is expired though the owner is live.
cf=$(claim_f ex1 t4)
tmp="$d/cf.tmp"; jq '.beat = 1' "$cf" > "$tmp" && mv "$tmp" "$cf"
FM_QUEUE_LEASE_TTL=1 "$Q" reap >/dev/null || fail "reap-lease: reap errored"
assert_present "$(ready_f t4)" "reap-lease: expired-lease claim should return to ready/ despite a live owner"
pass "reaper re-homes an expired-lease claim even when the owner PID is alive"

# --- reaper dead-letters to failed/ past max_attempts -----------------------
new_case
"$Q" enqueue t5 >/dev/null
sleep 30 & deadpid=$!; kill "$deadpid" 2>/dev/null; wait "$deadpid" 2>/dev/null || true
"$Q" claim ex1 --owner-pid "$deadpid" >/dev/null || fail "reap-max: claim failed"
# Pretend this claim already burned one attempt; with max=2 the reap tips it over.
cf=$(claim_f ex1 t5)
tmp="$d/cf.tmp"; jq '.attempts = 1' "$cf" > "$tmp" && mv "$tmp" "$cf"
FM_QUEUE_MAX_ATTEMPTS=2 "$Q" reap >/dev/null || fail "reap-max: reap errored"
assert_present "$(fail_f t5)" "reap-max: task past max_attempts should dead-letter to failed/"
assert_absent "$(ready_f t5)" "reap-max: it must NOT be re-homed to ready/ past the max"
jq -e '.attempts == 2 and (.fail_reason | test("max-attempts"))' "$(fail_f t5)" >/dev/null \
  || fail "reap-max: dead-letter record should record attempts and a max-attempts reason"
pass "reaper dead-letters a claim to failed/ once attempts hit the max"

# --- ADOPTION SWITCH: reap is a no-op when the queue dir is absent -----------
new_case
export FM_QUEUE_DIR="$d/does-not-exist"
"$Q" reap >/dev/null 2>&1 || fail "adoption: reap should exit 0 with no queue dir"
assert_absent "$FM_QUEUE_DIR" "adoption: reap must NOT create the queue dir"
pass "adoption switch: reap is a complete no-op when the queue dir is absent"

# --- executor drain loop with an injected hook (register -> claim -> done) ---
new_case
hook="$d/hook.sh"
cat > "$hook" <<'SH'
#!/usr/bin/env bash
# Stand-in for the DORMANT build hook: echo a fake sha, exit 0 (built).
echo "cafef00d"
exit 0
SH
chmod +x "$hook"
"$Q" enqueue e1 --board-item bd1 --pool any >/dev/null || fail "exec: enqueue failed"
FM_EXECUTOR_TASK_HOOK="$hook" FM_EXECUTOR_MAX_ITER=1 FM_EXECUTOR_IDLE=1 \
  "$EX" run drainer --pool any >/dev/null 2>&1 || fail "exec: run errored"
assert_present "$(done_f e1)" "exec: the drained task should land in done/"
jq -e '.sha == "cafef00d"' "$(done_f e1)" >/dev/null || fail "exec: done record should carry the hook's sha"
# The board was lit and cleared through the sanctioned fm-item-agent calls only.
assert_present "$FM_STATE_OVERRIDE/item-agents.json" "exec: item-agents.json should exist (board lit via fm-item-agent)"
jq -e '.items.bd1.done == true' "$FM_STATE_OVERRIDE/item-agents.json" >/dev/null \
  || fail "exec: board item bd1 should be marked done via fm-item-agent"
assert_absent "$FM_STATE_OVERRIDE/board.json" "exec: executor must NEVER write board.json directly"
pass "executor drains a task end to end (register -> claim -> hook -> done) with an injected hook"

# --- executor DORMANCY: no hook wired -> refuses to drain --------------------
new_case
"$Q" enqueue e2 --pool any >/dev/null || fail "dormant: enqueue failed"
out=$(FM_EXECUTOR_MAX_ITER=1 "$EX" run drainer --pool any 2>&1) || fail "dormant: run should exit 0"
assert_contains "$out" "DORMANT" "dormant: run should announce it is dormant"
assert_present "$(ready_f e2)" "dormant: the task must remain UNCLAIMED with no hook wired"
pass "executor is DORMANT without a task hook: it announces and refuses to drain"

echo "all fm-queue tests passed"

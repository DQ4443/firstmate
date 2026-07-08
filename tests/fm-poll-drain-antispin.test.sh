#!/usr/bin/env bash
# tests/fm-poll-drain-antispin.test.sh - the anti-spin gate in isolation.
#
# The robustness claim of finding 2's fix: the poller spawns the headless drain on
# a REAL unanswered David message, never on the raw queue seq. So even when a check
# makes state/.wake-queue.seq advance every cycle (exactly what the live un-demoted
# board-threads.check.sh does - "N new" every cycle), if no David message is
# actually waiting the poller must settle attempted-seq and spawn NOTHING, never a
# drain worker per cycle.
#
# This drives the real poller against a sandbox whose one thread's newest message
# is firstmate-authored (already answered) while a check keeps bumping the seq, and
# asserts: no drain worker is ever spawned, and attempted-seq tracks the seq
# (settled, not perpetually lagging).
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }

SANDBOX=$(fm_test_tmproot fm-drain-antispin)
POLL="$ROOT/bin/fm-poll.sh"
ITEM="answered-item"
THREAD="$SANDBOX/data/board-threads/$ITEM"
STATE_DIR="$SANDBOX/state"
POLL_PID=""
mkdir -p "$THREAD" "$STATE_DIR"
printf '# a\n' > "$SANDBOX/AGENTS.md"
printf '# c\n' > "$SANDBOX/CLAUDE.md"

kill_poller() {
  [ -n "${POLL_PID:-}" ] || return 0
  kill -KILL "$POLL_PID" 2>/dev/null || true
  wait "$POLL_PID" 2>/dev/null || true
  POLL_PID=""
}
cleanup() { kill_poller; fm_test_cleanup; }
trap cleanup EXIT

# A check that fires "1 new" EVERY cycle (an unconditional emit), standing in for
# the live un-demoted board-threads.check.sh that never settles. This is what made
# the raw-seq gate spin-spawn a drain every cycle.
cat > "$STATE_DIR/board-threads.check.sh" <<'CHECK'
#!/bin/sh
printf 'board-threads: 1 new\n'
CHECK
chmod +x "$STATE_DIR/board-threads.check.sh"

# The one thread is ALREADY ANSWERED: its newest file is firstmate-authored, so
# has_unanswered_david is false and no drain should ever spawn.
ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
ms=$(( $(date +%s) * 1000 ))
{
  printf '{"thread_id": "%s", "parent_ref": null, "author": "firstmate", "ts": "%s"}\n' "$ITEM" "$ts"
  printf '\nAlready handled.\n'
} > "$THREAD/$ms.md"

# A claude stub that, if ever invoked, records the violation (it must never run).
STUBDIR=$(mktemp -d "${TMPDIR:-/tmp}/fm-antispin-stub.XXXXXX")
cat > "$STUBDIR/claude" <<STUB
#!/usr/bin/env bash
cat >/dev/null
touch "$STATE_DIR/.claude-was-invoked"
STUB
chmod +x "$STUBDIR/claude"

FM_ROOT_OVERRIDE="$SANDBOX" \
FM_STATE_OVERRIDE="$STATE_DIR" \
FM_POLL_INTERVAL=1 \
FM_WAKE_INJECT=0 \
FM_DRAIN_CLAUDE_BIN="$STUBDIR/claude" \
PATH="$STUBDIR:$PATH" \
bash "$POLL" >"$STATE_DIR/poller.log" 2>&1 &
POLL_PID=$!

# Let several poll cycles run (seq is bumping every cycle the whole time).
sleep 6
kill_poller
rm -rf "$STUBDIR" 2>/dev/null || true

assert_no_grep "spawned headless board drain" "$STATE_DIR/poller.log" \
  "poller spawned a drain despite no unanswered David message (anti-spin gate failed)"
pass "no drain worker spawned while the seq bumped every cycle with nothing unanswered"

assert_absent "$STATE_DIR/.claude-was-invoked" "a headless claude turn ran with nothing unanswered"
pass "no headless claude turn ran"

# attempted-seq must have SETTLED up toward the churning queue seq (the gate
# advances it when it declines to spawn), not stayed pinned at 0 forever.
cur=$(cat "$STATE_DIR/.wake-queue.seq" 2>/dev/null || echo 0)
att=$(cat "$STATE_DIR/.drain-attempted-seq" 2>/dev/null || echo 0)
[ "$cur" -ge 1 ] || fail "the seq never advanced; the test's churn check did not fire (cur=$cur)"
[ "$att" -ge 1 ] || fail "attempted-seq never settled toward the queue seq (cur=$cur att=$att)"
pass "attempted-seq settled toward the churning queue seq without spawning (cur=$cur att=$att)"

echo "all fm-poll-drain-antispin tests passed"

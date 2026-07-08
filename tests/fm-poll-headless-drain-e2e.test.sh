#!/usr/bin/env bash
# tests/fm-poll-headless-drain-e2e.test.sh - THE Phase 0 acceptance test.
#
# Proves a David board message becomes a firstmate turn UNATTENDED, with no
# interactive REPL ever involved. It runs the REAL launchd poller (bin/fm-poll.sh)
# against a throwaway FM_ROOT sandbox with:
#   - NO session-pane.env and no repl-presence.json (no reachable REPL), and
#     FM_WAKE_INJECT=0 (the tmux fast path is off), so the poller MUST fall to the
#     headless drain;
#   - a demoted board-threads.check.sh (edge-dedup marker, NOT a serviced
#     watermark) that fires one wake per new thread activity;
#   - a stub `claude` that stands in for the headless `claude -p` turn: it reads
#     the on-disk preamble on stdin and posts a holding-ack via the REAL
#     bin/fm-board-reply.sh --once for each UNANSWERED_ITEM.
#
# Asserts: within a couple of poll intervals a firstmate-authored holding-ack
# lands in the thread; the item is left un-serviced (serviced-seq unadvanced, SLA
# armed); and no second drain double-posts (exactly one firstmate reply).
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }

SANDBOX=$(fm_test_tmproot fm-headless-drain)
POLL="$ROOT/bin/fm-poll.sh"
ITEM="demo-item"
THREAD="$SANDBOX/data/board-threads/$ITEM"
STATE_DIR="$SANDBOX/state"
POLL_PID=""

mkdir -p "$THREAD" "$STATE_DIR"
printf '# firstmate (sandbox)\n' > "$SANDBOX/AGENTS.md"
printf '# firstmate (sandbox CLAUDE.md)\n' > "$SANDBOX/CLAUDE.md"

# kill only our captured poller (never a pattern kill that could hit the live
# launchd poller); fm-poll.sh ignores SIGTERM, so SIGKILL.
kill_poller() {
  [ -n "${POLL_PID:-}" ] || return 0
  kill -KILL "$POLL_PID" 2>/dev/null || true
  wait "$POLL_PID" 2>/dev/null || true
  POLL_PID=""
}
cleanup() { kill_poller; rm -rf "${DRAIN_STUBDIR:-}" 2>/dev/null || true; fm_test_cleanup; }
trap cleanup EXIT

# --- demoted board-threads.check.sh (edge-dedup, not a serviced watermark) ----
# Fires one wake per NEW thread file relative to a plain "already-enqueued"
# marker, then advances the marker. It never claims a message is serviced - that
# is now .serviced-seq's job, advanced only on a real close-out - so a premature
# touch can no longer ghost an un-answered David message.
cat > "$STATE_DIR/board-threads.check.sh" <<CHECK
#!/bin/sh
root="$SANDBOX/data/board-threads"
mark="\$root/.enqueued"
[ -d "\$root" ] || exit 0
if [ -f "\$mark" ]; then
  n=\$(find "\$root" -type f -name '*.md' -newer "\$mark" 2>/dev/null | wc -l | tr -d ' ')
else
  n=\$(find "\$root" -type f -name '*.md' 2>/dev/null | wc -l | tr -d ' ')
fi
[ "\${n:-0}" -gt 0 ] 2>/dev/null || exit 0
touch "\$mark"
printf 'board-threads: %s new\n' "\$n"
CHECK
chmod +x "$STATE_DIR/board-threads.check.sh"

# --- stub claude: the headless turn ------------------------------------------
DRAIN_STUBDIR=$(mktemp -d "${TMPDIR:-/tmp}/fm-drain-stub.XXXXXX")
cat > "$DRAIN_STUBDIR/claude" <<STUB
#!/usr/bin/env bash
# Stand-in for the headless \`claude -p\` turn. Reads the preamble on stdin and
# posts a holding-ack for each UNANSWERED_ITEM via the real fm-board-reply.sh.
set -u
prompt=\$(cat)
printf '%s\n' "\$prompt" | grep '^UNANSWERED_ITEM: ' | sed 's/^UNANSWERED_ITEM: //' | while IFS= read -r id; do
  [ -n "\$id" ] || continue
  FM_ROOT_OVERRIDE="$SANDBOX" "$ROOT/bin/fm-board-reply.sh" "\$id" \
    "Captured your message; the live orchestrator will pick this up. Holding until then." \
    --your-court --once >/dev/null 2>&1 || true
done
exit 0
STUB
chmod +x "$DRAIN_STUBDIR/claude"

count_replies() {  # firstmate-authored files in the thread
  local f n=0 author
  for f in "$THREAD"/*.md; do
    [ -e "$f" ] || continue
    author=$(head -n1 "$f" 2>/dev/null | jq -r '.author // ""' 2>/dev/null || true)
    [ "$author" = firstmate ] && n=$((n + 1))
  done
  printf '%s' "$n"
}

wait_for_reply() {  # <seconds>
  local secs=$1 i=0
  while [ "$i" -lt "$((secs * 5))" ]; do
    [ "$(count_replies)" -ge 1 ] && return 0
    sleep 0.2; i=$((i + 1))
  done
  return 1
}

# --- post David's message, then start the poller (no REPL, push disabled) -----
ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
ms=$(( $(date +%s) * 1000 ))
{
  printf '{"thread_id": "%s", "parent_ref": null, "author": "david", "ts": "%s"}\n' "$ITEM" "$ts"
  printf '\n'
  printf 'Is the poller healthy right now?\n'
} > "$THREAD/$ms.md"

FM_ROOT_OVERRIDE="$SANDBOX" \
FM_STATE_OVERRIDE="$STATE_DIR" \
FM_POLL_INTERVAL=1 \
FM_WAKE_INJECT=0 \
FM_DRAIN_CLAUDE_BIN="$DRAIN_STUBDIR/claude" \
PATH="$DRAIN_STUBDIR:$PATH" \
bash "$POLL" >"$STATE_DIR/poller.log" 2>&1 &
POLL_PID=$!

if ! wait_for_reply 15; then
  echo "--- poller.log ---" >&2; cat "$STATE_DIR/poller.log" >&2
  echo "--- thread ---" >&2; ls -la "$THREAD" >&2
  fail "no headless firstmate reply landed in the thread"
fi
pass "a David board message triggered a headless firstmate turn with NO interactive REPL"

grep -q "spawned headless board drain" "$STATE_DIR/poller.log" \
  || fail "poller did not log spawning the headless drain"
pass "poller spawned bin/fm-drain-worker.sh unattended (logged)"

# The reply is firstmate-authored and is a holding-ack (item left un-serviced).
reply=$(ls -t "$THREAD"/*.md | head -n1)
author=$(head -n1 "$reply" | jq -r '.author')
[ "$author" = firstmate ] || fail "newest thread file is not firstmate-authored (got '$author')"
assert_grep "live orchestrator will pick this up" "$reply" "holding-ack body not found"
pass "the headless turn posted a holding-ack, not a fabricated close-out"

# The spawn-dedup marker (.drain-attempted-seq) MUST advance so the poller stops
# re-spawning. The detached worker writes it just after posting (reconcile adds a
# beat), so poll for convergence rather than reading instantly.
att=0
i=0
while [ "$i" -lt 50 ]; do
  att=$(cat "$STATE_DIR/.drain-attempted-seq" 2>/dev/null || echo 0)
  [ "$att" -ge 1 ] && break
  sleep 0.2; i=$((i + 1))
done
[ "$att" -ge 1 ] || fail "drain-attempted-seq did not advance (would re-spawn every cycle): $att"
# serviced-seq must NOT have advanced: a holding-ack is not a close-out, so the
# pager SLA stays armed until the live orchestrator really resolves the item.
[ ! -f "$STATE_DIR/.serviced-seq" ] || {
  s=$(cat "$STATE_DIR/.serviced-seq"); [ "$s" = 0 ] || fail "serviced-seq advanced to $s on a holding-ack (SLA disarmed)"
}
pass "serviced-seq left armed, attempted-seq advanced (no per-cycle re-spawn)"

# No double-post: give the poller several more cycles; still exactly one reply.
sleep 4
n=$(count_replies)
[ "$n" -eq 1 ] || fail "double-post / re-drain: expected 1 firstmate reply, found $n"
pass "idempotency holds: exactly one firstmate reply after repeated poll cycles"

kill_poller
echo "all fm-poll-headless-drain-e2e tests passed"

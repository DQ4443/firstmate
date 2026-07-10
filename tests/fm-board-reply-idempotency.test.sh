#!/usr/bin/env bash
# tests/fm-board-reply-idempotency.test.sh - the --once idempotency claim.
#
# Proves bin/fm-board-reply.sh --once makes a headless drain and the interactive
# session safe to both answer the same David message:
#   - two --once replies to the SAME David message collapse to ONE post
#   - a NEW David message (new newest-file generation) is answered again
#   - without --once, repeated replies each post (existing callers unaffected)
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }

REPLY="$ROOT/bin/fm-board-reply.sh"
SB=$(fm_test_tmproot fm-reply-once)
ITEM="item-x"
THREAD="$SB/data/board-threads/$ITEM"
mkdir -p "$THREAD"

post_david() {  # <generation> - widely-spaced stamps so a firstmate reply (forced
                # strictly-newer, +1ms) never collides with the NEXT generation.
  local g=${1:-0} ts ms
  ts=$(date -u +%Y-%m-%dT%H:%M:%SZ); ms=$(( 2000000000000 + g * 100000 ))
  {
    printf '{"thread_id": "%s", "parent_ref": null, "author": "david", "ts": "%s"}\n' "$ITEM" "$ts"
    printf '\nmessage %s\n' "$g"
  } > "$THREAD/$ms.md"
}

fm_replies() {
  local f n=0 a
  for f in "$THREAD"/*.md; do
    [ -e "$f" ] || continue
    a=$(head -n1 "$f" 2>/dev/null | jq -r '.author // ""' 2>/dev/null || true)
    [ "$a" = firstmate ] && n=$((n + 1))
  done
  printf '%s' "$n"
}

reply_once() { FM_ROOT_OVERRIDE="$SB" "$REPLY" "$ITEM" "$1" --your-court --once; }
reply_plain() { FM_ROOT_OVERRIDE="$SB" "$REPLY" "$ITEM" "$1" --your-court; }

# --- 1. two --once replies to the same David message => one post -------------
post_david 1
reply_once "ack A" >/dev/null 2>&1; rc1=$?
sleep 0.005
out2=$(reply_once "ack B" 2>&1); rc2=$?
expect_code 0 "$rc1" "first --once reply"
expect_code 0 "$rc2" "second --once reply (should be a clean no-op)"
assert_contains "$out2" "idempotent no-op" "second --once reply did not report the idempotent no-op"
[ "$(fm_replies)" -eq 1 ] || fail "expected exactly 1 firstmate reply after two --once calls, got $(fm_replies)"
pass "two --once replies to the same David message collapse to one post"

# --- 2. a NEW David message is a new generation => answered again -------------
post_david 2
reply_once "ack for the second message" >/dev/null 2>&1
[ "$(fm_replies)" -eq 2 ] || fail "a new David message was not answered (idempotency over-suppressed): $(fm_replies)"
pass "a new David message resets the idempotency key and is answered again"

# --- 3. without --once, repeated replies each post (no regression) -----------
before=$(fm_replies)
reply_plain "plain 1" >/dev/null 2>&1; sleep 0.005
reply_plain "plain 2" >/dev/null 2>&1
after=$(fm_replies)
[ "$after" -eq "$((before + 2))" ] || fail "plain replies were suppressed; --once must not change default callers ($before -> $after)"
pass "without --once, repeated replies each post (existing callers unaffected)"

echo "all fm-board-reply-idempotency tests passed"

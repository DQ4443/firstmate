#!/usr/bin/env bash
# tests/fm-drain-worker-real-claude.test.sh - the LOAD-BEARING proof.
#
# The hermetic acceptance test (fm-poll-headless-drain-e2e.test.sh) stands a
# `claude` STUB in for the headless turn, so it proves the plumbing but NOT the
# one claim that actually matters: that a REAL `claude -p` reads the on-disk
# preamble, OBEYS "post a holding-ack only" under the scoped tool allowlist, and
# actually posts to an unanswered David thread. Per David's standing rule a
# stubbed test is not sufficient evidence for the user-experienced path; this test
# closes that gap by driving the REAL binary end to end.
#
# It runs bin/fm-drain-worker.sh (no stub) against a throwaway FM_ROOT/FM_STATE
# sandbox under tmp with a real, unanswered David thread message, then asserts a
# real firstmate-authored holding-ack landed, attempted-seq advanced, and
# serviced-seq stayed un-armed (a holding-ack is not a close-out).
#
# Because a real LLM turn costs tokens and needs network/quota, it is OPT-IN:
#   FM_TEST_REAL_CLAUDE=1 [FM_DRAIN_CLAUDE_MODEL=<cheap-model>] \
#     bash tests/fm-drain-worker-real-claude.test.sh
# Unset FM_TEST_REAL_CLAUDE, or an unresolvable `claude`, self-skips (exit 0) so
# the default suite stays deterministic; the hermetic test covers the logic.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }

if [ "${FM_TEST_REAL_CLAUDE:-0}" != 1 ]; then
  echo "skip: real-binary drain test is opt-in (set FM_TEST_REAL_CLAUDE=1 to run it)"
  exit 0
fi

# Resolve a real claude the same way the worker does (env override, PATH, nvm,
# homebrew), so a bare `claude` not on this test's PATH is still found.
CLAUDE_BIN="${FM_DRAIN_CLAUDE_BIN:-}"
if [ -z "$CLAUDE_BIN" ]; then
  CLAUDE_BIN=$(command -v claude 2>/dev/null || true)
fi
if [ -z "$CLAUDE_BIN" ]; then
  for c in "$HOME"/.nvm/versions/node/*/bin/claude /opt/homebrew/bin/claude /usr/local/bin/claude; do
    [ -x "$c" ] && { CLAUDE_BIN="$c"; break; }
  done
fi
if [ -z "$CLAUDE_BIN" ] || [ ! -x "$CLAUDE_BIN" ]; then echo "skip: no real claude binary resolvable"; exit 0; fi

WORKER="$ROOT/bin/fm-drain-worker.sh"
SANDBOX=$(fm_test_tmproot fm-drain-real)
ITEM="poller-health"
THREAD="$SANDBOX/data/board-threads/$ITEM"
mkdir -p "$THREAD" "$SANDBOX/state"

# Small on-disk contract so the real turn stays cheap and focused; the worker
# concatenates these into the preamble exactly as it does with the live files.
printf '# firstmate (sandbox AGENTS.md)\nYou orchestrate a board.\n' > "$SANDBOX/AGENTS.md"
printf '# firstmate (sandbox CLAUDE.md)\n' > "$SANDBOX/CLAUDE.md"

# One genuinely-unanswered David thread message.
ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
ms=$(( $(date +%s) * 1000 ))
{
  printf '{"thread_id": "%s", "parent_ref": null, "author": "david", "ts": "%s"}\n' "$ITEM" "$ts"
  printf '\n'
  printf 'Is the poller healthy right now?\n'
} > "$THREAD/$ms.md"
printf '1\n' > "$SANDBOX/state/.wake-queue.seq"

count_firstmate_replies() {
  local f n=0 author
  for f in "$THREAD"/*.md; do
    [ -e "$f" ] || continue
    author=$(head -n1 "$f" 2>/dev/null | jq -r '.author // ""' 2>/dev/null || true)
    [ "$author" = firstmate ] && n=$((n + 1))
  done
  printf '%s' "$n"
}

echo "running the REAL claude drain worker: $CLAUDE_BIN (model=${FM_DRAIN_CLAUDE_MODEL:-<account default>})" >&2
FM_ROOT_OVERRIDE="$SANDBOX" \
FM_STATE_OVERRIDE="$SANDBOX/state" \
FM_DRAIN_CLAUDE_BIN="$CLAUDE_BIN" \
FM_DRAIN_TIMEOUT="${FM_DRAIN_TIMEOUT:-240}" \
bash "$WORKER" 2>"$SANDBOX/state/worker.log" || true

if [ "$(count_firstmate_replies)" -lt 1 ]; then
  echo "--- worker.log ---" >&2; cat "$SANDBOX/state/worker.log" >&2
  echo "--- thread ---" >&2; ls -la "$THREAD" >&2
  fail "the real claude -p turn posted no holding-ack to the unanswered David thread"
fi
pass "a REAL claude -p headless turn posted a holding-ack to an unanswered David thread"

# The posted reply must be firstmate-authored (a real board reply, not an echo).
reply=$(find "$THREAD" -maxdepth 1 -name "*.md" -print0 | xargs -0 ls -t | head -n1)
author=$(head -n1 "$reply" | jq -r '.author')
[ "$author" = firstmate ] || fail "newest thread file is not firstmate-authored (got '$author')"
body=$(sed '1,2d' "$reply" | tr -d '[:space:]')
[ -n "$body" ] || fail "the real turn posted an empty reply body"
pass "the real reply is a firstmate-authored board post with a non-empty body"
echo "    reply body: $(sed '1,2d' "$reply" | tr '\n' ' ' | sed 's/  */ /g')" >&2

# Success bookkeeping: attempted-seq advanced to the queue seq, serviced-seq left
# un-armed (a holding-ack is not a close-out, so the pager SLA stays live).
att=$(cat "$SANDBOX/state/.drain-attempted-seq" 2>/dev/null || echo 0)
[ "$att" = 1 ] || fail "attempted-seq did not advance to the queue seq on a real success (got '$att')"
assert_absent "$SANDBOX/state/.serviced-seq" "serviced-seq must stay unwritten for a holding-ack (SLA armed)"
pass "attempted-seq advanced and serviced-seq left armed after the real turn"

echo "all fm-drain-worker-real-claude tests passed"

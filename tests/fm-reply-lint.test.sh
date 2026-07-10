#!/usr/bin/env bash
# tests/fm-reply-lint.test.sh - the board-reply VOICE pin hook.
#
# Proves bin/fm-reply-lint.sh, a PreToolUse hook on the Bash tool, BLOCKS
# (exit 2) a fm-board-reply.sh command carrying an em/en dash, an emoji, or a
# filler phrase, ALLOWS a clean board reply, and NEVER touches a non-board-reply
# Bash call even when that call contains a banned character.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

HOOK="$ROOT/bin/fm-reply-lint.sh"

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }

EMDASH=$(printf '\xe2\x80\x94')  # U+2014
ENDASH=$(printf '\xe2\x80\x93')  # U+2013
ROCKET=$(printf '\xf0\x9f\x9a\x80')  # U+1F680

# run_hook <command-string> : feed a Bash tool-call JSON on stdin, echo exit.
run_hook() { jq -n --arg c "$1" '{tool_input: {command: $c}}' | "$HOOK"; }

expect_block() {  # <label> <command>
  if run_hook "$2" >/dev/null 2>&1; then fail "$1: expected BLOCK (exit 2) but hook allowed"; fi
  pass "$1"
}
expect_allow() {  # <label> <command>
  run_hook "$2" >/dev/null 2>&1 || fail "$1: expected ALLOW (exit 0) but hook blocked"
  pass "$1"
}

REPLY='bin/fm-board-reply.sh item-1'

# --- dashes ------------------------------------------------------------------
expect_block "an em dash in a board reply is blocked" \
  "$REPLY \"done here ${EMDASH} over to you\" --your-court"

expect_block "an en dash in a board reply is blocked" \
  "$REPLY \"range 1 ${ENDASH} 5\" --done"

expect_allow "a clean board reply with no dashes is allowed" \
  "$REPLY \"done here, over to you\" --your-court"

# --- emoji -------------------------------------------------------------------
if command -v perl >/dev/null 2>&1; then
  expect_block "an emoji in a board reply is blocked" \
    "$REPLY \"shipped ${ROCKET}\" --done"
else
  echo "skip: perl not found, emoji sub-check not exercised"
fi

# --- filler phrases ----------------------------------------------------------
expect_block "'Great question' in a board reply is blocked" \
  "$REPLY \"Great question. Here is the answer\" --your-court"

expect_block "'I hope this helps' in a board reply is blocked" \
  "$REPLY \"here is the result. I hope this helps\" --done"

# Case-insensitive: a lowercased filler variant still blocks.
expect_block "a lowercased filler variant still blocks" \
  "$REPLY \"great question, here goes\" --your-court"

# --- never touches a non-board-reply Bash call -------------------------------
# A banned character in an unrelated command passes untouched (fail open).
expect_allow "a non-board-reply command with an em dash is untouched" \
  "echo hello ${EMDASH} world"

expect_allow "a non-board-reply command with an emoji is untouched" \
  "git commit -m \"ship ${ROCKET}\""

expect_allow "a plain unrelated command is allowed" \
  "ls -la /tmp"

# --- fail open ---------------------------------------------------------------
printf '' | "$HOOK" >/dev/null 2>&1 || fail "fail-open: empty stdin should ALLOW"
pass "empty stdin fails open (allow)"

printf 'not json' | "$HOOK" >/dev/null 2>&1 || fail "fail-open: garbage should ALLOW"
pass "unparseable stdin fails open (allow)"

printf '%s' '{"tool_input":{}}' | "$HOOK" >/dev/null 2>&1 \
  || fail "fail-open: a payload with no command should ALLOW"
pass "a payload with no command fails open (allow)"

# The banned patterns living only in a board-reply command, not the tool name:
# a board reply that mentions fm-board-reply.sh as an argument still gets scanned,
# which is fine; the key guarantee is the clean reply above passes.

echo "all fm-reply-lint tests passed"

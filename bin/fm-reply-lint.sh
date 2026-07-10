#!/usr/bin/env bash
# fm-reply-lint.sh - PreToolUse hook that mechanically enforces the VOICE pins on
# board replies, so a compacted session cannot ghost the no-em-dash / no-emoji /
# no-filler rules onto David's threads (~/VOICE.md, AGENTS.md section 9).
#
# Wired as a PreToolUse hook on the Bash tool (settings.local.json). It reads the
# tool-call JSON on stdin and acts ONLY on commands that invoke fm-board-reply.sh;
# every other Bash call passes untouched (exit 0). On a board-reply command it
# BLOCKS (exit 2, reason on stderr) when the command text carries any of:
#   - an em dash (U+2014) or en dash (U+2013)
#   - an emoji (checked with perl's Unicode ranges when perl is present)
#   - a filler pattern: 'Great question' or 'I hope this helps'
#
# Scanning the whole command (not a fragile re-parse of just the message arg) is
# deliberate: board item ids and flags are constrained ASCII, so any of these
# patterns in a board-reply command is in the human-facing message. It FAILS OPEN
# (exit 0) on unreadable input or a missing tool, so a parse hiccup never wedges a
# shell call. Defense-in-depth behind the discipline, not the sole guarantee.
set -u

PAYLOAD=$(cat 2>/dev/null || true)
[ -n "$PAYLOAD" ] || exit 0
command -v jq >/dev/null 2>&1 || exit 0

CMD=$(printf '%s' "$PAYLOAD" | jq -r '.tool_input.command // empty' 2>/dev/null) || exit 0
[ -n "$CMD" ] || exit 0

# Only board-reply invocations; never touch any other Bash call.
case "$CMD" in
  *fm-board-reply.sh*) : ;;
  *) exit 0 ;;
esac

REASONS=""
add_reason() { REASONS="${REASONS}$1"$'\n'; }

# em dash / en dash by raw UTF-8 bytes (portable across bash 3.2 and 5.x).
EMDASH=$(printf '\xe2\x80\x94')  # U+2014
ENDASH=$(printf '\xe2\x80\x93')  # U+2013
case "$CMD" in
  *"$EMDASH"*) add_reason "em dash (U+2014) in a board reply: VOICE.md bans em dashes. Use a comma, period, or parentheses." ;;
esac
case "$CMD" in
  *"$ENDASH"*) add_reason "en dash (U+2013) in a board reply: VOICE.md bans dashes. Use a comma, period, or parentheses." ;;
esac

# Filler patterns (case-insensitive).
if printf '%s' "$CMD" | grep -qiF 'Great question'; then
  add_reason "'Great question' in a board reply: VOICE.md bans filler openers. Lead with the load-bearing line."
fi
if printf '%s' "$CMD" | grep -qiF 'I hope this helps'; then
  add_reason "'I hope this helps' in a board reply: VOICE.md bans filler closers. End on the ask or the result."
fi

# Emoji: perl carries reliable Unicode ranges; if perl is absent, skip this
# sub-check (the dash and filler checks still fire) rather than false-block.
# Capture a marker on match instead of leaning on perl's exit status, which an
# END block would clobber.
if command -v perl >/dev/null 2>&1; then
  hit=$(printf '%s' "$CMD" | perl -CSD -ne 'print "X" if /[\x{1F000}-\x{1FAFF}\x{2600}-\x{27BF}\x{2764}\x{2B00}-\x{2BFF}\x{FE0F}]/' 2>/dev/null || true)
  if [ -n "$hit" ]; then
    add_reason "emoji in a board reply: VOICE.md bans emojis. Plain prose only."
  fi
fi

if [ -n "$REASONS" ]; then
  printf 'fm-reply-lint blocked this board reply:\n%s' "$REASONS" >&2
  exit 2
fi
exit 0

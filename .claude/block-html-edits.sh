#!/usr/bin/env bash
# PreToolUse hook: firstmate orchestrator must NEVER edit HTML files.
# Reads the tool-call JSON on stdin, extracts .tool_input.file_path, and
# blocks (exit 2) if the path ends in .html (case-insensitive).
# Fails OPEN (exit 0) on any malformed/empty input so it can never wedge a session.

set -u

# Read all of stdin; tolerate empty/no input.
input="$(cat 2>/dev/null || true)"
[ -z "$input" ] && exit 0

# Extract file_path. Prefer jq; fall back to grep/sed if jq is absent.
if command -v jq >/dev/null 2>&1; then
  file_path="$(printf '%s' "$input" | jq -r '.tool_input.file_path // empty' 2>/dev/null || true)"
else
  # No-jq fallback: pull the first "file_path":"..." string value.
  file_path="$(printf '%s' "$input" \
    | grep -o '"file_path"[[:space:]]*:[[:space:]]*"[^"]*"' \
    | head -n1 \
    | sed -E 's/.*"file_path"[[:space:]]*:[[:space:]]*"([^"]*)".*/\1/' || true)"
fi

# No path resolved -> nothing to guard, fail open.
[ -z "${file_path:-}" ] && exit 0

# Case-insensitive .html suffix check.
shopt -s nocasematch 2>/dev/null || true
case "$file_path" in
  *.html)
    printf '%s\n' "firstmate does not edit HTML (orchestrator rule). Steer the board-keeper: bin/fm-send.sh fm-board-keeper-b1 '<change>' - or dispatch a page crewmate." >&2
    exit 2
    ;;
esac

exit 0

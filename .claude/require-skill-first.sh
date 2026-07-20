#!/usr/bin/env bash
# PreToolUse hook on the Workflow tool: enforce skill-first dispatch (David 2026-07-20).
# Blocks Workflow unless the Skill tool was invoked recently (sentinel stamped by
# skill-sentinel.sh within the last 30 minutes). This makes "load /pdw|/build|/explore
# before authoring a workflow" mechanical instead of remembered.
set -u
SENTINEL="${CLAUDE_PROJECT_DIR:-/Users/dq4443/dev/personal/firstmate}/.claude/.skill-loaded"
MAX_AGE_S=1800

if [ -f "$SENTINEL" ]; then
  now=$(date +%s)
  mtime=$(stat -f %m "$SENTINEL" 2>/dev/null || stat -c %Y "$SENTINEL" 2>/dev/null || echo 0)
  age=$((now - mtime))
  if [ "$age" -le "$MAX_AGE_S" ]; then
    exit 0
  fi
fi

printf '%s\n' "skill-first dispatch (David 2026-07-20): no fresh Skill invocation found. Load the matching skill (/pdw for multi-step build/fix/verify, /explore or /websearch for recon, /build for a build loop) via the Skill tool FIRST, then relaunch the Workflow. For build work, prefer a sub-agent that itself runs /build." >&2
exit 2

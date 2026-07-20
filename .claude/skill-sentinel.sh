#!/usr/bin/env bash
# PostToolUse hook on the Skill tool: stamp the skill-first sentinel.
# The PreToolUse Workflow gate (require-skill-first.sh) requires this stamp
# to be fresh, so a Workflow call is only possible shortly after a Skill load.
# Fails open: sentinel trouble must never wedge a session.
set -u
touch "${CLAUDE_PROJECT_DIR:-/Users/dq4443/dev/personal/firstmate}/.claude/.skill-loaded" 2>/dev/null || true
exit 0

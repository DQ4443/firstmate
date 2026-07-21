#!/bin/bash
# fm-codex-bootstrap.sh: one-paste codex fleet-node setup.
# Launches an interactive codex session in the firstmate repo, seeded with the
# node bootstrap prompt (data/fleet/briefs/codex-bootstrap-prompt.md), approvals
# and sandbox bypassed (fleet nodes are unattended; same rationale as claude
# --dangerously-skip-permissions on the Claude nodes).
set -eu
FM_ROOT="$HOME/dev/personal/firstmate"
PROMPT_FILE="$FM_ROOT/data/fleet/briefs/codex-bootstrap-prompt.md"
[ -f "$PROMPT_FILE" ] || { echo "missing $PROMPT_FILE" >&2; exit 1; }
cd "$FM_ROOT"
exec codex --dangerously-bypass-approvals-and-sandbox "$(cat "$PROMPT_FILE")"

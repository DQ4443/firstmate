#!/bin/bash
# Firstmate launcher: Fable 5 on API credits, isolated from the plan.
# The key lives ONLY in ~/.config/anthropic/fable.key (chmod 600) and ONLY
# this launcher exports it, so crewmates spawned from tmux never inherit it.
set -euo pipefail
KEYFILE="$HOME/.config/anthropic/fable.key"
[ -s "$KEYFILE" ] || { echo "No API key at $KEYFILE - create it first (see data/captain.md billing notes)"; exit 1; }
export ANTHROPIC_API_KEY="$(cat "$KEYFILE")"
cd "$(dirname "$0")/.."
exec claude --model claude-fable-5 "$@"

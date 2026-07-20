#!/bin/bash
# Firstmate launcher: Opus 4.8 on the subscription (no separate API key).
# Decision (a), 2026-07-05: Opus runs on the Claude subscription, not API
# credits, so there is NO ANTHROPIC_API_KEY export here (unlike the Fable
# launcher, whose key existed only to isolate Fable API billing). If David
# later wants Opus on API credits, add a ~/.config/anthropic/opus.key block
# mirroring launch-firstmate-fable.sh.
set -euo pipefail
cd "$(dirname "$0")/.."
exec claude --model claude-opus-4-8 "$@"

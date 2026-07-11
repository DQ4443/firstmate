#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)

grep -qx 'model = "gpt-5.6-sol"' "$ROOT/.codex/config.toml"
grep -qx 'model_reasoning_effort = "high"' "$ROOT/.codex/config.toml"
for role in planner implementer refute-reviewer; do
  grep -qx "\[agents.$role\]" "$ROOT/.codex/config.toml"
  grep -qx 'approval_policy = "never"' "$ROOT/.codex/agents/$role.toml"
  if grep -Eq '^(model|model_reasoning_effort) =' "$ROOT/.codex/agents/$role.toml"; then
    printf 'not ok - worker role hardcodes model or effort: %s\n' "$role" >&2
    exit 1
  fi
done
grep -qx 'sandbox_mode = "read-only"' "$ROOT/.codex/agents/planner.toml"
grep -qx 'sandbox_mode = "workspace-write"' "$ROOT/.codex/agents/implementer.toml"
grep -qx 'sandbox_mode = "read-only"' "$ROOT/.codex/agents/refute-reviewer.toml"
printf 'ok - root and role TOML contain the intended controls\n'

codex --strict-config -C "$ROOT" --version >/dev/null
printf 'ok - installed Codex accepts strict config mode\n'

#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
ROUTER="$ROOT/.agents/skills/pdw/scripts/route-effort.sh"

assert_json() {
  local label=$1
  local json=$2
  local filter=$3
  jq -e "$filter" <<<"$json" >/dev/null || { printf 'not ok - %s\n' "$label" >&2; exit 1; }
  printf 'ok - %s\n' "$label"
}

assert_json "mechanical maps to Light" "$($ROUTER --task-kind mechanical)" '.requested_effort == "light" and .effective_effort == "light"'
assert_json "routine maps to Medium" "$($ROUTER --task-kind routine)" '.requested_effort == "medium"'
assert_json "review maps to High" "$($ROUTER --task-kind review)" '.requested_effort == "high"'
assert_json "deep maps to Max" "$($ROUTER --task-kind deep)" '.requested_effort == "max"'
assert_json "large independent work maps to Ultra" "$($ROUTER --task-kind large-parallel --parallel-lanes 3)" '.requested_effort == "ultra" and .effective_effort == "ultra"'
assert_json "user override wins" "$($ROUTER --task-kind mechanical --requested high)" '.requested_effort == "high" and .effective_effort == "high" and .override_applied'
assert_json "Ultra needs independent lanes" "$($ROUTER --task-kind large-parallel --parallel-lanes 1)" '.requested_effort == "ultra" and .effective_effort == "max" and .ultra_gate_applied'
assert_json "unsupported level falls back visibly" "$($ROUTER --task-kind deep --supported light,medium,high)" '.requested_effort == "max" and .effective_effort == "high" and .fallback_applied'
assert_json "quota never changes routing" "$($ROUTER --task-kind review --quota-state nearly-exhausted)" '.effective_effort == "high" and (.quota_changed_routing | not)'

if "$ROUTER" --task-kind review --requested impossible >/dev/null 2>&1; then
  printf 'not ok - unknown effort was accepted\n' >&2
  exit 1
fi
printf 'ok - unknown effort is rejected\n'

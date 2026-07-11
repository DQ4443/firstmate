#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
PDW="$ROOT/.agents/skills/pdw/SKILL.md"
BUILD="$ROOT/.agents/skills/build/SKILL.md"

python3 - "$PDW" "$BUILD" <<'PY'
import pathlib
import sys

pdw = pathlib.Path(sys.argv[1]).read_text()
build = pathlib.Path(sys.argv[2]).read_text()

def ordered(text, markers):
    cursor = -1
    for marker in markers:
        found = text.find(marker, cursor + 1)
        assert found >= 0, marker
        assert found > cursor, marker
        cursor = found

ordered(pdw, ["## Core loop", "## PDW shape", "## Dispatch contract", "## Sizing", "## Speed", "## Parallelism", "## Research", "## Test to settle"])
ordered(pdw, ["Map", "Implement", "Review", "Synthesize"])
ordered(build, ["## Phase 0: Intent", "## Entry Recon", "### 1. Checkpoint", "### 2. Move Recon", "### 3. Plan plus TDD", "### 4. Implement", "### 5. Validate", "### 6. Commit", "### 7. Issue Recon", "### 8. Update the ledger", "## Stop rule", "## Exit: Final Validate, Closing Artifact, Hold, /submit"])
PY
printf 'ok - Jim execution module and node order is preserved\n'

for required in requested_effort effective_effort requested_status effective_status routing_rationale return_thread_id return_host_id NEXT_STEP UNVERIFIED; do
  rg -q "$required" "$PDW" || { printf 'not ok - missing PDW carrier %s\n' "$required" >&2; exit 1; }
done
printf 'ok - PDW contains the approved routing and return carriers\n'

if rg -n '\.claude/agents|Workflow TOOL|PushNotification|ScheduleWakeup|RunPlatform|ReviewBot|Jim says|Jim chooses' "$ROOT/.agents/skills/pdw" "$ROOT/.agents/skills/build" "$ROOT/.codex"; then
  printf 'not ok - Claude or Jim-specific artifact survived adaptation\n' >&2
  exit 1
fi
printf 'ok - adapted execution files contain no forbidden Claude artifacts\n'

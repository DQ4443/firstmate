#!/usr/bin/env bash
# shellcheck disable=SC2016,SC2088
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
PDW="$ROOT/.agents/skills/pdw/SKILL.md"
BUILD="$ROOT/.agents/skills/build/SKILL.md"
TMP=$(mktemp -d "${TMPDIR:-/tmp}/execution-source.XXXXXX")
trap 'rm -rf "$TMP"' EXIT

verify_structure() {
  python3 - "$1" "$2" <<'PY'
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

ordered(pdw, ["## Core loop", "## PDW shape", "## Dispatch contract", "## Don't to do", "## Sizing", "## Speed", "## Parallelism", "## Research", "## Test to settle"])
ordered(pdw, ["Map", "Implement", "Review", "Synthesize"])
ordered(build, ["## Phase 0: Intent", "## Entry Recon", "### 1. Checkpoint", "### 2. Move Recon", "### 3. Plan plus TDD", "### 4. Implement", "### 5. Validate", "### 6. Commit", "### 7. Issue Recon", "### 8. Update the ledger", "## Stop rule", "## Exit: Final Validate, Closing Artifact, Hold, $submit"])
assert "An explicit `$pdw` always uses the workflow shape and never degrades" in pdw
assert "may degrade" not in pdw
assert "genuinely new direction outside the authorized intent" in build
for evidence_rule in ["E0 is Assumed", "E1 is Ran", "E2 is Works-unit", "E3 is Works-live", "E4 is Independently reproduced", "E5 is Refute-survived", "Laptop-only evidence is capped at E1", "Side claims, qualifiers, and supporting comparisons must earn the same bar"]:
    assert evidence_rule in build, evidence_rule
assert "Overlapping writers serialize even when their worktrees are isolated." in pdw
ledger_line = next(line for line in build.splitlines() if line.startswith("Create `state/build-loops/"))
for field in ["proof", "scout_artifact", "loop_artifact", "blockers", "r4_gate", "preregistered_before_after"]:
    assert f"`{field}`" in ledger_line, field
PY
}

verify_structure "$PDW" "$BUILD"
printf 'ok - Jim execution module and node order is preserved\n'

for required in requested_effort effective_effort requested_status effective_status routing_rationale return_thread_id return_host_id report_id NEXT_STEP UNVERIFIED; do
  grep -Eq "$required" "$PDW" || { printf 'not ok - missing PDW carrier %s\n' "$required" >&2; exit 1; }
done
printf 'ok - PDW contains the approved routing and return carriers\n'

if grep -ERn --exclude='*.pyc' --exclude-dir='__pycache__' '\.claude/agents|Workflow TOOL|PushNotification|ScheduleWakeup|RunPlatform|ReviewBot|Jim says|Jim chooses' "$ROOT/.agents/skills/pdw" "$ROOT/.agents/skills/build" "$ROOT/.codex"; then
  printf 'not ok - Claude or Jim-specific artifact survived adaptation\n' >&2
  exit 1
fi
printf 'ok - adapted execution files contain no forbidden Claude artifacts\n'

if grep -En '/(pdw|build|scout|explore|websearch|lavish|submit)([^A-Za-z0-9_-]|$)' "$PDW" "$BUILD" "$ROOT/.agents/skills/pdw/evals.md" "$ROOT/.agents/skills/build/evals.md"; then
  printf 'not ok - Claude slash skill invocation survived adaptation\n' >&2
  exit 1
fi
printf 'ok - Codex skill invocations use dollar syntax\n'

cp "$PDW" "$TMP/pdw.md"
sed -i.bak 's/always uses the workflow shape and never degrades/may degrade/' "$TMP/pdw.md"
rm -f "$TMP/pdw.md.bak"
if verify_structure "$TMP/pdw.md" "$BUILD" >/dev/null 2>&1; then
  printf 'not ok - explicit PDW degradation mutation survived\n' >&2
  exit 1
fi
printf 'ok - explicit PDW degradation mutation fails the structure gate\n'

cp "$PDW" "$TMP/pdw.md"
sed -i.bak 's/## Don.t to do/## Removed/' "$TMP/pdw.md"
rm -f "$TMP/pdw.md.bak"
if verify_structure "$TMP/pdw.md" "$BUILD" >/dev/null 2>&1; then
  printf 'not ok - missing Don.t to do module survived\n' >&2
  exit 1
fi
printf 'ok - missing Don.t to do module fails the structure gate\n'

cp "$BUILD" "$TMP/build.md"
sed -i.bak 's/, `r4_gate`//' "$TMP/build.md"
rm -f "$TMP/build.md.bak"
if verify_structure "$PDW" "$TMP/build.md" >/dev/null 2>&1; then
  printf 'not ok - missing canonical ledger field survived\n' >&2
  exit 1
fi
printf 'ok - missing canonical ledger field fails the structure gate\n'

if [[ -n ${JIM_SOURCE:-} ]]; then
  [[ $(shasum -a 256 "$JIM_SOURCE" | awk '{print $1}') == 134eb182731726ae9305d6a7a74d8a767bfb7f042201e953536ceec507f19f7c ]]
  sed -n '248,495p' "$JIM_SOURCE" >"$TMP/source-execution.txt"
  grep -Fq '## DON' "$TMP/source-execution.txt"
  grep -Fq 'Workflow TOOL' "$TMP/source-execution.txt"
  grep -Fq 'One root Codex task' "$PDW"
  grep -Fq '~/notes/build-loops/<branch>.json' "$TMP/source-execution.txt"
  grep -Fq 'state/build-loops/<branch>.json' "$BUILD"
  printf 'ok - source hash and audited Claude-to-Codex adaptation carriers match\n'
fi

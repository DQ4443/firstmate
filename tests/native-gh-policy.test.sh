#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

pass() {
  printf 'PASS: %s\n' "$*"
}

owned_files=(
  .agents/skills/submit/SKILL.md
  .agents/skills/sync/SKILL.md
  CLAUDE.md
  CONTRIBUTING.md
  docs/architecture.md
  docs/configuration.md
  docs/cmux-backend.md
  docs/herdr-backend.md
  docs/orca-backend.md
  docs/scripts.md
  docs/tmux-backend.md
  docs/zellij-backend.md
)

retired_tool='gh''-axi'
if grep -in "$retired_tool" "${owned_files[@]/#/$ROOT/}"; then
  fail 'owned policy and documentation still refer to the retired GitHub wrapper'
fi
pass 'owned policy and documentation use native GitHub CLI guidance'

submit="$ROOT/.agents/skills/submit/SKILL.md"
sync="$ROOT/.agents/skills/sync/SKILL.md"

grep -Fq 'gh pr checks --json name,state,bucket,link,description' "$submit" \
  || fail 'submit does not require the canonical gh pr checks fields'
grep -Fq 'bucket' "$submit" \
  || fail 'submit does not require bucket-based check interpretation'
grep -Fq 'command exit status' "$submit" \
  || fail 'submit does not forbid PASS inference from the JSON command exit status'
grep -Fq 'exact head SHA before and after' "$submit" \
  || fail 'submit does not detect head changes across status inspection'
grep -Fq 'Commit.statusCheckRollup' "$submit" \
  || fail 'submit does not name the raw GraphQL rollup field'
grep -Fq 'CheckRun' "$submit" \
  || fail 'submit does not cover GraphQL CheckRun contexts'
grep -Fq 'StatusContext' "$submit" \
  || fail 'submit does not cover legacy GraphQL StatusContext contexts'
grep -Fq 'combined commit status' "$submit" \
  || fail 'submit does not document the exact-SHA REST status fallback'
grep -Fq 'check-runs' "$submit" \
  || fail 'submit does not combine legacy status with exact-SHA check runs'
grep -Fq 'at least one matching CodeRabbit context' "$submit" \
  || fail 'submit does not reject a vacuous CodeRabbit pass'
grep -Fq 'all matching CodeRabbit contexts' "$submit" \
  || fail 'submit does not require every matching CodeRabbit context to pass'
grep -Fq 'unresolved review threads separately' "$submit" \
  || fail 'submit conflates CodeRabbit check state with review-thread resolution'
pass 'submit defines exact-head native gh and raw API status interpretation'

if grep -Eq 'gh pr list.*--json[^`]*statusCheckRollup' "$sync"; then
  fail 'sync requests unsupported statusCheckRollup data from gh pr list'
fi
grep -Fq 'gh pr checks --repo <repo> <number> --json name,state,bucket,link,description' "$sync" \
  || fail 'sync does not inspect each listed pull request with gh pr checks'
pass 'sync lists pull requests first and checks each pull request separately'

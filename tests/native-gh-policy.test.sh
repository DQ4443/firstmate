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

if find "$ROOT/.github/workflows" -maxdepth 1 -type f -iname '*no-mistakes*' -print -quit \
  | grep -q .; then
  fail 'retired no-mistakes provenance workflow is still active'
fi

retired_provenance_pattern='git[[:space:]]+push[[:space:]]+no-mistakes|(raised|submitted)[[:space:]]+(via|through)[[:space:]]+no-mistakes|no-mistakes[-_ ]required|require[[:space:]]+no-mistakes|no-mistakes[^[:alnum:]]*(signature|provenance)|(signature|provenance)[^[:alnum:]]*no-mistakes|(https://github\.com/|git@github\.com:)[^/[:space:]]+/no-mistakes(\.git)?'
if grep -ERiq -- "$retired_provenance_pattern" "$ROOT/.github/workflows"; then
  fail 'an active workflow still requires the retired no-mistakes provenance marker'
fi

ci="$ROOT/.github/workflows/ci.yml"
require_ci_job() {
  local job_id=$1
  local expected_name=$2
  local failure=$3

  awk -v target="$job_id" -v expected="$expected_name" '
    /^[^[:space:]#][^:]*:/ {
      in_jobs = ($0 ~ /^jobs:[[:space:]]*(#.*)?$/)
      current = 0
      next
    }
    in_jobs && /^  [[:alnum:]_-]+:[[:space:]]*(#.*)?$/ {
      job = $0
      sub(/^  /, "", job)
      sub(/:.*/, "", job)
      current = (job == target)
      next
    }
    in_jobs && current && /^    name:[[:space:]]*/ {
      value = $0
      sub(/^[[:space:]]*name:[[:space:]]*/, "", value)
      sub(/[[:space:]]+#.*$/, "", value)
      if ((substr(value, 1, 1) == "\"" && substr(value, length(value), 1) == "\"") ||
          (substr(value, 1, 1) == "\047" && substr(value, length(value), 1) == "\047")) {
        value = substr(value, 2, length(value) - 2)
      }
      found = (value == expected)
    }
    END { exit(found ? 0 : 1) }
  ' "$ci" || fail "$failure"
}

require_ci_job lint 'Lint shell scripts' 'CI no longer retains the shell lint safety gate'
require_ci_job tests 'Behavior tests' 'CI no longer retains the behavior test safety gate'
require_ci_job invariants 'Repo invariants' 'CI no longer retains the repository invariant safety gate'
pass 'native GitHub pull requests retain the unrelated CI safety gates'

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
  fail 'sync bypasses the required per-PR gh pr checks bucket policy'
fi
grep -Fq 'gh pr checks --repo <repo> <number> --json name,state,bucket,link,description' "$sync" \
  || fail 'sync does not inspect each listed pull request with gh pr checks'
pass 'sync lists pull requests first and checks each pull request separately'

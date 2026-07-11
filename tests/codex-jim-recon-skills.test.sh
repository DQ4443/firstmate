#!/usr/bin/env bash
# shellcheck disable=SC2016
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

assert_contains() {
  local file=$1
  local needle=$2
  grep -Fq -- "$needle" "$file" || fail "$file is missing: $needle"
}

assert_not_contains() {
  local file=$1
  local needle=$2
  if grep -Fq -- "$needle" "$file"; then
    fail "$file contains forbidden text: $needle"
  fi
}

skills=(scout explore websearch)

for skill in "${skills[@]}"; do
  skill_file="$ROOT/.agents/skills/$skill/SKILL.md"
  eval_file="$ROOT/.agents/skills/$skill/evals.md"
  [[ -f "$skill_file" ]] || fail "missing $skill_file"
  [[ -f "$eval_file" ]] || fail "missing $eval_file"
  assert_contains "$skill_file" "name: $skill"
  assert_contains "$skill_file" 'Read `/pdw` before dispatch'
  assert_contains "$skill_file" 'requested effort, effective effort'
  assert_contains "$skill_file" 'every native subagent is a leaf that returns only to its immediate parent'
  assert_contains "$skill_file" 'reject degenerate upstream outputs'
  assert_contains "$skill_file" '`UNVERIFIED`'
  assert_contains "$eval_file" '## Should trigger'
  assert_contains "$eval_file" '## Should not trigger'
  assert_contains "$eval_file" 'requested effort, effective effort'
  assert_not_contains "$skill_file" 'Workflow'
  assert_not_contains "$skill_file" 'Skill('
  assert_not_contains "$skill_file" 'ToolSearch'
  assert_not_contains "$skill_file" 'agentType'
done

assert_contains "$ROOT/.agents/skills/scout/SKILL.md" 'Load `/explore` and `/websearch`, then dispatch both halves concurrently'
assert_contains "$ROOT/.agents/skills/scout/SKILL.md" 'Cull by reasoning only candidates killed by redundancy or YAGNI'
assert_contains "$ROOT/.agents/skills/scout/SKILL.md" 'Run every cheap local experiment now'
assert_contains "$ROOT/.agents/skills/scout/SKILL.md" 'Flag and justify expensive external experiments without launching them'
assert_contains "$ROOT/.agents/skills/scout/SKILL.md" 'NEXT_STEP: invoke /lavish decision page before reporting'
assert_contains "$ROOT/.agents/skills/explore/SKILL.md" 'Choose two to five angles'
assert_contains "$ROOT/.agents/skills/explore/SKILL.md" '`file:line` anchor'
assert_contains "$ROOT/.agents/skills/explore/SKILL.md" 'Do not search the web inside an explore cell'
assert_contains "$ROOT/.agents/skills/websearch/SKILL.md" 'direct URL, a publication or last-updated date, and a `reported` or `verified` label'
assert_contains "$ROOT/.agents/skills/websearch/SKILL.md" 'official OpenAI documentation connector first'
assert_contains "$ROOT/.agents/skills/websearch/SKILL.md" 'Do not inspect local repository implementation inside a websearch cell'

if find "$ROOT/.agents" -type f -path '*/skills-spine/*' -print -quit | grep -q .; then
  fail 'found forbidden .agents/skills-spine target'
fi

printf 'PASS: scout, explore, and websearch preserve separate Codex recon contracts\n'

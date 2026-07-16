#!/usr/bin/env bash
# shellcheck disable=SC2016
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
SKILL="$ROOT/.agents/skills/orient/SKILL.md"
EVALS="$ROOT/.agents/skills/orient/evals.md"
TMP=$(mktemp -d "${TMPDIR:-/tmp}/orient-skill.XXXXXX")
trap 'rm -rf "$TMP"' EXIT

fail() {
  printf 'not ok - %s\n' "$1" >&2
  exit 1
}

contains() {
  grep -Fq -- "$2" "$1"
}

verify_skill() {
  local file=$1
  contains "$file" 'name: orient' || return 1
  contains "$file" 'user-invocable: true' || return 1
  contains "$file" 'metadata:' || return 1
  contains "$file" 'internal: true' || return 1
  contains "$file" 'what is the bigger picture' || return 1
  contains "$file" 'remind me what this task is doing' || return 1
  contains "$file" 'what does success look like' || return 1
  contains "$file" 'where are we and what happens next' || return 1
  contains "$file" 'give me the decision-relevant status' || return 1
  contains "$file" 'Do not use for a one-line status lookup, raw logs, detailed debugging, or a request to implement or fix work.' || return 1
  contains "$file" 'verified current task state' || return 1
  contains "$file" 'Separate facts, inference, and unknowns.' || return 1
  contains "$file" 'falsifiable' || return 1
  contains "$file" 'end-to-end proof' || return 1
  contains "$file" '150 to 300 words' || return 1
  contains "$file" 'Read-only by default.' || return 1
  contains "$file" 'End with a literal `NEXT_STEP:` line.' || return 1
}

[[ -f "$SKILL" ]] || fail 'orient skill is missing'
[[ -f "$EVALS" ]] || fail 'orient evals are missing'
verify_skill "$SKILL" || fail 'orient skill contract is incomplete'
printf 'ok - orient trigger, evidence, output, and read-only contracts are present\n'

for heading in \
  '## Build task' \
  '## Blocked research decision' \
  '## Submit-gated task' \
  '## Near misses' \
  '## Grading rubric'; do
  contains "$EVALS" "$heading" || fail "missing eval section: $heading"
done
for criterion in \
  'inverted pyramid' \
  'falsifiable success' \
  'verified current state' \
  'decision relevance' \
  'concise next steps' \
  'random facts' \
  'accidental mutation authority'; do
  contains "$EVALS" "$criterion" || fail "missing eval criterion: $criterion"
done
printf 'ok - realistic build, blocked-decision, submit-gate, and near-miss evals are present\n'

contains "$ROOT/README.md" '| `/orient`' || fail 'README skill discovery entry is missing'
contains "$ROOT/AGENTS.md" 'Load `$orient`' || fail 'AGENTS orient trigger is missing'
printf 'ok - orient is discoverable from README and the operating contract\n'

if grep -En '[—–]|[⚡⚙🔁📦]' "$SKILL" "$EVALS"; then
  fail 'banned prose survived in orient files'
fi
printf 'ok - orient files use the repository prose style\n'

cp "$SKILL" "$TMP/skill.md"
sed -i.bak '/End with a literal `NEXT_STEP:` line\./d' "$TMP/skill.md"
rm -f "$TMP/skill.md.bak"
if verify_skill "$TMP/skill.md"; then
  fail 'NEXT_STEP mutation survived the verifier'
fi
printf 'ok - removing the literal NEXT_STEP contract fails the verifier\n'

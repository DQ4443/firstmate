#!/usr/bin/env bash
# shellcheck disable=SC2016
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
SKILL="$ROOT/.agents/skills/orient/SKILL.md"
EVALS="$ROOT/.agents/skills/orient/evals.md"
BAD_FIXTURE="$ROOT/.agents/skills/orient/fixtures/eng-330-muddled.md"
GOOD_FIXTURE="$ROOT/.agents/skills/orient/fixtures/eng-330-corrected.md"
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
  contains "$file" 'Default to 150 to 300 words unless the task genuinely needs more.' || return 1
  contains "$file" 'Read-only by default.' || return 1
  contains "$file" 'End with a literal `NEXT_STEP:` line.' || return 1
  contains "$file" '## Bigger picture' || return 1
  contains "$file" '## Success' || return 1
  contains "$file" '## Current status' || return 1
  contains "$file" '## Next steps' || return 1
  contains "$file" 'Do not put an executive paragraph before `## Bigger picture`.' || return 1
  contains "$file" 'Lead with what the user can do or trust' || return 1
  contains "$file" 'instead of starting the success path halfway through.' || return 1
  contains "$file" 'Make the first Success sentence begin at the verified user action' || return 1
  contains "$file" 'Treat worktree cleanliness and branch sync lag as status noise' || return 1
}

verify_output_structure() {
  local file=$1
  local heading_lines headings first_nonblank bigger success current next bigger_text bigger_first
  heading_lines=$(grep -En '^#{1,6}[[:space:]]+' "$file" || true)
  headings=$(printf '%s\n' "$heading_lines" | cut -d: -f2-)
  [[ "$headings" == $'## Bigger picture\n## Success\n## Current status\n## Next steps' ]] || return 1
  first_nonblank=$(grep -n -m1 '[^[:space:]]' "$file" | cut -d: -f1)
  bigger=$(grep -n '^## Bigger picture$' "$file" | cut -d: -f1)
  success=$(grep -n '^## Success$' "$file" | cut -d: -f1)
  current=$(grep -n '^## Current status$' "$file" | cut -d: -f1)
  next=$(grep -n '^## Next steps$' "$file" | cut -d: -f1)
  [[ "$first_nonblank" == "$bigger" ]] || return 1
  bigger_text=$(sed -n "$((bigger + 1)),$((success - 1))p" "$file")
  [[ -n "${bigger_text//[[:space:]]/}" ]] || return 1
  bigger_first=$(printf '%s\n' "$bigger_text" | grep -m1 '[^[:space:]]')
  printf '%s\n' "$bigger_first" | grep -Eq '^[[:space:]]*ENG-[0-9]+' && return 1
  printf '%s\n' "$bigger_text" |
    grep -Eiq 'blocked|blocker|dependenc|depends on|waiting|awaiting|pending|in progress|must finish first|branch|commit|head [0-9a-f]|evidence|E[0-5]|PR #[0-9]+|merged' && return 1
  [[ "$bigger" -lt "$success" && "$success" -lt "$current" && "$current" -lt "$next" ]] || return 1
  tail -n 1 "$file" | grep -q '^NEXT_STEP:' || return 1
}

[[ -f "$SKILL" ]] || fail 'orient skill is missing'
[[ -f "$EVALS" ]] || fail 'orient evals are missing'
[[ -f "$BAD_FIXTURE" ]] || fail 'real-world muddled ENG-330 fixture is missing'
[[ -f "$GOOD_FIXTURE" ]] || fail 'corrected ENG-330 fixture is missing'
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

if verify_output_structure "$BAD_FIXTURE"; then
  fail 'the real-world muddled ENG-330 output passed the structure verifier'
fi
verify_output_structure "$GOOD_FIXTURE" || fail 'the corrected ENG-330 output failed the structure verifier'
good_words=$(wc -w <"$GOOD_FIXTURE" | tr -d ' ')
[[ "$good_words" -ge 150 && "$good_words" -le 300 ]] || fail 'the corrected ENG-330 fixture is outside the default word range'
printf 'ok - ENG-330 regression rejects the detail dump and accepts the four-section correction\n'

cp "$GOOD_FIXTURE" "$TMP/missing-heading.md"
sed -i.bak '/^## Current status$/d' "$TMP/missing-heading.md"
rm -f "$TMP/missing-heading.md.bak"
if verify_output_structure "$TMP/missing-heading.md"; then
  fail 'missing Current status heading survived the structure verifier'
fi

cp "$GOOD_FIXTURE" "$TMP/out-of-order.md"
sed -i.bak 's/^## Success$/## TEMP/; s/^## Current status$/## Success/; s/^## TEMP$/## Current status/' "$TMP/out-of-order.md"
rm -f "$TMP/out-of-order.md.bak"
if verify_output_structure "$TMP/out-of-order.md"; then
  fail 'out-of-order headings survived the structure verifier'
fi

cp "$GOOD_FIXTURE" "$TMP/status-first.md"
sed -i.bak '/^## Bigger picture$/a\
ENG-330 is in progress.' "$TMP/status-first.md"
rm -f "$TMP/status-first.md.bak"
if verify_output_structure "$TMP/status-first.md"; then
  fail 'status language before the practical goal survived the structure verifier'
fi

cp "$GOOD_FIXTURE" "$TMP/ticket-mechanism-first.md"
sed -i.bak '/^## Bigger picture$/a\
ENG-330 carries a selected mode into forward simulation.' "$TMP/ticket-mechanism-first.md"
rm -f "$TMP/ticket-mechanism-first.md.bak"
if verify_output_structure "$TMP/ticket-mechanism-first.md"; then
  fail 'ticket-mechanism-first Bigger picture survived the structure verifier'
fi

cp "$GOOD_FIXTURE" "$TMP/dependency-first.md"
sed -i.bak '/^## Bigger picture$/a\
ENG-330 depends on ENG-331.' "$TMP/dependency-first.md"
rm -f "$TMP/dependency-first.md.bak"
if verify_output_structure "$TMP/dependency-first.md"; then
  fail 'dependency language before the practical goal survived the structure verifier'
fi

cp "$GOOD_FIXTURE" "$TMP/extra-heading.md"
sed -i.bak '/^## Current status$/i\
### Dependency detail\
' "$TMP/extra-heading.md"
rm -f "$TMP/extra-heading.md.bak"
if verify_output_structure "$TMP/extra-heading.md"; then
  fail 'an extra heading survived the structure verifier'
fi
printf 'ok - missing, out-of-order, status-first, ticket-mechanism-first, dependency-first, and extra-heading near misses fail closed\n'

cp "$SKILL" "$TMP/skill.md"
sed -i.bak '/End with a literal `NEXT_STEP:` line\./d' "$TMP/skill.md"
rm -f "$TMP/skill.md.bak"
if verify_skill "$TMP/skill.md"; then
  fail 'NEXT_STEP mutation survived the verifier'
fi
printf 'ok - removing the literal NEXT_STEP contract fails the verifier\n'

#!/usr/bin/env bash
# shellcheck disable=SC2016
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
SKILL="$ROOT/.agents/skills/submit/SKILL.md"
EVALS="$ROOT/.agents/skills/submit/evals.md"
TMP=$(mktemp -d "${TMPDIR:-/tmp}/submit-skill.XXXXXX")
trap 'rm -rf "$TMP"' EXIT

fail() {
  printf 'not ok - %s\n' "$1" >&2
  exit 1
}

contains() {
  grep -Fq -- "$2" "$1"
}

ordered() {
  local file=$1
  shift
  local previous=0
  local marker
  local line
  for marker in "$@"; do
    line=$(grep -nF -- "$marker" "$file" | head -1 | cut -d: -f1)
    [[ -n "$line" && "$line" -gt "$previous" ]] || return 1
    previous=$line
  done
}

verify_skill() {
  local file=$1
  contains "$file" 'Invariant triggers are pointers, not restatements.' || return 1
  contains "$file" 'The panel is one PDW in step 1.' || return 1
  contains "$file" 'Findings block only with a runnable reproduction in step 1.' || return 1
  contains "$file" 'Read and update the canary at panel time and close time in step 1.' || return 1
  contains "$file" 'Every monitor or wake payload carries the loop count, both caps, and the closing tail rule from step 3.' || return 1
  contains "$file" 'The pull request stays open under Constraints.' || return 1
  ordered "$file" \
    '### 0. Sync the base first' \
    '### 1. Pre-push adversarial panel: model and persona matrix, difficulty-gated' \
    '### 2. Commit, then hold for push and pull-request opening' \
    '### 3. Babysit to green and CodeRabbit-clean as a loop' \
    '### 4. Re-panel every 4 stuck loops' \
    '### 5. HOLD at 16' \
    '### 6. Closing report through /lavish report mode' \
    '## Constraints' || return 1
  contains "$file" 'three to six distinct model and refutation-persona pairs' || return 1
  contains "$file" 'runnable failing test, replay, or mutation' || return 1
  contains "$file" 'Fold records pairwise' || return 1
  contains "$file" 'local Codex review' || return 1
  contains "$file" 'state/submit-canary.json' || return 1
  contains "$file" 're-panel threshold 4, pause threshold 16' || return 1
  contains "$file" 'At loop 16, stop.' || return 1
  contains "$file" 'HOLD for explicit approval to push and open the pull request' || return 1
  contains "$file" '`/submit` still does not merge' || return 1
}

verify_evals() {
  local file=$1
  contains "$file" '## Should trigger (positive)' || return 1
  contains "$file" '## Should NOT trigger (negative)' || return 1
  contains "$file" 'Run the push and pull-request pipeline we use.' || return 1
  contains "$file" 'Commit this locally so we can revert later.' || return 1
  contains "$file" 'Four continuous stuck loops triggered' || return 1
  contains "$file" 'Loop 16 stopped on HOLD' || return 1
  contains "$file" 'CodeRabbit was the post-push canary' || return 1
  contains "$file" '`/submit` did not merge' || return 1
}

verify_skill "$SKILL" || fail 'submit skill structure or threshold contract is incomplete'
verify_evals "$EVALS" || fail 'submit eval trigger or gate contract is incomplete'
printf 'ok - submit structure, trigger head, thresholds, and eval checks are present\n'

if rg -n '[—–]|[⚡⚙🔁📦]|\.claude|Workflow|ReviewBot|PushNotification|ScheduleWakeup|Skill\(' "$SKILL" "$EVALS"; then
  fail 'Claude artifact or banned prose survived adaptation'
fi
printf 'ok - submit skill has no Claude artifact or banned prose\n'

cp "$SKILL" "$TMP/skill.md"
sed -i '' '/Findings block only with a runnable reproduction in step 1\./d' "$TMP/skill.md"
if verify_skill "$TMP/skill.md"; then
  fail 'trigger-head mutation survived'
fi
printf 'ok - removing an invariant trigger fails the verifier\n'

cp "$SKILL" "$TMP/skill.md"
sed -i '' 's/re-panel threshold 4, pause threshold 16/re-panel threshold 5, pause threshold 17/' "$TMP/skill.md"
if verify_skill "$TMP/skill.md"; then
  fail 'threshold mutation survived'
fi
printf 'ok - changing re-panel and HOLD thresholds fails the verifier\n'

cp "$SKILL" "$TMP/skill.md"
sed -i '' 's/### 4\. Re-panel every 4 stuck loops/### 7. Re-panel every 4 stuck loops/' "$TMP/skill.md"
if verify_skill "$TMP/skill.md"; then
  fail 'module-order mutation survived'
fi
printf 'ok - changing the source node sequence fails the verifier\n'

cp "$EVALS" "$TMP/evals.md"
sed -i '' '/Run the push and pull-request pipeline we use\./d' "$TMP/evals.md"
if verify_evals "$TMP/evals.md"; then
  fail 'positive-trigger mutation survived'
fi
printf 'ok - removing a positive trigger fails the verifier\n'

if [[ -n ${JIM_SOURCE:-} ]]; then
  [[ -f "$JIM_SOURCE" ]] || fail 'JIM_SOURCE does not exist'
  source_sha=$(shasum -a 256 "$JIM_SOURCE" | awk '{print $1}')
  [[ "$source_sha" == 134eb182731726ae9305d6a7a74d8a767bfb7f042201e953536ceec507f19f7c ]] || fail 'Jim source hash changed'
  sed -n '1136,1221p' "$JIM_SOURCE" | grep -Fq '## The loop' || fail 'Jim submit source heading is missing'
  sed -n '1136,1221p' "$JIM_SOURCE" | grep -Fq '## Constraints' || fail 'Jim submit constraints heading is missing'
  printf 'ok - Jim source hash and submit headings match the translation map\n'
fi

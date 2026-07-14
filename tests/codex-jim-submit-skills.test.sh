#!/usr/bin/env bash
# shellcheck disable=SC2016
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
SKILL="$ROOT/.agents/skills/submit/SKILL.md"
EVALS="$ROOT/.agents/skills/submit/evals.md"
TMP=$(mktemp -d "${TMPDIR:-/tmp}/submit-skill.XXXXXX")
trap 'rm -rf "$TMP"' EXIT

positive_triggers=(
  'ok do that please, execute the same push PR pipeline that we always use'
  'ship the auth-refactor branch - panel, push, PR, babysit it to green'
  '$submit branch fix/foo in worktree bar, title fix: [<work-repo>] ...'
  'the change is validated, drive it to an open green PR'
  'run the commit-push-pr flow on this'
)

negative_trigger_lines=(
  '1. `commit this locally so we can revert later`, because a checkpoint commit is not submission.'
  '2. `is the PR green yet?`, because that is one status lookup.'
  '3. `merge #<n>`, because `$submit` never merges.'
)

eval_rules=(
  'The work branch synced onto the remote default branch before the panel ran.'
  'The invariant-trigger head block preserved the panel, runnable-reproduction, canary, loop-payload, and open-pull-request pointers.'
  'The panel was difficulty-gated, with one strong reviewer for mechanical diffs or three to six distinct model and persona pairs for subjective, multi-file, or logic diffs.'
  'Every panel cell reviewed the whole diff and recorded requested and effective model and effort plus enforcement evidence.'
  'Every blocking finding carried a runnable failing test, replay, or mutation, and every finding without one was demoted to speculative.'
  'Structured findings used `defect`, `repro_ref`, `severity`, and `confidence`, then passed through a pairwise tournament fold.'
  'Local Codex review ran as the second lens at High, or requested Max with recorded effective `xhigh`, and its findings were deduplicated against the panel.'
  '`state/submit-canary.json` used exactly `pr`, `panel_missed`, `drip_rounds`, `note`, and `matrix_recall`, and was updated at panel and close time.'
  'CodeRabbit was the post-push canary and review source.'
  'Two real CodeRabbit misses on one pull request, or at least three drip rounds on two consecutive pull requests, switched later work to one strong reviewer and flagged redesign.'
  'Every confirmed issue was fixed before proceeding, and every non-trivial fix triggered another panel.'
  'The pull-request body used Summary, Debug evidence, Validation, and Risk with recorded proof and exact pass counts.'
  'The human saw the drafted title and body and explicitly approved the outward push and pull-request opening in that moment.'
  "Evidence used Jim's E0 through E5 meanings, laptop-only evidence never exceeded E1, and side claims earned the headline bar or displayed their own lower level."
  'No autonomous exception authorized a push, pull-request opening, or merge.'
  'If a proven installed guard required its documented one-shot sentinel, the sentinel was used immediately before pull-request opening, and no sentinel or bypass was invented otherwise.'
  'The babysit stage ran as one owning monitor or Codex automation, with every payload carrying the current loop, threshold 4, threshold 16, and the closing-report `NEXT_STEP`.'
  'Notifications occurred only on the five named transitions.'
  'Four continuous stuck loops triggered a fresh difficulty-gated panel over the current diff.'
  'Loop 16 stopped on HOLD with the failing state, attempts, and leading hypothesis.'
  'The same Lavish workstream page closed in report mode with the final pipeline diagram, evidence, findings, pull-request state, review pointers, and remaining merge decision.'
  'The stable Lavish URL returned with a short task summary.'
  'The pull request remained open and `$submit` did not merge.'
  'Every subsequent push, outward message, review reply, or review-thread resolution remained human-gated.'
)

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
    '### 6. Closing report through $lavish report mode' \
    '## Constraints' || return 1
  contains "$file" 'three to six distinct model and refutation-persona pairs' || return 1
  contains "$file" 'runnable failing test, replay, or mutation' || return 1
  contains "$file" 'Fold records pairwise' || return 1
  contains "$file" 'local Codex review' || return 1
  contains "$file" 'state/submit-canary.json' || return 1
  contains "$file" 're-panel threshold 4, pause threshold 16' || return 1
  contains "$file" 'At loop 16, stop.' || return 1
  contains "$file" 'HOLD for explicit approval to push and open the pull request' || return 1
  contains "$file" '`$submit` still does not merge' || return 1
  contains "$file" 'The file has exactly `pr`, `panel_missed`, `drip_rounds`, `note`, and `matrix_recall` fields.' || return 1
  contains "$file" 'at least two real findings that the panel missed on one pull request' || return 1
  contains "$file" 'at least three drip rounds on two consecutive pull requests' || return 1
  contains "$file" 'The human must explicitly approve the push and pull-request opening at step 2' || return 1
  contains "$file" 'Merge requires a separate explicit human decision' || return 1
  contains "$file" 'When arriving from `$build`, the loop must have exited as Done or an approved scope-creep cut' || return 1
  contains "$file" 'Run the review as one `$pdw` owned by the top-level task.' || return 1
  contains "$file" '### 6. Closing report through $lavish report mode' || return 1
}

verify_evals() {
  local file=$1
  local actual
  local expected
  local index
  contains "$file" '## Should trigger (positive)' || return 1
  contains "$file" '## Should NOT trigger (negative)' || return 1
  actual=$(awk '
    /^## Should trigger \(positive\)$/ {inside=1; next}
    /^## / {if (inside) exit}
    inside && /^[0-9]+\. / {print}
  ' "$file")
  expected=""
  index=1
  for line in "${positive_triggers[@]}"; do
    expected+=$(printf '%s. `%s`\n' "$index" "$line")
    expected+=$'\n'
    index=$((index + 1))
  done
  expected=${expected%$'\n'}
  [[ "$actual" == "$expected" ]] || return 1

  actual=$(awk '
    /^## Should NOT trigger \(negative\)$/ {inside=1; next}
    /^## / {if (inside) exit}
    inside && /^[0-9]+\. / {print}
  ' "$file")
  expected=$(printf '%s\n' "${negative_trigger_lines[@]}")
  expected=${expected%$'\n'}
  [[ "$actual" == "$expected" ]] || return 1

  actual=$(awk '
    /^## Binary output checks$/ {inside=1; next}
    /^## / {if (inside) exit}
    inside && /^- \[ \] / {print}
  ' "$file")
  expected=""
  for line in "${eval_rules[@]}"; do
    expected+=$(printf -- '- [ ] %s\n' "$line")
    expected+=$'\n'
  done
  expected=${expected%$'\n'}
  [[ "$actual" == "$expected" ]] || return 1
}

verify_skill "$SKILL" || fail 'submit skill structure or threshold contract is incomplete'
verify_evals "$EVALS" || fail 'submit eval trigger or gate contract is incomplete'
printf 'ok - submit structure, trigger head, thresholds, and eval checks are present\n'
printf 'ok - all five positive triggers, three negative triggers, and 24 binary eval rules are enumerated\n'

if grep -En '[—–]|[⚡⚙🔁📦]|\.claude|Workflow|ReviewBot|PushNotification|ScheduleWakeup|Skill\(' "$SKILL" "$EVALS"; then
  fail 'Claude artifact or banned prose survived adaptation'
fi
printf 'ok - submit skill has no Claude artifact or banned prose\n'

cp "$SKILL" "$TMP/skill.md"
sed -i.bak '/Findings block only with a runnable reproduction in step 1\./d' "$TMP/skill.md"
rm -f "$TMP/skill.md.bak"
if verify_skill "$TMP/skill.md"; then
  fail 'trigger-head mutation survived'
fi
printf 'ok - removing an invariant trigger fails the verifier\n'

cp "$SKILL" "$TMP/skill.md"
sed -i.bak 's/re-panel threshold 4, pause threshold 16/re-panel threshold 5, pause threshold 17/' "$TMP/skill.md"
rm -f "$TMP/skill.md.bak"
if verify_skill "$TMP/skill.md"; then
  fail 'threshold mutation survived'
fi
printf 'ok - changing re-panel and HOLD thresholds fails the verifier\n'

cp "$SKILL" "$TMP/skill.md"
sed -i.bak 's/### 4\. Re-panel every 4 stuck loops/### 7. Re-panel every 4 stuck loops/' "$TMP/skill.md"
rm -f "$TMP/skill.md.bak"
if verify_skill "$TMP/skill.md"; then
  fail 'module-order mutation survived'
fi
printf 'ok - changing the source node sequence fails the verifier\n'

cp "$EVALS" "$TMP/evals.md"
sed -i.bak '/run the commit-push-pr flow on this/d' "$TMP/evals.md"
rm -f "$TMP/evals.md.bak"
if verify_evals "$TMP/evals.md"; then
  fail 'positive-trigger mutation survived'
fi
printf 'ok - removing a positive trigger fails the verifier\n'

cp "$EVALS" "$TMP/evals.md"
sed -i.bak 's/panel, push, PR/panel, approved push, PR/' "$TMP/evals.md"
rm -f "$TMP/evals.md.bak"
if verify_evals "$TMP/evals.md"; then
  fail 'second positive-trigger wording mutation survived'
fi
printf 'ok - inserting approved into the exact second trigger fails the verifier\n'

cp "$EVALS" "$TMP/evals.md"
python3 - "$TMP/evals.md" "${negative_trigger_lines[0]}" <<'PY'
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
line = sys.argv[2]
text = path.read_text(encoding="utf-8")
text = text.replace(line + "\n", "", 1)
text = text.replace("\n## Should NOT trigger (negative)", "\n" + line + "\n\n## Should NOT trigger (negative)", 1)
path.write_text(text, encoding="utf-8")
PY
if verify_evals "$TMP/evals.md"; then
  fail 'negative-to-positive section mutation survived'
fi
printf 'ok - moving a negative prompt into the positive section fails the verifier\n'

cp "$EVALS" "$TMP/evals.md"
sed -i.bak 's/## Should NOT trigger (negative)/## Should trigger (negative)/' "$TMP/evals.md"
rm -f "$TMP/evals.md.bak"
if verify_evals "$TMP/evals.md"; then
  fail 'NOT-negation mutation survived'
fi
printf 'ok - removing NOT from the negative heading fails the verifier\n'

cp "$SKILL" "$TMP/skill.md"
sed -i.bak 's/, and `matrix_recall`//' "$TMP/skill.md"
rm -f "$TMP/skill.md.bak"
if verify_skill "$TMP/skill.md"; then
  fail 'canary-field mutation survived'
fi
printf 'ok - changing the exact canary fields fails the verifier\n'

cp "$SKILL" "$TMP/skill.md"
sed -i.bak 's/at least two real findings/at least three real findings/' "$TMP/skill.md"
rm -f "$TMP/skill.md.bak"
if verify_skill "$TMP/skill.md"; then
  fail 'panel-miss fallback mutation survived'
fi
printf 'ok - changing the panel-miss fallback predicate fails the verifier\n'

cp "$SKILL" "$TMP/skill.md"
sed -i.bak 's/at least three drip rounds on two consecutive pull requests/at least four drip rounds on three consecutive pull requests/' "$TMP/skill.md"
rm -f "$TMP/skill.md.bak"
if verify_skill "$TMP/skill.md"; then
  fail 'drip-round fallback mutation survived'
fi
printf 'ok - changing the drip-round fallback predicate fails the verifier\n'

cp "$EVALS" "$TMP/evals.md"
sed -i.bak 's/The human saw the drafted title/The human reviewed the drafted title/' "$TMP/evals.md"
rm -f "$TMP/evals.md.bak"
if verify_evals "$TMP/evals.md"; then
  fail 'exact pull-request approval eval mutation survived'
fi
printf 'ok - changing the exact pull-request approval eval fails the verifier\n'

cp "$EVALS" "$TMP/evals.md"
sed -i.bak 's/`\$submit` did not merge/`$submit` may merge/' "$TMP/evals.md"
rm -f "$TMP/evals.md.bak"
if verify_evals "$TMP/evals.md"; then
  fail 'merge-gate mutation survived'
fi
printf 'ok - changing the merge gate fails the verifier\n'

for carrier in pdw build lavish; do
  cp "$SKILL" "$TMP/skill.md"
  sed -i.bak "s/\\\$$carrier/\/$carrier/g" "$TMP/skill.md"
  rm -f "$TMP/skill.md.bak"
  if verify_skill "$TMP/skill.md"; then
    fail "slash-$carrier carrier mutation survived"
  fi
  printf 'ok - changing $%s to /%s fails the verifier\n' "$carrier" "$carrier"
done

if [[ -n ${JIM_SOURCE:-} ]]; then
  [[ -f "$JIM_SOURCE" ]] || fail 'JIM_SOURCE does not exist'
  source_sha=$(shasum -a 256 "$JIM_SOURCE" | awk '{print $1}')
  [[ "$source_sha" == 134eb182731726ae9305d6a7a74d8a767bfb7f042201e953536ceec507f19f7c ]] || fail 'Jim source hash changed'
  sed -n '1136,1221p' "$JIM_SOURCE" >"$TMP/source-submit.txt"
  grep -Fq '## The loop' "$TMP/source-submit.txt" || fail 'Jim submit source heading is missing'
  grep -Fq '## Constraints' "$TMP/source-submit.txt" || fail 'Jim submit constraints heading is missing'
  printf 'ok - Jim source hash and submit headings match the translation map\n'
fi

#!/usr/bin/env bash
# tests/codex-jim-lavish.test.sh - structural fidelity checks for Jim's Lavish and Oat port.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

LAVISH="$ROOT/.agents/skills/lavish/SKILL.md"
EVALS="$ROOT/.agents/skills/lavish/evals.md"
DECISION="$ROOT/.agents/skills/lavish/references/decision-zone.md"
SIDEBAR="$ROOT/.agents/skills/lavish/references/nav-sidebar.md"
OAT="$ROOT/.agents/skills/oat/SKILL.md"

for file in "$LAVISH" "$EVALS" "$DECISION" "$SIDEBAR" "$OAT"; do
  [ -f "$file" ] || fail "missing required file: $file"
done
pass "all assigned Lavish and Oat files exist"

assert_grep 'data/operating-model/components/david-warm.html' "$LAVISH" "Lavish does not point to David-warm"
assert_grep 'data/operating-model/components/david-warm.html' "$OAT" "Oat does not point to David-warm"
# shellcheck disable=SC2016
assert_grep 'Copy each required component from its `COPY VERBATIM` marker' "$OAT" "Oat lost verbatim component copying"
assert_no_grep '#F0EEE6' "$OAT" "Jim's old oat background leaked into Oat"
assert_no_grep '#CC785C' "$OAT" "Jim's old clay token leaked into Oat"
assert_no_grep '--oat:' "$OAT" "Jim's old oat token leaked into Oat"
pass "David-warm is the only visual style source"

assert_grep 'references/decision-zone.md' "$LAVISH" "Lavish lost the decision-zone Read pin"
assert_grep 'references/nav-sidebar.md' "$LAVISH" "Lavish lost the nav-sidebar Read pin"
assert_grep 'Recommended option is first and preselected' "$LAVISH" "Recommended-first invariant is missing"
assert_grep 'Decided log' "$LAVISH" "decided-tab retirement is missing"
assert_grep 'Every short-answer question gets a real textarea' "$LAVISH" "typed response surface is missing"
assert_grep 'append' "$LAVISH" "append-only checkpoint history is missing"
# shellcheck disable=SC2016
assert_grep 'The sidebar has exactly `Main`, `Rounds`, and `Decisions` groups.' "$LAVISH" "three-group sidebar invariant is missing"
pass "Lavish preserves Jim's decision and checkpoint structure"

assert_grep 'navigator.clipboard.writeText' "$DECISION" "clipboard primary path is missing"
assert_grep "document.execCommand('copy')" "$DECISION" "clipboard fallback path is missing"
assert_grep 'Command-C' "$DECISION" "manual clipboard fallback is missing"
assert_grep 'IntersectionObserver' "$SIDEBAR" "sidebar scrollspy is missing"
assert_grep 'overflow-y:auto' "$SIDEBAR" "independent rail scrolling is missing"
assert_grep '1150' "$SIDEBAR" "paired desktop breakpoint is missing"
assert_grep '&#10003;' "$SIDEBAR" "canonical done glyph is missing"
assert_grep '&middot;' "$SIDEBAR" "canonical round-label separator is missing"
pass "progressive-disclosure references retain their mechanical behaviors"

assert_grep 'lavish-axi <html-file>' "$LAVISH" "existing lavish-axi delivery path is missing"
assert_grep 'lavish-axi poll <html-file>' "$LAVISH" "lavish-axi feedback loop is missing"
assert_no_grep 'lavish-axi share' "$OAT" "Oat suggests the outward Lavish share path"
assert_no_grep 'ht-ml.app' "$OAT" "Oat suggests a public HTML host"
# shellcheck disable=SC2016
assert_grep 'Do not run `lavish-axi share`' "$LAVISH" "outbound share fence is missing"
pass "Lavish keeps local delivery and the outward-action fence"

for file in "$LAVISH" "$EVALS" "$DECISION" "$SIDEBAR" "$OAT"; do
  if LC_ALL=C grep -n $'\342\200\224\|\342\200\223' "$file" >/dev/null; then
    fail "em or en dash found in $file"
  fi
done
pass "tracked prose contains no em or en dash"

assert_no_grep '/.claude/' "$LAVISH" "Claude path leaked into Lavish"
assert_no_grep '.agents/skills-spine' "$LAVISH" "abandoned spine path leaked into Lavish"
assert_no_grep '/.claude/' "$OAT" "Claude path leaked into Oat"
assert_no_grep '.agents/skills-spine' "$OAT" "abandoned spine path leaked into Oat"
pass "Codex skill paths contain no Claude artifact target"

assert_grep 'wrappingWidth' "$OAT" "Mermaid wrapping-width invariant is missing"
assert_grep '-w 1800' "$OAT" "Mermaid render viewport invariant is missing"
assert_grep 'viewBox="0 0 1150 520"' "$OAT" "cycle geometry invariant is missing"
pass "Oat preserves Jim's diagram and cycle mechanics"

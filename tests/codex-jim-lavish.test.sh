#!/usr/bin/env bash
set -euo pipefail

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

LAVISH="$ROOT/.agents/skills/lavish/SKILL.md"
EVALS="$ROOT/.agents/skills/lavish/evals.md"
OAT="$ROOT/.agents/skills/oat/SKILL.md"
DECISION="$ROOT/.agents/skills/lavish/references/decision-zone.md"
SIDEBAR="$ROOT/.agents/skills/lavish/references/nav-sidebar.md"
INSTALLER="$ROOT/.agents/skills/lavish/scripts/install-components.py"
VALIDATOR="$ROOT/.agents/skills/lavish/scripts/validate-contract.py"
CANONICAL=${DAVID_WARM_COMPONENT_FILE:-$ROOT/data/operating-model/components/david-warm.html}
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

for file in "$LAVISH" "$EVALS" "$OAT" "$DECISION" "$SIDEBAR" "$INSTALLER" "$VALIDATOR" "$CANONICAL"; do
  [ -f "$file" ] || fail "missing required file: $file"
done

python3 - "$CANONICAL" "$tmp/crlf.html" <<'PY'
import pathlib
import sys

source = pathlib.Path(sys.argv[1]).read_bytes().replace(b"\r\n", b"\n")
path = pathlib.Path(sys.argv[2])
path.write_bytes(source.replace(b"\n", b"\r\n"))
path.chmod(0o754)
PY
cp "$tmp/crlf.html" "$tmp/crlf-original.html"
python3 "$INSTALLER" "$tmp/crlf.html" >"$tmp/install-first.out"
first_sha=$(shasum -a 256 "$tmp/crlf.html" | awk '{print $1}')
python3 "$INSTALLER" "$tmp/crlf.html" >"$tmp/install-second.out"
second_sha=$(shasum -a 256 "$tmp/crlf.html" | awk '{print $1}')
[ "$first_sha" = "$second_sha" ] || fail "component installer is not idempotent"
[ "$(python3 -c 'import os,stat,sys; print(oct(stat.S_IMODE(os.stat(sys.argv[1]).st_mode))[2:])' "$tmp/crlf.html")" = 754 ] || fail "installer changed source mode"
python3 - "$tmp/crlf-original.html" "$tmp/crlf.html" <<'PY'
import pathlib
import sys

before = pathlib.Path(sys.argv[1]).read_bytes()
after = pathlib.Path(sys.argv[2]).read_bytes()
close = before.rfind(b"</div>")
assert close >= 0
assert after.startswith(before[:close])
assert after.endswith(before[close:])
assert b"\n" not in after.replace(b"\r\n", b"")
assert b"COPY VERBATIM: DECISION ZONE" in after
assert b"COPY VERBATIM: DYNAMIC SIDEBAR" in after
assert b"COPY VERBATIM: EXECUTABLE MERMAID" not in after
PY
pass "installer preserves mode, CRLF line endings, untouched bytes, and idempotence"

python3 "$INSTALLER" "$CANONICAL" --output "$tmp/lf.html" >"$tmp/install-lf.out"
[ "$(python3 -c 'import os,stat,sys; print(oct(stat.S_IMODE(os.stat(sys.argv[1]).st_mode))[2:])' "$tmp/lf.html")" = "$(python3 -c 'import os,stat,sys; print(oct(stat.S_IMODE(os.stat(sys.argv[1]).st_mode))[2:])' "$CANONICAL")" ] || fail "output copy changed source mode"

printf '<html><p>unsafe</p></html>\n' >"$tmp/unsafe.html"
if python3 "$INSTALLER" "$tmp/unsafe.html" >"$tmp/unsafe.out" 2>"$tmp/unsafe.err"; then
  fail "installer accepted an unknown substrate"
fi
assert_grep 'unknown or unsafe substrate' "$tmp/unsafe.err" "unsafe substrate failure is not explicit"

python3 - "$tmp/lf.html" "$tmp/fixture.html" "$tmp/components" <<'PY'
import pathlib
import re
import sys

canonical = pathlib.Path(sys.argv[1]).read_text(encoding="utf-8")
fixture = pathlib.Path(sys.argv[2])
directory = pathlib.Path(sys.argv[3])
directory.mkdir()

def block(name):
    pattern = re.compile(rf"<!-- =+ COPY VERBATIM: {re.escape(name)} =+ -->.*?<!-- =+ /COPY VERBATIM: {re.escape(name)} =+ -->", re.DOTALL)
    matches = pattern.findall(canonical)
    assert len(matches) == 1
    value = matches[0]
    (directory / f"{name.lower().replace(' ', '-')}.html").write_bytes(value.encode())
    return value

decision = block("DECISION ZONE")
sidebar = block("DYNAMIC SIDEBAR")
for token in ("What", "Why now", "Why / why not", "Cost / risk", "david-warm-option-template", "david-warm-question-template", "spec.options.length < 2", "spec.options.length > 4", "spec.options.forEach", "input.checked = index === 0", "fallback.hidden = false", "fallback.select()", "<details", "tabbar.offsetTop", "press Command-C", "[data-decision]", "[data-question]"):
    assert token in decision
for forbidden in ("for (const id of ['D1','D2'])", "data-question=\"Q1\""):
    assert forbidden not in decision

page = f'''<!doctype html><meta charset="utf-8">
<main id="main" data-nav="main|&#9679;|Summary"></main>
<section id="round-7" data-nav="round|&#10003;|R7 &middot; result"></section>
<section id="decision-7" data-nav="decision|&#9675;|Open decisions">
<div class="tabbar"><button data-tab="pane-d7"><span data-badge-for="D7"></span></button></div>
<section class="tab on" id="pane-d7"><input data-decision="D7" type="radio" name="D7" value="O9" checked><input data-decision="D7" type="checkbox" value="O12"><input data-note="D7"><textarea data-question="Q4"></textarea></section>
</section>
{decision}
{sidebar}'''
fixture.write_text(page, encoding="utf-8")
assert decision.encode() in fixture.read_bytes()
assert sidebar.encode() in fixture.read_bytes()
scripts = re.findall(r"<script>(.*?)</script>", page, re.DOTALL)
for index, script in enumerate(scripts):
    (directory / f"script-{index}.js").write_text(script, encoding="utf-8")
PY
for script in "$tmp"/components/script-*.js; do
  node --check "$script"
done
pass "deterministic fixture supports arbitrary IDs and byte-identical generic components"

cp "$tmp/lf.html" "$tmp/duplicate.html"
python3 - "$tmp/duplicate.html" <<'PY'
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
text = path.read_text(encoding="utf-8")
marker = "<!-- ==================== COPY VERBATIM: DECISION ZONE ====================== -->"
assert text.count(marker) == 1
path.write_text(text.replace(marker, marker + "\n" + marker, 1), encoding="utf-8")
PY
if python3 "$INSTALLER" "$tmp/duplicate.html" >"$tmp/duplicate.out" 2>"$tmp/duplicate.err"; then
  fail "installer accepted duplicate canonical markers"
fi
assert_grep 'duplicate DECISION ZONE component marker' "$tmp/duplicate.err" "duplicate marker failure is not explicit"
pass "installer rejects duplicate canonical markers"

python3 "$VALIDATOR" --lavish "$LAVISH" --evals "$EVALS" --oat "$OAT" --decision "$DECISION" --sidebar "$SIDEBAR" --installer "$INSTALLER" >"$tmp/validate.out"

mutate_and_reject() {
  local label=$1 file=$2 old=$3 new=$4
  local dir="$tmp/mutation-$label"
  mkdir -p "$dir"
  cp "$LAVISH" "$dir/lavish.md"
  cp "$EVALS" "$dir/evals.md"
  cp "$OAT" "$dir/oat.md"
  cp "$DECISION" "$dir/decision.md"
  cp "$SIDEBAR" "$dir/sidebar.md"
  cp "$INSTALLER" "$dir/installer.py"
  python3 - "$dir/$file" "$old" "$new" <<'PY'
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
text = path.read_text(encoding="utf-8")
assert sys.argv[2] in text
path.write_text(text.replace(sys.argv[2], sys.argv[3], 1), encoding="utf-8")
PY
  if python3 "$VALIDATOR" --lavish "$dir/lavish.md" --evals "$dir/evals.md" --oat "$dir/oat.md" --decision "$dir/decision.md" --sidebar "$dir/sidebar.md" --installer "$dir/installer.py" >"$dir/out" 2>"$dir/err"; then
    fail "validator accepted mutation: $label"
  fi
}

swap_and_reject() {
  local label=$1 file=$2 first=$3 second=$4 expected=$5
  local dir="$tmp/mutation-$label"
  mkdir -p "$dir"
  cp "$LAVISH" "$dir/lavish.md"
  cp "$EVALS" "$dir/evals.md"
  cp "$OAT" "$dir/oat.md"
  cp "$DECISION" "$dir/decision.md"
  cp "$SIDEBAR" "$dir/sidebar.md"
  cp "$INSTALLER" "$dir/installer.py"
  python3 - "$dir/$file" "$first" "$second" <<'PY'
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
text = path.read_text(encoding="utf-8")
first, second = sys.argv[2:4]
assert first in text and second in text
placeholder = "__LAVISH_MUTATION_SWAP__"
assert placeholder not in text
text = text.replace(first, placeholder, 1)
text = text.replace(second, first, 1)
text = text.replace(placeholder, second, 1)
path.write_text(text, encoding="utf-8")
PY
  if python3 "$VALIDATOR" --lavish "$dir/lavish.md" --evals "$dir/evals.md" --oat "$dir/oat.md" --decision "$dir/decision.md" --sidebar "$dir/sidebar.md" --installer "$dir/installer.py" >"$dir/out" 2>"$dir/err"; then
    fail "validator accepted mutation: $label"
  fi
  if ! grep -Fq -- "$expected" "$dir/err"; then
    cat "$dir/err" >&2
    fail "validator rejected mutation for the wrong reason: $label"
  fi
}

# Literal backticks and dollar signs are intentional mutation targets.
# shellcheck disable=SC2016
mutate_and_reject module-order lavish.md 'Read `.agents/skills/oat/SKILL.md`' 'Load the style guide'
# shellcheck disable=SC2016
mutate_and_reject trigger evals.md '$lavish discuss the dashboard design here' 'discuss the dashboard design here'
mutate_and_reject recommended lavish.md 'The Recommended option is first and preselected.' 'The Recommended option may appear anywhere.'
mutate_and_reject textarea lavish.md 'Every short-answer question gets a real textarea wired into the reply bar.' 'Short answers use plain text.'
mutate_and_reject stable-path lavish.md 'Keep one stable file path per workstream.' 'Create a new path per round.'
mutate_and_reject append-only lavish.md 'Keep one mutable current-round section directly after the page header and an append-only chronological history of completed rounds below it.' 'Keep only the latest round.'
mutate_and_reject move-without-duplication lavish.md 'At a round transition, append the completed section to history before creating the next current section; move it rather than duplicating it.' 'Duplicate the completed section in history.'
mutate_and_reject real-resume lavish.md 'Claim session resume only after a real open, update, and reopen returns evidence for the same session identity.' 'Assume session resume.'
mutate_and_reject checkpoint-orientation lavish.md '### Checkpoint orientation' '### Decision preface'
swap_and_reject orientation-before-summary lavish.md '### Checkpoint orientation' '### Short summary' 'checkpoint orientation must precede the short summary'
# shellcheck disable=SC2016
mutate_and_reject orientation-mandatory lavish.md 'Every checkpoint begins immediately after the page header with one mutable current-round section.' 'A checkpoint may include a current-round section.'
# shellcheck disable=SC2016
mutate_and_reject current-round-table-placement lavish.md "Its round heading is followed immediately by that round's visible \`Where you are\` table before the short summary, evidence, or decisions." 'The current round may use one page-level table outside its section.'
# shellcheck disable=SC2016
mutate_and_reject round-exactly-once lavish.md 'Each round appears exactly once on the page.' 'A round may appear twice on the page.'
# shellcheck disable=SC2016
mutate_and_reject orientation-never-hidden lavish.md 'The tables are never hidden in a fold or tab.' 'The tables may be hidden in a fold or tab.'
# shellcheck disable=SC2016
mutate_and_reject per-round-orientation lavish.md "Every preserved earlier-round section also begins with its own visible \`Where you are\` table immediately after the round heading and before that round's summary, evidence, or decisions." 'Only the current round needs an orientation table.'
# shellcheck disable=SC2016
mutate_and_reject frozen-round-orientation lavish.md "When the next round begins, freeze the completed round's table with that round's final state, move the complete section into chronological history, and create a fresh current-round section at the top." 'Rewrite every table to show the newest state.'
# shellcheck disable=SC2016
mutate_and_reject refresh-round-orientation lavish.md 'Refresh all seven rows when a new round begins so the table is a truthful snapshot of that round.' 'Reuse the previous round table unchanged.'
# shellcheck disable=SC2016
mutate_and_reject current-round-field lavish.md '- `Current round`: the present phase, what is proven or unproven, and why David is being asked to decide now.' '- `Round status`: optional context.'
# shellcheck disable=SC2016
mutate_and_reject active-round-refresh lavish.md 'While a round is active, update its `Current round` row and any changed boundary in place.' 'While a round is active, leave its current state stale.'
# shellcheck disable=SC2016
mutate_and_reject complete-round-log lavish.md "The preserved content includes that round's seven-row orientation table, evidence, decisions, findings, and outcome." 'Preserve only the latest outcome.'
# shellcheck disable=SC2016
mutate_and_reject no-prior-round-rewrite lavish.md 'Never rewrite an earlier round to match the current state, remove it after supersession, or replace the page with only the latest round.' 'Rewrite earlier rounds to match the current state.'
# shellcheck disable=SC2016
mutate_and_reject discarded-work-preservation lavish.md 'Keep discarded work in its original round and mark its verdict `DISCARDED` with the reason.' 'Remove discarded work.'
# shellcheck disable=SC2016
mutate_and_reject orientation-outside-fold lavish.md 'Older round bodies may use `details` folds but may not disappear, and their round heading plus seven-row orientation table stay unfolded.' 'Older rounds may hide their entire sections in details folds.'
# shellcheck disable=SC2016
mutate_and_reject project-field lavish.md '`Project`' '`Repo name`'
# shellcheck disable=SC2016
mutate_and_reject ticket-field lavish.md '`Ticket`' '`Issue`'
# shellcheck disable=SC2016
mutate_and_reject bigger-picture-field lavish.md '`Bigger picture`' '`Motivation`'
# shellcheck disable=SC2016
mutate_and_reject system-position-field lavish.md '`System position`' '`Pipeline slot`'
# shellcheck disable=SC2016
mutate_and_reject whole-ticket-success lavish.md '`Whole-ticket success`' '`Round success`'
# shellcheck disable=SC2016
mutate_and_reject scope-boundaries-field lavish.md '`Scope boundaries`' '`Boundaries`'
# shellcheck disable=SC2016
mutate_and_reject orientation-eval evals.md "The single current-round section and every preserved earlier round began with that round's visible, unfolded \`Where you are\` table containing Project, Ticket, Bigger picture, System position, Whole-ticket success, Current round, and Scope boundaries before its summary, evidence, or decisions." 'A checkpoint may include a brief orientation.'
mutate_and_reject round-log-eval evals.md "The round-N page contains exactly one mutable current-round section plus N-1 complete chronological history sections, including each round's frozen seven-row orientation snapshot, evidence, decisions, findings, and outcome; earlier round bodies may fold without deletion or current-state rewriting." 'The round-N page may replace earlier rounds.'
mutate_and_reject style-owner oat.md 'only source of visual tokens and components' 'one optional source of visual tokens and components'
# shellcheck disable=SC2016
mutate_and_reject arbitrary-ids decision.md 'arbitrary page-scoped `Dn`, `On`, and `Qn`' 'fixed D1 and D2 identifiers'
mutate_and_reject decision-source decision.md 'DAVID_WARM_COMPONENT_FILE' 'hardcoded component path'
mutate_and_reject sidebar-source sidebar.md 'DAVID_WARM_COMPONENT_FILE' 'hardcoded component path'
mutate_and_reject nav-fields sidebar.md 'data-nav="<group>|<status-glyph>|<label>"' 'data-nav="<status>|<label>"'
mutate_and_reject nav-parser installer.py "const [group,status,label] = section.dataset.nav.split('|');" "const [status,label] = section.dataset.nav.split('|');"
mutate_and_reject option-range installer.py 'spec.options.length < 2 || spec.options.length > 4' 'spec.options.length < 1 || spec.options.length > 6'
mutate_and_reject option-repeat installer.py 'spec.options.forEach((option, index) =>' 'spec.options.slice(0, 1).forEach((option, index) =>'
mutate_and_reject recommended-gate installer.py 'spec.options[0].recommended !== true' 'spec.options[0].recommended === true'
mutate_and_reject checked-state installer.py 'input.checked = index === 0;' 'input.checked = false;'
mutate_and_reject question-template installer.py '<textarea class="qtext" data-question="{{Q_ID}}"' '<div class="qtext" data-question="{{Q_ID}}"'
mutate_and_reject input-binding installer.py 'bindInputs(fragment);' 'compose();'
mutate_and_reject fallback-visible installer.py 'fallback.hidden = false;' 'fallback.hidden = true;'
mutate_and_reject fallback-select installer.py 'fallback.select();' 'area.select();'
mutate_and_reject manual-visible installer.py 'instruction.hidden = false;' 'instruction.hidden = true;'
mutate_and_reject duplicate-markers installer.py 'if open_count > 1 or close_count > 1:' 'if open_count > 2 or close_count > 2:'
pass "hostile mutations protect component ownership and Lavish interaction contracts"

assert_no_grep 'COPY VERBATIM: EXECUTABLE MERMAID' "$OAT" "Oat claims unverified executable Mermaid"
assert_no_grep 'wrappingWidth' "$OAT" "Oat carries a conflicting Mermaid width literal"
assert_no_grep '#FFFFFF' "$OAT" "Oat carries a conflicting Mermaid background literal"
assert_no_grep 'lavish-axi share' "$OAT" "Oat suggests outward sharing"

if grep -Fq 'COPY VERBATIM: DECISION ZONE' "$CANONICAL"; then
  echo "CANONICAL_UPGRADE=INSTALLED_OUTSIDE_THIS_LANE"
else
  echo "CANONICAL_UPGRADE=BLOCKED_PENDING_INDEPENDENT_REVIEW"
fi
echo "BROWSER_GATE=BLOCKED_NO_RENDER_CLAIM"
echo "LAVISH_SESSION_RESUME=BLOCKED_NO_REAL_SESSION_EVIDENCE"
echo "PASS: deterministic Lavish component and contract suite"

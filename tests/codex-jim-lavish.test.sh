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
[ "$(stat -f '%Lp' "$tmp/crlf.html")" = 754 ] || fail "installer changed source mode"
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
[ "$(stat -f '%Lp' "$tmp/lf.html")" = "$(stat -f '%Lp' "$CANONICAL")" ] || fail "output copy changed source mode"

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
for token in ("What", "Why now", "Why / why not", "Cost / risk", "{{BENEFIT}}", "{{COST}}", "<details", "tabbar.offsetTop", "press Command-C", "[data-decision]", "[data-question]"):
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

python3 "$VALIDATOR" --lavish "$LAVISH" --evals "$EVALS" --oat "$OAT" --decision "$DECISION" --sidebar "$SIDEBAR" >"$tmp/validate.out"

mutate_and_reject() {
  local label=$1 file=$2 old=$3 new=$4
  local dir="$tmp/mutation-$label"
  mkdir -p "$dir"
  cp "$LAVISH" "$dir/lavish.md"
  cp "$EVALS" "$dir/evals.md"
  cp "$OAT" "$dir/oat.md"
  cp "$DECISION" "$dir/decision.md"
  cp "$SIDEBAR" "$dir/sidebar.md"
  python3 - "$dir/$file" "$old" "$new" <<'PY'
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
text = path.read_text(encoding="utf-8")
assert sys.argv[2] in text
path.write_text(text.replace(sys.argv[2], sys.argv[3], 1), encoding="utf-8")
PY
  if python3 "$VALIDATOR" --lavish "$dir/lavish.md" --evals "$dir/evals.md" --oat "$dir/oat.md" --decision "$dir/decision.md" --sidebar "$dir/sidebar.md" >"$dir/out" 2>"$dir/err"; then
    fail "validator accepted mutation: $label"
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
mutate_and_reject append-only lavish.md 'Each round appends a section and preserves all prior round content.' 'Each round replaces prior content.'
mutate_and_reject real-resume lavish.md 'Claim session resume only after a real open, update, and reopen returns evidence for the same session identity.' 'Assume session resume.'
mutate_and_reject style-owner oat.md 'only source of visual tokens and components' 'one optional source of visual tokens and components'
# shellcheck disable=SC2016
mutate_and_reject arbitrary-ids decision.md 'arbitrary page-scoped `Dn`, `On`, and `Qn`' 'fixed D1 and D2 identifiers'
mutate_and_reject decision-source decision.md 'DAVID_WARM_COMPONENT_FILE' 'hardcoded component path'
mutate_and_reject sidebar-source sidebar.md 'DAVID_WARM_COMPONENT_FILE' 'hardcoded component path'
mutate_and_reject dynamic-sidebar sidebar.md 'Build round links at load time' 'Maintain a hand-written round list'
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

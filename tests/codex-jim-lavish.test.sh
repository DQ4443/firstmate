#!/usr/bin/env bash
set -euo pipefail

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

LAVISH="$ROOT/.agents/skills/lavish/SKILL.md"
EVALS="$ROOT/.agents/skills/lavish/evals.md"
OAT="$ROOT/.agents/skills/oat/SKILL.md"
INSTALLER="$ROOT/.agents/skills/lavish/scripts/install-components.py"
VALIDATOR="$ROOT/.agents/skills/lavish/scripts/validate-contract.py"
CANONICAL=${DAVID_WARM_COMPONENT_FILE:-$ROOT/data/operating-model/components/david-warm.html}
tmp=$(mktemp -d)
session="codex-lavish-$$"
trap 'rm -rf "$tmp"' EXIT

for file in "$LAVISH" "$EVALS" "$OAT" "$INSTALLER" "$VALIDATOR" "$CANONICAL"; do
  [ -f "$file" ] || fail "missing required file: $file"
done

python3 "$INSTALLER" "$CANONICAL" --output "$tmp/david-warm.html" >"$tmp/install-first.out"
first_sha=$(shasum -a 256 "$tmp/david-warm.html" | awk '{print $1}')
python3 "$INSTALLER" "$tmp/david-warm.html" >"$tmp/install-second.out"
second_sha=$(shasum -a 256 "$tmp/david-warm.html" | awk '{print $1}')
[ "$first_sha" = "$second_sha" ] || fail "component installer is not idempotent"

printf '<html><p>unsafe</p></html>\n' >"$tmp/unsafe.html"
if python3 "$INSTALLER" "$tmp/unsafe.html" >"$tmp/unsafe.out" 2>"$tmp/unsafe.err"; then
  fail "installer accepted an unknown substrate"
fi
assert_grep 'unknown or unsafe substrate' "$tmp/unsafe.err" "unsafe substrate failure is not explicit"

python3 - "$tmp/david-warm.html" "$tmp/fixture.html" "$tmp/components" "$CANONICAL" <<'PY'
import pathlib
import re
import sys

canonical = pathlib.Path(sys.argv[1]).read_text(encoding="utf-8")
fixture = pathlib.Path(sys.argv[2])
component_dir = pathlib.Path(sys.argv[3])
original = pathlib.Path(sys.argv[4]).read_text(encoding="utf-8")
component_dir.mkdir()
names = [
    "TOKENS",
    "BASE RESET + ELEMENTS",
    "CARD",
    "YOUR-CALL BLOCK",
    "DECISION ZONE",
    "DYNAMIC SIDEBAR",
    "EXECUTABLE MERMAID",
]

def block(name):
    pattern = re.compile(
        rf"<!-- =+ COPY VERBATIM: {re.escape(name)} =+ -->.*?<!-- =+ /COPY VERBATIM: {re.escape(name)} =+ -->",
        re.DOTALL,
    )
    matches = pattern.findall(canonical)
    assert len(matches) == 1, (name, len(matches))
    value = matches[0]
    (component_dir / f"{name.lower().replace(' ', '-').replace('+', 'plus')}.html").write_bytes(value.encode())
    return value

parts = {name: block(name) for name in names}
close = original.rfind("</div>")
assert close >= 0
assert canonical.startswith(original[:close])
assert canonical.endswith(original[close:])
rounds = "\n".join(
    f'<section id="r{i}" data-nav="round|&#10003;|R{i} &middot; result"><h2>Round {i}</h2><p>Evidence.</p></section>'
    for i in range(1, 41)
)
page = f'''<!doctype html><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
{parts["TOKENS"]}
{parts["BASE RESET + ELEMENTS"]}
{parts["CARD"]}
{parts["YOUR-CALL BLOCK"]}
<div class="page-shell"><div></div><main>
<section id="main" data-nav="main|&#9679;|Summary"><h1>Representative Lavish checkpoint</h1></section>
<section id="pipeline"><h2>Final pipeline</h2>{parts["EXECUTABLE MERMAID"]}</section>
{rounds}
<section id="decisions" data-nav="decision|&#9675;|Open decisions">{parts["DECISION ZONE"]}</section>
</main>{parts["DYNAMIC SIDEBAR"]}</div>
<script>
window.__mermaid = {{initialize:c => window.__mermaidConfig=c,run:async o => window.__mermaidRun=o.querySelector}};
window.renderDavidWarmMermaid(window.__mermaid);
</script>'''
fixture.write_text(page, encoding="utf-8")
for name in ("DECISION ZONE", "DYNAMIC SIDEBAR", "EXECUTABLE MERMAID"):
    copied = parts[name].encode()
    assert copied in fixture.read_bytes()
    assert copied == (component_dir / f"{name.lower().replace(' ', '-').replace('+', 'plus')}.html").read_bytes()
PY
pass "installer is idempotent, rejects unsafe substrates, and supports byte-exact component copies"

mkdir -p "$tmp/bin"
python3 - "$tmp/bin/lavish-axi" <<'PY'
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
path.write_text("#!/bin/sh\nprintf '%s\\n' \"$*\" >> \"$LAVISH_STUB_LOG\"\n", encoding="utf-8")
path.chmod(0o755)
PY
LAVISH_STUB_LOG="$tmp/lavish.log" PATH="$tmp/bin:$PATH" lavish-axi "$tmp/fixture.html"
LAVISH_STUB_LOG="$tmp/lavish.log" PATH="$tmp/bin:$PATH" lavish-axi "$tmp/fixture.html"
[ "$(wc -l <"$tmp/lavish.log" | tr -d ' ')" = 2 ] || fail "lavish local stub did not record two opens"
[ "$(sort -u "$tmp/lavish.log" | wc -l | tr -d ' ')" = 1 ] || fail "lavish did not resume the stable path"
assert_no_grep 'share' "$tmp/lavish.log" "local delivery invoked sharing"
pass "stable-path lavish open and resume stay local"

python3 - "$tmp/fixture.html" "$tmp/scripts" <<'PY'
import pathlib
import re
import sys

page = pathlib.Path(sys.argv[1]).read_text(encoding="utf-8")
directory = pathlib.Path(sys.argv[2])
directory.mkdir()
scripts = re.findall(r"<script>(.*?)</script>", page, re.DOTALL)
assert len(scripts) >= 4
for index, script in enumerate(scripts):
    (directory / f"script-{index}.js").write_text(script, encoding="utf-8")
assert 'type="radio"' in page
assert 'type="checkbox"' in page
assert 'class="dnote"' in page
assert 'class="qtext"' in page
assert 'data-tab="d2"' in page
assert "document.execCommand('copy')" in page
assert "IntersectionObserver" in page
assert "overflow-y:auto" in page
assert "window.renderDavidWarmMermaid" in page
PY
for script in "$tmp"/scripts/*.js; do
  node --check "$script"
done
pass "deterministic fixture contains syntactically valid interaction modules"

if [ "${RUN_LAVISH_BROWSER:-0}" = 1 ]; then
  export CHROME_DEVTOOLS_AXI_SESSION="$session"
  chrome-devtools-axi open "file://$tmp/fixture.html" >"$tmp/browser-open.out"
  chrome-devtools-axi resize 900 700 >"$tmp/browser-resize.out"
  chrome-devtools-axi eval '(() => {
  document.querySelector("input[name=D1][value=O2]").click();
  document.querySelector("input[data-decision=D2][value=O2]").click();
  const note=document.querySelector("[data-note=D1]"); note.value="ship carefully"; note.dispatchEvent(new Event("input",{bubbles:true}));
  const q=document.querySelector("[data-question=Q1]"); q.value="keep history"; q.dispatchEvent(new Event("input",{bubbles:true}));
  document.querySelector("[data-tab=d2]").click();
  window.__forceClipboardFailure=true;
  document.execCommand=command => command === "copy";
  document.getElementById("copy-reply").click();
  return new Promise(resolve => setTimeout(() => {
    const rail=document.getElementById("dynamic-side");
    resolve(JSON.stringify({
      radio:document.querySelector("input[name=D1][value=O2]").checked,
      checkbox:document.querySelector("input[data-decision=D2][value=O2]").checked,
      note:note.value,textarea:q.value,tab:document.getElementById("d2").classList.contains("on"),
      reply:document.getElementById("reply").textContent,copy:window.__copyPath,
      groups:[...rail.querySelectorAll(".nav-title")].map(x=>x.textContent),
      links:rail.querySelectorAll("a").length,scrollable:getComputedStyle(rail).overflowY,
      mermaidInit:!!window.__mermaidConfig,mermaidRun:window.__mermaidRun
    }));
  },80));
})()' >"$tmp/browser-eval.out"
  chrome-devtools-axi screenshot "$tmp/lavish.png" >"$tmp/browser-shot.out"
  [ -s "$tmp/lavish.png" ] || fail "browser screenshot is missing"
  for token in '"radio":true' '"checkbox":true' 'ship carefully' 'keep history' '"tab":true' 'D1: O2 (ship carefully)' 'D2: O1+O2' 'Q1: keep history' '"copy":"execCommand"' 'Main' 'Rounds' 'Decisions' '"links":42' '"scrollable":"auto"' '"mermaidInit":true' '"mermaidRun":".mermaid"'; do
    assert_grep "$token" "$tmp/browser-eval.out" "browser interaction missing: $token"
  done
  pass "real Chrome rendered and exercised decisions, notes, textarea, tabs, Copy fallback, sidebar, Mermaid, and screenshot"
else
  echo "BROWSER_BLOCKED: chrome-devtools-axi startup terminated the isolated execution cell after about 28 seconds with no stdout or stderr; set RUN_LAVISH_BROWSER=1 on a host where the bridge starts successfully"
fi

python3 "$VALIDATOR" --lavish "$LAVISH" --evals "$EVALS" --oat "$OAT" >"$tmp/validate.out"

mutate_and_reject() {
  local label=$1 file=$2 old=$3 new=$4
  local dir="$tmp/mutation-$label"
  mkdir -p "$dir"
  cp "$LAVISH" "$dir/lavish.md"
  cp "$EVALS" "$dir/evals.md"
  cp "$OAT" "$dir/oat.md"
  python3 - "$dir/$file" "$old" "$new" <<'PY'
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
text = path.read_text(encoding="utf-8")
assert sys.argv[2] in text
path.write_text(text.replace(sys.argv[2], sys.argv[3], 1), encoding="utf-8")
PY
  if python3 "$VALIDATOR" --lavish "$dir/lavish.md" --evals "$dir/evals.md" --oat "$dir/oat.md" >"$dir/out" 2>"$dir/err"; then
    fail "validator accepted mutation: $label"
  fi
}

# Literal dollar signs and backticks are intentional mutation targets.
# shellcheck disable=SC2016
mutate_and_reject module-order lavish.md 'Read `.agents/skills/oat/SKILL.md`' 'Load the style guide'
# shellcheck disable=SC2016
mutate_and_reject lavish-trigger evals.md '$lavish discuss the dashboard design here' 'discuss the dashboard design here'
# shellcheck disable=SC2016
mutate_and_reject d1-ids lavish.md 'Use stable page-scoped IDs `D1`, `D2`, and later.' 'Use arbitrary identifiers.'
mutate_and_reject notes lavish.md 'Every block ends with a free-text note input wired into the reply bar.' 'Notes are optional.'
mutate_and_reject report-diagram lavish.md 'The first content section after the short summary is a rendered diagram' 'A later section is a rendered diagram'
mutate_and_reject append-history lavish.md 'Each round appends a section and preserves all prior round content.' 'Each round replaces the previous section.'
# shellcheck disable=SC2016
mutate_and_reject outbound-share lavish.md 'Do not run `lavish-axi share`' 'Sharing is allowed'
mutate_and_reject outbound-send lavish.md "do not send the file externally without David's explicit word" 'external sending is allowed'
# shellcheck disable=SC2016
mutate_and_reject mermaid-owner oat.md 'Pages with directed graphs copy `COPY VERBATIM: EXECUTABLE MERMAID` verbatim.' 'Pages with directed graphs use local Mermaid settings.'
pass "hostile mutations protect module order, triggers, IDs, notes, report order, history, and outbound gates"

for file in "$LAVISH" "$EVALS" "$OAT" "$INSTALLER" "$VALIDATOR"; do
  if LC_ALL=C grep -n $'\342\200\224\|\342\200\223' "$file" >/dev/null; then
    fail "em or en dash found in $file"
  fi
done
assert_no_grep 'wrappingWidth' "$OAT" "Oat carries a conflicting Mermaid width literal"
assert_no_grep '#FFFFFF' "$OAT" "Oat carries a conflicting Mermaid background literal"
assert_no_grep 'lavish-axi share' "$OAT" "Oat suggests outward sharing"
pass "portable tracked files avoid local Mermaid literals and outward actions"

echo "PASS: Lavish and Oat adversarial fixture and contract suite"

#!/bin/sh
set -eu

repo_root=$(git rev-parse --show-toplevel)
source_file=${JIM_RIG_SOURCE:-/Users/dq4443/Downloads/message (4).txt}
scripts="$repo_root/.agents/skills/rig-atlas/scripts"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT INT TERM

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

python3 "$scripts/source-audit.py" "$source_file" >"$tmp/audit.json"
python3 - "$tmp/audit.json" <<'PY'
import json
import sys

data = json.load(open(sys.argv[1], encoding="utf-8"))
assert data["source_line_ranges"] == ["1222-1352", "1678-3055", "3057-3505"]
assert len(data["include_both"]) == 47
assert len(data["full_only"]) == 47
assert data["exclude_both_count"] == 41
assert len(data["spine_skills"]) == 9
assert len(data["roles"]) == 3
assert data["portable_sanitizer"] == "redacted"
assert data["errors"] == []
PY

python3 "$scripts/source-audit.py" "$source_file" --setup "$tmp/state" >"$tmp/setup.json"
[ "$(find "$tmp/state/portable-memory" -type f -name '*.md' | wc -l | tr -d ' ')" = 47 ] || fail "portable extraction count"
python3 - "$tmp/state" <<'PY'
import json
import pathlib
import sys

state = pathlib.Path(sys.argv[1])
inventory = json.loads((state / "source-inventory.json").read_text())
names = {path.name for path in (state / "portable-memory").glob("*.md")}
assert names == set(inventory["include_both"])
assert not names & set(inventory["full_only"])
status = json.loads((state / "portable-status.json").read_text())
assert status["portable_twin"] == "BLOCKED"
PY

python3 "$scripts/generate-atlas.py" --repo-root "$repo_root" --state-dir "$tmp/state" >"$tmp/generate.out"
[ -f "$tmp/state/rig-atlas.md" ] || fail "full atlas missing"
[ ! -f "$tmp/state/rig-atlas-portable.md" ] || fail "portable twin unexpectedly exists"
grep -q '^# Rig Atlas$' "$tmp/state/rig-atlas.md" || fail "full atlas heading"
grep -q '^Include-both: 47\.$' "$tmp/state/rig-atlas.md" || fail "full atlas include-both count"
grep -q '^Full-only: 47\.$' "$tmp/state/rig-atlas.md" || fail "full atlas full-only count"
grep -q '^Exclude-both: 41\.$' "$tmp/state/rig-atlas.md" || fail "full atlas exclude-both count"

if python3 "$scripts/generate-atlas.py" --repo-root "$repo_root" --state-dir "$tmp/state" --portable >"$tmp/portable.out" 2>"$tmp/portable.err"; then
  fail "portable generation did not fail closed"
fi
[ ! -f "$tmp/state/rig-atlas-portable.md" ] || fail "failed portable generation left output"
grep -q 'portable sanitizer is redacted' "$tmp/portable.err" || fail "portable failure reason"

mutate_and_reject() {
  label=$1
  expression=$2
  cp "$source_file" "$tmp/$label.txt"
  python3 - "$tmp/$label.txt" "$expression" <<'PY'
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
old, new = sys.argv[2].split("|||", 1)
text = path.read_text()
assert old in text
path.write_text(text.replace(old, new, 1))
PY
  if python3 "$scripts/source-audit.py" "$tmp/$label.txt" >"$tmp/$label.out" 2>&1; then
    fail "mutation accepted: $label"
  fi
}

mutate_and_reject include-count "    'feedback-adversarial-panel-before-reviewbot.md',|||"
mutate_and_reject exclude-count "+ 41 excluded via opus-classified three-bucket rubric|||+ 40 excluded via opus-classified three-bucket rubric"
mutate_and_reject spine-roster "'rig-atlas']|||]"
mutate_and_reject sanitizer-marker "# [portable-twin sanitize pass redacted in this edition: its swap/drop lists|||# portable sanitizer implemented"
mutate_and_reject body-leak "### \`memory/feedback-adversarial-panel-before-reviewbot.md\`|||### \`memory/feedback-agent-means-tracking-not-agency.md\`"

if git check-ignore -q "$repo_root/state/rig/probe"; then
  :
else
  fail "state/rig is not ignored"
fi

if git ls-files --error-unmatch state/rig/probe >/dev/null 2>&1; then
  fail "runtime output is tracked"
fi

echo "PASS: pinned source, counts, coverage, ownership, fail-closed portable gate, and hostile mutations"

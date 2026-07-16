#!/bin/sh
set -eu

repo_root=$(git rev-parse --show-toplevel)
source_file=${JIM_RIG_SOURCE:-}
scripts="$repo_root/.agents/skills/rig-atlas/scripts"
skill="$repo_root/.agents/skills/rig-atlas/SKILL.md"
evals="$repo_root/.agents/skills/rig-atlas/evals.md"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT INT TERM

if [ -z "$source_file" ]; then
  echo "PASS: pinned Jim source audit skipped because JIM_RIG_SOURCE is not configured"
  exit 0
fi
[ -f "$source_file" ] || {
  echo "FAIL: JIM_RIG_SOURCE does not exist: $source_file" >&2
  exit 1
}

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

python3 "$scripts/source-audit.py" "$source_file" >"$tmp/audit.json"
python3 - "$tmp/audit.json" <<'PY'
import json
import sys

data = json.load(open(sys.argv[1], encoding="utf-8"))
assert data["source_line_ranges"] == ["1-244", "1222-1352", "1678-3055", "3057-3505"]
assert len(data["include_both"]) == 47
assert len(data["full_only"]) == 47
assert len(data["exclude_both"]) == 41
assert len(set(data["exclude_both"])) == 41
assert len(data["spine_skills"]) == 9
assert len(data["roles"]) == 3
assert data["portable_sanitizer"] == "redacted"
assert data["errors"] == []
assert data["integrity_sha256"]
assert data["embedded_generator_sha256"]
assert data["embedded_generator_source_lines"] == "3063-3504"
PY

python3 "$scripts/source-audit.py" "$source_file" --setup "$tmp/state" >"$tmp/setup.json"
[ "$(find "$tmp/state/portable-memory" -type f -name '*.md' | wc -l | tr -d ' ')" = 47 ] || fail "portable extraction count"
[ -f "$tmp/state/assemble_replication.py" ] || fail "embedded runtime generator missing"
[ -f "$tmp/state/assemble-replication.integrity.json" ] || fail "embedded generator integrity missing"
sed -n '3063,3504p' "$source_file" >"$tmp/expected-assemble-replication.py"
cmp "$tmp/expected-assemble-replication.py" "$tmp/state/assemble_replication.py" || fail "embedded generator is not the exact pinned source body"
PYTHONPYCACHEPREFIX="$tmp/pycache" python3 -m py_compile "$tmp/state/assemble_replication.py"
python3 "$scripts/source-audit.py" "$source_file" --verify-setup "$tmp/state" >"$tmp/verify-setup.json"
python3 - "$tmp/state" <<'PY'
import json
import pathlib
import re
import sys

state = pathlib.Path(sys.argv[1])
inventory = json.loads((state / "source-inventory.json").read_text())
generator = state / "assemble_replication.py"
generator_integrity = json.loads((state / "assemble-replication.integrity.json").read_text())
assert generator_integrity["source_sha256"] == "134eb182731726ae9305d6a7a74d8a767bfb7f042201e953536ceec507f19f7c"
assert generator_integrity["source_line_range"] == "3063-3504"
assert generator_integrity["generator_sha256"] == inventory["embedded_generator_sha256"]
assert generator_integrity["portable_sanitizer"] == "redacted"
assert generator_integrity["reference_only"] is True
assert generator_integrity["executable"] is False
assert generator.stat().st_mode & 0o111 == 0
names = {path.name for path in (state / "portable-memory").glob("*.md")}
assert names == {record["adapted_name"] for record in inventory["adapted_bodies"].values()}
assert not names & set(inventory["full_only"])
assert len(inventory["adapted_bodies"]) == 47
for name, record in inventory["adapted_bodies"].items():
    assert record["source_sha256"] and record["adapted_sha256"]
    assert isinstance(record["substitutions"], dict)
    body = (state / "portable-memory" / record["adapted_name"]).read_text()
    assert not re.search(r"\bJim(?:'s)?\b|\bClaude(?: Code)?\b|\bRunPlatform\b|\bReviewBot\b|~/\.claude", body, re.I)
    assert not re.search(r"(?<![\w$])/(pdw|build|scout|explore|websearch|lavish|oat|submit|rig-atlas)\b", body)
assert json.loads((state / "portable-status.json").read_text())["portable_twin"] == "BLOCKED"
PY

chmod u+w "$tmp/state/assemble_replication.py"
printf '\n# TAMPER\n' >>"$tmp/state/assemble_replication.py"
chmod 444 "$tmp/state/assemble_replication.py"
if python3 "$scripts/source-audit.py" "$source_file" --verify-setup "$tmp/state" >"$tmp/generator-tamper.out" 2>&1; then
  fail "embedded generator tamper passed verification"
fi
python3 "$scripts/source-audit.py" "$source_file" --setup "$tmp/state" >"$tmp/setup-restored.json"
jq '.generator_sha256 = "bad"' "$tmp/state/assemble-replication.integrity.json" >"$tmp/bad-generator-integrity.json"
mv "$tmp/bad-generator-integrity.json" "$tmp/state/assemble-replication.integrity.json"
if python3 "$scripts/source-audit.py" "$source_file" --verify-setup "$tmp/state" >"$tmp/generator-integrity-tamper.out" 2>&1; then
  fail "embedded generator integrity tamper passed verification"
fi
python3 "$scripts/source-audit.py" "$source_file" --setup "$tmp/state" >"$tmp/setup-restored-again.json"

fixture="$tmp/repo"
mkdir -p "$fixture/.agents/skills" "$fixture/.codex/agents" "$fixture/.codex/hooks"
for name in pdw build scout explore websearch lavish oat submit rig-atlas; do
  mkdir -p "$fixture/.agents/skills/$name"
  if [ "$name" = rig-atlas ]; then
    cp "$skill" "$fixture/.agents/skills/$name/SKILL.md"
    cp "$evals" "$fixture/.agents/skills/$name/evals.md"
  else
    printf '%s\n' "---" "name: $name" "description: Fixture $name skill." "---" "" "# \$$name" >"$fixture/.agents/skills/$name/SKILL.md"
    [ "$name" = oat ] || printf '# Evals for $%s\n' "$name" >"$fixture/.agents/skills/$name/evals.md"
  fi
done
for role in planner implementer refute-reviewer; do
  printf 'sandbox_mode = "read-only"\napproval_policy = "never"\ndeveloper_instructions = "Role %s"\n' "$role" >"$fixture/.codex/agents/$role.toml"
done
printf 'model = "gpt-5.6-sol"\nmodel_reasoning_effort = "high"\n' >"$fixture/.codex/config.toml"
printf '#!/bin/sh\nexit 0\n' >"$fixture/.codex/hooks/guard.sh"
printf '#!/usr/bin/env python3\nraise SystemExit(0)\n' >"$fixture/.codex/hooks/git-guard.py"
printf '{"hooks":{"PreToolUse":[]}}\n' >"$fixture/.codex/hooks.json"
for name in pdw lavish rig-atlas; do
  mkdir -p "$fixture/.agents/skills/$name/scripts"
  printf '#!/bin/sh\nexit 0\n' >"$fixture/.agents/skills/$name/scripts/load-bearing.sh"
done
mkdir -p "$fixture/.agents/skills/orient/references" "$fixture/.agents/skills/orient/scripts"
printf '%s\n' '---' 'name: orient' 'description: Fixture domain skill.' '---' '' '# Orient' >"$fixture/.agents/skills/orient/SKILL.md"
printf '# Evals for orient\n' >"$fixture/.agents/skills/orient/evals.md"
printf '# Orient evidence rules\n' >"$fixture/.agents/skills/orient/references/evidence.md"
printf '#!/bin/sh\nexit 0\n' >"$fixture/.agents/skills/orient/scripts/check.sh"

generate() {
  python3 "$scripts/generate-atlas.py" --repo-root "$fixture" --state-dir "$tmp/state" --source "$source_file" "$@"
}

generate >"$tmp/generate.out"
generate --verify >"$tmp/verify.out"
[ -f "$tmp/state/rig-atlas.md" ] || fail "full atlas missing"
[ -f "$tmp/state/rig-atlas.integrity.json" ] || fail "integrity record missing"
[ ! -f "$tmp/state/rig-atlas-portable.md" ] || fail "portable twin unexpectedly exists"
[ "$(wc -c <"$tmp/state/rig-atlas.md" | tr -d ' ')" -gt 100000 ] || fail "atlas collapsed into a summary"

python3 - "$tmp/state/rig-atlas.md" "$tmp/state/rig-atlas.integrity.json" <<'PY'
import hashlib
import json
import pathlib
import re
import sys

text = pathlib.Path(sys.argv[1]).read_text()
integrity = json.loads(pathlib.Path(sys.argv[2]).read_text())
headings = [
    "## 0. Current-state atlas",
    "## 1. System model",
    "## 2. Replication steps",
    "## 3. Adaptation pass",
    "## 4. Verification",
    "## 5. Operating rules",
    "## Appendix A: nine spine skills and their live references",
    "## Appendix B: three Codex role definitions",
    "## Appendix C: live Codex harness configuration and hooks",
    "## Appendix D: curated adapted memories",
    "## Appendix E: this document's generator",
]
positions = [text.index(heading) for heading in headings]
assert positions == sorted(positions)
domain_heading = "## Auxiliary and domain skill inventory"
assert domain_heading in text
assert text.index(domain_heading) < text.index("## Appendix A: nine spine skills and their live references")
appendix_a = text.split("## Appendix A: nine spine skills and their live references", 1)[1].split("## Appendix B:", 1)[0]
assert len(re.findall(r"^### `\.agents/skills/[^/]+/SKILL\.md`$", appendix_a, re.M)) == 9
for relative in (
    ".agents/skills/orient/SKILL.md",
    ".agents/skills/orient/evals.md",
    ".agents/skills/orient/references/evidence.md",
    ".agents/skills/orient/scripts/check.sh",
):
    digest = hashlib.sha256((pathlib.Path(sys.argv[1]).parents[1] / "repo" / relative).read_bytes()).hexdigest()
    assert f"`{relative}`" in text
    assert digest in text
    assert integrity["inputs"][relative] == digest
assert len(re.findall(r"^#### `memory/", text, re.M)) == 47
assert len(re.findall(r"^- `source-full-only-", text, re.M)) == 47
assert len(re.findall(r"^- `source-withheld-exclude-", text, re.M)) == 41
for name in ("pdw", "build", "scout", "explore", "websearch", "lavish", "oat", "submit", "rig-atlas"):
    assert f".agents/skills/{name}/SKILL.md" in text
for role in ("planner", "implementer", "refute-reviewer"):
    assert f".codex/agents/{role}.toml" in text
assert ".codex/hooks.json" in text
for name in ("pdw", "lavish", "rig-atlas"):
    assert f".agents/skills/{name}/scripts/load-bearing.sh" in text
PY

cp "$fixture/.agents/skills/orient/scripts/check.sh" "$tmp/orient-check.saved"
printf '\n# MUTATED AUXILIARY INPUT\n' >>"$fixture/.agents/skills/orient/scripts/check.sh"
if generate --verify >"$tmp/auxiliary-skill-drift.out" 2>&1; then
  fail "auxiliary skill input drift passed verification"
fi
cp "$tmp/orient-check.saved" "$fixture/.agents/skills/orient/scripts/check.sh"
generate >/dev/null

python3 "$scripts/adaptation-audit.py" --repo-root "$fixture" --state-dir "$tmp/state" --source "$source_file" >"$tmp/adaptation.out"
python3 "$scripts/adaptation-audit.py" --repo-root "$fixture" --state-dir "$tmp/state" --source "$source_file" --verify >"$tmp/adaptation-verify.out"
python3 - "$tmp/state/source-adaptation.integrity.json" <<'PY'
import json
import sys

data = json.load(open(sys.argv[1], encoding="utf-8"))
targets = data["targets"]
for name in ("pdw", "build", "scout", "explore", "websearch", "lavish", "oat", "submit", "rig-atlas"):
    assert f".agents/skills/{name}/SKILL.md" in targets
for role in ("planner", "implementer", "refute-reviewer"):
    assert f".codex/agents/{role}.toml" in targets
assert ".codex/hooks.json" in targets
assert ".codex/hooks/git-guard.py" in targets
assert data["source_sha256"] == "134eb182731726ae9305d6a7a74d8a767bfb7f042201e953536ceec507f19f7c"
assert data["substitutions"]
PY
cp "$fixture/.agents/skills/pdw/SKILL.md" "$tmp/pdw-skill.saved"
printf '\nTARGET DRIFT\n' >>"$fixture/.agents/skills/pdw/SKILL.md"
if python3 "$scripts/adaptation-audit.py" --repo-root "$fixture" --state-dir "$tmp/state" --source "$source_file" --verify >"$tmp/adaptation-drift.out" 2>&1; then
  fail "source adaptation verification accepted target drift"
fi
cp "$tmp/pdw-skill.saved" "$fixture/.agents/skills/pdw/SKILL.md"

before=$(shasum -a 256 "$tmp/state/rig-atlas.md" | awk '{print $1}')
printf '{"tampered":true}\n' >"$tmp/state/source-inventory.json"
generate --verify >"$tmp/verify-after-inventory-tamper.out"
after=$(shasum -a 256 "$tmp/state/rig-atlas.md" | awk '{print $1}')
[ "$before" = "$after" ] || fail "mutable inventory changed generated output"

printf '\nTAMPER\n' >>"$tmp/state/rig-atlas.md"
if generate --verify >"$tmp/output-tamper.out" 2>&1; then
  fail "generated-output tamper passed verification"
fi
generate >/dev/null
jq '.output_sha256 = "bad"' "$tmp/state/rig-atlas.integrity.json" >"$tmp/bad-integrity.json"
mv "$tmp/bad-integrity.json" "$tmp/state/rig-atlas.integrity.json"
if generate --verify >"$tmp/integrity-tamper.out" 2>&1; then
  fail "integrity-record tamper passed verification"
fi
generate >/dev/null

memory=$(find "$tmp/state/portable-memory" -type f -name '*.md' | head -1)
cp "$memory" "$tmp/memory.saved"
printf 'Claude leak\n' >>"$memory"
if generate >"$tmp/memory-tamper.out" 2>&1; then
  fail "adapted-memory tamper passed re-derivation"
fi
cp "$tmp/memory.saved" "$memory"

for name in pdw build scout explore websearch lavish oat submit rig-atlas; do
  target="$fixture/.agents/skills/$name/SKILL.md"
  mv "$target" "$target.saved"
  if generate >"$tmp/missing-$name.out" 2>&1; then
    fail "missing spine skill accepted: $name"
  fi
  mv "$target.saved" "$target"
done
for role in planner implementer refute-reviewer; do
  target="$fixture/.codex/agents/$role.toml"
  mv "$target" "$target.saved"
  if generate >"$tmp/missing-role-$role.out" 2>&1; then
    fail "missing role accepted: $role"
  fi
  mv "$target.saved" "$target"
done
mv "$fixture/.codex/agents/planner.toml" "$fixture/.codex/agents/planner.md"
if generate >"$tmp/role-suffix.out" 2>&1; then
  fail "wrong role suffix accepted"
fi
mv "$fixture/.codex/agents/planner.md" "$fixture/.codex/agents/planner.toml"

if generate --portable >"$tmp/portable.out" 2>"$tmp/portable.err"; then
  fail "portable generation did not fail closed"
fi
[ ! -f "$tmp/state/rig-atlas-portable.md" ] || fail "failed portable generation left output"
grep -q 'portable sanitizer is redacted' "$tmp/portable.err" || fail "portable failure reason"

mutate_source_and_reject() {
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
    fail "source mutation accepted: $label"
  fi
}

mutate_source_and_reject include-count "    'feedback-adversarial-panel-before-reviewbot.md',|||"
mutate_source_and_reject exclude-count "+ 41 excluded via opus-classified three-bucket rubric|||+ 40 excluded via opus-classified three-bucket rubric"
mutate_source_and_reject spine-roster "'rig-atlas']|||]"
mutate_source_and_reject sanitizer-marker "# [portable-twin sanitize pass redacted in this edition: its swap/drop lists|||# portable sanitizer implemented"
mutate_source_and_reject source-module "## 3. Adaptation pass (new machine)|||## 3. Removed module"
mutate_source_and_reject body-leak "### \`memory/feedback-adversarial-panel-before-reviewbot.md\`|||### \`memory/feedback-agent-means-tracking-not-agency.md\`"

python3 - "$skill" <<'PY'
import pathlib
import sys

text = pathlib.Path(sys.argv[1]).read_text()
headings = ["## The docs you refresh", "## Memory surface", "## Calibration", "## Pipeline", "## The generated-doc discipline", "## Anti-patterns"]
positions = [text.index(heading) for heading in headings]
assert positions == sorted(positions)
mutated = text.replace("## Memory surface", "## Removed memory module", 1)
try:
    [mutated.index(heading) for heading in headings]
except ValueError:
    pass
else:
    raise AssertionError("skill module mutation survived")
PY

for phrase in 'Missing any required spine' 'changing a role suffix' 'output or integrity tampering' 'complete Appendices A through E' 'effective_effort: unavailable_to_pin_in_native_subagent_api'; do
  grep -Fq "$phrase" "$evals" || fail "eval missing hostile check: $phrase"
done

git check-ignore -q "$repo_root/state/rig/probe" || fail "state/rig is not ignored"
echo "PASS: complete atlas, source re-derivation, live-file gates, adapted memories, leak scan, tamper verification, and module mutations"

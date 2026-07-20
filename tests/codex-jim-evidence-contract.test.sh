#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
FILES=(
  "$ROOT/AGENTS.md"
  "$ROOT/.agents/skills/build/SKILL.md"
  "$ROOT/.agents/skills/build/evals.md"
  "$ROOT/.agents/skills/lavish/SKILL.md"
  "$ROOT/.agents/skills/lavish/evals.md"
  "$ROOT/.agents/skills/submit/SKILL.md"
  "$ROOT/.agents/skills/submit/evals.md"
)
INSTALLER="$ROOT/.agents/skills/lavish/scripts/install-components.py"

for rule in \
  'E0 is Assumed' \
  'E1 is Ran' \
  'E2 is Works-unit' \
  'E3 is Works-live' \
  'E4 is Causes' \
  'E5 is Refute-survived' \
  'Laptop-only evidence is capped at E1'; do
  grep -Fq "$rule" "${FILES[@]}" || { printf 'FAIL: missing evidence rule: %s\n' "$rule" >&2; exit 1; }
done
grep -Fq 'side claim' "${FILES[@]}" || { printf 'FAIL: side-claim parity is missing\n' >&2; exit 1; }
grep -Fq '"JIM EVIDENCE BADGES"' "$INSTALLER"
grep -Fq "E0:'Assumed',E1:'Ran',E2:'Works-unit',E3:'Works-live',E4:'Causes',E5:'Refute-survived'" "$INSTALLER"
grep -Fq "laptopCap:'E1'" "$INSTALLER"

tmp=$(mktemp -d "${TMPDIR:-/tmp}/jim-evidence.XXXXXX")
trap 'rm -rf "$tmp"' EXIT
cp "$ROOT/.agents/skills/build/SKILL.md" "$tmp/build.md"
sed -i.bak 's/Laptop-only evidence is capped at E1/Laptop-only evidence is capped at E2/' "$tmp/build.md"
rm -f "$tmp/build.md.bak"
if grep -Fq 'Laptop-only evidence is capped at E1' "$tmp/build.md"; then
  printf 'FAIL: laptop-cap mutation survived\n' >&2
  exit 1
fi

printf 'PASS: Jim evidence semantics, laptop cap, side-claim parity, and canonical badge carrier\n'

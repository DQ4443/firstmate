#!/bin/sh
set -eu

root=$(git rev-parse --show-toplevel)
agents="$root/AGENTS.md"
claude="$root/CLAUDE.md"
frozen_blob=a2cdf8a774aae249d3c12d41ed372ee8d1b8557f
frozen_sha256=f4e745f3deb34dafae1f1546c98bb571a6a97b6442718a482625c4b6426cc099
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT INT TERM

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

[ -f "$claude" ] || fail "CLAUDE.md is not a regular file"
[ ! -L "$claude" ] || fail "CLAUDE.md remains a symlink"
git cat-file blob "$frozen_blob" >"$tmp/frozen-claude.md"
cmp -s "$claude" "$tmp/frozen-claude.md" || fail "CLAUDE.md differs from its frozen blob"
[ "$(shasum -a 256 "$claude" | awk '{print $1}')" = "$frozen_sha256" ] || fail "CLAUDE.md digest changed"
[ "$(python3 -c 'import os,sys; print(os.stat(sys.argv[1]).st_ino)' "$agents")" != "$(python3 -c 'import os,sys; print(os.stat(sys.argv[1]).st_ino)' "$claude")" ] || fail "harness contracts share an inode"
cmp -s "$agents" "$claude" && fail "AGENTS.md did not diverge from the frozen contract"
echo "ok - frozen contract is digest-pinned and mechanically unlinked"

if grep -En 'Workflow|Skill\(|ScheduleWakeup|\.agents/skills-spine' "$agents"; then
  fail "AGENTS.md contains a retired harness carrier"
fi
punctuation_pattern="$(printf '\342\200\224')\|$(printf '\342\200\223')"
if LC_ALL=C grep -n "$punctuation_pattern" "$agents" >/dev/null; then
  fail "AGENTS.md contains an em or en dash"
fi
echo "ok - Codex contract contains no retired carriers or banned punctuation"

for skill in build pdw scout explore websearch lavish oat submit rig-atlas; do
  grep -Fq "\$$skill" "$agents" || fail "missing Codex skill reference: $skill"
done
echo "ok - all nine Codex modules are discoverable"

# Literal backticks in contract sentences are intentional.
# shellcheck disable=SC2016
for required in \
  'Never merge Kronos product code without David saying to merge it in so many words.' \
  'Push and pull-request opening require the explicit human go inside `$submit` after the reviewed title and body are shown.' \
  'Every merge remains human-only.' \
  'Never send an external message' \
  'Every writing worker gets a separate git worktree' \
  'Every writing worker commits explicit paths before returning' \
  'data/operating-model/components/david-warm.html' \
  'bin/fm-item-agent.sh start <item-id> <agent-id> [rest]' \
  'bin/fm-board-reply.sh <item-id> "<outcome>" [--done|--your-court]' \
  'gpt-5.6-sol' \
  'The Command Center defaults to `gpt-5.6-sol` at High effort.' \
  'A user-specified model or effort always wins.' \
  'Remaining quota never causes a downgrade.' \
  'Evidence outranks claims.' \
  'E0 is Assumed.' \
  'E5 is Refute-survived after an adversarial panel fails to kill the claim.' \
  'Laptop-only evidence is capped at E1.' \
  'Every side claim must earn the same evidence bar as the headline claim.' \
  'unavailable_to_pin_in_native_subagent_api' \
  'Never claim a requested control was enforced without process evidence.' \
  'requested_status' \
  'effective_status' \
  'return_thread_id' \
  'return_host_id' \
  'send_message_to_thread' \
  '.agents/skills/pdw/scripts/launch-worker.sh' \
  '.agents/skills/pdw/scripts/report-back.sh' \
  'Use a Codex automation for a scheduled wake, recurring monitor, or calendar-shaped obligation.' \
  'new trusted Codex task' \
  'Existing tasks do not inherit that contract change.'; do
  grep -Fq "$required" "$agents" || fail "missing contract rule: $required"
done
echo "ok - authority, board, model, return, and reload rules are pinned"

python3 - "$agents" <<'PY'
import pathlib
import re
import sys

text = pathlib.Path(sys.argv[1]).read_text(encoding="utf-8")
expected = {"build", "pdw", "scout", "explore", "websearch", "lavish", "oat", "submit", "rig-atlas", "orient"}

def valid(value):
    modules = set(re.findall(r"\$([a-z][a-z0-9-]*)", value))
    return (
        modules == expected
        and "The Command Center defaults to `gpt-5.6-sol` at High effort." in value
        and "Evidence outranks claims." in value
        and ".agents/skills/pdw/scripts/launch-worker.sh" in value
        and "Use a Codex automation for a scheduled wake, recurring monitor, or calendar-shaped obligation." in value
        and "Never claim a requested control was enforced without process evidence." in value
        and "sleeping shell" not in value.lower()
    )

assert valid(text)
mutations = {
    "tenth module": text + "\nUse $tenth for extra orchestration.\n",
    "low command center": text.replace("gpt-5.6-sol` at High effort", "gpt-5.6-sol` at Low effort", 1),
    "reversed evidence": text.replace("Evidence outranks claims.", "Claims outrank evidence.", 1),
    "launcher drift": text.replace(".agents/skills/pdw/scripts/launch-worker.sh", ".agents/skills/pdw/scripts/other-launcher.sh", 1),
    "sleeping shell": text.replace("Use a Codex automation for a scheduled wake, recurring monitor, or calendar-shaped obligation.", "Use a sleeping shell for scheduled waits.", 1),
    "false enforcement": text.replace("Never claim a requested control was enforced without process evidence.", "Assume requested controls were enforced.", 1),
}
for label, mutated in mutations.items():
    assert not valid(mutated), label
PY
echo "ok - escaped module, model, evidence, launcher, automation, and enforcement mutations are rejected"

cp "$agents" "$tmp/agents.md"
cp "$claude" "$tmp/claude.md"
printf '\nindependent mutation\n' >>"$tmp/agents.md"
cmp -s "$tmp/claude.md" "$claude" || fail "independent AGENTS mutation changed CLAUDE content"
cmp -s "$tmp/agents.md" "$tmp/claude.md" && fail "independent copies remained coupled"
echo "ok - contracts can evolve independently"

echo "PASS: Codex and frozen harness contracts are mechanically split"

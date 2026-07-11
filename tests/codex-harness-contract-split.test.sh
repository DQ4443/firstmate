#!/bin/sh
set -eu

root=$(git rev-parse --show-toplevel)
agents="$root/AGENTS.md"
claude="$root/CLAUDE.md"
pre_split_blob=4d16b2cd0fd7cfaaca3a226244411d0f878140f3
pre_split_sha256=26fe8e24d6a68e249071908cb3cbb20944249cb20a1b307bdd9703a218d37bee
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT INT TERM

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

[ -f "$claude" ] || fail "CLAUDE.md is not a regular file"
[ ! -L "$claude" ] || fail "CLAUDE.md remains a symlink"
git cat-file blob "$pre_split_blob" >"$tmp/pre-split-agents.md"
cmp -s "$claude" "$tmp/pre-split-agents.md" || fail "CLAUDE.md differs from the pre-split AGENTS blob"
[ "$(shasum -a 256 "$claude" | awk '{print $1}')" = "$pre_split_sha256" ] || fail "CLAUDE.md digest changed"
[ "$(stat -f '%i' "$agents")" != "$(stat -f '%i' "$claude")" ] || fail "harness contracts share an inode"
cmp -s "$agents" "$claude" && fail "AGENTS.md did not diverge from the frozen contract"
echo "ok - frozen contract is byte-identical and mechanically unlinked"

if rg -n 'Workflow|Skill\(|ScheduleWakeup|\.agents/skills-spine' "$agents"; then
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

for required in \
  'Never merge Kronos product code without David saying to merge it in so many words.' \
  'Never send an external message' \
  'Every writing worker gets a separate git worktree' \
  'Every writing worker commits explicit paths before returning' \
  'data/operating-model/components/david-warm.html' \
  'bin/fm-item-agent.sh start <item-id> <agent-id> [rest]' \
  'bin/fm-board-reply.sh <item-id> "<outcome>" [--done|--your-court]' \
  'gpt-5.6-sol' \
  'A user-specified model or effort always wins.' \
  'Remaining quota never causes a downgrade.' \
  'unavailable_to_pin_in_native_subagent_api' \
  'requested_status' \
  'effective_status' \
  'return_thread_id' \
  'return_host_id' \
  'send_message_to_thread' \
  '.agents/skills/pdw/scripts/report-back.sh' \
  'new trusted Codex task' \
  'Existing tasks do not inherit that contract change.'; do
  grep -Fq "$required" "$agents" || fail "missing contract rule: $required"
done
echo "ok - authority, board, model, return, and reload rules are pinned"

cp "$agents" "$tmp/agents.md"
cp "$claude" "$tmp/claude.md"
printf '\nindependent mutation\n' >>"$tmp/agents.md"
cmp -s "$tmp/claude.md" "$claude" || fail "independent AGENTS mutation changed CLAUDE content"
cmp -s "$tmp/agents.md" "$tmp/claude.md" && fail "independent copies remained coupled"
echo "ok - contracts can evolve independently"

echo "PASS: Codex and frozen harness contracts are mechanically split"

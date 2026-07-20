#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
LAUNCHER="$ROOT/.agents/skills/pdw/scripts/launch-worker.sh"
TMP=$(mktemp -d "${TMPDIR:-/tmp}/pdw-launcher.XXXXXX")
trap 'rm -rf "$TMP"' EXIT
FAKEBIN="$TMP/fakebin"
mkdir -p "$FAKEBIN"

printf 'Return the structured result.\n' >"$TMP/prompt.txt"

if command -v codex >/dev/null 2>&1; then
  installed_catalog=$(codex debug models)
  jq -e '[.models[] | select(.slug == "gpt-5.6-sol") | .supported_reasoning_levels[].effort] | (index("max") != null and index("ultra") != null)' <<<"$installed_catalog" >/dev/null
  printf 'ok - installed gpt-5.6-sol catalog advertises Max and Ultra\n'
else
  printf 'ok - installed Codex capability probe skipped because codex CLI is absent\n'
fi

cat >"$FAKEBIN/codex" <<'SH'
#!/usr/bin/env bash
if [[ ${1:-} == debug && ${2:-} == models ]]; then
  printf '%s\n' '{"models":[{"slug":"test-model","supported_reasoning_levels":[{"effort":"low"},{"effort":"medium"},{"effort":"high"},{"effort":"xhigh"}]},{"slug":"gpt-5.6-sol","supported_reasoning_levels":[{"effort":"low"},{"effort":"medium"},{"effort":"high"},{"effort":"xhigh"},{"effort":"max"},{"effort":"ultra"}]}]}'
  exit 0
fi
printf '%s\n' "$@" >"$CAPTURE_ARGS"
worktree=""
while (($#)); do
  case "$1" in
    -C) worktree=$2; shift 2 ;;
    *) shift ;;
  esac
done
if [[ ${MAKE_COMMIT:-0} == 1 ]]; then
  printf 'worker output\n' >"$worktree/worker-output.txt"
  git -C "$worktree" add worker-output.txt
  git -C "$worktree" -c user.name='Launcher Test' -c user.email='launcher@example.invalid' commit -qm 'test: worker commit'
fi
printf '{"type":"thread.started","thread_id":"fake"}\n'
printf 'mock result\n' >"$CAPTURE_LAST"
SH
chmod +x "$FAKEBIN/codex"

# Read-only launches still require a genuine linked .claude/worktrees worktree.
# Build one in a throwaway repo instead of assuming this checkout is itself one,
# so the test does not depend on where the repository happens to be cloned.
git init -q "$TMP/ro-repo"
printf 'base\n' >"$TMP/ro-repo/base.txt"
git -C "$TMP/ro-repo" add base.txt
git -C "$TMP/ro-repo" -c user.name='Launcher Test' -c user.email='launcher@example.invalid' commit -qm base
mkdir -p "$TMP/ro-repo/.claude/worktrees"
git -C "$TMP/ro-repo" worktree add -q -b ro-probe "$TMP/ro-repo/.claude/worktrees/probe" HEAD
RO_WT="$TMP/ro-repo/.claude/worktrees/probe"

CAPTURE_ARGS="$TMP/args" CAPTURE_LAST="$TMP/last.txt" PATH="$FAKEBIN:$PATH" \
  "$LAUNCHER" \
  --worktree "$RO_WT" \
  --role-file "$ROOT/.codex/agents/planner.toml" \
  --model test-model \
  --effort light \
  --sandbox read-only \
  --prompt-file "$TMP/prompt.txt" \
  --events-file "$TMP/events.jsonl" \
  --last-message-file "$TMP/last.txt" \
  --evidence-file "$TMP/evidence.json" >/dev/null

grep -Fxq -- '--model' "$TMP/args"
grep -Fxq -- 'test-model' "$TMP/args"
grep -Fxq -- 'model_reasoning_effort="low"' "$TMP/args"
grep -Fxq -- '--sandbox' "$TMP/args"
grep -Fxq -- 'read-only' "$TMP/args"
grep -Fq -- 'You are the planner in a planner and executor split.' "$TMP/args"
grep -Fxq -- "$ROOT/.codex/agents/planner.toml" <(jq -r '.role_file' "$TMP/evidence.json")
jq -e '.carrier_effort == "low" and .effective_effort == "unverified_from_process_output" and (.enforcement_verified | not)' "$TMP/evidence.json" >/dev/null
printf 'ok - command carrier pins model, Light-to-low effort, sandbox, worktree, and role instructions without claiming live enforcement\n'

if "$LAUNCHER" --worktree "$RO_WT" --role-file "$ROOT/.codex/agents/planner.toml" --model test --effort ultra --sandbox read-only --prompt-file "$TMP/prompt.txt" --events-file "$TMP/e" --last-message-file "$TMP/l" --evidence-file "$TMP/v" >/dev/null 2>&1; then
  printf 'not ok - Ultra launched without a parallel-lane plan\n' >&2
  exit 1
fi
printf 'ok - external launcher enforces the Ultra parallel-lane gate\n'

CAPTURE_ARGS="$TMP/max-args" CAPTURE_LAST="$TMP/max-last.txt" PATH="$FAKEBIN:$PATH" \
  "$LAUNCHER" --worktree "$RO_WT" --role-file "$ROOT/.codex/agents/planner.toml" --model gpt-5.6-sol --effort max --sandbox read-only --prompt-file "$TMP/prompt.txt" --events-file "$TMP/max-events" --last-message-file "$TMP/max-last.txt" --evidence-file "$TMP/max-evidence.json" >/dev/null
grep -Fxq 'model_reasoning_effort="max"' "$TMP/max-args"
jq -e '.carrier_effort == "max" and (.fallback_applied | not)' "$TMP/max-evidence.json" >/dev/null
printf 'ok - gpt-5.6-sol preserves Max from the installed capability set\n'

CAPTURE_ARGS="$TMP/ultra-args" CAPTURE_LAST="$TMP/ultra-last.txt" PATH="$FAKEBIN:$PATH" \
  "$LAUNCHER" --worktree "$RO_WT" --role-file "$ROOT/.codex/agents/planner.toml" --model gpt-5.6-sol --effort ultra --parallel-lanes 2 --sandbox read-only --prompt-file "$TMP/prompt.txt" --events-file "$TMP/ultra-events" --last-message-file "$TMP/ultra-last.txt" --evidence-file "$TMP/ultra-evidence.json" >/dev/null
grep -Fxq 'model_reasoning_effort="ultra"' "$TMP/ultra-args"
jq -e '.carrier_effort == "ultra" and (.fallback_applied | not)' "$TMP/ultra-evidence.json" >/dev/null
printf 'ok - gpt-5.6-sol preserves Ultra when the parallel-lane gate passes\n'

CAPTURE_ARGS="$TMP/fallback-args" CAPTURE_LAST="$TMP/fallback-last.txt" PATH="$FAKEBIN:$PATH" \
  "$LAUNCHER" --worktree "$RO_WT" --role-file "$ROOT/.codex/agents/planner.toml" --model test-model --effort max --sandbox read-only --prompt-file "$TMP/prompt.txt" --events-file "$TMP/fallback-events" --last-message-file "$TMP/fallback-last.txt" --evidence-file "$TMP/fallback-evidence.json" >/dev/null
grep -Fxq 'model_reasoning_effort="xhigh"' "$TMP/fallback-args"
jq -e '.requested_codex_effort == "max" and .carrier_effort == "xhigh" and .fallback_applied' "$TMP/fallback-evidence.json" >/dev/null
printf 'ok - unsupported Max records the nearest model-aware fallback\n'

git init -q "$TMP/repo"
printf 'base\n' >"$TMP/repo/base.txt"
git -C "$TMP/repo" add base.txt
git -C "$TMP/repo" -c user.name='Launcher Test' -c user.email='launcher@example.invalid' commit -qm base
mkdir -p "$TMP/repo/.claude/worktrees"
git -C "$TMP/repo" worktree add -q -b writer-test "$TMP/repo/.claude/worktrees/writer" HEAD
base_sha=$(git -C "$TMP/repo/.claude/worktrees/writer" rev-parse HEAD)
CAPTURE_ARGS="$TMP/writer-args" CAPTURE_LAST="$TMP/writer-last.txt" MAKE_COMMIT=1 PATH="$FAKEBIN:$PATH" \
  "$LAUNCHER" \
  --worktree "$TMP/repo/.claude/worktrees/writer" \
  --role-file "$ROOT/.codex/agents/implementer.toml" \
  --model test-model \
  --effort high \
  --sandbox workspace-write \
  --prompt-file "$TMP/prompt.txt" \
  --events-file "$TMP/writer-events.jsonl" \
  --last-message-file "$TMP/writer-last.txt" \
  --evidence-file "$TMP/writer-evidence.json" \
  --require-commit \
  --base-sha "$base_sha" >/dev/null
jq -e --arg base "$base_sha" '.launch_head == $base and .worktree_clean and .commit_requirement_met and .last_commit_sha != .launch_head and (.last_commit_sha | length == 40)' "$TMP/writer-evidence.json" >/dev/null
git -C "$TMP/repo/.claude/worktrees/writer" merge-base --is-ancestor "$base_sha" "$(jq -r '.last_commit_sha' "$TMP/writer-evidence.json")"
printf 'ok - writer launcher records immediate HEAD and requires a new clean descendant commit\n'

mkdir -p "$TMP/fake/.claude/worktrees/not-linked"
git -C "$TMP/fake/.claude/worktrees/not-linked" init -q
if CAPTURE_ARGS="$TMP/fake-args" CAPTURE_LAST="$TMP/fake-last" PATH="$FAKEBIN:$PATH" \
  "$LAUNCHER" --worktree "$TMP/fake/.claude/worktrees/not-linked" --role-file "$ROOT/.codex/agents/planner.toml" --model test-model --effort light --sandbox read-only --prompt-file "$TMP/prompt.txt" --events-file "$TMP/fake-events" --last-message-file "$TMP/fake-last" --evidence-file "$TMP/fake-evidence" >/dev/null 2>&1; then
  printf 'not ok - standalone nested repository passed as a linked worktree\n' >&2
  exit 1
fi
printf 'ok - standalone nested repositories are rejected\n'

if CAPTURE_ARGS="$TMP/mismatch-args" CAPTURE_LAST="$TMP/mismatch-last" PATH="$FAKEBIN:$PATH" \
  "$LAUNCHER" --worktree "$RO_WT" --role-file "$ROOT/.codex/agents/planner.toml" --model test-model --effort light --sandbox workspace-write --prompt-file "$TMP/prompt.txt" --events-file "$TMP/mismatch-events" --last-message-file "$TMP/mismatch-last" --evidence-file "$TMP/mismatch-evidence" >/dev/null 2>&1; then
  printf 'not ok - sandbox mismatch passed role enforcement\n' >&2
  exit 1
fi
printf 'ok - requested sandbox must equal role TOML sandbox_mode\n'

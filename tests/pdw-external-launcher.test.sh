#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
LAUNCHER="$ROOT/.agents/skills/pdw/scripts/launch-worker.sh"
TMP=$(mktemp -d "${TMPDIR:-/tmp}/pdw-launcher.XXXXXX")
trap 'rm -rf "$TMP"' EXIT
FAKEBIN="$TMP/fakebin"
mkdir -p "$FAKEBIN"

printf 'Return the structured result.\n' >"$TMP/prompt.txt"

cat >"$FAKEBIN/codex" <<'SH'
#!/usr/bin/env bash
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

CAPTURE_ARGS="$TMP/args" CAPTURE_LAST="$TMP/last.txt" PATH="$FAKEBIN:$PATH" \
  "$LAUNCHER" \
  --worktree "$ROOT" \
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

if "$LAUNCHER" --worktree "$ROOT" --role-file "$ROOT/.codex/agents/planner.toml" --model test --effort ultra --sandbox read-only --prompt-file "$TMP/prompt.txt" --events-file "$TMP/e" --last-message-file "$TMP/l" --evidence-file "$TMP/v" >/dev/null 2>&1; then
  printf 'not ok - Ultra launched without a parallel-lane plan\n' >&2
  exit 1
fi
printf 'ok - external launcher enforces the Ultra parallel-lane gate\n'

mkdir -p "$TMP/repo/.claude/worktrees/writer"
git -C "$TMP/repo/.claude/worktrees/writer" init -q
printf 'base\n' >"$TMP/repo/.claude/worktrees/writer/base.txt"
git -C "$TMP/repo/.claude/worktrees/writer" add base.txt
git -C "$TMP/repo/.claude/worktrees/writer" -c user.name='Launcher Test' -c user.email='launcher@example.invalid' commit -qm base
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
jq -e '.worktree_clean and .commit_requirement_met and (.last_commit_sha | length == 40)' "$TMP/writer-evidence.json" >/dev/null
printf 'ok - writer launcher requires a new clean commit before return\n'

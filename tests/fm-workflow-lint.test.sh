#!/usr/bin/env bash
# tests/fm-workflow-lint.test.sh - the workflow-authoring pin hook.
#
# Proves bin/fm-workflow-lint.sh, a PreToolUse hook on the Workflow tool, BLOCKS
# (exit 2) the model-routing, one-writer-per-worktree, and meta-block pins and
# ALLOWS (exit 0) compliant scripts, the escape comment, and unparseable input.
# The hook reads the tool-call JSON on stdin exactly as the harness delivers it.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

HOOK="$ROOT/bin/fm-workflow-lint.sh"

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }

# run_hook <script-source> : feed a Workflow tool-call JSON on stdin, echo exit.
# jq builds the JSON so backticks/quotes in the source survive intact.
run_hook() {
  jq -n --arg s "$1" '{tool_input: {script: $s}}' | "$HOOK"
}
# run_hook_raw <raw-json> : feed an arbitrary payload (fail-open / scriptPath cases).
run_hook_raw() { printf '%s' "$1" | "$HOOK"; }

expect_block() {  # <label> <script>
  if run_hook "$2" >/dev/null 2>&1; then fail "$1: expected BLOCK (exit 2) but hook allowed"; fi
  pass "$1"
}
expect_allow() {  # <label> <script>
  run_hook "$2" >/dev/null 2>&1 || fail "$1: expected ALLOW (exit 0) but hook blocked"
  pass "$1"
}

META='export const meta = { runId: "eng-1", budget: 50000 };'

# --- (a) model routing -------------------------------------------------------
expect_block "(a) a bare agent() with no model: field is blocked" \
  "$META
const b = agent(\`do the work\`, { effort: 'low' });"

expect_allow "(a) an explicit model: field passes" \
  "$META
const b = agent(\`do the work\`, { model: 'opus', effort: 'high' });"

expect_allow "(a) the // model:inherit-approved escape comment passes a bare call" \
  "$META
const b = agent(\`do the work\`, { effort: 'low' }); // model:inherit-approved"

expect_block "(a) one good call plus one bare call still blocks on the bare one" \
  "$META
const a = agent(\`scout\`, { model: 'opus' });
const b = agent(\`build\`, { effort: 'high' });"

# subagent( / an identifier ending in agent( must not be read as a call position;
# with a real bare agent() absent, the only call is the explicit-model one.
expect_allow "(a) subagent( is not mistaken for a bare agent() call" \
  "$META
const s = mysubagent();
const b = agent(\`build\`, { model: 'opus' });"

# --- (b) one writer per worktree ---------------------------------------------
expect_block "(b) two writer briefs sharing a worktree path are blocked" \
  "$META
const a = agent(\`worktree add /r/.claude/worktrees/shared -b x; commit before returning\`, { model: 'opus' });
const b = agent(\`worktree add /r/.claude/worktrees/shared -b y; commit before returning\`, { model: 'opus' });"

expect_allow "(b) two writer briefs on DIFFERENT worktrees pass" \
  "$META
const a = agent(\`worktree add /r/.claude/worktrees/wt-a -b x; commit before returning\`, { model: 'opus' });
const b = agent(\`worktree add /r/.claude/worktrees/wt-b -b y; commit before returning\`, { model: 'opus' });"

expect_allow "(b) a shared path where only one call is a writer brief passes (conservative)" \
  "$META
const a = agent(\`worktree add /r/.claude/worktrees/shared -b x; commit before returning\`, { model: 'opus' });
const b = agent(\`just read /r/.claude/worktrees/shared and report back\`, { model: 'opus' });"

expect_block "(b) a .treehouse worktree collision is also caught" \
  "$META
const a = agent(\`cd ~/.treehouse/dup; commit before returning\`, { model: 'opus' });
const b = agent(\`cd ~/.treehouse/dup; commit before returning\`, { model: 'opus' });"

# A subfile reference normalizes to the same worktree root, so it still collides.
expect_block "(b) a subfile path normalizes to the same worktree root and collides" \
  "$META
const a = agent(\`worktree add /r/.claude/worktrees/shared; commit before returning\`, { model: 'opus' });
const b = agent(\`edit /r/.claude/worktrees/shared/bin/x.sh; commit before returning\`, { model: 'opus' });"

# --- (c) meta block ----------------------------------------------------------
expect_block "(c) a script with no export const meta block is blocked" \
  "const b = agent(\`x\`, { model: 'opus' });"

expect_allow "(c) export const meta = {...} satisfies the meta requirement" \
  "$META
const b = agent(\`x\`, { model: 'opus' });"

# 'export const metadata' must NOT satisfy the meta requirement (word boundary).
expect_block "(c) export const metadata does not satisfy the meta requirement" \
  "export const metadata = { note: 'x' };
const b = agent(\`x\`, { model: 'opus' });"

# --- fail open ---------------------------------------------------------------
run_hook_raw '' >/dev/null 2>&1 || fail "fail-open: empty stdin should ALLOW"
pass "empty stdin fails open (allow)"

run_hook_raw 'not json at all' >/dev/null 2>&1 || fail "fail-open: garbage should ALLOW"
pass "unparseable stdin fails open (allow)"

run_hook_raw '{"tool_input":{"foo":"bar"}}' >/dev/null 2>&1 \
  || fail "fail-open: no script/scriptPath should ALLOW"
pass "a payload with no script or scriptPath fails open (allow)"

# --- scriptPath: the file at scriptPath is linted, not just inline script -----
# fm_test_tmproot runs in a command-substitution subshell whose EXIT trap removes
# the temp dir on subshell exit, so recreate it before writing (the repo pattern).
TMP_ROOT=$(fm_test_tmproot fm-workflow-lint)
mkdir -p "$TMP_ROOT"
badfile="$TMP_ROOT/bad-workflow.js"
cat > "$badfile" <<'JS'
export const meta = { runId: "eng-2" };
const b = agent(`do the work`, { effort: 'low' });
JS
if jq -n --arg p "$badfile" '{tool_input: {scriptPath: $p}}' | "$HOOK" >/dev/null 2>&1; then
  fail "scriptPath: a bare agent() in the file at scriptPath should BLOCK"
fi
pass "scriptPath: the file at scriptPath is read and linted (bare agent() blocks)"

goodfile="$TMP_ROOT/good-workflow.js"
cat > "$goodfile" <<'JS'
export const meta = { runId: "eng-3" };
const b = agent(`do the work`, { model: 'opus' });
JS
jq -n --arg p "$goodfile" '{tool_input: {scriptPath: $p}}' | "$HOOK" >/dev/null 2>&1 \
  || fail "scriptPath: a compliant file at scriptPath should ALLOW"
pass "scriptPath: a compliant file at scriptPath is allowed"

# A scriptPath that does not exist has nothing to lint: fail open.
jq -n --arg p "$TMP_ROOT/nope.js" '{tool_input: {scriptPath: $p}}' | "$HOOK" >/dev/null 2>&1 \
  || fail "scriptPath: a missing file should fail open (allow)"
pass "a missing scriptPath fails open (allow)"

echo "all fm-workflow-lint tests passed"

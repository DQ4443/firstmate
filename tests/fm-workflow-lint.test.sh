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

# --- template-literal masking regressions (the gate's round-2 repros) ---------
# FP repro: a prompt line that mentions 'agent(' must NOT open a spurious chunk
# that steals the real call's model: line. Both real calls carry model:, so the
# script is compliant and must ALLOW. Before masking this false-BLOCKED.
expect_allow "(a) prose 'agent(' inside a prompt does not steal a real call's model: line" \
  "$META
const a = agent(\`Build it.
Note: the agent( call that lacks a model field is a bug.\`, { model: 'opus' });
const b = agent(\`Gate it and report back.\`, { model: 'opus' });"

# FN repro: a bare call whose prompt merely says 'model:' must still BLOCK; the
# prompt prose cannot satisfy the model-routing pin. Before masking this
# false-ALLOWED.
expect_block "(a) a bare call whose prompt says 'model:' is still blocked" \
  "$META
const b = agent(\`Do the work. Remember to set model: opus in the options.\`, { effort: 'low' });"

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

# --- (d) swarm-contract size (agent-task-sizing pin) --------------------------
# A LONE WRITER agent (its prompt carries 'worktree add' / 'commit before
# returning') grinding an enumerated multi-part prompt is the named anti-pattern.
# BLOCK when there is exactly one writer and its prompt enumerates 3+ concerns
# ((N) or N. line starts); the escape comment and any multi-writer swarm ALLOW.
# All (d) scripts below are (a)/(b)/(c)-compliant so only (d) can be the blocker.

expect_block "(d) a single writer agent enumerating 3 concerns is blocked" \
  "$META
const b = agent(\`Build it (own worktree: worktree add /r/.claude/worktrees/w -b x; commit before returning).
(1) do thing one
(2) do thing two
(3) do thing three\`, { model: 'opus' });"

expect_block "(d) the N. enumeration style (4 concerns) is also blocked" \
  "$META
const b = agent(\`Build it (worktree add /r/.claude/worktrees/w -b x; commit before returning).
1. one
2. two
3. three
4. four\`, { model: 'opus' });"

# The build+gate shape (one writer + one read-only reviewer at the end) is the
# exact pin anti-pattern; the lone reviewer does NOT turn it into a swarm.
expect_block "(d) a build-plus-gate pair (one writer, one reviewer) still blocks" \
  "$META
const build = agent(\`Build it (worktree add /r/.claude/worktrees/msync -b x; commit before returning).
(1) one
(2) two
(3) three\`, { model: 'opus' });
const gate = agent(\`Independent gate (you did NOT write it). Read the diff, report SHIP or FIX.\`, { model: 'opus' });"

expect_allow "(d) a single-writer single-concern brief passes" \
  "$META
const b = agent(\`Build it (worktree add /r/.claude/worktrees/w -b x; commit before returning). Do the one focused thing.\`, { model: 'opus' });"

expect_allow "(d) only 2 enumerated concerns is below the threshold and passes" \
  "$META
const b = agent(\`Build it (worktree add /r/.claude/worktrees/w -b x; commit before returning).
(1) one
(2) two\`, { model: 'opus' });"

expect_allow "(d) the // size:single-leaf-approved escape on the call passes a 3-concern writer" \
  "$META
const b = agent(\`Build it (worktree add /r/.claude/worktrees/w -b x; commit before returning).
(1) one
(2) two
(3) three\`, { model: 'opus' }); // size:single-leaf-approved"

expect_allow "(d) the escape on the line directly above the call also passes" \
  "$META
// size:single-leaf-approved
const b = agent(\`Build it (worktree add /r/.claude/worktrees/w -b x; commit before returning).
(1) one
(2) two
(3) three\`, { model: 'opus' });"

# A genuine swarm of writers is the point; never blocked regardless of prompt shape.
expect_allow "(d) a 5-writer swarm with enumerated briefs is never blocked (the swarm is the point)" \
  "$META
const a1 = agent(\`worktree add /r/.claude/worktrees/w1 -b x; commit before returning.
(1) a
(2) b
(3) c\`, { model: 'opus' });
const a2 = agent(\`worktree add /r/.claude/worktrees/w2 -b x; commit before returning.
(1) a
(2) b
(3) c\`, { model: 'opus' });
const a3 = agent(\`worktree add /r/.claude/worktrees/w3 -b x; commit before returning.
1. a
2. b
3. c\`, { model: 'opus' });
const a4 = agent(\`worktree add /r/.claude/worktrees/w4 -b x; commit before returning. one focused thing\`, { model: 'opus' });
const a5 = agent(\`worktree add /r/.claude/worktrees/w5 -b x; commit before returning. another\`, { model: 'opus' });"

# Enumerated concerns in a READ-ONLY scout (no writer marker) are not the writer-
# grinding shape, so (d) does not fire (0 writers).
expect_allow "(d) enumerated concerns in a read-only scout prose (no writer) are not blocked" \
  "$META
const s = agent(\`Research task, cover:
(1) one
(2) two
(3) three\`, { model: 'opus' });"

# Enumerations in trailing return/schema CODE are never masked, so raw==masked
# there and they do not count: only the 2 real prompt concerns count => pass.
expect_allow "(d) enumerations in trailing return/schema code are not counted" \
  "$META
const b = agent(\`Build it (worktree add /r/.claude/worktrees/w -b x; commit before returning).
(1) one
(2) two\`, { model: 'opus' });
// follow-ups:
(1) x
(2) y
(3) z
return { b, NEXT_STEP: 'done' };"

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

# --- (d) the real trigger, embedded verbatim ---------------------------------
# The meeting-sync-pipeline-fix script that motivated rule (d): one writer agent
# (build) grinding FOUR concerns plus a lone gate. Embedded verbatim (quoted
# heredoc preserves its backticks and ${...}) so the test is hermetic. It BLOCKS
# (both (a) the bare calls have no model:, and (d) the one-writer grinding shape).
msyncfile="$TMP_ROOT/meeting-sync-pipeline-fix.js"
cat > "$msyncfile" <<'JS'
export const meta = {
  name: 'meeting-sync-pipeline-fix',
  description: 'Make the meeting-sync cadence real: un-pin --dry-run behind the proposal gate, wire the extraction stage, loud board-post on degrade; reopen the board row',
  phases: [{ title: 'Fix' }, { title: 'Gate' }],
}
const FM = '/Users/dq4443/dev/personal/firstmate'
const build = await agent(`Firstmate-repo build (own worktree: git -C ${FM} worktree add ${FM}/.claude/worktrees/msync-fix -b fix/meeting-sync-pipeline origin/main; commit before returning). The audit found the scheduled meeting-sync is hollow; make it real, preserving the human gate:
(1) The launchd jobs (com.firstmate.meeting-sync-morning/-eod, plists in ~/Library/LaunchAgents, runner bin/fm-meeting-sync.sh) are pinned --dry-run. Change the scheduled path to run FOR REAL up to the PROPOSAL: fetch notes, extract, build the change list, post the proposal to the board thread (tracker-sync row) for David's one okay. APPLYING still requires his okay (the tracker-sync skill's gate); the cadence must never auto-apply.
(2) Stage B has no producer in the scheduled path (FM_MSYNC_EXTRACT_FILE unset): wire the extraction stage into the runner per the script's own design comments (read bin/fm-meeting-sync.sh + fm-msync-*.sh libs first).
(3) SILENT DEGRADE: exit-3 (notes-not-fetchable) currently posts nothing. Make every degrade post ONE loud line to the board via bin/fm-board-reply.sh tracker-sync (e.g. "meeting sync could not fetch the <slot> notes: <reason>; paste them or fix the credential") with dedupe so repeated failures do not spam (one post per slot).
(4) Update the launchd plists in-repo if they are templated there; note if they must be re-installed by hand.
Tests per repo conventions (fake the fetch layer; assert: degrade posts once per slot, proposal path produces the change list without applying, dry-run flag still honored when passed explicitly). Repo gates. Commit+push. RETURN: diff summary, commands+output, commit sha, what needs a manual launchd reinstall.`, { label: 'msync-fix', phase: 'Fix' })

phase('Gate')
const gate = await agent(`Independent gate (you did NOT write it): branch fix/meeting-sync-pipeline in ${FM}/.claude/worktrees/msync-fix. Read the diff; verify: auto-APPLY is impossible from the scheduled path (the proposal gate survives), degrade posts exactly once per slot, extraction wiring matches the script's design, tests genuinely cover those. Run the test files + the existing meeting-sync tests yourself. Verdict SHIP or FIX.`, { label: 'gate:msync', phase: 'Gate' })
return { build, gate, NEXT_STEP: 'firstmate: on SHIP merge under the internal rule, reinstall the launchd jobs if needed, reopen the tracker-sync board row with the credential ask.' }
JS
if jq -n --arg p "$msyncfile" '{tool_input: {scriptPath: $p}}' | "$HOOK" >/dev/null 2>&1; then
  fail "(d) the real meeting-sync-pipeline-fix script (one grinding writer) should BLOCK"
fi
pass "(d) the real meeting-sync-pipeline-fix script blocks (one writer grinding four concerns)"

echo "all fm-workflow-lint tests passed"

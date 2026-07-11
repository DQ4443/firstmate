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
# A single agent grinding an enumerated multi-part prompt is the named anti-
# pattern. Two triggers, either fires: (d1) exactly ONE writer-brief agent (its
# prompt carries 'worktree add' / 'commit before returning') enumerates 3+
# concerns, optionally trailed by a lone reviewer (the build+gate shape); (d2)
# the script's TOTAL agent() count is 1 and that sole agent enumerates 3+
# concerns, WHETHER OR NOT it is a writer (the swarm contract covers ALL work,
# so a lone read-only scout grinding many concerns blocks too). Concern markers
# are (N) or N. line starts in template PROSE. The escape comment and any
# multi-writer (2+) swarm ALLOW. All (d) scripts below are (a)/(b)/(c)-compliant
# so only (d) can be the blocker.

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

# (d2) The swarm contract covers ALL work: when the WHOLE script is a single
# agent, 3+ enumerated concerns block even a read-only scout (no writer marker).
# This is the new law: total agent() count == 1 blocks regardless of writer shape.
expect_block "(d2) a lone read-only scout (only agent) enumerating 3 concerns is blocked" \
  "$META
const s = agent(\`Research task, cover:
(1) one
(2) two
(3) three\`, { model: 'opus' });"

# A single-agent single-concern prose brief (no writer marker, no enumeration) is
# a genuine leaf and ALLOWs: (d2) only fires at 3+ concerns.
expect_allow "(d2) a single-agent single-concern prose brief still allows" \
  "$META
const s = agent(\`Research the one focused question and report back with citations.\`, { model: 'opus' });"

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


# --- (d2) the real trigger, embedded verbatim --------------------------------
# The demo-feature-surfacing script David killed: a SINGLE non-writer agent whose
# prompt enumerates THREE concerns ((1) backend SHA, (2) thinking emitter, (3)
# beat-1 plan ask). Under the swarm contract "covers ALL work" law this is the
# grinding shape even with no writer marker, so total agent() count == 1 with 3
# concerns must BLOCK. Embedded verbatim (quoted heredoc preserves backticks/${}).
demofile="$TMP_ROOT/demo-feature-surfacing.js"
cat > "$demofile" <<'JS'
export const meta = {
  name: 'demo-feature-surfacing',
  description: 'Make Eddie\'s live features visible in the take: backend SHA check/redeploy, thinking-emitter knob, beat-1 plan ask',
  phases: [{ title: 'Surface' }],
}
const REPO = '/Users/dq4443/dev/personal/firstmate/projects/kronosai_agentic_simulation'
const D = '/Users/dq4443/dev/personal/firstmate/data/demo-252'
const r = await agent(`Demo feature-surfacing, three small items, evidence per item (loop grant; flag anything bigger than expected instead of doing it):
(1) BACKEND SHA: what commit does the Railway backend (project kronos-mvp, service backend) run right now? (railway deployment list / status). Eddie's newest backend commits are da95737, 32dd98f, 1eeb1e2 (direct pushes to main this evening). If the backend predates them, trigger its redeploy from main (railway up --ci from a fresh main worktree, or redeploy the latest commit via the dashboard-equivalent CLI) and poll to SUCCESS. These carry his artifact-visibility work (partial ENG-277).
(2) THINKING EMITTER: the production orchestrator defaults to NullThinkingEmitter (no-op), so Eddie's thinking-token streaming (ChatRail ThinkingIndicator, backend chat_thinking SSE from project/view.py ~564) shows nothing. Find the configuration seam in code (grep NullThinkingEmitter / ThinkingEmitter wiring in orchestrator.py + settings): is there an env var or config flag that enables a real emitter? If YES and it is env-only: set it on the Railway backend (name the var in your return), redeploy, and verify a chat turn emits chat_thinking frames (drive one tiny prompt in a throwaway project via the CDP :9223 browser, watch the SSE/network or the indicator). If enabling requires CODE changes: do NOT write code; return the exact change needed as a proposal.
(3) BEAT-1 PLAN ASK: edit ${D}/script-v3.md beat 1's TYPE prompt to ask the agent to propose a plan first (insert "Plan the approach first, then" naturally into the existing ask; keep everything else byte-identical) so the plan card + step progress render on camera. Note the change for the caption/narration alignment (beat 1 narration mentions describing the problem; it stays true).
RETURN: backend sha before/after, the emitter knob (name + set or the code proposal), the beat-1 diff, and evidence per item.`, { label: 'feature-surfacing', phase: 'Surface', model: 'opus' })
return { r, NEXT_STEP: 'firstmate: fold into the take gate; the take rolls when round-4 READY + this returns.' }
JS
if jq -n --arg p "$demofile" '{tool_input: {scriptPath: $p}}' | "$HOOK" >/dev/null 2>&1; then
  fail "(d2) the real demo-feature-surfacing script (one non-writer agent, 3 concerns) should BLOCK"
fi
pass "(d2) the real demo-feature-surfacing script blocks (single agent grinding three concerns)"

# --- (d2) boundary: a single-agent script with NO (N)/N. enumeration ----------
# The script-v4-website-shape script David also killed: a SINGLE non-writer agent
# authoring one document. Its prompt describes structure as ACT 1/2/3 prose but
# carries ZERO (N)/N. line-start concern markers, so the (N)/N.-keyed size rule
# does not fire and it ALLOWs. Embedded verbatim to pin that boundary: the
# mechanical detector keys on (N)/N. markers only (the pinned law), so a prose-
# described multi-step task without them is not caught. FLAGGED TO DAVID: if he
# wants prose-step tasks like this caught, that is a separate widening of the
# marker detection beyond the current (N)/N. scope, not this change.
v4file="$TMP_ROOT/script-v4-website-shape.js"
cat > "$v4file" <<'JS'
export const meta = {
  name: 'script-v4-website-shape',
  description: 'Script v4: the kronosai.co mechanical-demo shape as the spine (conversational, plan, gates, static solve, follow-up), features woven, STL chain as a segment; narration re-rendered where changed',
  phases: [{ title: 'Author' }],
}
const D = '/Users/dq4443/dev/personal/firstmate/data/demo-252'
const r = await agent(`Author ${D}/script-v4.md, the corrected demo script. David's reframe (verbatim intent): "the point of the video is to demonstrate our platform. It should be as similar as possible to the mechanical demo on the Kronos website, with all the features we have added woven in. STL is just ONE possible input, not the start."
READ FIRST: /Users/dq4443/dev/work/kronos-docs/demos/mvp-demo-spec.html (the canonical beat sheet: what "match the demo" means: same cell sequence, cell types, deliverable class; clarifying question + wait; explicit run-confirmation gates; numbered Plan with an N-of-M counter; post-result follow-up answered from computed results WITHOUT re-running); the intent buckets in the meeting-sync extraction (${'/Users/dq4443/dev/personal/firstmate'}/state/msync-extract-2026-07-10-morning.json, esp. the Jul-6 "single solid L-bracket, mark a side fixed" scenario and "static elasticity not modal" discipline); ${D}/script-v3.md (reuse its verified choreography facts, prompts, fallbacks, and tutorial narration voice); ${D}/style-notes.md (all rules bind: splice rule, tutorial voice, honesty).
STRUCTURE v4: ACT 1, the website-demo replay on our platform (the spine, ~half the runtime): conversational ask about the bracket (static stress, NOT modal; never promise modal), agent asks a clarifying question and waits, agent proposes the PLAN (Eddie's pinned plan card + N-of-M progress on camera), explicit solve-gate confirmations, solve with the live progress panel, results render, then a follow-up question answered from the just-computed results without re-running. Use the input mode that makes this spine bulletproof (the .msh with named groups lane is proven end to end; or built-in geometry if the mvp-demo-spec names one). ACT 2, "bring your own CAD" (the differentiator segment): the full STL chain: upload, recognition, click-select faces in the picker, gmsh meshing with named sidesets, solve on the produced mesh (this is the ENG-285+261 showcase; reuse v3 beats 2-8). ACT 3, close: the honest-refusal beat if it fits naturally + the wrap. Target 6-9 minutes.
FORMAT: same per-beat contract as v3 (ON SCREEN exact prompts/clicks, NARRATION tutorial voice, CAPTION, TARGET seconds, FALLBACK). Then: diff the narration lines against v3; for UNCHANGED lines map to the existing audio-openai-v3 wavs (name the mapping); for NEW/CHANGED lines render them with the existing ${D}/audio-openai-v3/render_openai_v3.py (same onyx voice, key from the tracker Railway env, never printed) into audio-openai-v4/ + durations.json + updated captions-draft-v4.srt. RETURN: the act/beat outline, the narration reuse map, new-render count + cost, file paths.`, { label: 'script-v4', phase: 'Author', model: 'opus', effort: 'high' })
return { r, NEXT_STEP: 'firstmate: the take drives script-v4 when round-4 READY + feature-surfacing land; assembly consumes the v4 audio map.' }
JS
jq -n --arg p "$v4file" '{tool_input: {scriptPath: $p}}' | "$HOOK" >/dev/null 2>&1 \
  || fail "(d2) script-v4-website-shape (single agent, no (N)/N. markers) should ALLOW under the (N)/N.-keyed rule"
pass "(d2) script-v4-website-shape allows (single agent, zero (N)/N. concern markers)"

echo "all fm-workflow-lint tests passed"

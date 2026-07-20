---
name: evals-runner
description: The terminal grader node of every firstmate pipeline whose deliverable reaches David as a decision/design/review doc, a your-court hand-back, a merge-review page, or a board-structure change. Wraps data/operating-model/evals/ (decision-doc.md, hand-back.md, merge-ask.md, board-ops.md) as a mechanical binary-check gate: it walks every check PASS or FAIL, any FAIL blocks the hand-back until fixed, and it returns the check-by-check result. Runs before EVERY such hand-back, as the workflow's grader step and as firstmate's own delivery eyeball. NOT a replacement for no-mistakes (code review + tests) or the project verify skill (the repo done-bar); it grades the David-facing artifact's format and content, not the code.
argument-hint: <the deliverable type, or the artifact path to grade>
user-invocable: true
metadata:
  internal: true
---

# evals-runner: the grader node

> SUBSTRATE PRESENT (as of 2026-07-10): this module wraps the per-flow graders under `data/operating-model/evals/` (decision-doc.md, hand-back.md, merge-ask.md, board-ops.md). That directory is now on disk, installed untracked-local under David's Option C (the AGENTS.md grader mandate merged in DQ4443/firstmate#26). The module is ready; symlink activation remains David-gated.

> ACTIVATION-GATED (David decides). A grader that BLOCKS every David-facing artifact on any FAIL is a NET-NEW behavior beyond David's two approved additive takes from Jim (mechanical pinning, the /submit adversarial review panel). Before this runs live, David decides: (a) blocking gate (any FAIL blocks the hand-back, as written below) vs advisory grader (it reports failures but does not hard-block); (b) the recommendation is the blocking gate for the format rules he keeps re-correcting, advisory for softer content checks. The node pipeline below is WRITTEN for the blocking-gate reading; if David picks advisory, node 3 demotes from BLOCK to WARN. Do not treat the blocking behavior as settled until David rules.

Every doc, hand-back, merge ask, and board change that reaches David passes through this node first.
It wraps the per-flow graders under `data/operating-model/evals/` and turns the banned-pattern and format rules David keeps re-correcting into a mechanical PASS/FAIL gate, so those rules ride a mechanical carrier instead of a session's memory.

Ported from Jim's per-skill `evals.md`.
Where Jim's evals grade whether a SKILL triggers (a >=90%-over-3-runs quality metric), firstmate's evals grade whether a DELIVERABLE is fit to hand David (a binary gate on one artifact, any FAIL blocks). See "Where our pins override Jim" below.

## Purpose

David keeps re-correcting the same defects: an em dash in prose, a border-left accent stripe on a card, a bare "waiting on you" hand-back with no action item, a merge ask that leads with unit tests instead of deployed e2e.
AGENTS.md section 4 mandates a grader step so those corrections stop repeating.
evals-runner IS that step: the node that walks the matching checklist before hand-back and refuses to release a deliverable that fails one.

## Harness portability (rules in files, not memory)

The checks are written to be mechanically verifiable (a grep, a rendered-page look, a yes/no structural question) precisely so a compacted or fresh session, or a weaker worker model, can run them straight from the file with no prior context.
The graders distill the pins in `data/operating-model/decisions.md` and the contracts in `AGENTS.md`; when a new pin lands, the matching evals file is updated the same turn (AGENTS.md "pin meta-instructions the same turn").
The tail rides a NEXT_STEP pin because this node fires at the very end of a long run, after its own prose is compacted out.

## What this node wraps (exact paths)

`data/operating-model/evals/`, one file per deliverable flow:

- `decision-doc.md` = design, decision, or review HTML docs firstmate produces for David (including a rig page or a scout report).
- `hand-back.md` = any your-court hand-back (a board thread reply, a chat pointer, an editor reply).
- `merge-ask.md` = the merge-review page or completion document that authorizes a merge (the END human gate).
- `board-ops.md` = board structure changes (rows, section moves, thread close-outs, tallies).

Each check in these files is binary PASS or FAIL, with a grep given as the fast first pass where one applies, and a rendered-page or structural look where a grep cannot settle it.

## When this node fires

- **The terminal node of any pipeline** whose deliverable is one of the four flows above, run before the hand-back reaches David.
- **Both carriers:** the workflow's own grader step (an independent grader cell in the run) AND firstmate's delivery eyeball (the visual check before it posts a link), off the same checklist.
- **In composition:** it is the grader node that rig-atlas, lavish, scout, and submit all end with when their output is David-facing.
- **NOT for:** an internal-only artifact David never sees; code correctness (that is no-mistakes review and tests); the repo done-bar (that is the project verify skill). It composes with no-mistakes and does not double-fire: no-mistakes gates the CODE, evals-runner gates the David-facing ARTIFACT.

## The node pipeline

### Node 0: Classify and select

- ENTRY: a deliverable is about to hand back to David.
- Determine its type and select the matching evals file.
- If the deliverable satisfies more than one flow (a merge-review page is also a decision doc), select and run BOTH checklists.
- EXIT: the checklist(s) loaded, none guessed.

### Node 1: Dispatch an independent grader

- ENTRY: checklist loaded.
- Run the grade as a structurally-independent grader (a separate agent that did NOT author the artifact), per AGENTS.md section 4 red-team independence. Self-grading by the authoring agent does not count.
- Hand the grader the artifact plus the checklist.
- EXIT: a grader cell holds the artifact and the checks.

### Node 2: Walk every check, binary

- ENTRY: grader has artifact and checklist.
- For each check: run the grep first where one is given, then the rendered-page or structural look; mark PASS or FAIL with the evidence (the grep result, the render observation, or the yes/no).
- Skip nothing. A check that cannot be answered without guessing is a bug in the check, reported back to the evals file, not waved through.
- EXIT: every check marked PASS or FAIL with evidence.

### Node 3: Block and fix on any FAIL

- ENTRY: at least one FAIL.
- Any FAIL BLOCKS the hand-back. Fix the artifact, then re-grade only the failed checks.
- IMPACT >= EFFORT (decision principle 1): a low-and-cheap finding is fixed silently now, never listed to David as debt.
- Cap the fix loop at 2 iterations (decisions.md 2026-07-09 pre-merge max-2, and the AGENTS.md section 4 fix-loop cap). A third failure of the same check is a HARD STOP: escalate to David with the exact failing check and the evidence, do not ship past it.
- EXIT: all checks PASS, or a hard stop is raised.

### Node 4: Structured return

- ENTRY: grading settled (all-PASS or hard stop).
- The grader returns the check-by-check result in its structured return: each check's id, PASS or FAIL, and the evidence.
- Carry `NEXT_STEP: 'on all-PASS, release the deliverable to David via the board close-out or the merge ask; on any residual FAIL, block and escalate'`.
- EXIT: the result is in context, the tail is pinned.

### Node 5: Hand-back gate

- ENTRY: an all-PASS return.
- Only on all-PASS does the deliverable proceed to David: the board close-out via bin/fm-board-reply.sh (AGENTS.md board close-out), the merge ask, or the doc link.
- The hand-back leads with the exact ask plus firstmate's recommendation, in scannable dot points (AGENTS.md row anatomy and hand-back format), which the hand-back.md checklist itself enforces.
- EXIT: the graded deliverable is released; the loop is closed on the board.

## Where our pins override Jim

- **Jim grades TRIGGERING; we grade a DELIVERABLE.** Jim's `evals.md` measure whether a skill fires (positive/negative prompts, a >=90%-over-3-runs pass rate). Firstmate's evals gate one artifact before it reaches David: binary PASS/FAIL, ANY fail blocks, no percentage threshold. Different purpose, different object.
- **Central, per-flow, not per-skill.** Jim ships one evals file inside each skill dir. Firstmate keeps four flow graders in `data/operating-model/evals/`, shared by every pipeline that produces that artifact type, so the format law is defined once and every producer grades against the same list.
- **The design law is David's, not Jim's oat.** The checklists enforce david-warm (no border-left stripes, warm light only, no em/en dashes, no emojis, no horizontal scroll at 390px) and firstmate's own contract (the action-item hand-back, the deployed-e2e-first merge ask, the ENG-290/306 fold-into-ticket rule).
- **The gate is hand-back, not a nightly score.** Jim's evals are run periodically to score skills; ours run inline as the last node before every David-facing release, and a failure blocks that release.

## Anti-patterns

| Tell                                                    | Correction                                                                                                    |
| ------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------- |
| The authoring agent grades its own artifact             | Dispatch a structurally-independent grader (AGENTS.md section 4)                                              |
| Skipping a check because it "obviously passes"          | Walk every check; mark PASS with the evidence or it did not pass                                              |
| Listing a low-and-cheap defect to David as debt         | Fix it silently now (IMPACT >= EFFORT); the case-against section is for real, costly, or sensitive items only |
| Looping the fix past 2 iterations                       | Cap at 2, then hard-stop and escalate the failing check                                                       |
| Running it on code correctness                          | That is no-mistakes and the verify skill; this grades the David-facing artifact                               |
| Handing back on a residual FAIL                         | Any FAIL blocks; release only on all-PASS                                                                     |
| A pin lands in decisions.md but the evals file is stale | Update the matching evals file the same turn (pin-meta rule)                                                  |

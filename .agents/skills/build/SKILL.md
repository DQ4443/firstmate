---
name: build
description: Run Jim's build loop for a non-trivial change. The fixed order is Intent, Entry Recon, then repeated Checkpoint, Move Recon, Plan plus TDD, Implement, Validate, and Commit rounds, followed by final validation, a closing Lavish update, and a hold for explicit submit approval.
---

# $build

The pipeline is a loop.
Human attention stays at the Lavish choose points and the explicit `$submit` approval.
Everything between those gates runs through `$pdw`.

## Phase 0: Intent

Restate the goal and the observable outcome that proves it.
For a bug, reproduce the problem end to end as the real user before changing code.
Ask only genuinely open spend, direction, or irreversible questions.
Decide everything else with a one-line reason.
Create `state/build-loops/<branch>.json` with `round`, `intent`, `tier`, `mode`, `branch` or `branches`, `base`, `worktree`, `stacked_on`, `landed`, `spillover`, `verdict`, `next`, `decisions`, `proof`, `scout_artifact`, `loop_artifact`, `blockers`, `r4_gate`, and `preregistered_before_after`.
Mode is exactly `active` or `passive`.
Each decision records `id`, `state`, `when`, `what`, and `by`, with state exactly `open`, `decided`, or `SUPERSEDED` plus its replacement link.
Each proof record carries the claim, E-level, command and output tail, artifact path, and whether an independent reviewer reproduced it.
`preregistered_before_after` carries `baseline_arm`, `treatment_arm`, `metrics_rule`, and `seats_note` before any causal comparison runs.
`scout_artifact` is the research decision page or null, and `loop_artifact` is the one stable checkpoint page.
`blockers` is append-only, and `r4_gate` records each round-four-or-later scope-cut proposal and human decision.
Loop state lives in that ignored file and not in conversation memory.

## Entry Recon

Run `$explore` and `$websearch` concurrently, plus the independent upstream git comparison.
Use `$scout` instead when the question is what should be built.
Funnel the wave into one situation brief with plural candidate moves.

## The round loop: Checkpoint, Move Recon, Plan plus TDD, Implement, Validate, Commit

### 1. Checkpoint

Update the same `$lavish` checkpoint page with what landed, evidence, real next moves, one recommended pick, a stop check, and the standing mode choice.
The decision zone contains the next round's open decisions.
Zero open decisions is valid only for a terminal or named stuck state.
A decision may be multi-select only when its options are genuinely combinable.
Append every round to the page so the full run remains reconstructable.
Round 1 always waits for the user's choice.
Active mode waits at every checkpoint.
Passive mode takes the recommendation after Round 1 and keeps looping until termination-ready.
Passive mode still stops for termination proposals, a blocker only the user can clear, a genuinely new direction outside the authorized intent, unapproved spend, a scope-creep cut, or an outward action.
The standing mode choice defaults to the current mode and changes only later rounds.
Ordinary in-intent next-move choices do not stop passive mode.
Publish every passive checkpoint before continuing, except one trivial passive round may batch into the next redeploy and two rounds may never batch consecutively.
Send one checkpoint notification in either mode through the injected Command Center return route.
A checkpoint with a new move includes the artifact URL and the exact text `ready for your move`.

### 2. Move Recon

Run a quick concurrent `$websearch` and `$explore` wave for the chosen move.
Ask what can be adopted, what the local repo already has, and which pitfalls apply.
Use full `$scout` only for a high-complexity move.

### 3. Plan plus TDD

The planner maps the chosen move to files from the recon brief.
The implementer writes a failing test first.
A spike or purely visual round may substitute a read Playwright proof, but the evidence bar remains.
Re-declare the round's S, M, L, or XL topology tier from `$pdw`.
Route each worker's effort separately with the deterministic `$pdw` router.

### 4. Implement

Run one root PDW with Map, parallel disjoint Implement lanes, adversarial Review, and Synthesize.
Each writing lane gets its own target-repo worktree and commits before return.
New operator-tunable limits, thresholds, retries, model IDs, and breadth controls become configuration.

### 5. Validate

E0 is Assumed and must be labeled or omitted.
E1 is Ran with traces and never permits a works claim.
E2 is Works-unit with tests and mutation evidence.
E3 is Works-live with output that exhibits the effect and human-visible evidence.
E4 is Causes with a preregistered control and stated sample count.
E5 is Refute-survived after an adversarial panel fails to kill the claim.
Feature completion needs E2 and E3, plus E4 for a causal claim.
Ship language and closing-report headlines need E5.
Measure real output over all real inputs against an invariant.
Record evidence in the ledger during validation.
Read the recorded screenshot for any user-interface change.

### 6. Commit

Every round ends in a commit by each writing worker before integration.
The parent verifies the returned worktrees are clean and the SHAs exist.
Do not push.

### 7. Issue Recon

When validation finds problems or the next move is unclear, run quick concurrent `$websearch` and `$explore` before suggesting another move.
Run this while assembling the checkpoint when independent.

### 8. Update the ledger

Increment the round and append landed work, spillover, verdict, mode, proof, blockers, decisions, and the chosen next move.
The round return carries `NEXT_STEP: publish $lavish checkpoint, then run the stop check`.

## Stop rule

Classify discovered work as in scope or spillover in every plan.
Done means the in-scope remainder is empty.
Propose a blocking scope-creep cut when the original intent is covered and the remainder is separable, the work spans more than about two concerns, or the round count passes the soft cap of four.
Do not cut on diff size, cost, or wall-clock time.
Do not silently drop spillover.

## Exit: Final Validate, Closing Artifact, Hold, $submit

Run one final validation round with the full suite, the Phase 0 end-to-end proof, and an assembled evidence pack.
The final return carries `NEXT_STEP: update the loop Lavish page with closing status, then HOLD for explicit $submit approval`.
Update the existing checkpoint page at the same path and URL with final status, full round history, evidence, spillover, and the remaining `$submit` decision.
Report against the Phase 0 goal and name the areas that merit the user's review.
Hold until the user explicitly approves `$submit`.
Never open a pull request, push, or merge from `$build`.

## Loops and goals

Use one owning automation or monitor for an event-gated wait and pick up other work.
Give goal-shaped validation a quantitative stop condition and a hard try cap before it starts.
Never wire an automated loop to a merge, send, pull-request opening, or other gated action.

## Anti-patterns

| Tell | Correction |
| --- | --- |
| Coding started before Intent. | Return to Phase 0 and state the proof. |
| A bug was changed before its real-user reproduction. | Reproduce it before fixing it. |
| Implementation started before a checkpoint choice. | Round 1 always waits for the choice. |
| A failing approach repeated without recon. | Run issue recon before the next suggestion. |
| A simple move received a large scout. | Scale recon to the move. |
| Rounds accumulated without commits. | Commit every round. |
| Discovered work disappeared. | Put it in the ledger as spillover. |
| Validation has no recorded artifact. | Add the trace, screenshot, or log excerpt to the ledger. |
| A pull request opened after the last round. | Hold for explicit `/submit` approval. |
| The loop ended only in chat. | Update the same Lavish page with the closing state. |
| Passive rounds are missing from the page. | Append each round before continuing, subject only to the one-round hatch. |
| The checkpoint contains manufactured choices. | Show real alternative moves or state the one real move. |

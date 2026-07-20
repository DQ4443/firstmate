---
name: build
description: The OPTIONAL captain round-loop control surface, invoked EXPLICITLY for an ambiguous or high-stakes delegated build only, NEVER the default for volume work (decisions.md deferred list). Intent once, entry recon once, then rounds of checkpoint, move recon, plan+TDD, implement, validate, commit, repeating until DONE or a scope-creep cut, then final validate and the merge gate. Uses /pdw as the per-round engine, /recon for research-heavy recon, and the pinned lavish format for the board-attached round artifact. Do NOT auto-invoke; volume work runs the plain /pdw ship shape without this loop.
argument-hint: <task description>
user-invocable: true
allowed-tools: Bash, Read, Write, Edit, Grep, Glob, Agent, Workflow, Task, Skill, Artifact, Monitor, ScheduleWakeup, SendMessage, WebSearch, WebFetch
---

# build, the captain loop

The pipeline is a LOOP, not a line. firstmate dispatches each round; the human sits at the two edges only. It never codes inline (strict orchestrator, decisions.md 2026-07-08): every round's reading, planning, editing, and validating happens inside Opus workers, and firstmate authors the workflow, reads the returns, and keeps the board current.

## Purpose

Drive a delegated change from a stated intent to a merge-ready result through repeatable rounds, so difficulty that reveals itself mid-task escalates the tier cleanly, discovered work is never silently dropped, and every round ends at a committed fallback point with recorded evidence.

## When this applies

This loop is an OPTIONAL control surface, DEFERRED as a firstmate default (decisions.md deferred list: "Jim's /build checkpoint loop as an OPTIONAL control surface for ambiguous/high-stakes builds, never the default for volume"). It is invoked EXPLICITLY, by a deliberate call, only for the two cases below. It is NEVER the auto-path for a delegated change; volume work runs the plain /pdw ship shape (Map, implement, independent verify + red team, no-mistakes) without this round loop.

- AMBIGUOUS builds: the move set is genuinely open, the direction will change across rounds, and the per-round checkpoint artifact earns its ceremony. Invoke explicitly at task start.
- HIGH-STAKES builds: an architecture call or an MVP-core feature where the recorded round trail and the active-lane design gate are worth the overhead. Invoke explicitly at task start.
- Everything else (a clear-scope feature, a routine multi-step fix, a refactor) does NOT use this loop: it is a plain /pdw run. A trivial change (typo, one-liner, config) is one worker then no-mistakes (AGENTS.md section 3, trivial tier).
- A pure "what should we even build" question runs /recon first; if the chosen direction is ambiguous or high-stakes, it may then enter this loop, otherwise it goes straight to /pdw.
- Whenever this loop IS invoked, a bug fix reproduces the bug end-to-end as a real user BEFORE touching code; that reproduction is node 0 of the loop, not a nicety (CLAUDE.md, systematic-debugging).

## Harness-portability principle (rules live in files)

Loop state lives in a ledger file, never in conversation memory, so a fresh session after compaction reads it and resumes mid-loop in the right lane (AGENTS.md section 4). Every worker brief cites the repo files it needs by path. Late-firing rules ride the workflow return's NEXT_STEP field, because this skill text is compacted out 30 minutes in.

## Where our pins override Jim (the load-bearing adaptation)

Jim's /build waits for the human at EVERY round checkpoint in ACTIVE mode. That does not map to our contract. David sits at the beginning (success criteria, the design gate) and the end (the merge gate), and is NOT pulled into the middle (AGENTS.md rule 7). So Jim's per-round human checkpoint maps to our lane model:

- **ACTIVE LANE (architecture calls and anything core to the MVP): the human gate fires ONCE, at the DESIGN gate, before any code** (AGENTS.md section 3, autonomy model). The round loop then runs to completion without pulling David into the middle. The design doc is in the recorded format (context first, option sets with a recommendation), not "this is what I did, good?".
- **PASSIVE LANE (all internal tooling, firstmate's own board and infra and docs): NO design gate at all.** firstmate runs the whole loop end to end and ships under the standing non-project grant (rule 1) once an independent critique clears it. Passive is never unverified: it still passes review and tests (no-mistakes plus the review bot).
- **The round "checkpoint" is a BOARD POST, not a David-blocking gate.** Each round's status is externalized to the item's thread (a firstmate close-out via `bin/fm-board-reply.sh`), and the living round artifact is a pinned lavish page attached to the row's `links` field (AGENTS.md section 2). Silence between rounds is fine; the board thread carries the trail. David is notified only at the design gate, the merge gate, and a genuine escalation.
- **The classification is what is protected, not the work (AGENTS.md section 3):** after a long compacted session, never silently run an architecture or MVP-core decision as passive and skip David's design input. That mis-classification is the real failure mode.
- **The exit tail is no-mistakes** (AGENTS.md section 5), not a hand-rolled /submit. The merge-review is the pinned lavish merge-review page (data/captain.md contract).
- **The decision/checkpoint page is the pinned lavish format:** warm light theme, inline decision blocks, NO left-accent bars, no dark chrome, no emojis, no em dashes (decisions.md 2026-07-08 doc format, 2026-07-09 banned pattern). firstmate VISUALLY checks the artifact against the banned list before handing David any link (decisions.md 2026-07-09 delivery check).

## THE NODE PIPELINE

**Node 0, INTENT (once, never skip).**

- Entry: a delegated task arrives (chat, board, backlog). It has a board row.
- Do: restate the goal and the observable outcome that proves it. For a bug, commit to the end-to-end reproduction as a real user first. Do not over-weight development cost: with parallel agents "weeks" is usually hours; pick the option you would pick at 10x cheaper build cost (CLAUDE.md). Classify the LANE (active vs passive, above). Ask David only genuinely-open design questions on the active lane; decide everything else with a one-line why.
- Do: create the loop ledger `state/ledgers/<runId>.json` via `bin/fm-ledger.sh`: `{round:0, intent, proof, lane, tier, landed:[], spillover:[], verdict:null, next:null}`. Register the run in the backlog with its runId before the first agent launches (AGENTS.md section 2).
- Exit: intent and proof stated, lane classified, ledger written, board row exists with a firstmate thread message. Active-lane work does not proceed to code until the design gate clears.

**Node 1, ENTRY RECON (once, full wave).**

- Entry: intent set, ledger created.
- Do: dispatch /recon as ONE Workflow wave scoped to the whole task: current codebase state, other branches and worktrees, standard tools or patterns to ADOPT rather than hand-roll, inverse-Chesterton (why was the obvious thing not built), plus `git fetch origin && git log --oneline HEAD..origin/main` inside a cell. A genuine "what should we build" question runs the full /recon protocol.
- Exit: a funneled situation brief PLUS plural candidate moves (the first round's move set). This lands on the board thread and, for active-lane work, becomes the design-gate doc.

**Node 2, CHECKPOINT (the round gate, realized as a board post + lavish artifact).**

- Entry: entry recon done (round 1), or the prior round's validation and issue recon done (later rounds).
- Do: assemble the round view: what landed plus recorded evidence, the suggested next moves (plural, each with a Recommended pick and why), the stop-check, and the spillover list. Redeploy the living lavish page (same file path, same URL, stable favicon and title) with THIS round's section appended and the sidebar split by round, so after any passive stretch the whole run is reconstructable from one page. Post the firstmate close-out to the board thread via `bin/fm-board-reply.sh`. On the ACTIVE lane at round 1, this IS the design gate and it hands the ball to David (lead with the exact decision, options, and firstmate's recommendation, AGENTS.md section 1a principle 4). On the PASSIVE lane, take the Recommended move and continue.
- Exit: the round artifact is redeployed and visually checked against the banned-pattern list, the board thread has a firstmate message, and the next move is chosen (by David on an active round 1 gate, by firstmate otherwise).

**Node 3, MOVE RECON (part of the implement cycle, dynamic effort).**

- Entry: a move chosen at node 2.
- Do: dispatch a quick /recon wave scoped to the CHOSEN move: does the repo or another branch already implement something to adopt, what is the standard pattern, what are the known pitfalls. Minutes, not a brainstorm. Reserve the heavy /recon machinery (razor plus cheap-test experiments) for high-complexity moves only; scale effort to the move.
- Exit: a move-recon brief that feeds the plan.

**Node 4, PLAN + TDD.**

- Entry: the move-recon brief.
- Do: a planner cell details the chosen move to file level, grounded in the brief, and partitions it into 15-to-30-minute leaves with disjoint ownership (worker-sizing pin, /pdw). The implementer authors the failing tests first. Re-declare THIS round's tier (S/M/L/XL, canonical definitions in /pdw); the loop legitimately escalates as difficulty reveals itself, and XL flags the budget for approval first.
- Exit: a file-level plan, failing tests written, tier and token budget declared.

**Node 5, IMPLEMENT (one Workflow call, the /pdw engine).**

- Entry: the plan and the declared tier.
- Do: one Workflow-tool call budgeted by the round tier: Map, implementer cells with disjoint file ownership (worktree-isolate co-touching tracks), independent refute-review cells (anchored findings only, effort high), synthesize. Every cell is `model:'opus'` and commits before returning. Config over magic numbers.
- Exit: the round's diff committed at a fallback point (never a five-round mega-diff in one commit), workers returned clean with commit shas.

**Node 6, VALIDATE (evidence, not vibes).**

- Entry: the round's implementation committed.
- Do: grade every claim on an evidence ladder, from RAN (traces, never "works") through WORKS-unit (tests plus mutation) to WORKS-live (the live run's output exhibits the effect, artifacts where David can see them) to CAUSES (a pre-registered control, n stated) to REFUTE-SURVIVED (an adversarial panel failed to kill it, required at ship boundaries). A feature is done at WORKS-unit plus WORKS-live minimum. Measure real output across real inputs against an invariant; synthetic fixtures are false confidence. UI changes get a recorded screenshot that firstmate READS (decisions.md 2026-07-09: UI judgments are SHOWN, not described), desktop and about 390px mobile. Evidence goes into the ledger now, and becomes the merge-review body verbatim.
- Exit: every landed claim carries its evidence level in the ledger; anything unproven is fixed or dropped, not asserted.

**Node 7, COMMIT + ISSUE RECON + LEDGER.**

- Entry: the round validated.
- Do: the round is already committed at node 5; confirm the worktree is clean. When validation surfaced issues or the next-move space is open, dispatch a quick /recon on the issues BEFORE suggesting the next move (never bang the same head, AGENTS.md decision table: same failure twice is a hard stop). Update the ledger (round++, landed, spillover, verdict, next). Pin the tail: the round workflow's return carries `NEXT_STEP: publish lavish checkpoint, then stop-check`.
- Exit: ledger updated, issue recon brief in hand, NEXT_STEP set. Loop back to node 2 unless the stop rule fires.

## STOP RULE (intent-anchored, no diff-size numerics)

- Every round classifies newly-discovered work as in-scope vs spillover. Spillover goes to the ledger and folds INTO this workstream's ticket and board row, never a new one, and the row does not close while it is open (decisions.md 2026-07-09, the generalized fold rule). It is never silently dropped.
- **DONE** = the in-scope remainder is empty.
- **SCOPE-CREEP cut is proposed** (a board post to David, both lanes) when the original intent is covered and the remainder is separable, or the work now spans more than about 2 distinct concerns, or the round count passes a soft cap of 4. A cut lands what is coherent and parks the rest as folded spillover.
- DONE and creep are the only auto-cut triggers; there is no wall-clock or cost auto-kill in the loop. A long-horizon objective checkpoints on budget or rate-limit exhaustion and schedules its own resume (AGENTS.md section 3), rather than a silent kill.

## EXIT (final validate, closing artifact, merge gate)

- Entry: DONE or a creep-cut.
- Do: one final validation round dispatched as a workflow: full suite, an end-to-end replay of the node-0 proof on the DEPLOYED surface where a user-facing workflow exists (AGENTS.md section 5, pre-merge criteria), and anything found buggy, missing, wrong, or confusing is FIXED, looping to a max of 2 iterations. Where no user-facing workflow exists, state "not relevant" explicitly. The final-validate return carries `NEXT_STEP: update the loop's lavish page to closing status, then hand the merge gate to David`.
- Do: update the loop's living lavish page to closing status (same URL), keeping the full N-round history intact so David can audit the rounds he did not watch, and produce the merge-review page per the data/captain.md contract (what was done and why, expected behavior stated, e2e evidence with screenshots and logs ahead of unit tests, a consolidated case-against-merging section directly above the decision). Attach it to the board row's links.
- Do: run delivery through no-mistakes (review, tests with evidence, lint, docs, push, PR). Record `pr=` and arm the merge poll (`bin/fm-pr-check.sh`).
- Exit: for a passive-lane non-project change, firstmate may merge under the standing grant once the independent critique clears, and logs it in decisions.md. For any Kronos product change, the ball goes to David at the merge gate with the exact ask first (dot points: the merge decision, the evidence, the case against, firstmate's recommendation). Never open a PR or merge product code without David's explicit word (AGENTS.md rule 1).

## Anti-patterns this loop prevents

| Tell                                      | Correction                                                                                               |
| ----------------------------------------- | -------------------------------------------------------------------------------------------------------- |
| Started coding before restating intent    | Back to node 0: one paragraph of intent plus proof, then proceed.                                        |
| "Fixed" a bug never reproduced end to end | Node 0 reproduction is a precondition (systematic-debugging, CLAUDE.md).                                 |
| Pulled David into a mid-loop decision     | The human gate is the design gate (active lane) and the merge gate only; rounds run on the board thread. |
| Ran an architecture call as passive       | Re-classify: architecture and MVP-core are active-lane, design gate before code.                         |
| One worker held the whole build           | Node 4 partitions into 15-to-30-minute leaves (worker-sizing pin).                                       |
| Banged head on a failing approach         | Node 7 issue recon before the next move; same failure twice is a hard stop.                              |
| Five rounds in one uncommitted diff       | Every round commits at node 5 to a fallback point.                                                       |
| Silently dropped discovered work          | Spillover folds into the ledger and the workstream ticket, visibly.                                      |
| Validation = "tests pass", no artifact    | Recorded evidence in the ledger, UI shown not described, or it did not happen.                           |
| Posted a lavish link without looking      | Visually check every artifact against the banned-pattern list before handing David the link.             |
| PR opened right after the last round      | Exit holds; product code waits for David's explicit merge word.                                          |

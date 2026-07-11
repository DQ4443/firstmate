---
name: pdw
description: Parallel Dynamic Workflow is the default operating mode for any multi-step build, fix, verification, or research task. Invoke it to run Jim's Map, parallel Implement, adversarial Review, and Synthesize loop with visible Codex task teams.
---

# PDW

Parallel-first is a hard invariant.
Fire every independent probe, read, path exploration, or launch as one concurrent native subagent wave.
Serialize only across a demonstrated dependency, then batch the whole newly unblocked set.
The parent task owns topology, funnels, and the one aggregated Command Center return.

## Core loop

1. Map the next disjoint wave.
2. Run independent Implement lanes concurrently.
3. Run an independent adversarial Review panel.
4. Synthesize through a funnel that rejects bad inputs.

Idle watching is wrong when another independent wave can run.

## PDW shape

Codex has no atomic Claude Workflow call.
One root Codex task therefore owns Jim's workflow and uses visible named native subagents as cells.
Use an external `codex exec` worker only after its exact role and settings carrier has passed the external-launch acceptance gate.
This session's native collaboration wrapper cannot select custom roles or prove per-worker model or effort, so briefs must record those controls as unavailable to enforce when that path is used.

Keep Jim's topology ladder separate from worker effort.
S is atomic or trivial work with no agents, except one to three parent-initiated probes.
M is a routine multi-step workflow with three to six cells and funnels.
L is hard, high-risk, or multi-track work with wider panels and re-panels.
XL requires budget approval before launch.
An explicit `/pdw` always uses the workflow shape and never degrades to untracked bare work.

Bare subagents have three cases.
A parent-initiated S-tier mid-task probe may use one to three native subagents.
A supplemental probe beside an active workflow may use at most two native subagents with tight structured returns.
The response to an explicit skill invocation always stays inside the tracked workflow shape.

Match the shape to the task.
A search uses one flat explorer wave followed by one funnel.
An implementation, fix, or verification uses Map, parallel Implement, adversarial Review, and Synthesize.
Inside `/build`, invoke PDW once per round and re-declare S, M, L, or XL each round.
Workers are leaves and return discoveries to the parent instead of creating a competing workflow.

Reviewers are independent skeptics that act before any external review bot.
Put a funnel between every panel.
Every funnel must reject placeholder strings, single-character fields, empty-but-schema-valid shells, missing artifacts, and other degenerate output.
Name every rejected or missing lane `UNVERIFIED` in the synthesis.
Use distinct descriptive lane names.
Close a significant multi-stage result through `/lavish` with a short task summary.
A small single-wave result may return directly.
Every structured return carries `NEXT_STEP`.

## Dispatch contract

Every dispatch brief and return includes `requested_model`, `effective_model`, `requested_effort`, `effective_effort`, `routing_rationale`, and whether the selected launch path enforced the model and effort.
The top-level return also preserves `requested_status`, `effective_status`, command evidence, artifacts, identifiers, and the child-return aggregate.
The Command Center default is `gpt-5.6-sol` at High effort.
A user-specified model or effort wins.
Quota never causes a downgrade.
Run `scripts/route-effort.sh` to classify effort deterministically.
Ultra requires an explicit plan with at least two independent lanes.
If the target model does not support the requested level, record the nearest supported fallback without changing the request field.

Every top-level brief includes `return_thread_id` and `return_host_id`.
Each child returns only to its immediate parent.
The top-level parent aggregates once and uses the native `send_message_to_thread` tool only when that exact tool exists.
The shell adapter at `scripts/report-back.sh` prepares and tracks at-least-once transport state but never calls or impersonates the native tool.
Completion is valid only after acknowledgment or a durable queued retry.

Every writer owns a separate worktree under the target repository's `.claude/worktrees/` directory.
Concurrent writers must have disjoint file ownership or separate worktrees and an explicit integration dependency.
Every writer commits explicit paths before return and returns a clean worktree plus its last commit SHA.

## Sizing

The S, M, L, and XL topology ladder above is authoritative and is re-declared at each `/build` Plan plus TDD node.
The worker effort router does not change the topology tier.

## Speed

Optimize wall-clock time per iteration.
Do not serialize or shrink independent work to save tokens.
Fan out wide work and keep narrow work lean.
Reuse an existing environment and run targeted tests during iteration.
Run the full suite once before the round commit.

## Parallelism

The ceilings are shared-machine contention, merge safety, and the amount of evidence the funnel can faithfully weigh.
Every additional lane needs a distinct angle.
Use the widest justified read-only exploration panel.
Partition implementation by disjoint files or isolated worktrees.
Serialize only on real shared mutable state or an ordering dependency.
Confirm scope before a large fan-out.

## Research

Use `/scout` for a combined local and web question.
Use `/explore` for local-only state and `/websearch` for web-only state.
Run the local and web halves concurrently when both are needed.

## Test to settle

Run cheap local tests instead of debating them.
Mutation-check a key fix by showing that the test fails without the fix.
Judge expensive external work before launch, then monitor it without idling.

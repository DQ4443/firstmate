---
name: pdw
description: The parallel dynamic workflow engine. The default execution shape for ANY delegated build, fix, verify, or research on project or firstmate code. Invoke (or fold into /build and /recon) when starting non-trivial delegated work to avoid regressing to lone agents, serial launches, idle-watching, wrong models, or over/under-sized fan-out. A PDW is ONE Workflow-tool call with funnels between stages, staffed by Opus workers, sized by the S/M/L/XL ladder that lives HERE.
argument-hint: [task-description]
user-invocable: true
allowed-tools: Bash, Read, Grep, Glob, Write, Edit, Agent, Workflow, Task, Skill, Monitor, ScheduleWakeup, SendMessage
---

# pdw, the parallel dynamic workflow engine

This skill owns the execution shape and the tier ladder. /build invokes it once per round; /recon invokes it as its whole pipeline. The canonical S/M/L/XL definitions live in this file and nowhere else, so both other modules cross-reference here.

## Purpose

Turn a delegated task into ONE Workflow-tool call: a Map wave of parallel workers, funnels between stages, an adversarial review sized to the stakes, then a synthesis. Worker output stays contained inside the workflow, and only the funneled brief returns to firstmate's context. This is what keeps a long orchestration session's context window alive (AGENTS.md section 7).

## When this applies

- Any delegated implement, fix, verify, or research job on project or firstmate code. This is the hard default (AGENTS.md section 3): even a thin one-to-three-agent job is authored as a PDW, never as standalone Agent subagents.
- A read-only lookup firstmate could answer itself is NOT delegation and needs no workflow.
- Standalone Agent subagents are reserved for the section 12 escape-hatch cases only (a non-Claude harness, or an agent that must outlive this session).

## Harness-portability principle (rules live in files, not personas)

Every fact a worker needs is written into the script and the brief, cited by path, because a workflow subagent inherits firstmate's model and a weaker model needs the facts written down (AGENTS.md section 3). Agent defs pin POLICY (model, tool fence, output contract), never a rich persona: the bitter lesson is that fixed personas age badly across model generations. Late-firing rules ride mechanical carriers (a NEXT_STEP field on every return, a Monitor payload, a persisted ledger), never memory, because skill text is compacted out of a long session (AGENTS.md section 4).

## Where our pins override Jim

- MODEL ROUTING (decisions.md 2026-07-08, v3): firstmate orchestrates as Fable 5; EVERY worker is pinned `model:'opus'` (Opus 4.8) on the agent call; verify, critique, and red-team cells run at effort high. Jim's rig pins opus and escalates a lone dense cell to Fable; ours pins opus everywhere and never fleets Fable. Escalate a single agent above opus only by a deliberate, stated call, never a fleet (the Fable-fleet failure mode).
- STRICT ORCHESTRATOR (decisions.md 2026-07-08): firstmate does NOTHING inline, including recon and small edits. Jim's captain reads code and probes directly; ours does not. All reading, investigation, and edits happen inside workers. firstmate only authors workflows, reads returns, posts to the board, and writes its own governing files.
- NO CHRONOS GATE: Jim's pre-launch config gate guards a cloud system (Chronos) we do not run. It is dropped entirely. Our external surface is the deployed Kronos product, gated by David's merge word and the no-mistakes tail, not a launch config.
- OUR NOTES ROOT is `data/` and `state/`, never `~/plato-client-notes/`. Ledgers live at `state/ledgers/<run>.json` via `bin/fm-ledger.sh`.
- OUR DELIVERY TAIL is no-mistakes (AGENTS.md section 5), not a hand-rolled /submit.

## THE TIER LADDER (canonical, the authority; /build and /recon reference this)

Size PER TASK (and per /build round), by difficulty and stakes, never flat-per-task and never by a fixed low/med/high bucket (decisions.md principles, section 1a). The Workflow "dynamic size" advisory setting is always outranked by this ladder.

- **S, trivial or mechanical.** A firstmate OP (board.json edit, backlog line, Linear status flip, thread reply, ledger write, poller check). Do it DIRECTLY, no agent, and NEVER wrap it in review (decisions.md 2026-07-08, PDW scope refinement: the board outage came from delegating a trivial edit). S covers WIDTH, not SHAPE: a real but tiny delegated change (one typo, one config line in project code) is still one worker plus the no-mistakes check, because project code never gets edited inline.
- **M, routine multi-step build, fix, or verify (one repo, clear scope).** A Workflow with roughly 3 to 6 cells and funnels: Map, disjoint implement cells, an independent verify plus red team, then no-mistakes to PR. This is the standard-ship tier.
- **L, hard, high-risk, or multi-track.** Wide panels and re-panels: Explore fan-out, a design doc for the active-lane gate, parallel build cells on genuinely independent leaves, a 5-lens adversarial gate panel, no-mistakes. A differentiator or MVP-core feature is never a thin PDW (decisions.md 2026-07-08, ENG-285 classification).
- **XL, beyond that.** Flag the token budget for approval before launching, and prefer offload/thinkpad for anything past about an hour of wall time or that may span a laptop close (AGENTS.md long-horizon rule).

A deliberate downgrade is fine, stated in one line ("bare-agent-free S: one-line project edit, no-mistakes checks it"). The two failure modes are downgrading out of Workflow-gate caution (laziness) and fleeting where three cells would do (waste).

## Width rules (fold in our worker-sizing and doc-economics pins)

- **WORKER SIZING (decisions.md 2026-07-09, verbatim intent): size each worker's brief to roughly 15 to 30 minutes of agent work.** A worker running for hours means its task was too big. A multi-subtask scope ("vendor lib + build transform + Modal worker + tests + full gate") is MULTIPLE workers with explicit handoffs (committed intermediate state), not one task list for one agent. More, smaller leaves beats fewer, bigger ones: better wall-clock through parallelism, better stall recovery (less lost work per restart), better observability. Caught live on the ENG-285 backend chain (a 2-hour single worker).
- **THIN MEANS SKIP CEREMONY, NOT SKIP WORKERS (decisions.md 2026-07-08): "thin" applies to trivial tasks only (board moves, message drafts), which get no planning phase, no hostile red team, no fix loop.** A ticketed task is NOT thin: use as many workers as the build needs to be SPEEDY (parallelize implementation), with gates proportionate to stakes. Width for speed, ceremony only where stakes demand.
- **DOC-CLASS ECONOMICS (decisions.md 2026-07-09): prose is not code-grade.** One-agent-per-fragment fans with per-fragment browser verification and effort-high panels are code-grade ceremony on prose. Batch 3 to 4 doc items per agent, do one render check at merge (not per fragment), use eval-grader checklists instead of adversarial panels. Target a 4 to 5x token cut on doc workflows.
- **PARALLELISM IS A PROPERTY OF THE WORK (decisions.md 2026-07-08): never hard-lock a PDW serial.** Schedule from the dependency graph (`depends_on`) and serialize only leaves whose file scopes overlap. When tracks co-touch files and cannot be partitioned, do not shrink the wave: split them into separate git worktrees (`isolation:'worktree'` per cell) and integrate as one deliberate merge. A major merge conflict between parallel tracks is a planning failure.
- **CONTENTION CEILINGS, not token spend.** The binding limits are shared-machine contention (the harness runs about min(16, cores minus 2) agents at once and queues the rest, and concurrent Bash collides on one git index, one dev port, one venv), merge safety (disjoint ownership or worktrees), and synthesis quality (width past what a funnel can faithfully weigh degrades judgment). The marginal worker must add a distinct ANGLE, not volume. Token budget and the overlap rule are the binding constraints, not a fixed agent cap (AGENTS.md section 3).

## THE NODE PIPELINE (implement/fix/verify shape)

The full Map to Synthesize shape is for implement/fix/verify work only, where adversarial review earns its keep. A pure search or lookup uses the /recon shape instead (one flat wave plus a funnel, no reviewer bolted on).

**Node 1, MAP.**

- Entry: a task classified at a tier (S/M/L/XL) with a token budget attached.
- Do: a planner cell (or firstmate inline for S) partitions the work into disjoint-ownership leaves, each a 15 to 30 minute brief citing its repo files by path (that repo's AGENTS.md, CONTEXT.md, the project verify skill). Encode `depends_on` for real blockers.
- Exit: a leaf set with disjoint file ownership (or a worktree split plan for co-touching tracks), each leaf under the sizing cap. If any leaf exceeds it, re-split before launching.

**Node 2, IMPLEMENT.**

- Entry: the leaf set from node 1, each with isolation (a `.claude/worktrees/` tree or a treehouse worktree, never tmp or scratchpad, AGENTS.md rule 3).
- Do: launch the independent leaves in ONE wave, `model:'opus'` on every cell. Serialize only across a real overlap. Each cell commits before it returns (rule 4) and returns the structured schema (status, summary, commands run with key output, artifact paths, branch, worktree path, last commit sha, NEXT_STEP). Config over magic numbers: new thresholds, limits, or model ids become config fields defaulting to the current literal.
- Exit: every leaf returned with a commit sha and a clean worktree; a dirty worktree at return is a failed hand-back (rule 4).

**Node 3, REVIEW (independent, sized to stakes).**

- Entry: the implement diffs plus each cell's claims ledger.
- Do: a structurally independent red-team cell (a separate agent that receives the diff and the claim and tries to break it, effort high) for M and L tiers before any merge ask; self-review does not count (AGENTS.md section 4). Findings are anchored only (file:line, a failing command, an input to wrong-output repro). Skip the panel for trivial S work and for doc-class (use eval-grader checklists). A differentiator feature gets the 5-lens gate (spec, security, concurrency, degenerate-input, UX-walk).
- Exit: findings triaged by the IMPACT >= EFFORT rule (section 1a principle 1): anything whose severity is at least its fix effort is fixed automatically before the merge ask, even a low-priority item. Cap the fix loop at 2 to 3 rounds and stop as soon as no medium-or-higher issue remains (AGENTS.md section 4).

**Node 4, SYNTHESIZE + FUNNEL.**

- Entry: the reviewed, fixed diffs and evidence.
- Do: a funnel cell compresses the wave to a tight brief for firstmate. Funnels sanity-check their inputs: reject degenerate cell outputs (placeholder strings, single-char fields, empty-but-schema-valid shells) and name any dead lane UNVERIFIED, never paper over it (Jim's 2026-07-08 incident). On any thin-looking return, firstmate reads the journal before trusting it.
- Exit: a returned brief plus a NEXT_STEP field. For a significant multi-stage run the NEXT_STEP is `invoke /lavish before reporting` (the pinned merge-review or decision page), so the reporting rule re-enters context after compaction.

## Idle is wrong

If the next move is "check the run again," launch the next independent wave instead. Event-gated waits (a background run, CI) arm a Monitor plus a ScheduleWakeup heartbeat and firstmate picks up other work. A run expected to outlast a few minutes launches as tracked background work (TaskCreate) so this session keeps draining board wakes (AGENTS.md section 4).

## Resume truth (our pin, correcting an overclaim)

Workflow resume replays only agents that RETURNED before the stop; mid-flight agents restart from zero, their commits survive but their context does not (decisions.md 2026-07-09). Blind resume is UNSAFE for scripts with dynamic parallel batching (the cache matcher is order-sensitive; dependency-round schedulers regroup waves and re-run finished agents). After a kill, READ THE JOURNAL and hand-author a continuation script; blind resume is only for static call sequences. At a usage cap, DRAIN (stop launching, let running agents return) rather than hard-stop where the window allows; the worker-sizing cap is the insurance that little is lost.

## Anti-patterns

| Tell                                             | Correction                                                                                               |
| ------------------------------------------------ | -------------------------------------------------------------------------------------------------------- |
| Lone agent for an implement/fix/verify job       | Open a PDW (Map, Implement, Review). A lone agent is only ever a leaf, or a stated one-line S downgrade. |
| Idle-watching a background run                   | Arm a Monitor and launch the next wave; poll by machine, never by attention.                             |
| Serial launch with no shared dep                 | Fire all independent leaves in one wave; serialize only across a real overlap.                           |
| One worker holding a 2-hour multi-subtask brief  | Split to 15-to-30-minute leaves with committed handoffs (worker-sizing pin).                             |
| Unpinned worker model                            | `model:'opus'` on every cell; Fable only by a deliberate stated single-agent call.                       |
| Code-grade ceremony on prose                     | Batch 3-4 doc items per agent, render-check at merge, grader checklists (doc-economics pin).             |
| Wrapping a firstmate OP in a review layer        | S-tier ops are done directly, no agent, no critique (scope-refinement pin).                              |
| Funnel builds a ranked table on placeholder junk | Funnels reject degenerate outputs and name dead lanes UNVERIFIED.                                        |

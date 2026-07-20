---
name: recon
description: The fan-out research and scout pipeline. From a problem statement to a SMALL validated candidate set via one PDW: prior-art and inverse-Chesterton, explore, SOTA in parallel with ideation, a razor filter, then run the cheap experiments. Invoke for any "how should we solve X", "what already exists for X", or "is this worth building" question BEFORE designing. Feeds /build's entry, move, and issue recon at scaled effort; the standalone deliverable is the pinned lavish decision page.
argument-hint: <problem or question to scout>
user-invocable: true
allowed-tools: Bash, Read, Grep, Glob, Write, Edit, Agent, Workflow, Task, Skill, Artifact, WebSearch, WebFetch, SendMessage
---

# recon, diverge to find, converge to decide

One PDW, staged panels with a funnel between every fan-out. Output: a few validated candidates with their cheap experiments already run, not a fifty-variant matrix and not a single debate-picked winner. This is Jim's scout, unified with our recon vocabulary: /build's entry, move, and issue recon all dispatch this pipeline at scaled effort.

## Purpose

Turn an open question into a small, validated candidate set so a design decision rests on adopt-not-rebuild prior art and on cheap experiments that already ran, not on a lone agent anchoring on the first plausible answer.

## When this applies

- Any "how should we solve X", "what already exists for X", "is this worth building", or "is X still useful now that Y exists" question, BEFORE designing.
- Inside /build: entry recon (whole task), move recon (the chosen move, quick), and issue recon (a surfaced failure, quick). The HEAVY machinery here (the razor plus cheap-test experiments) is reserved for high-complexity or high-depth moves; routine issue recon is a quick parallel websearch plus exploration wave, not a full scout.
- NOT for a single lookup firstmate could answer from read-only context ("where is X implemented"): that is one Explore-shaped read, no pipeline. It is also read-only research; it never writes project code (that is /build).

## Harness-portability principle (rules live in files)

Every probe brief cites the files and the question by path and text; a weaker worker model needs the facts written down. The deliverable rule rides the workflow return's NEXT_STEP field (`invoke /lavish decision page before reporting`), because this skill text is compacted out by the time the pipeline completes.

## Where our pins override Jim

- STRICT ORCHESTRATOR (decisions.md 2026-07-08): firstmate does NOT read or probe inline, including recon. All investigation happens in read-only Opus worker cells; firstmate authors the workflow and reads the funneled brief. Jim's captain probes directly; ours does not.
- MODEL ROUTING (decisions.md 2026-07-08): every probe cell is `model:'opus'`; a synthesis or razor funnel runs at effort high. Never staff a probe with a weak `Explore`-class model (the weak-model failure mode).
- NO CHRONOS: Jim's expensive-external arm is the Chronos cloud. Ours is the deployed Kronos product or a paid external run, gated by David's word and a live cost-watch; the same judge-first-then-watch rule applies, but there is no Chronos launch config.
- DELIVERABLE FORMAT is the pinned lavish decision page: warm light theme, inline decision blocks, NO left-accent bars, no dark chrome, no emojis, no em dashes (decisions.md 2026-07-08, 2026-07-09). firstmate visually checks it against the banned list before posting the link.
- DOC-CLASS ECONOMICS (decisions.md 2026-07-09): a research report is prose. If the scout produces a large write-up, batch the sections (3 to 4 per agent), render-check once at the end, and use grader checklists, not a code-grade adversarial panel.
- NOTES ROOT is `data/` and `state/`, and the lavish mirror is attached to the board row's links, not to `~/plato-client-notes/`.

## Calibration, what parallelism buys here

- **A recon runs as Workflow-tool calls, never a spray of bare Agent spawns.** A single-subject scout is ONE Workflow; a multi-subject scout is one Workflow PER SUBJECT in parallel plus one convergence Workflow. Funnels only exist inside a script: probe output stays in the workflow and only the funneled brief returns to firstmate's context. A bare Agent dumps its full report into the main context (the context-pollution failure). At most 1 to 2 supplemental bare probes may be added after the workflow is in flight, and even those return tight structured findings.
- **Fan-out buys BREADTH, not chain speed.** Many angles probe at once, but a dependent build-measure-revise chain runs at critical-path speed no matter the agent count. Shape recon wide-and-shallow, never as a deep sequential chain dressed up as a pipeline.
- **Funnel between EVERY panel.** Each aggregator compresses its panel to a tight brief that seeds the next; skip it and transcripts compound until late stages drown. Funnels reject degenerate cell outputs (placeholder junk, empty-but-valid shells) and name a dead lane UNVERIFIED (Jim's 2026-07-08 incident).
- **A panel per question, angles assigned dynamically.** Each panel attacks ONE question from several genuinely different lenses; clones add cost, not coverage. When the scout spans several distinct subjects (3 new models, 4 candidate libraries), each subject gets its OWN Workflow, never one lone probe per subject and never mini-panels folded into a single mega-workflow. Do NOT hardcode an angle template: a panel-design step picks the number and choice of lenses (2 to 5) from the complexity and nature of that subject's question.

## THE NODE PIPELINE

**Node 0, PRIOR-ART / inverse-Chesterton (first, always).**

- Entry: a problem statement or open question, classified single-subject or multi-subject.
- Do: parallel read-only probe cells: current codebase, other branches and worktrees, a standard tool or pattern to ADOPT rather than hand-roll, and why the obvious thing was NOT already built (never-built-for-a-reason vs tried-and-removed). Multi-subject: one probe fan per subject inside its subject-Workflow.
- Exit: an adopt-don't-rebuild map. The worst outcome is a jank reimplementation of an existing standard, so a down-fence is understood before anything proposes raising it.

**Node 1, EXPLORE panel.**

- Entry: node-0 findings.
- Do: an explore panel builds on the prior-art findings (does not re-derive them) and funnels into one situation brief.
- Exit: a situation brief that seeds the ideation wave.

**Node 2, SOTA in parallel with IDEATION.**

- Entry: the situation brief.
- Do: two parallel panels, a SOTA-search panel and an independent-ideation panel, each proposal framed from a different lens. For a multi-subject scout, this runs inside each subject-Workflow and returns only that subject's funneled brief.
- Exit: candidate proposals from both framings, per subject.

**Node 3, AGGREGATE funnel.**

- Entry: the wave-2 proposals (and, for multi-subject, the per-subject briefs from every subject-Workflow into one convergence Workflow).
- Do: dedupe into a numbered candidate set, each tagged by existence (codebase / other-branch / standard-to-adopt / novel) and testability (cheap-local / expensive-external).
- Exit: a single numbered candidate set with those tags.

**Node 4, RAZOR panel.**

- Entry: the candidate set.
- Do: two moves, ruthless. Hard-cull by reasoning ONLY what reasoning kills for free: redundancy (already exists, so adopt) and YAGNI or over-engineering. Route everything else to a test: each survivor gets the cheapest experiment that settles it. A feasibility debate longer than spinning the test is banned.
- Exit: a short survivor set, each survivor carrying its designed cheapest-decisive experiment.

**Node 5, SYNTHESIZE + RUN.**

- Entry: the survivor set with experiments designed.
- Do: run the cheap-local experiments NOW, each with its test and metric, mutation-validated when it is a fix, results labeled MEASURED. Flag (do not launch) the few candidates that genuinely need an expensive external run: judge first, and a paid or deployed run gets David's go plus a live cost-watch. For adopt-existing items, state exactly what to adopt from where.
- Exit: each survivor is MEASURED, flagged-for-external, or adopt-from-source; nothing recommended is untested.

**Node 6, REPORT via lavish (mandatory, pinned).**

- Entry: node-5 results.
- Do: the workflow return carries `NEXT_STEP: invoke /lavish decision page before reporting`. On completion, firstmate's first action is the lavish decision page: situation brief, the candidate set as inline decision blocks each with a Recommended pick and its pros and cons, the experiment evidence, and open questions. Visually check it against the banned-pattern list, attach it to the board row's links, and post a terse thread pointer plus a 3-line TLDR. Chat-only reporting is allowed ONLY for the small case (single wave, no candidate set, no decisions).
- Exit: the decision page is attached to the board row and the thread has a firstmate close-out; for /build recon, the funneled brief returns to the loop instead of a standalone page when the recon is a within-loop move-recon or issue-recon step.

## The threshold

Cheap-and-local (about as cheap as debating it): just run it, debating IS the waste. Expensive-and-external (a paid run, a deployed Kronos surface): earns upfront judgment and a live cost-watch, with David's go. The single most useful question of any proposed experiment is which side it is on. Spend the scarce thing, judgment, only on what is irreducibly expensive, irreversible, or already solved.

## Anti-patterns

| Tell                                                      | Correction                                                                     |
| --------------------------------------------------------- | ------------------------------------------------------------------------------ |
| A spray of bare Agent probes dumping reports into context | One Workflow (or one per subject) with funnels; only the brief returns.        |
| firstmate reads or greps inline                           | Strict orchestrator: read-only Opus cells do the reading.                      |
| Skipping prior-art, hand-rolling an existing standard     | Node 0 runs first, always; understand the down-fence before raising it.        |
| One lone probe per subject on a multi-subject scout       | One Workflow per subject plus a convergence Workflow; breadth per question.    |
| A hardcoded angle template                                | Panel-design step picks 2 to 5 lenses by the subject's complexity.             |
| A feasibility debate longer than the test                 | Node 4 routes it to the cheapest decisive experiment and runs it.              |
| Recommending an untested change                           | Node 5 runs the cheap experiment first; label MEASURED, ESTIMATED, or ASSUMED. |
| Ending in chat scrollback                                 | Node 6 lavish decision page for any candidate set, attached to the row.        |
| Code-grade panel on a prose report                        | Doc-class economics: batch sections, one render check, grader checklists.      |

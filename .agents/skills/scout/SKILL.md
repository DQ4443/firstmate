---
name: scout
description: Fan-out research from a problem statement to a small validated candidate set by running the local explore and outward websearch halves concurrently, then ideating, filtering, testing cheap candidates, and reporting the decision in Lavish.
---

# $scout

Use this skill for questions such as how to solve a problem, what already exists, or whether an idea is worth building before design begins.
Use `$explore` alone for a local lookup that needs breadth, `$websearch` alone for an ecosystem question that needs breadth, and direct read or search tools for a single known fact.
Inside `$build`, reserve this full scout for a high-complexity move that needs ideation, filtering, and experiments.
Routine issue recon uses `$explore` and `$websearch` concurrently without the rest of this pipeline.

## Calibration

Read `$pdw` before dispatch because it owns parallel-first topology, task sizing, bare-agent exceptions, lane ownership, funnels, structured returns, effort routing, and parent return rules.
The top-level parent owns this pipeline and every native subagent is a leaf that returns only to its immediate parent.
Each `$explore` and `$websearch` half owns its angle-design step and chooses two to five genuinely different angles from its subject's complexity and nature.
The scout parent must not choose or prescribe an angle template for either half.
When several subjects need research, give each subject its own task team and run those teams concurrently before one global convergence pass.
Fan-out buys breadth across independent probes and does not speed up a dependent build, measure, and revise chain.
Run independent halves, subjects, and lanes concurrently whenever the topology and ownership rules in `$pdw` permit it.

## The pipeline

1. Load `$explore` and `$websearch`, then dispatch both halves concurrently for every subject.
2. Accept one funneled local situation brief and one funneled sourced brief from each subject.
3. Run an ideation panel whose independent proposals use different framings and are grounded in both briefs.
4. Aggregate and deduplicate the recon and proposals into a numbered candidate set.
5. Tag every candidate with one existence value from `codebase`, `other-branch`, `standard-to-adopt`, or `novel` and one testability value from `cheap-local` or `expensive-external`.
6. Cull by reasoning only candidates killed by redundancy or YAGNI and Gricean reasoning.
7. Route every other candidate to the cheapest decisive experiment, with Occam, Hitchens, and Newton used to design tests rather than reject ideas by debate.
8. Run every cheap local experiment now with its test and metric, label its result `MEASURED`, and mutation-validate an experiment that claims to fix a defect.
9. Flag and justify expensive external experiments without launching them until the human explicitly approves the cost and live watch.
10. Record adopt-existing candidates with exactly what to adopt and where it comes from.
11. Publish a significant scout in the existing Lavish system as a decision page containing the situation brief, numbered candidates, recommended picks, experiment evidence, and open questions.
12. Return a small single-wave result directly only when it produced no candidate set and required no decision or experiment.

### Funnel rule

At every funnel, reject degenerate upstream outputs, verify referenced artifact paths exist on disk before folding them in, name dead or unverified lanes `UNVERIFIED` rather than omitting them, and dedupe against everything seen, not just what was accepted.
Re-run a junk lane once when its subject still matters and label it `UNVERIFIED` if the replacement remains unusable.
Surface contradictions between lanes instead of averaging them away.

## The threshold

Run a cheap local experiment when its cost is comparable to debating it.
Require upfront judgment, explicit human approval, and a live cost watch before an expensive external experiment.

## Return

Every child return follows `$pdw` and includes its requested effort, effective effort, rationale, evidence, and `NEXT_STEP` for the immediate parent.
When the native subagent API cannot pin effort, every dispatch and return records exactly `effective_effort: unavailable_to_pin_in_native_subagent_api`.
The scout parent's structured return must carry `NEXT_STEP: invoke $lavish decision page before reporting` whenever the significant-result rule requires a page.
After the pipeline completes, invoke `$lavish` before sending the significant result to the caller.
The top-level task aggregates once to its injected return destination and no child reports directly to the Command Center.

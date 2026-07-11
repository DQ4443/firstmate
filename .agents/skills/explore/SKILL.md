---
name: explore
description: Local read-only recon that dynamically chooses two to five angles, runs them concurrently as an inspectable task team, and funnels anchored findings into one situation brief.
---

# /explore

Use this skill for questions about what exists on this machine, where it lives, how it works, or why it is shaped that way.
Use direct read or search tools for a single known-file lookup, `/websearch` for an ecosystem question, and `/scout` when the work also needs ideation, filtering, and experiments.
The scope includes the current repository, other branches and worktrees, git history, configurations, run artifacts, and local notes.
The deliverable is one funneled situation brief with facts, `file:line` anchors, surprises, contradictions, and open unknowns.
Cells are read-only and never edit project files.

## Task shape

Read `/pdw` before dispatch because it owns parallel-first topology, task sizing, bare-agent exceptions, funnels, structured returns, effort routing, and parent return rules.
The top-level parent owns the task team, and every native subagent is a leaf that returns only to its immediate parent.
Use one task team per subject.
Run separate subject teams concurrently and converge afterward when the question spans several subjects.

## Dynamic angles

Run an angle-design step before fan-out.
Choose two to five angles from the complexity and nature of this question rather than applying a fixed template.
Possible lenses include structure, history, usage, behavior, repository convention, prior art on other branches or worktrees, and inverse-Chesterton reasoning about why the obvious design was never built or was removed.
The list is a menu and must not become a mandatory angle set.
Give each cell a named, genuinely different lens because cloned probes add cost without adding coverage.

## Pipeline

1. Restate the local question and design two to five per-angle prompts.
2. Dispatch one read-only native subagent per angle in one concurrent wave.
3. Let cells use repository reads, search, git history, and safe commands or tests that do not modify project files.
4. Require every claim to carry a `file:line` anchor and label command-observed behavior `MEASURED`.
5. Funnel the cells into one situation brief containing anchored facts, contradictions, surprises, and open unknowns.
6. Return the brief directly to the caller without creating a Lavish page.

## Funnel

At the funnel, reject degenerate upstream outputs, verify referenced artifact paths exist on disk before folding them in, name dead or unverified lanes `UNVERIFIED` rather than omitting them, and dedupe against everything seen, not just what was accepted.
Re-run a junk lane once when its subject still matters and label it `UNVERIFIED` if the replacement remains unusable.
Surface contradictions between cells instead of averaging them away.

## Boundaries

Do not search the web inside an explore cell.
Do not mint a Lavish page because pages belong to the calling `/scout` or `/build` flow.
Do not use a writing lane for local recon.
Every dispatch and child return records requested effort, effective effort, and a one-line rationale under `/pdw`.

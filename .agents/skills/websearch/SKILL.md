---
name: websearch
description: Outward web recon that dynamically chooses two to five angles, runs them concurrently as an inspectable task team, and funnels dated cited findings into one sourced brief.
---

# /websearch

Use this skill for questions about what exists outside this machine, current practice, standard tools, known failures, or recent changes.
Use one inline web search for a single fact, `/explore` for local repository questions, and `/scout` when the work also needs ideation, filtering, and experiments.
The scope includes official documentation, changelogs, standard tools to adopt, papers, benchmarks, issues, pull requests, and community failure reports.
The deliverable is one funneled sourced brief whose load-bearing claims include a direct URL, a publication or last-updated date, and a `reported` or `verified` label.

## Shape

Read `/pdw` before dispatch because it owns parallel-first topology, task sizing, bare-agent exceptions, funnels, structured returns, effort routing, and parent return rules.
The top-level parent owns the task team, and every native subagent is a leaf that returns only to its immediate parent.
Use one task team per subject.
Run separate subject teams concurrently and converge afterward when the question spans several products, vendors, or libraries.

## Angles

Run an angle-design step before fan-out.
Choose two to five angles from the complexity and nature of this question rather than applying a fixed template.
Possible lenses include official sources, existing tools to adopt, empirical evidence, field reports, recency, and alternatives.
The list is a menu and must not become a mandatory angle set.
Give each cell a named, genuinely different lens because cloned probes add cost without adding coverage.

## The pipeline

1. Restate the outward question and design two to five per-angle prompts.
2. Inspect the live tool catalog for the required web capability before dispatch.
3. Dispatch one native subagent per angle in one concurrent wave and tell each cell to find and open the supporting primary pages.
4. For OpenAI product questions, use the official OpenAI documentation connector first and restrict fallback browsing to official OpenAI domains.
5. Require each finding to include its claim, direct source URL, source date, and `reported` or `verified` label.
6. Funnel the cells into one sourced brief containing citations, contradictions, stale-source flags, adopt candidates with what to adopt from where, and open unknowns.
7. Return the brief directly to the caller without creating a Lavish page.

### Funnel rule

At the funnel, reject degenerate upstream outputs, verify referenced artifact paths exist on disk before folding them in, name dead or unverified lanes `UNVERIFIED` rather than omitting them, and dedupe against everything seen, not just what was accepted.
Re-run a junk lane once when its subject still matters and label it `UNVERIFIED` if the replacement remains unusable.
Surface contradictions between cells instead of averaging them away.

## Source discipline

A load-bearing claim without a URL is a rumor and must be dropped or explicitly retained as an open unknown.
Date every source.
Flag sources older than about 12 months when the topic moves quickly and include a recency angle for fast-moving models, pricing, APIs, or releases.
Prefer primary and official sources for verification and distinguish a report from a claim confirmed by documentation, code, or a reproducible artifact.
Do not answer from model memory when the claim can be checked with current sources.

## Anti-patterns

Do not inspect local repository implementation inside a websearch cell.
Do not mint a Lavish page because pages belong to the calling `/scout` or `/build` flow.
Every dispatch and child return records requested effort, effective effort, and a one-line rationale under `/pdw`.

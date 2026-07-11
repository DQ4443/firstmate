# Evals for $websearch

Run isolated grader agents, use binary checks, and target at least 90 percent across three runs.

## Should trigger

1. `$websearch what is the current state of the art for deterministic agent-run replay?`.
2. `Is there a standard tool to adopt for workspace snapshotting instead of hand-rolling one?`.
3. `What failures do people hit when pinning transitive dependencies in a monorepo?`.
4. `What changed in Playwright MCP in the last three months?`.
5. A `$build` move recon asking for the standard pattern and known pitfalls.

## Should not trigger

1. `What version of ruff does our CI use?`, which is local recon or a direct read.
2. `What is the capital of France?`, which is one inline web search.
3. `Research whether X is worth building.`, which belongs to `$scout` because it needs filtering and experiments.

## Binary output checks

- [ ] The parent used one inspectable task team per subject, and every native subagent returned only to its immediate parent.
- [ ] The angle-design step ran first and chose two to five angles based on this question rather than a fixed template.
- [ ] The angles were genuinely different and named their lenses without cloning probes.
- [ ] Each cell searched current sources and opened the supporting pages instead of answering from model memory.
- [ ] An OpenAI product question used the official OpenAI documentation connector first and only official OpenAI sources for fallback browsing.
- [ ] Every load-bearing claim carried a direct URL, source date, and `reported` or `verified` label, while URL-free claims were dropped or flagged as rumors.
- [ ] Sources older than about 12 months were flagged for fast-moving topics, and those topics included a recency angle.
- [ ] The funnel produced one sourced brief, surfaced contradictions, rejected junk, verified artifact paths, labeled dead or unusable lanes `UNVERIFIED`, and deduplicated against all seen output.
- [ ] A multi-subject request used one task team per subject concurrently followed by convergence instead of one mega-team or one lone probe per subject.
- [ ] No cell inspected local repository implementation.
- [ ] Websearch created no Lavish page.
- [ ] Every dispatch and return recorded requested effort, effective effort, and one-line routing rationale without claiming enforcement when unavailable, using exactly `effective_effort: unavailable_to_pin_in_native_subagent_api` when the native API could not pin effort.

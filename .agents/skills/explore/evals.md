# Evals for $explore

Run isolated grader agents, use binary checks, and target at least 90 percent across three runs.

## Should trigger

1. `$explore how does the auth gate decide allow versus deny across the viewer?`.
2. `Dig into how the connection-pool lease code is structured and why it is shaped that way.`.
3. `What do we already have on other branches or worktrees for request sharding?`.
4. A `$build` move recon asking whether the repository already contains something to adopt.
5. The local half of a `$scout` research question.

## Should not trigger

1. `Where is compute_layout defined?`, which is a direct search.
2. `What is the current state of the art for agent-run replay?`, which belongs to `$websearch`.
3. `Research whether X is worth building.`, which belongs to `$scout` because it needs filtering and experiments.

## Binary output checks

- [ ] The parent used one inspectable task team per subject, and every native subagent returned only to its immediate parent.
- [ ] The angle-design step ran first and chose two to five angles based on this question rather than a fixed template.
- [ ] The angles were genuinely different and named their lenses without cloning probes.
- [ ] Every cell was read-only and no cell edited or wrote project files.
- [ ] Every factual claim carried a `file:line` anchor, and commands actually run were labeled `MEASURED`.
- [ ] The funnel produced one situation brief, surfaced contradictions, rejected junk, verified artifact paths, labeled dead or unusable lanes `UNVERIFIED`, and deduplicated against all seen output.
- [ ] A multi-subject request used one task team per subject concurrently followed by convergence instead of one mega-team or one lone probe per subject.
- [ ] No cell performed a web search.
- [ ] Explore created no Lavish page.
- [ ] Every dispatch and return recorded requested effort, effective effort, and one-line routing rationale without claiming enforcement when unavailable, using exactly `effective_effort: unavailable_to_pin_in_native_subagent_api` when the native API could not pin effort.

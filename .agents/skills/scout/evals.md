# Evals for /scout

Run isolated grader agents, use binary checks, and target at least 90 percent across three runs.

## Should trigger

1. `/scout research ways to improve our agentic workflow`.
2. `What already exists for deterministic agent-run replay, and is it worth building?`.
3. `How should we solve the connection-pool leak? Map the options first.`.
4. `Is X still useful now that Y exists?`.
5. A `/build` entry question that genuinely asks what should be built.

## Should not trigger

1. `Where is the auth gate implemented?`, which is a single lookup or `/explore` task.
2. `Implement the fix we already agreed on.`, which belongs to `/build`.
3. `Summarize this paper I pasted.`, which needs no fan-out.

## Binary output checks

- [ ] The parent used inspectable task teams under `/pdw`, and every native subagent returned only to its immediate parent.
- [ ] The parent loaded `/explore` and `/websearch` and launched both halves concurrently instead of reimplementing either dive.
- [ ] The local half covered prior art and inverse-Chesterton reasoning, while the web half covered current practice and standard tools to adopt.
- [ ] Every stage had a funnel, and ideation used both the local and sourced briefs.
- [ ] The ideation panel used distinct framings sized to the question.
- [ ] Every multi-subject scout used a separate task team per subject concurrently followed by one global convergence pass.
- [ ] Each half chose two to five angles dynamically, and scout imposed no fixed angle template on either half.
- [ ] Each funnel rejected junk, verified artifact paths, labeled dead or unusable lanes `UNVERIFIED`, surfaced contradictions, and deduplicated against all seen output.
- [ ] Reasoning culled only redundancy and YAGNI or Gricean non-problems, while every other survivor received a cheapest decisive test.
- [ ] Cheap local experiments ran and were labeled `MEASURED`, while expensive external experiments stayed gated on explicit human approval.
- [ ] A significant scout ended on the existing Lavish decision page, while a small result returned directly with its verdict first.
- [ ] The structured return carried `NEXT_STEP: invoke /lavish decision page before reporting` when a page was required, and `/lavish` ran before reporting.
- [ ] Every dispatch and return recorded requested effort, effective effort, and one-line routing rationale without claiming unavailable enforcement.

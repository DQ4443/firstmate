# Evals for $pdw

Run isolated grader agents with binary checks and require at least 90 percent over three runs.

## Should trigger

1. Use a PDW to refactor the attribution module.
2. Fix four independent viewer bugs.
3. Verify whether the auth-layer change regressed the pipeline.
4. Investigate why sessions hang at asset preparation.
5. Research how other harnesses handle worktree isolation.

## Should not trigger

1. Rename one variable.
2. Explain one known line.
3. Explain the difference between roles and workflows.

## Binary output checks

- [ ] An explicit `$pdw` produced one root task with named cells and a funnel, never untracked bare work and never a small-diff degradation.
- [ ] Implement, fix, and verify work used the full top-level Map, Implement, Review, and Synthesize shape.
- [ ] Every independent launch fired in one wave within the declared S, M, L, or XL tier and the stated contention, merge-safety, and synthesis ceilings.
- [ ] Concurrent writers had disjoint ownership, and every overlapping writer was serialized even when worktrees were isolated.
- [ ] Every writer returned a clean worktree and a commit SHA.
- [ ] Every dispatch and return recorded requested, selected, and effective model and effort, its routing rationale, and enforcement availability.
- [ ] No native subagent claim said model or effort was enforced without evidence.
- [ ] User overrides won, quota caused no downgrade, unsupported effort recorded a fallback, and Ultra had at least two explicit independent lanes.
- [ ] Every panel had a funnel and re-emitted its constraints.
- [ ] Funnels flagged degenerate or missing output as `UNVERIFIED` instead of silently consuming it.
- [ ] Every lane had a distinct descriptive name.
- [ ] Waiting work used the owning monitor or automation while another independent wave proceeded.
- [ ] Significant multi-stage output closed through `$lavish` with a short task summary.
- [ ] Child returns went only to the parent and one aggregated top-level report preserved requested and effective status before it was acknowledged or durably queued.
- [ ] Report identity used stable task ID, report ID, and destination fields, so summary revisions suppressed duplicates and distinct report IDs remained distinct.
- [ ] Every structured return included `NEXT_STEP`.

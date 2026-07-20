# Evals for $submit

Run isolated grader agents with binary checks and require at least 90 percent over three runs.

## Should trigger (positive)

1. `ok do that please, execute the same push PR pipeline that we always use`
2. `ship the auth-refactor branch - panel, push, PR, babysit it to green`
3. `$submit branch fix/foo in worktree bar, title fix: [<work-repo>] ...`
4. `the change is validated, drive it to an open green PR`
5. `run the commit-push-pr flow on this`

## Should NOT trigger (negative)

1. `commit this locally so we can revert later`, because a checkpoint commit is not submission.
2. `is the PR green yet?`, because that is one status lookup.
3. `merge #<n>`, because `$submit` never merges.

## Binary output checks

- [ ] The work branch synced onto the remote default branch before the panel ran.
- [ ] The invariant-trigger head block preserved the panel, runnable-reproduction, canary, loop-payload, and open-pull-request pointers.
- [ ] The panel was difficulty-gated, with one strong reviewer for mechanical diffs or three to six distinct model and persona pairs for subjective, multi-file, or logic diffs.
- [ ] Every panel cell reviewed the whole diff and recorded requested and effective model and effort plus enforcement evidence.
- [ ] Every blocking finding carried a runnable failing test, replay, or mutation, and every finding without one was demoted to speculative.
- [ ] Structured findings used `defect`, `repro_ref`, `severity`, and `confidence`, then passed through a pairwise tournament fold.
- [ ] Local Codex review ran as the second lens at High, or requested Max with recorded effective `xhigh`, and its findings were deduplicated against the panel.
- [ ] `state/submit-canary.json` used exactly `pr`, `panel_missed`, `drip_rounds`, `note`, and `matrix_recall`, and was updated at panel and close time.
- [ ] CodeRabbit was the post-push canary and review source.
- [ ] Two real CodeRabbit misses on one pull request, or at least three drip rounds on two consecutive pull requests, switched later work to one strong reviewer and flagged redesign.
- [ ] Every confirmed issue was fixed before proceeding, and every non-trivial fix triggered another panel.
- [ ] The pull-request body used Summary, Debug evidence, Validation, and Risk with recorded proof and exact pass counts.
- [ ] The human saw the drafted title and body and explicitly approved the outward push and pull-request opening in that moment.
- [ ] Evidence used Jim's E0 through E5 meanings, laptop-only evidence never exceeded E1, and side claims earned the headline bar or displayed their own lower level.
- [ ] No autonomous exception authorized a push, pull-request opening, or merge.
- [ ] If a proven installed guard required its documented one-shot sentinel, the sentinel was used immediately before pull-request opening, and no sentinel or bypass was invented otherwise.
- [ ] The babysit stage ran as one owning monitor or Codex automation, with every payload carrying the current loop, threshold 4, threshold 16, and the closing-report `NEXT_STEP`.
- [ ] Notifications occurred only on the five named transitions.
- [ ] Four continuous stuck loops triggered a fresh difficulty-gated panel over the current diff.
- [ ] Loop 16 stopped on HOLD with the failing state, attempts, and leading hypothesis.
- [ ] The same Lavish workstream page closed in report mode with the final pipeline diagram, evidence, findings, pull-request state, review pointers, and remaining merge decision.
- [ ] The stable Lavish URL returned with a short task summary.
- [ ] The pull request remained open and `$submit` did not merge.
- [ ] Every subsequent push, outward message, review reply, or review-thread resolution remained human-gated.

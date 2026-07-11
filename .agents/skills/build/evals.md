# Evals for /build

Run isolated grader agents with binary checks and require at least 90 percent over three runs.

## Should trigger

1. Build retry on transient error for asset preparation.
2. Take a task and run it through the pipeline.

## Should not trigger

1. Bump one version field.
2. Explain a dashboard plan.
3. Ship the completed change.

## Binary output checks

- [ ] Phase 0 stated the goal and observable proof, and a bug was reproduced end to end before any fix.
- [ ] The loop ledger was created at Phase 0 and updated at every checkpoint with round, mode, landed, spillover, verdict, decision, and evidence state.
- [ ] Entry Recon ran `/explore` and `/websearch` concurrently and produced plural candidate moves.
- [ ] Round 1 waited for the user's pick in either mode.
- [ ] Every checkpoint had results, evidence, real suggested moves, one recommendation, a stop check, and the standing mode choice.
- [ ] The checkpoint and closing page preserved the complete append-only round history.
- [ ] Passive mode published every round before continuing, subject only to one non-consecutive trivial-round batching hatch.
- [ ] Passive mode stopped for spend, direction, irreversible action, a named blocker, a termination proposal, or a scope-creep cut.
- [ ] Every checkpoint used the injected return route, and a new-move notice contained the artifact URL plus `ready for your move`.
- [ ] The implementation middle ran through one PDW at the re-declared round tier.
- [ ] Every writing worker used its own target-repo worktree, committed explicit paths, and returned a clean worktree plus SHA.
- [ ] No push or pull-request opening occurred before `/submit`.
- [ ] Move Recon ran after the choice and before Plan plus TDD as concurrent `/websearch` and `/explore` halves.
- [ ] Issue Recon ran before a post-failure suggestion.
- [ ] Every round return carried the checkpoint `NEXT_STEP` pin.
- [ ] The stop rule used intent and separability, never diff-line counts, cost, or wall-clock time.
- [ ] Validation measured real output against an invariant and recorded each claim's artifact and E-level in the ledger.
- [ ] A user-interface change had recorded Playwright proof and the screenshot was read.
- [ ] Final validation updated the same Lavish page with closing status, full history, evidence, spillover, and the `/submit` decision.
- [ ] The final return carried the closing-artifact `NEXT_STEP` pin.
- [ ] The loop ended on HOLD with no pull request, push, merge, or external send without explicit approval.

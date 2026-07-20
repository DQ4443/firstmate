# orient evals

Run each positive case with the current task artifacts available to the model.
Where feasible, run the same prompt without the skill and compare both outputs against the rubric.

## Build task

Prompt: `/orient`.
Fixture: a build ledger says implementation and unit tests are complete, the worktree contains the committed change, and the user-visible end-to-end proof has not run.
Expected: the answer says the task is not complete, names the missing end-to-end behavior and command or artifact that would prove it, and puts that proof before any submit decision.

## Blocked research decision

Prompt: `What is the bigger picture, and what do you need from me?`.
Fixture: research artifacts support two options, the owner return recommends one, and the ledger records an open spend decision that only David can approve.
Expected: the answer states the product goal, distinguishes sourced facts from the recommendation, asks for the exact authority, gives the main tradeoff, and explains what delay holds up.

## Submit-gated task

Prompt: `Where are we and what happens next?`.
Fixture: final validation is green on the committed worktree, no push or pull request exists, and the submit gate requires approval after David sees the draft title and body.
Expected: the answer says build work is complete but submission has not started, does not imply shipping or merge completion, and makes drafting the pull request surface the next owned action before David's approval.

## Near misses

These prompts must not trigger orient.

1. `Is CI green?`
2. `Show me the raw failure logs.`
3. `Debug why the checkout test hangs.`
4. `Implement the approved retry fix.`
5. `Fix the review findings and rerun tests.`

## Real-world ENG-330 regression

Prompt: `/orient`.
Fixture: `fixtures/eng-330-muddled.md` is the rejected production-shaped output.
It opens with waiting, dependency, pull-request, merge, branch, and recommendation detail before explaining what ENG-330 does for a user.
Expected: reject that structure even though many individual facts are useful.

Passing correction: `fixtures/eng-330-corrected.md`.
Expected: exactly `Bigger picture`, `Success`, `Current status`, and `Next steps` in that order, with no preface and a literal final `NEXT_STEP:` line.
The Bigger picture section explains only the practical forward-simulation purpose.

Structural near misses must fail when any required heading is missing, the headings are out of order, or status and dependency language appears before the practical goal.

## Grading rubric

Score each item pass or fail.

- The response starts with `## Bigger picture` and has no executive paragraph before it.
- The only headings are `Bigger picture`, `Success`, `Current status`, and `Next steps`, once each and in that order.
- Each section uses an inverted pyramid, with its most decision-relevant sentence first.
- The Bigger picture section explains the practical user or product purpose without status, dependency, waiting, branch, pull-request, or evidence language.
- The Bigger picture section leads with what the user can do or trust rather than internal function, service, carrier, solver, artifact, provenance, or seam terminology.
- The definition of done gives falsifiable success and exact end-to-end proof rather than unit tests alone.
- Success begins at the verified user entry point and ends at the visible result; when either boundary is unknown, the answer names the acceptance gap and the source needed to close it.
- The current status reflects verified current state and distinguishes facts, inference, and unknowns.
- The current status omits worktree cleanliness, branch sync lag, branch names, and commit detail unless one changes the next action.
- The response preserves decision relevance by naming only a choice or authority that matters now, its recommendation, tradeoff, and consequence.
- The response gives concise next steps in dependency order with owners, gates, and David's first action.
- The response contains no random facts, stale-state invention, hidden decision facts, or false completion.
- The response stays read-only and claims no accidental mutation authority.
- The final line begins exactly `NEXT_STEP:`.

---
name: submit
description: Run the pull request tail after a change has been implemented and validated. Sync the real merge diff, review it adversarially, hold for explicit push and pull-request approval, babysit the open pull request, and close through Lavish without merging.
---

# $submit: sync, adversarial panel, push, open pull request, babysit to green, closing report

Invariant triggers are pointers, not restatements.
The panel is one PDW in step 1.
Findings block only with a runnable reproduction in step 1.
Read and update the canary at panel time and close time in step 1.
Every monitor or wake payload carries the loop count, both caps, and the closing tail rule from step 3.
The pull request stays open under Constraints.

Precondition: do not start until the change is implemented and confirmed against the evidence bar.
When arriving from `$build`, the loop must have exited as Done or an approved scope-creep cut, its spillover must be recorded, and final validation must be green.
Finish validation first when that precondition is not met because `$submit` is the pull request tail and not the build tail.

Invoking `$submit` requests this pipeline but does not authorize an outward action.
The human must explicitly approve the push and pull-request opening at step 2 after seeing the drafted title and body.
Merge requires a separate explicit human decision after this skill finishes.

## The loop

### 0. Sync the base first

Determine the repository's remote default branch.
Fetch origin, then rebase or merge the work branch onto the latest remote default branch.
Resolve conflicts before review so the panel sees the diff that would actually merge.
If the sync changed a touched file, rerun its affected tests before the panel.

### 1. Pre-push adversarial panel: model and persona matrix, difficulty-gated

Run the review as one `$pdw` owned by the top-level task.
Apply `$pdw` worktree, funnel, structured-return, effort-routing, and parent-return rules without restating their contracts here.

Read and update `state/submit-canary.json` at panel time and close time.
The file has exactly `pr`, `panel_missed`, `drip_rounds`, `note`, and `matrix_recall` fields.
CodeRabbit reviews the pushed pull request and acts as the post-panel canary.
Record `panel-missed-but-CodeRabbit-caught: N` in the closing findings ledger.
If CodeRabbit reports at least two real findings that the panel missed on one pull request, set `matrix_recall` to failed.
Also fail matrix recall when the canary records at least three drip rounds on two consecutive pull requests.
After recall fails, use one strong reviewer for later pull requests and flag the matrix for human redesign.

Apply the difficulty gate before choosing review width.
A mechanical diff such as a lockfile bump, version bump, configuration field, copied string, or deterministic-test-covered change gets one strong reviewer.
A subjective, multi-file, or logic diff gets three to six distinct model and refutation-persona pairs scaled to complexity and depth.
Each cell reviews the whole diff through its persona instead of topic-sharding the diff.
Every cell records requested and effective model and effort, the routing rationale, and whether the launch path enforced either control.

A finding blocks only when it carries a runnable failing test, replay, or mutation that breaks the fix and makes the test fail.
A finding without a runnable reproduction is speculative, goes to human inspection, and cannot gate or start a fix loop.

Panel cells return records with `defect`, `repro_ref`, `severity`, and `confidence`.
Fold records pairwise to deduplicate and rank them so a finding cannot disappear inside one many-way read.
Re-emit the exact adversarial stance, verify-by-refutation rule, and outward-action fences in every panel and fold brief.

Run local Codex review beside the panel as the second automated lens.
Use `codex review --base <default-branch> -c 'model_reasoning_effort="high"'` for High.
For a hard diff, request Max and use the nearest supported local value only when the routing record states both requested Max and effective `xhigh`.
Do not invoke a separately billed cloud review automatically.
Dedupe local Codex findings against the panel through the same pairwise fold.

Fix every confirmed issue from the panel or local Codex review before pushing.
Re-panel after any non-trivial fix.
At close time, count confirmed issues the panel missed but local Codex or CodeRabbit found in the canary ledger.

### 2. Commit, then hold for push and pull-request opening

Commit with explicit pathspecs and do not sweep in another worker's staged files.
Use the repository's title convention when one exists.
Otherwise use `type: [service] optional-subcategory - description` with `feat`, `fix`, `refactor`, `chore`, or `docs`.
Do not add a co-author or generated-by footer.

If pre-commit reformats files, stage explicit paths, make the checkpoint commit, restage those same paths, and amend only before any push.
Never amend a pushed commit.
Move off the default branch before any push.

Draft the pull-request body in this order: Summary, Debug evidence, Validation, Risk.
Summary states the original intent and where the problem was observed.
Debug evidence includes recorded session identifiers, screenshots, or log excerpts.
Validation includes exact commands and pass counts.
Risk names what could still fail and the exact hunks worth human attention.

Show the drafted title and body to the human and HOLD for explicit approval to push and open the pull request.
After approval, push only the reviewed branch and open the pull request through the repository's approved GitHub tool.
If a proven installed guard requires a one-shot submit sentinel, use only the sentinel documented by that guard immediately before opening the pull request.
Do not invent a sentinel or bypass an unproven guard.
Leave the pull request open.

### 3. Babysit to green and CodeRabbit-clean as a loop

Done means continuous integration is green on the current head SHA, CodeRabbit has no unresolved blocking finding on that SHA, and the closing report is published.
Use one owning monitor or Codex automation as the wake carrier instead of foreground watching.
Every monitor or wake payload records the current loop count, re-panel threshold 4, pause threshold 16, and `NEXT_STEP: on green invoke $lavish report mode`.
Notify only when the pull request becomes ready for the merge decision, loop 4 triggers a re-panel, loop 16 triggers HOLD, a hard continuous-integration failure appears, or a new CodeRabbit finding arrives.
Work on another independent task while the loop waits.

Verify every CodeRabbit or human review comment against the actual current diff.
Never dismiss a comment as pre-existing without checking it.
Fix confirmed findings in an isolated writing worktree and commit explicit paths.
HOLD for explicit human approval before every subsequent push, review reply, or review-thread resolution, then repeat.
Resolve addressed review threads through the approved GitHub tool.

### 4. Re-panel every 4 stuck loops

After four continuous failing review or continuous-integration loops, stop the one-fix-per-round pattern.
Run the same difficulty-gated panel from step 1 over the current diff.
Reset the continuous stuck counter only when the blocking state materially changes.

### 5. HOLD at 16

At loop 16, stop.
Publish a concise HOLD note with the failing state, what was tried, and the leading hypothesis.
Do not keep polling or fixing without a new human decision.

### 6. Closing report through $lavish report mode

When the pull request is green and CodeRabbit-clean, or when step 5 produces a HOLD note, update the workstream's existing Lavish page in report mode.
Lead after the short summary with a rendered diagram of the final pipeline as it now stands and highlight the parts this pull request changed.
Then include the per-change summary, panel and CodeRabbit findings with their resolution, recorded validation evidence, pull-request link and status, and the risk-tiered human review pointer.
End with next steps and the explicit remaining merge decision.
Send the stable Lavish URL with a short task summary through the injected top-level return route.
The page is the merge decision surface, and `$submit` still does not merge.

## Constraints

- Leave the pull request open.
- Pull-request opening requires explicit human approval after the title and body are drafted.
- Merge requires a separate explicit human decision and is never performed by `$submit`.
- Give the opened pull request a risk rating and point to the exact high-risk hunks worth human review.
- State which hunks the panel, local Codex review, and CodeRabbit already covered.
- Draft every outward message or review reply for human approval before sending it.
- Use explicit pathspecs for git writes and never include another worker's staged files.

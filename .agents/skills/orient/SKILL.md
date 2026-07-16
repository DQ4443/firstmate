---
name: orient
description: >-
  Produce a concise, verified orientation when the user invokes /orient or asks "what is the bigger picture", "remind me what this task is doing", "what does success look like", "where are we and what happens next", or "give me the decision-relevant status".
  Do not use for a one-line status lookup, raw logs, detailed debugging, or a request to implement or fix work.
user-invocable: true
metadata:
  internal: true
---

# orient

Give David the decision-relevant shape of the current task from verified current task state.
Read-only by default.
Do not mutate the task, code, Linear, GitHub, deployments, Slack, or email unless the user separately asks.

## Verify current state

Read the task ledger, branch and worktree, linked ticket, pull request and checks, current artifacts, and latest owner returns when they are available.
Use only sources that bear on the current goal, proof, blocker, decision, or next action.
Separate facts, inference, and unknowns.
Label an inference as inference and say what would verify an unknown.
Do not invent status, infer completion from activity, or narrate history.
Surface a dependency or duplicate ownership only when it changes the next action.

## Answer

Use exactly these four headings, once each and in this order:

1. `## Bigger picture`
2. `## Success`
3. `## Current status`
4. `## Next steps`

Do not put an executive paragraph before `## Bigger picture`.
The fixed order keeps implementation state from obscuring what the task is for.
Default to 150 to 300 words unless the task genuinely needs more.

### Bigger picture

Explain the practical user or product purpose in plain language.
Answer what the task is trying to make possible, for whom, and why it matters.
Lead with what the user can do or trust, not the ticket mechanism or an internal function, service, carrier, solver, artifact, provenance field, or implementation seam.
Translate internal nouns into the user action and outcome: replace "the pipeline passes carrier identity into solver X" with "a user chooses an input once and can trust the displayed result still reflects that choice."
Keep this section free of blockers, dependencies, waiting language, ticket or pull-request state, branch or commit details, evidence levels, and next moves.
Those details belong later.

### Success

State falsifiable whole-ticket acceptance from the user's entry point through the user-visible result in observable end-to-end terms.
Describe the behavior and proof that would close the ticket, plus any explicit non-goals that prevent a misleading completion claim.
If verified sources do not establish the user's entry point or visible result, name that acceptance gap and the source needed to close it instead of starting the success path halfway through.
Make the first Success sentence begin at the verified user action, or state that this first acceptance boundary is unknown and what source must establish it.
Unit tests alone cannot close a user-visible behavior.
Name the exact end-to-end proof still needed when it has not been observed.

### Current status

Report what is complete, what is unproven, the evidence for each claim, blockers, risks, and the evidence level without replaying the work history.
Omit branch names and commit SHAs unless either changes the next action.
Treat worktree cleanliness and branch sync lag as status noise unless they cause a different next step.
For a live decision, state the exact choice or authority needed, recommend one option, name its material tradeoff, and explain the consequence of delay or the choice.
Omit decision detail when no decision is due.

### Next steps

Order next steps by dependency.
Give each step an owner and its prerequisite or gate.
Identify the first action David needs to take in this section, or say explicitly here that no action is needed from him.
End with a literal `NEXT_STEP:` line.

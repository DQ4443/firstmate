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

Lead with one self-sufficient executive paragraph that states the big-picture goal, why the task exists, current status, the decision or blocker that matters now, and the recommended next action.
The first paragraph must be enough for David to act without reading further.
Then use only the smallest useful headings or table to cover the remaining material.
Default to 150 to 300 words unless the task genuinely needs more.

State success in falsifiable terms, including the observable end-to-end behavior or evidence that would close the task and any explicit non-goals.
Unit tests alone cannot close a user-visible behavior.
Name the exact end-to-end proof still needed when it has not been observed.

Report what is complete, what remains, blockers, risks, and the evidence level without replaying the work history.
For a live decision, state the exact choice or authority needed, recommend one option, name its material tradeoff, and explain the consequence of delay or the choice.
Omit decision detail when no decision is due.

Order next steps by dependency.
Give each step an owner and its prerequisite or gate.
Identify the first action David needs to take, or say explicitly that no action is needed from him.
End with a literal `NEXT_STEP:` line.

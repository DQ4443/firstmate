---
name: submit
description: The delivery tail once a change is implemented AND validated. Sync onto main, run a structurally-independent adversarial review panel, fix to clean, then ship through the no-mistakes pipeline (review, tests with evidence, lint, docs, push, PR), publish a merge-review page, and route the merge by the grant model. Auto-applies when a validated change needs driving to an open, green, reported PR. Submitted is not merged: Kronos product code waits on David's completion-doc approval; non-project code merges autonomously under the standing grant.
argument-hint: [branch / worktree / PR title hint]
user-invocable: true
allowed-tools: Bash, Read, Write, Edit, Grep, Glob, Agent, Workflow, Task, Skill, Monitor, PushNotification, ScheduleWakeup
---

# submit — panel, then no-mistakes, then the merge gate

The ship tail, not the build tail. This is Jim's /submit adapted: same shape (sync, adversarial panel, fix, drive to green, closing report), but our terminal ship phase is the no-mistakes pipeline, our reviewer routing follows the phase-model rules, our closing report is the merge-review contract, and our merge is gated by the grant model rather than always left for a human click.

Precondition (do NOT start until it holds): the change is implemented AND already confirmed to actually work by a real run / e2e / tests. If it is not validated yet, validate first; this skill is the ship tail. Every writing agent that produced the change committed before returning, in its own worktree; a dirty worktree at return is a failed hand-back (AGENTS.md prime rule 4). Never develop on main (prime rule 8).

## Harness portability (why this is a file, not a habit)

The pipeline shape, the panel independence rule, the fix-loop cap, and the merge routing all live in this file. A ship agent, whatever its harness, drives a conformant delivery by reading these nodes; it does not rely on absorbed firstmate lore. The tail rules (invoke the merge-review page on green; route the merge by grant) fire long after this text is compacted, so they ride the workflow return values as `NEXT_STEP` (AGENTS.md section 4 mechanical pinning): a build/panel workflow return carries the next contract-critical action explicitly.

## The node pipeline

### Node 0 — SYNC THE BASE

- Entry: a validated change on its branch in an isolated worktree.
- Action: `git fetch origin`, rebase (or merge) onto latest origin default branch, resolve conflicts now. The panel must review the diff that will actually merge, not a stale base. If the sync pulled real changes to files you touched, re-run the affected tests before panelling.
- Exit: the branch sits on current main with conflicts resolved and tests still green.

### Node 1 — INDEPENDENT ADVERSARIAL REVIEW PANEL

- Entry: the synced diff plus the claim it makes.
- Action: run the panel as ONE Workflow-tool call, structurally independent: a separate agent (never the author, never self-review) receives the diff and the claim and tries to BREAK it (AGENTS.md section 4: red team is structurally independent; required for standard and large tiers before any merge ask). This is one of the two additive takes from Jim (decisions.md). Scale the panel to the diff: mechanical diffs (lockfile bump, config-field add, prose copy, changes already covered by deterministic tests) get one strong reviewer, no panel; subjective/multi-file/logic diffs get a matrix of 3-6 distinct (model, refutation-persona) cells, each sweeping the WHOLE diff through its lens (diversity of stance is the coverage mechanism, not topic-sharding). Every cell's brief carries the funnel junk-rejection clause; findings fold through the funnel gate. A finding only BLOCKS if it ships a runnable repro (a failing test, a replay, a mutation); no repro means demoted to "captain inspects," never a fix loop.
- Reviewer model: the standing principle is GPT-5.5 as the code reviewer at xhigh via codex (decisions.md phase-based routing). Codex is currently SHELVED (David 2026-07-08 "too finicky"), so the review runs as a native Opus panel at effort high until codex is un-shelved. The per-phase model is a knob (config/crew-dispatch.json), not hardcoded.
- Exit: a funneled findings ledger, each finding badged and either CONFIRMED-with-repro or demoted.

### Node 2 — FIX TO CLEAN (capped loop)

- Entry: the confirmed findings.
- Action: fix every confirmed issue. IMPACT >= EFFORT means fix it now, before the ask, including low-priority items whose impact is at least their effort (AGENTS.md decision principle 1); low-impact-plus-low-effort items get fixed silently, never listed as debt (decisions.md MERGE-GATE LOW-ITEMS RULE). Take the robust fix over the band-aid; if a fix is a stopgap, label it as one explicitly (decision principle 3). Re-panel if a fix is non-trivial, but CAP the loop at 2-3 rounds and stop as soon as no medium-or-higher-benefit issue remains; minor critiques do not justify another round (AGENTS.md section 4).
- Exit: no confirmed medium-or-higher finding remains; all fixes landed and committed.

### Node 3 — SHIP VIA NO-MISTAKES (the terminal phase)

- Entry: a clean, synced, panel-cleared branch.
- Action: ship through the no-mistakes pipeline: `git push no-mistakes <branch>` (or the /no-mistakes skill). This IS the terminal ship phase and owns review, tests with evidence, lint, docs, push, and PR-open (AGENTS.md section 5). Do NOT hand-roll push+PR; no-mistakes does it. Review is the terminal phase of the no-mistakes loop; Cursor Bugbot is a required check on KronosAIPS/core only (other repos keep the no-mistakes Opus review as sole reviewer; CodeRabbit is deferred). PR body carries the intent, debug evidence with recorded proof, exact validation commands and counts, and risk.
- Ship-agent reattach: the no-mistakes pipeline (~5-8 min of stages) can outlive a ship agent's window; the standard remedy is a thin finisher agent that reattaches via no-mistakes axi status + axi run --intent "<ticket> reattach" (decisions.md SHIP-AGENT PATTERN). Budget for it.
- Exit: an OPEN PR, CI running, no-mistakes stages passed.

### Node 4 — DEPLOYED E2E (Kronos product PRs only)

- Entry: an open PR for Kronos product code with a user-facing workflow.
- Action: e2e test as the expected user on the expected workflow, on the DEPLOYED product, not a branch rig (decisions.md 2026-07-09 eng-290 correction: the rig is not the deployed product; #96 was wrongly declared clean off a rig). If the deploy surface is stale, deploying it is part of finishing the ticket. Fix anything buggy, missing, wrong, misleading, unclear, or confusing, looping until nothing is left, max 2 iterations. Problems the e2e finds are folded INTO this ticket and its board row, never split into a new one (the ENG-290/306 fold rule, generalized: any bug on the surface folds in, and the row does not close while they are open). Where no user-facing workflow exists (test-only, pure infra), state "not relevant" explicitly in the merge ask.
- Exit: the deployed e2e passes with zero remaining fix items, or the two-iteration cap is hit and the residue is surfaced.

### Node 5 — MERGE-REVIEW PAGE (invoke lavish-gate REPORT mode)

- Entry: a green PR with its evidence pack.
- Action: `Skill(lavish-gate)` in REPORT mode. The page leads with the pipeline-recap diagram, states expected behavior explicitly, puts e2e evidence with screenshots and logs ahead of unit tests, badges every claim on the E0-E5 ladder, and consolidates the case-against-merging directly above the decision. The your-court block leads with the exact ask plus firstmate's recommendation, in dot points. Link it from the board thread with the full PR URL. David judges from this page, not the diff; a bare link is not a merge ask.
- Exit: the merge-review page is delivered via the lavish-axi editor lifecycle and linked on the row.

### Node 6 — ROUTE THE MERGE BY THE GRANT MODEL

- Entry: a merge-review page delivered.
- Action: route by what the change touches.
  - Non-project code (firstmate's own tooling, board, infra, docs): firstmate MAY merge, push to main, deploy autonomously under the standing grant, provided all of: an independent critique cleared it (node 1 satisfies this), all reasonable concerns addressed weighted by impact vs effort, and firstmate's best-effort review. LOG each such merge in data/operating-model (the autonomous-merge log). Then bin/fm-pr-merge.sh (squash default).
  - Kronos product code: does NOT merge unprompted. David's approval of the completion document (the node-5 page) IS the explicit word that authorizes the merge for that batch (decisions.md HUMAN GATE MODEL). There is no separate per-PR click; merge follows the approved completion doc, then bin/fm-pr-merge.sh. Never merge Kronos product code without David's word (prime rule 1).
- Exit: either an autonomous merge logged (non-project) or the PR held awaiting David's completion-doc approval (Kronos product).

### Node 7 — BABYSIT TO GREEN (loop, not attention)

- Entry: an open PR whose CI / Bugbot is still running or red, or a Kronos PR awaiting David.
- Action: run this as a loop, never foreground-watch. Arm a persistent Monitor on the PR head plus a ScheduleWakeup 1200-1800s fallback heartbeat; push-notify only on decision transitions (ready, hard CI fail, new Bugbot comment, give-up). Pin the loop count and caps onto the wake signal itself. Take every reviewer comment seriously, verify each against the actual diff, fix, push, repeat; resolve threads after addressing. Keep the whole board current (AGENTS.md section 5 PR/CI awareness): refresh open-PR status after any state change, at new work, on David's ask, and during long runs; surface to David only what needs his action. If a run is replaced (finisher, watcher), KILL the superseded run/task in the same turn as the replacement launch (decisions.md replacement-kills-predecessor).
- Exit: CI green + reviewer clean + the merge routed per node 6, or a concise give-up note surfaced.

## Where our rules override Jim

- Jim hand-rolls sync/push/PR and babysits Bugbot round-by-round; we push the whole terminal phase into the no-mistakes pipeline (review, tests, lint, docs, push, PR) and keep only the pre-push independent panel (the additive take) and the babysit loop on top.
- Jim's `~/.claude/.pr-go` git-guard sentinel is his; ours is the fm-write-fence plus no-mistakes owning the PR-open, so there is no sentinel to touch.
- Jim always leaves the PR open for a human merge; we route by the grant model: non-project code merges autonomously under the standing grant (logged), Kronos product code merges only on David's approval of the completion document.
- Jim's closing report is our merge-review contract, delivered through lavish-gate REPORT mode on the david-warm palette, badged on the E0-E5 ladder.
- Merge method is squash by default (bin/fm-pr-merge.sh), not Jim's normal-merge default.
- Reviewer routing follows the phase-model rules (GPT-5.5 reviewer via codex when un-shelved; native Opus panel while codex is shelved), a knob in config/crew-dispatch.json.

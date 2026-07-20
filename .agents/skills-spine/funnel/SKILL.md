---
name: funnel
description: The synthesis-hygiene gate every aggregating agent runs before folding upstream outputs into a brief or doc. Reject degenerate cell outputs, verify referenced artifact paths exist on disk, name dead lanes UNVERIFIED, dedupe against everything seen, and badge surviving claims on the E0-E5 ladder. Auto-applies to any synthesis, verify, merger, red-team-fold, or completion-doc-assembly brief. Wraps AGENTS.md section 4 as explicit pipeline nodes.
argument-hint: (no args, reference gate — its nodes ride inside a synthesis/verify/merger brief)
user-invocable: true
allowed-tools: Bash, Read, Grep, Glob
---

# funnel, the junk-rejection gate on every aggregator

> SUBSTRATE PRESENT (as of 2026-07-10): node 5 badges claims on the firstmate E0-E5 ladder in `data/operating-model/evidence-ladder.md`. That file is now on disk, installed untracked-local under David's Option C (the AGENTS.md evidence-ladder mandate merged in DQ4443/firstmate#26). The evidence-badge node is ready alongside the junk-rejection and dead-lane nodes; symlink activation remains David-gated.

A funnel is the point in a PDW where many upstream outputs converge into one brief that returns to the orchestrator. It is where junk gets laundered into false confidence: a survey cell returns a placeholder shell, the funnel silently ranks it, and the orchestrator acts on a fabricated table. This skill is the mandatory hygiene pass that stops that. Its nodes are the AGENTS.md section 4 funnel clause, written out so a fresh or weaker-harness agent runs them literally.

Ground truth this exists to prevent (both real firstmate incidents): the 2026-07-08 null board-row outage (a trivial edit delegated to an agent that wrote a null row and no one screened it) and the duplicate-tab resume wart (a resume re-ran journaled agents and the merger folded the dupes). Jim's parallel lesson: a survey cell returned `{"summary":"test","findings":[{"fact":"a"}]}` and the funnel built a ranked table on it, caught only by hand-reading the journal.

## Harness portability (why this is a file, not a habit)

The rules live in this file, not in a model's memory or persona. A funnel fires late in a long run, after the skill text that mandated it has been compacted out of context, so it must ride a mechanical carrier: every synthesis, verify, or merger agent BRIEF pastes this clause verbatim into the prompt (AGENTS.md section 4: "a weaker model needs the facts written down"). A GPT-5.5 review-fold cell dispatched via codex inherits these nodes by reading the brief, not by having internalized firstmate lore. Do not paraphrase the clause; paraphrase drops rules (Jim measured 0 to 38 percent violation on paraphrased constraints).

## WHEN this gate auto-applies

Any agent whose job is to CONSUME the outputs of other agents/cells and emit a combined product:

- funnel / aggregator cells inside a PDW (the classic case);
- verify or red-team synthesizers folding a panel's findings;
- a completion-document or merge-review-page assembler folding evidence from build + verify + red-team lanes;
- a board-row or backlog merger folding an agent's structured return into state.

Not for a single-source pass-through (one agent, one output, no aggregation) and not for the orchestrator answering a read-only lookup itself.

## The node pipeline (each brief runs these in order)

### Node 0 — INGEST

- Entry: the funnel cell holds the raw structured outputs of every upstream lane it is folding, plus the ORIGINAL constraints/schema those lanes were supposed to satisfy (re-emitted verbatim in the brief, never paraphrased).
- Exit: every lane is enumerated by name; none silently dropped for being inconvenient. A lane that failed to return at all is recorded as a MISSING lane, not skipped.

### Node 1 — DEGENERACY SCREEN

- Entry: the enumerated raw outputs from node 0.
- Action: reject degenerate outputs before they can be ranked or synthesized. Degenerate tells: placeholder strings (`test`, `foo`, `a`, `lorem`, `TODO`, `<...>`), single-character or one-word fields where prose was required, empty-but-schema-valid shells (the JSON parses but every field is a stub), findings with no anchor (no file, no command, no input to wrong-output), a summary that restates the prompt instead of reporting a result.
- Exit: each lane is tagged LIVE (real content) or DEAD (degenerate). A DEAD lane is never averaged in, ranked, or paraphrased into "the panel found." Its deadness is a finding, carried forward to node 3.

### Node 2 — ARTIFACT-PATH VERIFY

- Entry: the LIVE lanes from node 1, each of which may reference artifacts on disk (a worktree path, a screenshot, a log file, a committed sha, a report .md).
- Action: for every referenced path, confirm it exists before folding the claim that depends on it (`test -f`, `ls`, `git cat-file -e <sha>`). A claim resting on a path that does not exist is not evidence.
- Exit: paths that resolve pass through; paths that do not are stripped from the claim and the claim demoted to UNVERIFIED, carried to node 3. Never fold a "screenshot proves X" or "committed at <sha>" claim whose artifact you could not confirm.

### Node 3 — DEAD-LANE NAMING

- Entry: the DEAD lanes (node 1), MISSING lanes (node 0), and UNVERIFIED claims (node 2).
- Action: name each one explicitly in the emitted brief as UNVERIFIED or DEAD, with the reason. Never paper over a dead lane by quietly omitting it, because omission reads to the orchestrator as "this angle was covered and clean" when it was neither.
- Exit: the brief's coverage is honest: every angle that was supposed to be probed either has a real result or is flagged as not-actually-covered. Silent omission is the defect this node kills.

### Node 4 — DEDUPE

- Entry: the surviving LIVE, path-verified claims.
- Action: dedupe against EVERYTHING seen, not just what this funnel already accepted. Two lanes reporting the same finding collapse to one (keep the better-anchored). Watch specifically for duplicate-tab / resume artifacts, where the same agent's output appears twice because a resume re-ran a journaled cell.
- Exit: no finding is double-counted; severity ranking reflects distinct findings, not repetition.

### Node 5 — EVIDENCE BADGE (only for claims bound for a David-facing doc)

- Entry: the deduped claims destined for a completion document or merge-review page.
- Action: tag each landed claim with its badge on the firstmate E0-E5 ladder (data/operating-model/evidence-ladder.md, NOT Jim's ladder): E0 asserted, E1 code-read, E2 unit tests green, E3 deployed e2e as the expected user (the ready-to-merge bar), E4 independently reproduced by a non-author agent, E5 David-verified live. An unbadged claim reads as E0.
- Exit: every claim carries a badge; anything below E3 on a merge ask is flagged for the case-against-merging section. (For an internal-only funnel that never reaches David, this node is skipped and stated as skipped.)

### Node 6 — EMIT

- Entry: the badged, deduped, honestly-scoped set.
- Action: emit the tight funneled brief. Only the brief returns to the orchestrator; the raw transcripts stay in the workflow journal.
- Exit: the brief names its live findings, its dead/unverified/missing lanes, and (where relevant) its E-badges. A brief that presents a clean ranked table with no dead-lane accounting has failed this gate.

## Orchestrator-side backstop (not part of an agent brief)

On any workflow whose funneled result looks thin, too-clean, or surprising, READ state/ledgers or the run journal before trusting it, exactly as the section 4 clause was born from doing manually. The funnel gate is defense-in-depth; the orchestrator reading the journal on a suspicious return is the second layer.

## Where our rules override Jim

- Jim's funnels badge on his E-ladder (E1 ran ... E5 refute-survived). Ours badge on the firstmate E0-E5 ladder (E3 = deployed e2e as the expected user, E5 = David-verified live). Use ours.
- Jim's incident was a Chronos survey cell; ours are the null-row outage and the resume dupe. Same mechanism, our provenance.
- The clause is pinned in AGENTS.md section 4 as a mandate on every synthesis/verify/merger brief; this skill is that mandate expanded into runnable nodes.

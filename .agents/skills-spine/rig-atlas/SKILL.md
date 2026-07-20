---
name: rig-atlas
description: Scour the LIVE firstmate rig (the contract in AGENTS.md and CLAUDE.md, the pins in data/operating-model/decisions.md, the .agents/skills suite, the bin/ deterministic harness, the board and poller contracts, and the operating-model layer) and refresh its documentation to current state. The deliverable is the WHAT-is-here atlas (data/operating-model/rig-atlas.md, tracked) plus a david-warm mirror page folded into the existing rig page in place. Invoke after the rig changes (a new/removed/renamed skill, a new/removed bin/ script, a new dated pin in decisions.md, an AGENTS.md section edit, a new eval grader, a board or poller contract change) or periodically to catch drift. NOT for documenting product/repo code, NOT for a single skill's own inline edit, and NEVER for inventorying live operational state or secrets.
argument-hint: <optional: which rig surface changed, or "full">
user-invocable: true
metadata:
  internal: true
---

# rig-atlas: scour the rig, refresh its atlas + the david-warm mirror

> SUBSTRATE PRESENT (as of 2026-07-10): this module reads and documents `data/operating-model/{components/david-warm.html, evidence-ladder.md, funnel-rules.md, evals/*}` (surface 5, and it copies david-warm.html verbatim to build the mirror page). Those files are now on disk, installed untracked-local under David's Option C (the AGENTS.md mandates merged in DQ4443/firstmate#26). The module is ready; symlink activation remains David-gated.

> ACTIVATION-GATED (David decides). A recurring self-scour that refreshes the atlas and ships it autonomously is a NET-NEW behavior beyond David's two approved additive takes from Jim (mechanical pinning, the /submit adversarial review panel). Before this runs live, David decides the SCOUR CADENCE: (a) event-triggered only (run on a named rig change, the invoke conditions in the frontmatter) vs (b) event-triggered plus a periodic sweep (and if periodic, how often). The recommendation is event-triggered only to start, adding a periodic sweep later if drift proves it necessary. Do not treat any periodic cadence as settled until David rules.

The rig is firstmate's operating harness on this machine: the contract that governs the session, the pins that lock its near-term calls, the skill suite, the deterministic bin/ scripts, the board and poller contracts, and the operating-model layer the skills lean on.
This module re-reads all of it from the LIVE files and brings its documentation back into sync.
It is the seventh, meta member of the spine: it closes the loop on the system itself.

Ported from Jim's /rig-atlas.
Where Jim scours a personal never-committed notes rig, firstmate scours a tracked, committed contract-plus-harness rig, so two of Jim's invariants flip (see "Where our pins override Jim" below).

## Purpose

Documentation drifts silently.
A new bin/ script lands, a pin is added to decisions.md, a skill is retired to the escape hatch, and the atlas that a fresh or compacted session reads to orient itself is now a lie.
rig-atlas is the self-maintenance pass that diffs the live rig against its own documentation and refreshes the atlas to current state, so the map always matches the territory.

## Harness portability (rules in files, not memory)

Firstmate's behavior lives in files (AGENTS.md, the pins, the skills, the bin/ scripts), never only in a session window that compaction or restart erases.
rig-atlas exists to keep that file-based rig legible: a WHAT-is-here atlas is what a compacted session, a fresh restart (AGENTS.md section 8), or a new machine (bin/fm-bootstrap.sh) reads to reconstruct the rig.
Every node below cites its governing file by path, and the pipeline's tail rides a NEXT_STEP pin (AGENTS.md section 4) because this skill's prose is compacted out of a long run before the redeploy fires.

## The rig surfaces you scour (exact paths)

Five distinct subjects. Nothing else is in scope.

1. **The contract** = `AGENTS.md` (the governing sections, 1 through 12) + `CLAUDE.md` (the always-loaded preamble) + `data/captain.md` (the merge-review contract, historical filename, stays) + `data/operating-model/decisions.md` (David's locked near-term pins).
   Read the BODIES.
   Record the section map of AGENTS.md and the pin index of decisions.md (each pin's dated title, one line), never a paraphrase that will rot.
2. **The skill suite** = `.agents/skills/` (the live firstmate instruction surface) + `.agents/skills-spine/` (the staged spine, not yet symlinked live) + `skills/` (public, installer-facing, NOT loaded by firstmate, per updatefirstmate).
   Classify every skill: SPINE (the general workflow: pdw, build, scout, lavish, submit, rig-atlas, evals-runner) vs DOMAIN (a project or task wrapper: tracker-sync, kronos-ticket, daily-sync, hq, and the like) vs ESCAPE-HATCH (retired for new dispatch, kept on disk per AGENTS.md section 12: harness-adapters, fmx-respond, afk, stuck-crewmate-recovery, secondmate-provisioning, updatefirstmate).
   Note which spine skills ship evals coverage in `data/operating-model/evals/` and which do not; never claim "every skill ships evals."
3. **The deterministic harness** = `bin/` (the fm-*.sh scripts) + `config/` (crew-dispatch.json, the launchers, crew-harness).
   Group the scripts by function (board, poller and wake, worktree and teardown, ledger and check-in, codex worker dispatch, fleet sync and PR merge, session lock and recovery), one line each on what the script owns.
   This is the layer AGENTS.md keeps calling by name; the atlas is its index.
4. **The board and liveness contracts** = `state/*.check.sh` (the poller checks) + `bin/fm-board-*.sh` + `bin/fm-item-agent.sh` + `docs/liveness-board.md` + `docs/event-wake.md` + the launchd job `com.firstmate.poller` (bin/fm-poll.sh).
   Document the CONTRACT and the schema of `state/board.json` (the section semantics, the derive-In-progress rule), never a live row's text.
5. **The operating-model layer** = `data/operating-model/` structure: `decisions.md` (already surface 1), `evals/` (the per-flow graders wrapped by the evals-runner module), `components/david-warm.html` (the canonical component library), `evidence-ladder.md` (E0 through E5), `funnel-rules.md`.
   Layout and purpose only.

## Scope exclusion (HARD rule, our analog of Jim's memory-dir exclusion)

- **Live operational STATE is OUT of the scour and OUT of the atlas.** Never read, list, inventory, or transcribe the CONTENTS of `state/` (queues, board.json row values, check-in stamps, ledgers under state/ledgers/), the live values in `data/backlog.md`, board thread contents, the journal, or the `projects/<name>/` fleet clones and David's `~/dev/work` trees.
  Document CONVENTIONS, SCHEMA, and CONTRACTS; never live values.
  board.json's section semantics, yes; a row's task text, no. The ledger schema keys, yes; a run's values, no.
- **Secrets, tokens, and PII are NEVER inventoried or transcribed.** Cite the HANDOFF redaction rule (reference state by its regenerating command, never paste a secret) and the fm-linear precedent (token never printed).
  If a config file carries a credential, name the file and its purpose, never its value.
- **The memory mechanism gets at most one line.** Firstmate's durable memory is the tracked files under `data/` (backlog.md, captain.md, projects.md, budgets.md), size-managed by convention, per AGENTS.md section 10. That is the whole mention; do not inventory their live contents.

## The deliverable (three things, landed together)

- **(a) The WHAT-is-here atlas** = `data/operating-model/rig-atlas.md` (create if missing).
  A living current-state inventory of the five surfaces: the full skill roster with SPINE/DOMAIN/ESCAPE-HATCH classification and evals coverage, the AGENTS.md section map, the decisions.md pin index, the bin/ script inventory grouped by function, and the board and poller contract summary.
  This is the doc that answers "what is on this machine right now."
- **(b) A david-warm mirror page**, folded IN PLACE into the existing rig page (never a new standalone artifact), copying its components VERBATIM from `data/operating-model/components/david-warm.html`, deployed through the lavish-axi editor per the DOC REVIEW pin in decisions.md, and attached to the board row's links field (AGENTS.md row anatomy).
  If no rig page exists yet, create one once, then update it in place on every later run.
- **(c) The drift changelog** in the board thread and the run's structured return: what changed since the atlas was last written (added/removed/renamed skills, new/changed bin/ scripts, new pins, AGENTS.md section edits), as a concrete diff, never a full re-derivation.

## Where our pins override Jim

- **Jim's notes rig is never committed; ours is.** The atlas and the david-warm page are TRACKED material and ship autonomously through no-mistakes under the prime-rule-1b standing grant (non-project code: independent critique, concerns addressed by impact vs effort, best-effort firstmate review, logged in decisions.md).
  Jim's "nothing here is ever committed" invariant is inverted for us; the replacement invariant is the secrets/state exclusion above.
- **Jim excludes a memory dir; we exclude live operational state.** The exclusion's shape is identical (conventions and schema, never contents), the target is different (state/, backlog values, journal, projects/ clones instead of a MEMORY.md tree).
- **Jim regenerates a HOW-to-replicate guide from a generator script; we do not maintain a separate generator.** Firstmate's replication path is bin/fm-bootstrap.sh plus the tracked repo itself; the atlas is the human-readable index over it, refreshed by this skill directly (no assemble step).
- **Jim's oat/lavish artifact becomes our david-warm + lavish-axi editor.** The house style is `data/operating-model/components/david-warm.html`, the review surface is the lavish editor per the DOC REVIEW pin, not a bare Artifact publish.

## The node pipeline

Run as a scout-shaped fan-out through the Workflow tool (AGENTS.md section 3: all delegated work is a PDW, even thin).
Scour cells are read-only; the single write happens in one isolated worktree (prime rule 3), which commits before return (prime rule 4).

### Node 0: Orient

- ENTRY: rig-atlas invoked.
- Load the shape: read the pdw and scout module pipelines for Workflow mechanics and fan-out discipline.
- Read the baseline you diff against: the current `data/operating-model/rig-atlas.md` (if it exists) and its state-stamp, and the existing rig page.
- EXIT: the baseline is in hand; you know what is already documented, so the run is a diff, not a re-derivation.

### Node 1: Inventory fan-out (one surface-PDW per surface, in parallel)

- ENTRY: baseline loaded.
- Launch one Workflow per rig surface (contract, skill suite, harness, board contracts, operating-model layer), each with read-only cells sized dynamically to the surface (the skill suite warrants several read cells and a cross-ref pass; a single presence question is one `test -f`).
- Each cell reads BODIES with Read/Grep/Glob and `ls`/`test` Bash only; no cell touches `state/` contents, backlog values, the journal, projects/ clones, or any secret.
- Each surface-PDW funnels to a tight CURRENT-STATE brief (facts plus exact paths, skills classified SPINE/DOMAIN/ESCAPE-HATCH).
- EXIT: five current-state briefs returned, cell transcripts left in the journal, only the funneled briefs in context.

### Node 2: Convergence (diff, then write the atlas)

- ENTRY: five briefs in hand.
- DIFF vs the atlas: for each surface list what DRIFTED (added/removed/renamed skills, new/changed bin/ scripts, changed model routing, new dated pins in decisions.md, AGENTS.md section edits, stale claims or a stale state-stamp in the atlas). Produce a concrete changelog.
- WRITE the atlas `data/operating-model/rig-atlas.md` in place (create if missing) to current state, honoring the scope exclusion verbatim (state and secrets out, conventions and schema only).
- This write happens in one isolated worktree; it commits before the node returns.
- The return value MUST carry `NEXT_STEP: 'fold the refreshed atlas into the rig page in place via the lavish editor, then run the evals-runner grader before hand-back'`.
- EXIT: the atlas reflects current state, the changelog is written, the worktree is committed and clean, NEXT_STEP is pinned.

### Node 3: Mirror page (david-warm, in place, LAST)

- ENTRY: convergence-workflow completion, NEXT_STEP surfaced.
- Copy components VERBATIM from `data/operating-model/components/david-warm.html`; add no style the library does not carry.
- Fold the refreshed inventory into the existing rig page IN PLACE (bump its state-stamp), never mint a new standalone artifact, never append a dated section.
- QA the render before publish (screenshot at 390px and desktop, read it, no border-left, no em dashes, warm light only), then deploy through the lavish-axi editor and attach the link to the board row.
- EXIT: the rig page shows current state at its stable link, QA passed, link attached.

### Node 4: Grade and hand back

- ENTRY: atlas and page refreshed.
- Run the evals-runner grader against `decision-doc.md` (the page is a firstmate-produced David-facing doc). Any FAIL blocks the hand-back until fixed.
- Deliver via no-mistakes (this is tracked non-project code); log the autonomous merge in decisions.md per prime rule 1b.
- Close the board row with the drift changelog TL;DR and the page link (AGENTS.md board close-out).
- EXIT: atlas landed on main, page live, board thread closed, merge logged.

## Anti-patterns

| Tell                                                                 | Correction                                                                             |
| -------------------------------------------------------------------- | -------------------------------------------------------------------------------------- |
| One big Workflow with cells for all five surfaces                    | One PDW per surface in parallel plus a convergence workflow                            |
| Bare Agent spawns dumping full reports into context                  | Workflow-tool calls; only funneled briefs return (AGENTS.md section 3)                 |
| Reading or quoting `state/` contents, backlog values, or the journal | State is OUT; conventions and schema only, never live values                           |
| Transcribing a token, key, or PII from a config file                 | Name the file and purpose, never the value (HANDOFF redaction rule)                    |
| Minting a new standalone atlas artifact                              | Fold into the existing rig page in place, bump the state-stamp                         |
| A border-left stripe or an em dash on the page                       | david-warm forbids both; grep, then confirm on render                                  |
| Ending in chat with the atlas updated but no page and no grade       | The committed atlas plus the redeployed page plus the passed grader is the deliverable |
| Claiming a skill ships evals when it does not                        | Check `data/operating-model/evals/` coverage; state it honestly                        |

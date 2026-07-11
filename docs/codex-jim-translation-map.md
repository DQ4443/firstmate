# Jim workflow to Codex translation map

This document is the pre-code fidelity gate for reproducing Jim's workflow on Codex.
Implementation may begin only after every source component below has one Codex target and one acceptance check.
The abandoned custom runtime, submit state machine, authorization schema, review ledger, and reporting framework are out of scope.

## Source of truth

The source is `/Users/dq4443/Downloads/message (4).txt`.
Its SHA-256 is `134eb182731726ae9305d6a7a74d8a767bfb7f042201e953536ceec507f19f7c`.
The file has 3,510 lines and is state-stamped 2026-07-10.
The atlas and system model are at lines 1-192, the verbatim skill suite begins at line 248, the roles begin at line 1,356, the hooks begin at line 1,418, and the self-contained generator begins at line 3,057.
The clean canonical adaptation copy at lines 3,406-3,416 governs path swaps, project-specific deletions, submit substitutions, generic modules, human naming, and eval substitutions.
The same adaptation text appears earlier in the generated document, so the lines 3,406-3,416 copy is the comparison anchor.

## Translation boundary

Jim's nine skills, three roles, four hooks, composition graph, evals, round loop, and acceptance sequence remain the architecture.
Codex substitutions replace harness mechanisms only.
David's requested effort routing, Command Center return routing, worktree rule, CodeRabbit choice, and existing visual system are explicit deltas inside that architecture.
No atomic Codex equivalent exists for one Claude Workflow call.
Codex native task teams are inspectable in the desktop app and are the default way to express Jim's workflow cells.
Native subagent spawn cannot pin a per-worker model, reasoning effort, tool fence, or worktree isolation.
An explicit `codex exec` launch is the enforceable fallback when a worker needs a pinned model or effort, a restricted launch contract, or an isolated writing worktree.
The parent task owns the workflow topology and funnels because a worker must not create a competing orchestration layer.

## Exact target layout

The nine repo-local skills live at `.agents/skills/<name>/SKILL.md`.
The eight source graders live beside their skills as `.agents/skills/<name>/evals.md`, with no invented `oat/evals.md` because Jim's source has none.
The Lavish progressive-disclosure files live at `.agents/skills/lavish/references/decision-zone.md` and `.agents/skills/lavish/references/nav-sidebar.md`.
The thin Codex role definitions live at `.codex/agents/planner.toml`, `.codex/agents/implementer.toml`, and `.codex/agents/refute-reviewer.toml`.
The hook scripts live at `.codex/hooks/git-guard.py`, `.codex/hooks/session-title.sh`, `.codex/hooks/session-rename-nudge.sh`, and `.codex/hooks/pre-commit-install.sh`.
The repo-local Codex hook declaration lives at `.codex/hooks.json` only after its schema and project-scope behavior are proven against the installed harness.
The generated inventory lives at `.agents/rig/rig-atlas.md`, its portable twin lives at `.agents/rig/rig-atlas-neutral.md`, and its generator lives at `.agents/skills/rig-atlas/generate.py`.
No `.claude` artifact is a target of this port.
No `.agents/skills-spine` duplicate is permitted.

## Skill map

### pdw

`pdw` keeps Map to parallel Implement to adversarial Review to Synthesize, with funnels between stages.
It remains the single owner of parallel-first, the S/M/L/XL topology ladder, the three-case bare-agent rule, junk rejection, worktree isolation, structured returns, and `NEXT_STEP` pinning.
S/M/L/XL describes workflow shape and stays separate from worker reasoning effort.
Explicit `/pdw` never degrades to one untracked agent.
The Codex implementation uses one parent task with parallel native subagents for inspectable lanes and explicit `codex exec` for workers whose launch settings must be enforced.
The target files are `.agents/skills/pdw/SKILL.md` and `.agents/skills/pdw/evals.md`.

### build

`build` keeps intent, entry recon, checkpoint, parallel local and web move recon, plan plus TDD, implementation team, E-ladder validation, commit, and repeat.
Every round commits before the next checkpoint.
The checkpoint page preserves append-only round history at the same Lavish path.
Exit remains final validation, same-page closing update, HOLD, and `/submit` only after explicit go.
The trivial passive hatch and the spike or pure-visual-UI observation hatch remain exactly as Jim defined them.
Explicit `/build` never degrades to one untracked agent.
The target files are `.agents/skills/build/SKILL.md` and `.agents/skills/build/evals.md`.

### scout

`scout` remains the research composer and never absorbs the two recon primitives.
It launches `explore` and `websearch` concurrently, then runs ideation, aggregation, razor, cheap experiments, and a Lavish decision page.
Multi-subject work keeps one workflow per subject plus convergence.
The target files are `.agents/skills/scout/SKILL.md` and `.agents/skills/scout/evals.md`.

### explore

`explore` remains local, read-only recon over code, git history, worktrees, configuration, and local notes.
It dynamically chooses two to five non-overlapping angles and returns one funneled brief with file and line anchors.
The target files are `.agents/skills/explore/SKILL.md` and `.agents/skills/explore/evals.md`.

### websearch

`websearch` remains web-only recon over current tools, official sources, papers, benchmarks, and field failures.
It dynamically chooses two to five non-overlapping angles and returns one sourced brief with a URL and date for every load-bearing claim.
The brief distinguishes what a source reports from what a worker independently verified.
The target files are `.agents/skills/websearch/SKILL.md` and `.agents/skills/websearch/evals.md`.

### lavish

`lavish` remains one plan, report, and checkpoint module with one living page per workstream.
It uses the existing `lavish-axi` workflow and copies David-facing components from `data/operating-model/components/david-warm.html` verbatim.
The decision-zone and dynamic nav-sidebar references remain mandatory reads before those structures are built.
Checkpoint pages remain append-only, preserve round and decision history, use typed response fields, and are rendered and visually checked before presentation.
The target files are `.agents/skills/lavish/SKILL.md`, `.agents/skills/lavish/evals.md`, `.agents/skills/lavish/references/decision-zone.md`, and `.agents/skills/lavish/references/nav-sidebar.md`.

### oat

`oat` remains the single style-owner boundary for Lavish output.
For David-facing output it points to `data/operating-model/components/david-warm.html` instead of introducing Jim's palette or a second component system.
It keeps the source's diagram, layout, and screenshot-QA duties where they do not conflict with David-warm.
The target file is `.agents/skills/oat/SKILL.md`.

### submit

`submit` keeps sync, one adversarial panel, commit, push, open PR, babysit, re-panel at round 4, HOLD at round 16, and the same Lavish closing page.
CodeRabbit replaces ReviewBot.
Opening a PR and merging remain human-gated, and `/submit` never merges.
The guard and submit sentinel remain paired if the guard is proven and installed.
The target files are `.agents/skills/submit/SKILL.md` and `.agents/skills/submit/evals.md`.

### rig-atlas

`rig-atlas` inventories the skill suite and evals, Codex harness configuration and hooks, role definitions, notes conventions, and curated memory policy.
It regenerates one atlas and one portable twin, then updates the existing Lavish system-study page last.
It documents live files and never becomes a second source of their contracts.
The target files are `.agents/skills/rig-atlas/SKILL.md`, `.agents/skills/rig-atlas/evals.md`, `.agents/skills/rig-atlas/generate.py`, `.agents/rig/rig-atlas.md`, and `.agents/rig/rig-atlas-neutral.md`.

## Role map

The planner remains a divergent, read-only mapper that returns ordered file-level steps, test plans, alternatives, and risks while flagging gated actions.
The implementer remains a convergent executor for one reviewed plan leaf and returns the minimal change plus targeted evidence.
The refute reviewer remains source-read-only, begins from not proven, accepts findings only with a concrete anchor or reproduction, and retains the defect-signature memory policy only if Codex can support it without inventing a new runtime.
Firstmate's repo rule overrides Jim for writers, so every writing worker receives its own worktree under the target repo's `.claude/worktrees/` and commits before return.
Native task teams use these role policies in their briefs because native role files cannot mechanically fence tools or pin worker models.
Explicit `codex exec` loads the matching role file when mechanical launch control is required.

## Hook map

The git guard is the only load-bearing hook and ports narrowly to Codex's proven `PreToolUse` schema.
It blocks push to main or master, prohibited co-author or generated-by commit text, amendment of a pushed commit, and PR creation without the one-shot submit sentinel.
It must preserve existing Codex hooks rather than overwrite `/Users/dq4443/.codex/hooks.json`.
Session title is optional and lands only if Codex exposes a tested native title operation at `SessionStart`.
The ten-prompt rename nudge is optional and lands only if Codex exposes a tested `UserPromptSubmit` hook with a reliable session counter.
Pre-commit installation is optional and may run at `SessionStart` only when the repo has a pre-commit configuration, the hook is absent, and `uvx` is present.
Any unproven native event is recorded as unsupported instead of approximated with a daemon or custom state machine.

## Composition edges

`build` calls `scout` for research-shaped entry recon, `explore` and `websearch` concurrently for move and issue recon, `pdw` for implementation, `lavish` for every checkpoint, and `submit` only after explicit go.
`scout` calls `explore` and `websearch` concurrently, uses `pdw` for its panel shape, and ends at `lavish`.
`explore` and `websearch` each use the `pdw` topology without merging into one recon module.
`submit` uses `pdw` for its adversarial panel and `lavish` for its closing report.
`lavish` reads `oat` first and then the required structural reference for each decision zone or sidebar.
Every spine skill cross-references the parallel-first and bare-agent rules in `pdw` rather than restating them.
`rig-atlas` inventories the full graph and updates the existing Lavish system study after regeneration.

## David deltas

The Command Center root requests `gpt-5.6-sol` at High effort by default.
A user-specified model or effort always wins.
Remaining quota never causes a downgrade.
The deterministic effort router maps Light to mechanical edits and lookups, Medium to routine bounded work, High to debugging, reviews, or consequential implementation, Max to one tightly coupled deep problem, and Ultra only to a large objective with an explicit independent-lane plan.
Every dispatch brief and structured return records `requested_effort`, `effective_effort`, and a one-line rationale.
If native spawn cannot enforce the requested setting, `effective_effort` says enforcement is unavailable and the launcher uses explicit `codex exec` when that path supports the setting.
Unsupported effort levels use the nearest supported fallback and record it without silently changing the request.
Every top-level brief receives `return_thread_id` and `return_host_id`.
Each native subagent returns to its immediate parent, and the top-level parent aggregates once to the supplied Command Center destination.
The return carries status, summary, command evidence, artifacts, branch, worktree, last commit SHA, requested and effective effort, rationale, identifiers, and `NEXT_STEP`.
Completion is not valid until that one report succeeds or the existing Command Center delivery mechanism queues its retry.
No new reporting state machine is part of this port.

## Acceptance gates

- A source extraction test verifies the SHA, all nine skill headings, all eight eval headings, both Lavish reference headings, all three role headings, all four hook headings, the generator, and the canonical adaptation copy at lines 3,406-3,416.
- A layout test rejects `.claude` targets, `.agents/skills-spine`, missing target files, an invented `oat/evals.md`, or any abandoned custom runtime and schema file.
- A fresh-session simulation traces every mandated action from only the installed text and rejects any missing tool or undefined cross-reference.
- A contradiction test checks that every skill and eval agree, `pdw` is the only owner of topology and bare-agent rules, `oat` is the style boundary, and `explore` and `websearch` stay separate.
- A role-routing test proves native task-team visibility and records the unavailable native model, effort, tool-fence, and isolation controls without claiming enforcement.
- An external-launch test proves explicit `codex exec` pins the requested supported model and effort, loads the requested role policy, writes only in the assigned worktree, and returns a clean committed SHA.
- Effort tests cover every mapping, user override precedence, unsupported fallback, the Ultra parallel-lane gate, requested versus effective values, and the no-quota-downgrade rule.
- Hook tests prove git-guard blocks each forbidden command and allows ordinary commands, existing Codex hooks survive composition, and unsupported optional events stay uninstalled.
- A build-loop test proves intent, concurrent entry recon, checkpoint publication, move recon, plan plus TDD, parallel implementation, E-ladder validation, per-round commit, repeat, same-page close, HOLD, and explicit `/submit` handoff.
- A Lavish test renders the page, reads the screenshot, checks David-warm component identity, typed decision input, dynamic sidebar, append-only round history, and stable same-file delivery through `lavish-axi`.
- A submit test proves CodeRabbit substitution, human-gated PR creation, re-panel at round 4, HOLD at round 16, no merge, and same-page closing report.
- A return-routing test proves child-to-parent aggregation, one top-level Command Center report, requested and effective status preservation, duplicate suppression by the existing delivery path, and a durable retry on failure.
- The final end-to-end test runs a small `/build` task through a visible task team, produces committed worktree evidence, waits at the first checkpoint, resumes through validation, closes the same page, holds for `/submit`, and reports once to the injected return task.

## Source coverage checklist

- [x] `pdw/SKILL.md` is covered from lines 248-339 and `pdw/evals.md` from lines 340-373.
- [x] `build/SKILL.md` is covered from lines 374-458 and `build/evals.md` from lines 459-495.
- [x] `scout/SKILL.md` is covered from lines 496-537 and `scout/evals.md` from lines 538-571.
- [x] `explore/SKILL.md` is covered from lines 572-629 and `explore/evals.md` from lines 630-662.
- [x] `websearch/SKILL.md` is covered from lines 663-724 and `websearch/evals.md` from lines 725-757.
- [x] `lavish/SKILL.md` is covered from lines 758-849 and `lavish/evals.md` from lines 850-887.
- [x] `lavish/references/decision-zone.md` is covered from lines 888-923 and `lavish/references/nav-sidebar.md` from lines 924-950.
- [x] `oat/SKILL.md` is covered from lines 951-1,135 and its intentional lack of `evals.md` is preserved.
- [x] `submit/SKILL.md` is covered from lines 1,136-1,191 and `submit/evals.md` from lines 1,192-1,221.
- [x] `rig-atlas/SKILL.md` is covered from lines 1,222-1,313 and `rig-atlas/evals.md` from lines 1,314-1,352.
- [x] `planner.md` is covered from lines 1,356-1,373, `implementer.md` from lines 1,374-1,392, and `refute-reviewer.md` from lines 1,393-1,417.
- [x] The hook declaration is covered from lines 1,421-1,467, `git-guard.py` from lines 1,470-1,589, `session-title.sh` from lines 1,590-1,630, `session-rename-nudge.sh` from lines 1,631-1,660, and `pre-commit-install.sh` from lines 1,661-1,677.
- [x] The self-contained generator is covered from lines 3,057-3,388 and the canonical adaptation duplicate is covered from lines 3,406-3,416.

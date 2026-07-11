# Jim workflow to Codex translation map

This document is the pre-code fidelity gate for reproducing Jim's workflow on Codex.
Implementation may begin only after every source component below has one Codex target and one acceptance check.
The abandoned custom runtime, submit state machine, authorization schema, review ledger, and reporting framework are out of scope.

## Source of truth

The source is `/Users/dq4443/Downloads/message (4).txt`.
Its SHA-256 is `134eb182731726ae9305d6a7a74d8a767bfb7f042201e953536ceec507f19f7c`.
The file has 3,510 lines and is state-stamped 2026-07-10.
The atlas and system model are at lines 1-192, the verbatim skill suite begins at line 248, the roles begin at line 1,356, the hooks begin at line 1,418, the curated portable memories occupy lines 1,678-3,055, and the self-contained generator occupies lines 3,057-3,505.
The clean canonical adaptation copy at lines 3,406-3,416 governs path swaps, project-specific deletions, submit substitutions, generic modules, human naming, and eval substitutions.
The same adaptation text appears earlier in the generated document, so the lines 3,406-3,416 copy is the comparison anchor.

## Translation boundary

Jim's nine skills, three roles, four hooks, composition graph, evals, round loop, and acceptance sequence remain the architecture.
Codex substitutions replace harness mechanisms only.
David's requested effort routing, Command Center return routing, worktree rule, CodeRabbit choice, and existing visual system are explicit deltas inside that architecture.
No atomic Codex equivalent exists for one Claude Workflow call.
Codex native task teams are inspectable in the desktop app and are the default way to express Jim's workflow cells.
Codex custom roles can use a `config_file` to carry model, reasoning effort, sandbox, and role instructions.
This session's `collaboration.spawn_agent` wrapper exposes only `task_name`, `message`, and `fork_turns`, so it cannot select one of those custom roles or prove that its controls took effect.
An explicit `codex exec` launch is the intended fallback when launch settings must be enforced, but no role-loader command is approved until the external-launch acceptance test proves its exact config carrier and effective settings.
The parent task owns the workflow topology and funnels because a worker must not create a competing orchestration layer.

## Exact target layout

The nine repo-local skills live at `.agents/skills/<name>/SKILL.md`.
The only workflow transport adapter lives with its owner at `.agents/skills/pdw/scripts/report-back.sh`.
The eight source graders live beside their skills as `.agents/skills/<name>/evals.md`, with no invented `oat/evals.md` because Jim's source has none.
The Lavish progressive-disclosure files live at `.agents/skills/lavish/references/decision-zone.md` and `.agents/skills/lavish/references/nav-sidebar.md`.
The thin Codex role definitions live at `.codex/agents/planner.toml`, `.codex/agents/implementer.toml`, and `.codex/agents/refute-reviewer.toml`.
The hook scripts live at `.codex/hooks/git-guard.py`, `.codex/hooks/session-title.sh`, `.codex/hooks/session-rename-nudge.sh`, and `.codex/hooks/pre-commit-install.sh`.
The repo-local Codex hook declaration lives at `.codex/hooks.json` only after its schema and project-scope behavior are proven against the installed harness.
The ignored live build ledgers live at `state/build-loops/<branch>.json`.
The ignored live submit canary lives at `state/submit-canary.json`.
The gitignored local rig root is `state/rig/`, preserving Jim's uncommitted notes boundary.
The generated inventory target is `state/rig/rig-atlas.md`, and its only sanctioned twin target is `state/rig/rig-atlas-portable.md`.
The exact embedded generator input lives at `state/rig/assemble_replication.py`.
Portable include-both memories from Appendix D live verbatim after token adaptation at `state/rig/portable-memory/<source-basename>.md`.
The generator records the include-both, full-only, and exclude-both classifications, but it does not copy project-private full-only or excluded content into this repo.
Lines 3,501-3,503 state that the portable sanitizer is redacted from this edition, so `rig-atlas-portable.md` regeneration is BLOCKED until David supplies the unredacted sanitizer.
The embedded generator may regenerate only `rig-atlas.md`, and any attempt to synthesize or guess the portable sanitizer must fail closed.
The repository tracks only the skills, evals, role source, hook source, and this translation document, while `state/rig/` and Lavish runtime output stay untracked.
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
The `pdw` grader requires evidence of the requested model and effort, the effective model and effort, and whether the selected launch path enforced either value.
The `pdw` grader requires distinct descriptive names for every lane and rejects idle watching when another independent wave can run.
The `pdw` grader enforces the topology ceilings of shared-machine contention, disjoint ownership or separate worktrees, and a width that the funnel can faithfully weigh.
The `pdw` grader rejects concurrent writers without explicit file ownership and rejects a writer that returns a dirty worktree or no commit SHA.
The `pdw` grader requires a funnel between panels, verbatim constraint carriers, and explicit UNVERIFIED labels for degenerate or missing lane output.
The `pdw` grader requires significant multi-stage output to close through Lavish with a short task summary, while a small single-wave result may return directly.
The acceptance test runs one lane with an unenforceable requested effort, one junk lane, two disjoint writers, and one deliberately serialized dependency, then checks every grader verdict and the final Lavish closure.

### build

`build` keeps intent, entry recon, checkpoint, parallel local and web move recon, plan plus TDD, implementation team, E-ladder validation, commit, and repeat.
The ledger at `state/build-loops/<branch>.json` starts with `round`, `intent`, `tier`, `mode`, `branch` or `branches`, `base`, `worktree`, `stacked_on`, `landed`, `spillover`, `verdict`, `next`, `decisions`, `proof`, `scout_artifact`, `loop_artifact`, `blockers`, `r4_gate`, and `preregistered_before_after`.
The `preregistered_before_after` record carries `baseline_arm`, `treatment_arm`, `metrics_rule`, and `seats_note`, and each decision carries `id`, `state`, `when`, `what`, and `by`.
Every round commits before the next checkpoint.
The checkpoint page preserves append-only round history at the same Lavish path.
Round 1 always waits because it is the plan-approval gate.
ACTIVE waits at every checkpoint, while PASSIVE takes the Recommended move and continues until termination-ready.
Every checkpoint in either mode publishes the page and sends one notification, with the artifact URL and `ready for your move` when David has a new move to choose.
The standing mode-flip question defaults to staying in the current mode and changes only the next rounds.
PASSIVE still pauses on DONE or scope-creep proposals, a blocker only David can clear, spend outside the authorized intent, and outward actions.
DONE and scope-creep are the only automatic cut triggers, with no cost-budget or wall-clock kill.
Move recon runs after the choice and before planning, and issue recon runs after failed validation before the next suggestion.
Validation requires E2 plus E3 for feature completion, adds E4 for downstream-influence claims, caps laptop-only artifacts at E1, requires mutation checks for key fixes, and requires a recorded screenshot that the reviewer read for UI work.
Every round return carries `NEXT_STEP: publish /lavish checkpoint -> stop-check`, and final validation carries the same-page closing update and HOLD instruction.
Exit remains final validation, same-page closing update, HOLD, and `/submit` only after explicit go.
The trivial passive hatch and the spike or pure-visual-UI observation hatch remain exactly as Jim defined them.
Explicit `/build` never degrades to one untracked agent.
The target files are `.agents/skills/build/SKILL.md` and `.agents/skills/build/evals.md`.

### scout

`scout` remains the research composer and never absorbs the two recon primitives.
It launches `explore` and `websearch` concurrently, then runs ideation, aggregation, razor, cheap experiments, and a Lavish decision page.
Multi-subject work keeps one workflow per subject plus convergence.
The target files are `.agents/skills/scout/SKILL.md` and `.agents/skills/scout/evals.md`.
The `scout` grader allows reasoning to cull only redundancy and YAGNI, while every other surviving candidate receives the cheapest settling test.
The `scout` grader requires cheap local experiments to run now and label their results MEASURED.
The `scout` grader requires expensive external experiments to remain unlaunched until explicit approval and a live cost-watch plan exist.
The `scout` grader requires each subject to receive its own concurrent explore and websearch shape plus one global convergence, never one lone probe per subject or one mega-workflow.
The `scout` grader requires a candidate-producing or experiment-running scout to end in Lavish, while a genuinely small single-wave scout reports its verdict directly.
The acceptance test feeds one redundant candidate, one YAGNI candidate, one uncertain cheap candidate, one expensive candidate, and two subjects, then verifies the culls, MEASURED experiment, held external gate, concurrent subject shape, and report mode.

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

`submit` keeps sync, difficulty-gated adversarial review, commit, push, open PR, babysit, re-panel at round 4, HOLD at round 16, and the same Lavish closing page.
Mechanical diffs receive one strong reviewer, while subjective, multi-file, or logic diffs receive three to six distinct model and refutation lenses over the whole diff.
Every blocking finding must carry a runnable failing test, replay, or mutation, and a finding without one is speculative and cannot gate.
Panel cells return structured defect, repro reference, severity, and confidence records that are deduplicated and ranked through a pairwise tournament fold.
CodeRabbit replaces ReviewBot as the post-push canary and review source.
The persisted `state/submit-canary.json` preserves Jim's `pr`, `panel_missed`, `drip_rounds`, `note`, and `matrix_recall` fields and updates them at panel time and close time.
Two real CodeRabbit misses on one PR, or at least three drip rounds on two consecutive PRs, switches later PRs to one strong reviewer and flags the matrix for redesign.
A local Codex code review runs as the second automated lens at High effort, or Max for a hard diff, and its findings are deduplicated against the panel.
Every confirmed panel, local Codex review, or CodeRabbit issue is fixed before proceeding, and any non-trivial fix triggers another panel.
The babysitting carrier records the current loop, re-panel threshold 4, pause threshold 16, and closing-report `NEXT_STEP` in every monitor or wake payload.
Four continuous failing loops trigger a new difficulty-gated panel over the current diff, and loop 16 stops with the failing state, attempts, and leading hypothesis.
Opening a PR and merging remain human-gated, and `/submit` never merges.
The guard and submit sentinel remain paired if the guard is proven and installed.
The target files are `.agents/skills/submit/SKILL.md` and `.agents/skills/submit/evals.md`.

### rig-atlas

`rig-atlas` inventories the skill suite and evals, Codex harness configuration and hooks, role definitions, notes conventions, and the curated memory files.
It classifies every memory as include-both, full-only, or exclude-both before regeneration.
Include-both means general doctrine copied into both editions, full-only means project-bound doctrine retained only outside the portable repo copy, and exclude-both means project state, personal profile, superseded rules, or credential-shaped content copied nowhere.
One secret or private line excludes the whole file because included memories are otherwise verbatim.
The supplied `assemble_replication.py` may regenerate `state/rig/rig-atlas.md`, but portable-twin generation and the final Lavish system-study update remain BLOCKED until the unredacted sanitizer is available and passes its leak scan.
It documents live files and never becomes a second source of their contracts.
The tracked target files are `.agents/skills/rig-atlas/SKILL.md` and `.agents/skills/rig-atlas/evals.md`.
The ignored live targets are `state/rig/assemble_replication.py`, `state/rig/rig-atlas.md`, `state/rig/rig-atlas-portable.md`, and `state/rig/portable-memory/`.

## Replication and operating contract map

The section 2 install order remains directory skeleton, verbatim skill and eval copy, curated portable-memory copy, role copy, hook copy, adaptation, verification, and generator installation.
The implementation must write the source text verbatim first and apply the line 3,406-3,416 adaptation second so an adaptation diff can be audited against the source.
The target is the repo-local layout named in this document, and the test rejects a target that was synthesized without a preserved source-to-adaptation diff.
Existing skill edits hot-reload on the next invocation, while a new top-level skill directory requires a new Codex task or verified harness reload.
The target is each `.agents/skills/<name>/` directory, and the test opens a fresh task for the first invocation of every newly added skill.
Every body-mandated tool must have an available Codex equivalent and must match any declared capability list.
The target is every `SKILL.md` and role definition, and the parity test fails on an unavailable tool, undeclared required tool, or unsupported mechanism stated as available.
Decision pages keep page-scoped `D1`, `D2`, and later IDs, put the Recommended option first and preselect it, give every decision a free-text note, give every short-answer question a real textarea, and begin result pages with definitions.
The target is `.agents/skills/lavish/SKILL.md` plus its two references, and the rendered-page test exercises selection, typing, reply composition, and two-page decision disambiguation.
The default is to decide and state why, while asking only for spend, direction, irreversible action, or a case with no clear recommendation.
Round 1, PR opening, scope-cut, and merge gates remain explicit exceptions.
The target is `build`, `lavish`, and `submit`, and the test rejects a passive scope cut, a skipped round-1 wait, or an ungated outward action.
Before changing deliberately written code, the worker asks whether the behavior is intentional and pairs any change with evidence.
An execute instruction authorizes only the agreed plan, while a question about a better design produces analysis and a recommendation without starting a new design branch.
The target is the planner and implementer brief contract, and the authorization-fence test presents both prompts and verifies only the first can lead to writes.
Validation refutes claims, challenges the measuring oracle, measures all real inputs against an invariant, and runs the cheapest decisive experiment before recommending a change.
E0 is ASSUMED and must be labeled or omitted.
E1 is RAN with traces and never permits the word works, and laptop-only artifacts cap here.
E2 is WORKS-unit with tests plus mutation.
E3 is WORKS-live with live output that exhibits the effect and human-visible evidence.
E4 is CAUSES with a preregistered control and stated sample count whenever causality is claimed.
E5 is REFUTE-SURVIVED after an adversarial panel fails to kill the claim, and it is required for ship language, closing-report headlines, and submit boundaries.
Feature completion requires E2 and E3, side claims inherit the same bar, and an E5 panel attacks the claims ledger as well as the diff.
The target is `build`, `submit`, `lavish`, and their evals, and the evidence test rejects a claim whose badge lacks the required artifact.
Every operator-tunable threshold, limit, retry, model ID, or breadth control becomes configuration with the current literal as its default.
The target is every implemented module, and the review test rejects a new hardcoded operating knob.
One living artifact is kept per workstream at one stable path and URL.
Checkpoint history is append-only with round, move, chosen-by, landed, evidence, and verdict, while prior rounds may compress to rows without disappearing.
Decision state remains open, decided, or SUPERSEDED with a link to the replacement, and only a genuinely new direction creates a new artifact.
The target is the existing Lavish mirror and `david-warm` components, and the test reconstructs a multi-round PASSIVE run from the final single page.

## Curated memory map

Appendix D at lines 1,678-3,055 is source material, not optional background.
Every portable memory heading in that range maps by basename to `state/rig/portable-memory/<source-basename>.md` after placeholder and harness-token adaptation.
The include-both set is durable doctrine and remains in both generated atlas editions.
The full-only set is recorded as classification metadata but its project-bound contents are not copied into the portable repo target.
The exclude-both set is recorded as classification metadata and its contents are copied nowhere.
Any file containing a credential, secret, private identifier, or personal-profile line is excluded as a whole file rather than redacted line by line.
The generator omits the derived `MEMORY.md` index and rebuilds the memory appendix from the curated files.
The memory acceptance test enumerates every Appendix D heading, verifies a matching include-both target and hash after declared substitutions, verifies no unclassified file remains, and scans the full atlas and local memory target for excluded tokens.
The portable edition gets the same scan only after the unredacted sanitizer is supplied, and its absence blocks rather than skips the portable-twin gate.
The classification acceptance test uses the source counts of 47 include-both, 47 full-only, and 41 exclude-both as reconciliation expectations while allowing the portable source to omit full-only and excluded bodies.

## Role map

The planner remains a divergent, read-only mapper that returns ordered file-level steps, test plans, alternatives, and risks while flagging gated actions.
The implementer remains a convergent executor for one reviewed plan leaf and returns the minimal change plus targeted evidence.
The refute reviewer remains source-read-only, begins from not proven, accepts findings only with a concrete anchor or reproduction, and retains the defect-signature memory policy only if Codex can support it without inventing a new runtime.
Firstmate's repo rule overrides Jim for writers, so every writing worker receives its own worktree under the target repo's `.claude/worktrees/` and commits before return.
Codex custom-role registration can point `config_file` at these TOML files so they carry model, reasoning effort, sandbox, and role instructions when the harness actually selects that role.
This session's collaboration wrapper cannot select a custom role, so native task-team lanes receive the role policy in their briefs and record the effective controls as unavailable to verify.
No external loader is assumed.
The implementation must prove an exact `codex exec` command and config carrier in an isolated smoke test before claiming that an external worker loaded a role or enforced its settings.

## Claude to Codex carrier table

| Claude carrier | Exact Codex substitute | Acceptance test |
| --- | --- | --- |
| `Workflow` | One root Codex task owns Map, parallel `collaboration.spawn_agent` lanes, Review, funnels, and Synthesize, because Codex has no atomic Workflow call. | The desktop shows every lane, independent lanes overlap in time, rejected lane output is named UNVERIFIED, and only the parent synthesis reaches the return task. |
| `Agent` | `collaboration.spawn_agent` is the inspectable default, while an externally launched `codex exec` worker is allowed only after its role and setting carrier is proven. | The native wrapper signature is recorded, the external smoke test proves the exact model, effort, sandbox, worktree, role instructions, and clean commit, and unsupported controls remain labeled unavailable. |
| `Skill` | Codex loads the repo-local `.agents/skills/<name>/SKILL.md` through explicit skill invocation or trigger matching. | A fresh Codex task discovers each skill, an explicit invocation loads the intended file, and no `.claude` or `.agents/skills-spine` copy wins. |
| `AskUserQuestion` | Codex asks one direct concise question in the final response, or uses `request_user_input` only when that tool is available in the active mode. | A blocking-choice test produces one answerable final question, and a mode without `request_user_input` never claims or attempts the unavailable tool. |
| `ToolSearch` | The parent inspects `ALL_TOOLS` for the required capability and then calls the matching official or installed tool. | A lazy-tool test finds the named capability from `ALL_TOOLS`, invokes it successfully, and fails plainly when no matching tool exists. |
| `WebSearch` and `WebFetch` | Codex uses `web__run` with `search_query` followed by `open`, while OpenAI product questions use the official OpenAI documentation connector first. | A web-recon test returns dated direct-source links, opens the supporting pages, and uses only official OpenAI sources for an OpenAI product claim. |
| `Task` | The root Codex task is the tracked run, and named collaboration subagents are its visible cells. | The desktop activity view shows the root and cells, the parent can steer or interrupt a named cell, and the final return aggregates once. |
| `Artifact` | Existing `lavish-axi <html-file>` opens or resumes the stable living page built from David-warm components. | The same file reopens at the same Lavish URL, the browser screenshot is read, and round history survives a redeploy. |
| `Monitor` | A Codex recurring automation owns durable polling and carries the loop count, caps, condition, and `NEXT_STEP` in its prompt. | A short-interval test wakes the correct task after a state change, remains silent without a transition, and preserves the payload after app restart. |
| `ScheduleWakeup` | A one-shot Codex automation wakes the owning task at the requested time with the full resume payload. | A two-minute test fires once, names the correct task and phase, and does not fire again. |
| `CronCreate` | A recurring Codex automation owns calendar-shaped repetition. | A bounded test fires on two scheduled intervals, records both runs, and stops cleanly when disabled. |
| `PushNotification` | The top-level parent calls dynamic `send_message_to_thread` when that exact tool is present, while `.agents/skills/pdw/scripts/report-back.sh` prepares, queues, and acknowledges the stable report receipt. | A checkpoint test with the native tool receives the artifact URL and exact `ready for your move` text once, while a catalog without the tool records queued rather than delivered. |
| `allowed-tools` | Codex skill text declares required capabilities, while role TOML sandbox and approval settings provide the enforceable boundary available to that launch path. | The parity audit maps every required tool, runs a forbidden-write probe for read-only roles, and records any missing per-tool allow-list enforcement as unsupported. |
| Skill frontmatter | Codex `SKILL.md` keeps supported `name` and `description` fields and removes or adapts Claude-only keys only in the adaptation diff. | A fresh-task discovery test loads every skill without parser warnings and the source-to-adaptation audit accounts for every removed key. |

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
When the collaboration wrapper cannot select a role that enforces the requested setting, `effective_effort` says enforcement is unavailable and explicit `codex exec` may be used only after the external-launch gate proves the command and effective setting.
Unsupported effort levels use the nearest supported fallback and record it without silently changing the request.
Every top-level brief receives `return_thread_id` and `return_host_id`.
Each native subagent returns to its immediate parent, and the top-level parent aggregates once to the supplied Command Center destination.
The return carries status, summary, command evidence, artifacts, branch, worktree, last commit SHA, requested and effective effort, rationale, identifiers, and `NEXT_STEP`.
Completion is not valid until that one report succeeds or the minimal PDW report-back adapter durably queues its retry.
When a retry is queued, the completion delivery status is `queued`, never `delivered`.
The adapter is a narrow transport carrier inside `pdw`, not a separate reporting framework.

## Command Center return carrier

The primary carrier is the Codex desktop dynamic `send_message_to_thread` tool with `threadId`, optional `hostId`, `prompt`, optional `model`, and optional `thinking`.
Codex app 26.709 exposes that tool, but this task's catalog does not.
The tool returns only `threadId` and supplies no idempotency or retry guarantee.
The parent inspects the live tool catalog and calls `send_message_to_thread` directly only when the exact tool is present.
The shell adapter cannot call or impersonate the dynamic tool.
The carrier provides at-least-once delivery and never claims exactly-once delivery.
The only permitted adapter is `.agents/skills/pdw/scripts/report-back.sh`, which owns `prepare`, `claim`, `drain`, `ack`, and `receive` state transitions but never calls the native tool.
Every delivered prompt includes the stable line `REPORT_KEY: <key>`.
`prepare` derives the stable report key, checks `state/report-delivery/sent/<key>.json`, and atomically writes `state/report-delivery/pending/<key>.json` for an immediate native attempt or `state/report-delivery/retry/<key>.json` when delivery must queue.
`claim` atomically leases one retry by moving it to `state/report-delivery/inflight/<key>.json` with an incremented attempt count and claim timestamp.
The root calls the native tool for the claimed or pending payload and leaves all transport calls outside the shell adapter.
`ack` atomically records `state/report-delivery/sent/<key>.json` after native success and removes the matching pending or inflight record.
`drain` first returns stale inflight claims to retry, then atomically claims and returns no more than the configured batch of payloads for the root to send.
An inflight claim is stale only after the configured claim TTL has elapsed.
`receive` atomically records `state/report-delivery/received/<key>.json` before receiver side effects.
A repeated `REPORT_KEY` returns `duplicate-suppressed` and causes no repeated receiver side effects.
The operator-owned `state/report-delivery/config.json` supplies `retry_max_attempts`, `claim_ttl_seconds`, and `drain_batch_size`, and the adapter rejects missing or invalid values rather than hiding unowned literals in code.
When a claim reaches the configured retry maximum, the adapter atomically records `state/report-delivery/exhausted/<key>.json` and returns no further send payload for that key.
If the sender crashes after native success but before `ack`, the stale claim returns to retry and may deliver again, which is why receiver deduplication is mandatory and exactly-once is not claimed.
The documented `codex exec resume <SESSION_ID> <PROMPT>` command is a local-only fallback when `return_host_id=local` and cannot satisfy non-local host routing.
The local fallback also lacks the native tool's host field and remains `AVAILABLE_BUT_UNVERIFIED_IN_CURRENT_SANDBOX` because the probe hit a read-only Codex state database before transport.
Any non-local host is unsupported when the native tool is absent until an explicit remote address mapping exists.
Every child reports only to its parent, and the top-level parent prepares one aggregated structured return whose transport may attempt delivery more than once.
Adapter tests cover preparation, missing destination, claim, drain, acknowledgment, failure queueing, retry, bounded attempts, stale-claim recovery, sender crash after native success before acknowledgment, receiver duplicate suppression, and parent aggregation.
A live E2E in a task where the native dynamic tool is exposed is the activation gate, and no delivery claim may exceed the queued state before that gate passes.

## Acceptance gates

- A source extraction test verifies the SHA, all nine skill headings, all eight eval headings, both Lavish reference headings, all three role headings, all four hook headings, the generator, and the canonical adaptation copy at lines 3,406-3,416.
- A layout test rejects `.claude` targets, `.agents/skills-spine`, missing target files, an invented `oat/evals.md`, or any abandoned custom runtime and schema file.
- A notes-boundary test proves `state/rig/`, `state/build-loops/`, `state/submit-canary.json`, and Lavish runtime pages are ignored, and rejects any tracked generated atlas, generator output, portable memory, ledger, or canary.
- A portable-sanitizer test confirms lines 3,501-3,503 are redacted, marks `state/rig/rig-atlas-portable.md` BLOCKED, and fails closed until the unredacted sanitizer produces a zero-leak result.
- A fresh-session simulation traces every mandated action from only the installed text and rejects any missing tool or undefined cross-reference.
- A contradiction test checks that every skill and eval agree, `pdw` is the only owner of topology and bare-agent rules, `oat` is the style boundary, and `explore` and `websearch` stay separate.
- A role-routing test proves native task-team visibility, proves custom-role TOML can carry model, reasoning effort, sandbox, and instructions, and records that this session's collaboration wrapper cannot select that role.
- An external-launch test must prove the exact `codex exec` command and config carrier pin the requested supported model and effort, load the requested role policy, write only in the assigned worktree, and return a clean committed SHA before that path is used.
- Effort tests cover every mapping, user override precedence, unsupported fallback, the Ultra parallel-lane gate, requested versus effective values, and the no-quota-downgrade rule.
- Hook tests prove git-guard blocks each forbidden command and allows ordinary commands, existing Codex hooks survive composition, and unsupported optional events stay uninstalled.
- A build-loop test proves intent, concurrent entry recon, checkpoint publication, move recon, plan plus TDD, parallel implementation, E-ladder validation, per-round commit, repeat, same-page close, HOLD, and explicit `/submit` handoff.
- A Lavish test renders the page, reads the screenshot, checks David-warm component identity, typed decision input, dynamic sidebar, append-only round history, and stable same-file delivery through `lavish-axi`.
- A submit test proves CodeRabbit substitution, human-gated PR creation, re-panel at round 4, HOLD at round 16, no merge, and same-page closing report.
- A return-routing test proves child-to-parent aggregation, one top-level report payload with at-least-once transport, requested and effective status preservation, direct parent ownership of the native tool call, stable `REPORT_KEY` inclusion, receiver duplicate suppression, and a durable retry on failure.
- A crash-window test delivers natively, omits sender `ack`, expires the configurable lease, drains the retried payload, and verifies `receive` suppresses repeated receiver side effects.
- A retry-control test proves configured batch bounds, configured maximum attempts, stale claim recovery after the configured TTL, and refusal of missing or invalid configuration.
- A live transport activation test in a task exposing `send_message_to_thread` must deliver and acknowledge one report before the carrier can claim native delivery.
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
- [x] Appendix D is covered from lines 1,678-3,055, and its extraction check expects all 47 include-both memory files under `state/rig/portable-memory/`.
- [x] The self-contained generator is covered from lines 3,057-3,505 and the canonical adaptation duplicate is covered from lines 3,406-3,416.

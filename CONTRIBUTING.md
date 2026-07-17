# Contributing

Thanks for wanting to contribute.
Firstmate accepts ordinary GitHub pull requests targeting `main`.

## Workflow

1. Fork the repository and clone your fork.
2. Create a feature branch from the latest `main`.
3. Make the change and run the relevant checks from the Development section below.
4. Commit the validated change.
5. Push the branch to your fork with native Git:

   ```sh
   git push -u origin <branch>
   ```

6. Open a GitHub pull request from that branch to `kunchenguid/firstmate:main`.
7. Keep the branch current while the shell lint, behavior tests, repository invariants, and review checks run.

## Repo conventions

- This repo is a template for running a firstmate orchestrator agent.
  `AGENTS.md` is the Codex harness contract and `CLAUDE.md` is the frozen Claude harness contract; each is that harness's main job description and names when to load bundled firstmate skills.
  `CLAUDE.md` used to be a symlink to `AGENTS.md`, but the two contracts have diverged and it is now a tracked regular file; `.claude/skills` is still a symlink to `.agents/skills`.
- Only shared material is tracked: `AGENTS.md`, `CLAUDE.md`, `README.md`, `CONTRIBUTING.md`, `.tasks.toml`, `.github/workflows/`, `bin/`, `.agents/skills/`, `skills/`, `.codex/` (Codex harness config, roles, and hooks), and the single canonical component library `data/operating-model/components/david-warm.html`.
  `.agents/skills/` holds agent-loaded skills that assume a live firstmate home and carry `metadata.internal: true` so installers such as [skills.sh](https://skills.sh) hide them from discovery; `skills/` holds standalone, installer-facing public skills with no firstmate dependency (see the README's "Two-tier skill layout").
  Everything personal to one captain's fleet (`.env`, `data/`, `state/`, `config/`, `projects/`, `.no-mistakes/`) is gitignored; never commit it, with the one carved-out exception of the tracked `data/operating-model/components/david-warm.html` component library.
  The root `.tasks.toml` is tracked `tasks-axi` config for `data/backlog.md`; compatible `tasks-axi` is the default backend for routine backlog mutations.
  A local `config/backlog-backend=manual` opt-out forces hand-editing and stays gitignored.
  A local `config/backend` file explicitly overrides runtime auto-detection for new task endpoints and stays gitignored; spawn-supported values are `tmux` plus experimental `herdr`, `zellij`, `orca`, and `cmux`.
  It does not make `data/` tracked.
- Helper scripts in `bin/` are plain bash.
  Each starts with a usage header comment; keep it accurate when you change behavior.
  Test scripts and helpers in `tests/` are plain bash too.
  `shellcheck bin/*.sh bin/backends/*.sh tests/*.sh` must pass, and CI enforces it.
- Changes to harness adapters (detection in `bin/fm-harness.sh`, launch and hook mechanics in `bin/fm-spawn.sh`, busy signatures in `bin/fm-watch.sh` and `bin/fm-tmux-lib.sh`, cleanup in `bin/fm-teardown.sh`, and facts in `.agents/skills/harness-adapters/SKILL.md`) must be verified empirically against the real harness, never written from documentation alone.
- Changes to runtime session backends (`bin/fm-backend.sh`, `bin/backends/`, and the scripts that dispatch through them) need empirical adapter notes in the relevant backend guide: `docs/tmux-backend.md`, `docs/herdr-backend.md`, `docs/zellij-backend.md`, `docs/orca-backend.md`, or `docs/cmux-backend.md`.
- In Markdown, put each full sentence on its own line.
- `README.md` stays a concise overview plus pointers: it never carries a wall of inline detail.
  Route detail to the most specific `docs/` file (architecture, configuration, or a backend guide) and link to it instead.

## Development

Tracked changes to firstmate itself - `AGENTS.md`, `CLAUDE.md`, `README.md`, `CONTRIBUTING.md`, `.tasks.toml`, `.github/workflows/`, `bin/`, `.agents/skills/`, `skills/`, `.codex/`, and `data/operating-model/components/david-warm.html` - use an isolated feature branch, the build and submit workflows, and a native GitHub pull request with explicit push, pull-request, and merge approval.
Before making any such change, load the agent-only `firstmate-coding-guidelines` skill (`.agents/skills/firstmate-coding-guidelines/SKILL.md`).
It has the knowledge-placement rules that keep `AGENTS.md` from regrowing after each diet pass.
There is no reliable way for `bin/fm-brief.sh`'s scaffold to detect that a task's repo is firstmate itself, so firstmate adds this skill's load line to firstmate-repo briefs by hand.
A crewmate picking up such a brief should load the skill even if the brief predates this instruction.
When supervising live crewmates, keep firstmate's own long validation or build commands in the background so watcher wakes can still be handled.
Crewmate validation follows the build workflow and the repository checks below before the submit workflow reviews the native GitHub pull-request diff.
Captain-owned findings and outward actions still require escalation and explicit approval.
Local `.no-mistakes/` state remains gitignored for downstream project-mode compatibility, so do not commit `.no-mistakes/evidence/` here.

Check and test the toolbelt before pushing:

```sh
for script in bin/*.sh bin/backends/*.sh; do bash -n "$script"; done   # syntax-check the toolbelt
shellcheck bin/*.sh bin/backends/*.sh tests/*.sh   # lint the toolbelt and behavior tests; CI enforces this
for test_script in tests/*.test.sh; do bash "$test_script"; done   # behavior tests, matching CI
tests/fm-wake-queue.test.sh               # durable wake queue losslessness, catch-up, double-drain, duplicate-collapse, and drain liveness guard tests
tests/fm-watcher-lock.test.sh             # watcher singleton, lock-race, watch-arm liveness, and guard-warning tests
tests/fm-turnend-guard.test.sh            # shared supervision predicate plus Claude Stop-hook scoping, loop guard, fail-open, and live watcher health tests
tests/fm-watch-triage.test.sh             # always-on watcher triage: benign absorb, actionable surface, stale status-log override, wedge threshold, heartbeat backstop, and afk one-shot coherence
tests/fm-daemon.test.sh                   # sub-supervisor classifier, /afk presence-gating, max-defer, composer, and fm-send submit tests
tests/fm-send-settle.test.sh              # fm-send post-submit settle pause, tuning, disable, and --key bypass tests
tests/fm-send-popup-settle.test.sh        # fm-send pre-Enter popup-settle selection for slash commands and codex $skill invocations
tests/fm-send-secondmate-marker.test.sh   # fm-send from-firstmate marker for kind=secondmate targets: marked vs crewmate/explicit/--key, and the exact marker byte sequence
tests/fm-wake-daemon-lifecycle-e2e.test.sh # watcher + daemon lifecycle e2e: restart catch-up, batching, dedupe, stale-pane routing, and digest injection
tests/fm-composer-ghost.test.sh           # dim-ghost stripping, ghost-only composer detection, and escape-free peek tests
tests/fm-afk-inject-e2e.test.sh           # private-socket end-to-end test of the afk injection path (partial-input deferral, swallowed-Enter retry)
tests/fm-afk-inject-herdr-e2e.test.sh     # real-herdr end-to-end test of the afk daemon's herdr transport, on an isolated throwaway HERDR_SESSION: partial-input deferral, swallowed-Enter retry, a normal digest, and the max-defer wedge alarm on a persistently pending composer
tests/fm-bootstrap.test.sh                # bootstrap dependency, feature-probe, and crew-dispatch reporting tests
tests/fm-session-start.test.sh            # fm-session-start.sh: ABSENT vs empty-vs-present digest files, lock-refusal read-only path skipping every mutating step, diagnostics-first section ordering, status-tail bounding, tmux/herdr endpoint liveness, and composition of the real fm-lock/fm-bootstrap/fm-wake-drain scripts
tests/fm-grok-harness.test.sh             # grok adapter spawn hook, token guard, teardown cleanup, and session-lock detection tests
tests/fm-fleet-sync.test.sh               # project clone refresh: safe detached recovery, STUCK drift reports, benign skips, and bootstrap relay
tests/fm-x-mode.test.sh                   # X-mode poll, inbox context round-trip, reply threading, dismiss, completion follow-up counters/caps, dry-run preview, and .env-presence activation tests
tests/fm-tangle-guard.test.sh             # primary-checkout tangle detection, read-only remediation suppression, and spawn/brief isolation tests
tests/fm-brief.test.sh                    # fm-brief.sh bash -n parse regression guard (issue #166) and clean no-mistakes/direct-PR/local-only brief generation tests
tests/fm-spawn-batch.test.sh              # batch dispatch and FM_HOME project-path scoping tests
tests/fm-spawn-dispatch-profile.test.sh   # concrete dispatch profile flags: active-profile backstop, harness/model/effort meta, launch templates, batch forwarding, and secondmate exemption
tests/fm-spawn-worktree-symlink.test.sh   # worktree wait-loop path canonicalization: a symlinked project path (e.g. /tmp -> /private/tmp) must not misdetect the project as the worktree
tests/fm-gotmp.test.sh                    # per-task GOTMPDIR temp root: fm-spawn tasktmp= meta contract and fm-teardown cleanup of the recorded temp root
tests/fm-update.test.sh                   # fast-forward-only self-update, reread, nudge, dedup, and skip-safety tests
tests/fm-secondmate-sync.test.sh          # local-HEAD secondmate sync, no-fetch, bootstrap nudge gating, and spawn hook tests
tests/fm-secondmate-harness.test.sh       # secondmate-vs-crewmate harness resolution, optional secondmate model/effort pins, primary-to-secondmate config inheritance, and config-push tests
tests/fm-secondmate-lifecycle-e2e.test.sh # persistent secondmate routing, seeding, backlog handoff, spawn, recovery, teardown, and FM_HOME flow tests
tests/fm-secondmate-safety.test.sh        # secondmate home safety, idle charter, handoff validation, and teardown boundary tests
tests/fm-teardown.test.sh                 # fm-teardown.sh landed-work safety and reminder checks: fork-remote allow, squash/content landings, dirty and unlanded refusals, PR-head metadata, no-pr= branch discovery, tasks-axi/manual backlog reminder, --force override
tests/fm-review-diff.test.sh              # fm-review-diff.sh authoritative review diff coverage: recorded pr_head=, fetched refs/pull/<n>/head, no-pr local branch behavior, and warning fallback
tests/fm-pr-merge.test.sh                 # fm-pr-merge.sh records pr= and available pr_head= before merging, parses PR URLs into native gh pr merge number/--repo calls, defaults to squash, preserves explicit merge methods, rejects malformed URLs and repo overrides, and propagates real merge failures
tests/native-gh-policy.test.sh            # active policy and docs use native gh, per-PR bucket parsing, exact-head rollups, and non-vacuous CodeRabbit PASS semantics
tests/fm-crew-state.test.sh               # fm-crew-state.sh current-state reconciliation: run-step authority including closed panes, stale needs-decision/blocked superseded by a resumed run, genuine-parked, cross-branch runs-list attribution, bounded run-lookup retry/backoff recovering a raced `axi status` or coarse runs-list lookup, pane/status-log fallback, scout skip, torn-down/missing-meta graceful
tests/fm-backend.test.sh                  # runtime-backend abstraction: fm-backend.sh selection/meta/dispatch helpers, shell-portable sourced backend matching, and old-vs-new fake-tool command-log conformance for fm-send/fm-peek/fm-spawn/fm-teardown
tests/fm-backend-tmux-smoke.test.sh       # real (private-socket) tmux smoke test for the tmux adapter: create/duplicate-refuse, new-window trailing-colon session target (renumber-windows index-in-use guard), send text + Enter, send literal + key, bounded capture, live-window resolve, kill
tests/fm-backend-herdr.test.sh            # fake herdr CLI unit tests for the experimental herdr adapter, including version/tool gates, target parsing, send/capture, structural composer-state verification, slash-submit retry regression coverage, native busy state, per-home workspace-label resolution, default-tab prune safety, restored-layout husk replacement, and verified CLI bug workarounds
tests/fm-backend-herdr-smoke.test.sh      # real herdr adapter smoke test, skipped when herdr or jq is unavailable, using an isolated throwaway HERDR_SESSION and guarded session cleanup, including live-agent duplicate refusal and no-agent husk replacement
tests/fm-backend-autodetect-smoke.test.sh # real herdr auto-detection smoke test, skipped when herdr, jq, or treehouse is unavailable, using the same guarded session cleanup
tests/fm-backend-herdr-workspace-per-home-e2e.test.sh # mandatory isolated E2E for workspace-per-home: primary and secondmate-shaped homes, a crewmate spawned from a secondmate home, teardown, list-live recovery
tests/fm-backend-herdr-prune-safety-e2e.test.sh # isolated real-herdr E2E for the default-tab prune self-kill regression: adopted label-collision workspaces are never pruned, while freshly created workspaces still prune their seeded default tab
tests/fm-backend-herdr-respawn-idem-e2e.test.sh # isolated real-herdr E2E for restored-layout husk respawn idempotency across a real session restart, covering crewmate/scout and secondmate-shaped tabs plus live-agent duplicate refusal
tests/fm-backend-zellij.test.sh           # fake zellij CLI unit tests for the experimental zellij adapter, including version/tool gates, target parsing, home-scoped title creation, legacy-title fallback, send/capture, current-path probing, label-checked target safety, secondmate child cleanup, and tab cleanup
tests/fm-backend-zellij-smoke.test.sh     # real zellij adapter smoke test, skipped when zellij or jq is unavailable, using an isolated throwaway FM_ZELLIJ_SESSION and guarded session cleanup
tests/fm-backend-orca.test.sh             # fake Orca CLI unit tests for primitive adapter routing: capture, send text, Enter/interrupt keys, close, and dispatcher sourcing
tests/cmux-test-safety.sh                 # guarded cleanup helper for real-cmux tests, refusing to close anything except a matching fm-test- workspace
tests/fm-backend-cmux.test.sh             # fake cmux CLI unit tests for the experimental cmux adapter, including socket auth, title scoping, target recovery, fresh-surface liveness, current-path probing, structural composer verification, and secondmate refusal
tests/fm-backend-cmux-smoke.test.sh       # real cmux adapter smoke test, skipped when cmux or jq is unavailable or the socket is not password-mode authenticated, using fm-test- workspaces and guarded cleanup
tests/codex-harness-contract-split.test.sh # Codex and frozen Claude harness contracts (AGENTS.md vs CLAUDE.md) are mechanically split and do not cross-reference
tests/codex-jim-source-structure.test.sh  # Jim source-fidelity structure gate: required modules, canonical ledger fields, and source-hash/adaptation-carrier match
tests/codex-jim-evidence-contract.test.sh # Jim evidence semantics, laptop cap, side-claim parity, and the canonical E0-E5 badge carrier
tests/codex-jim-execution-config.test.sh  # installed Codex config loader resolves the root AGENTS contract, all nine pipeline skills, and every role config target (skipped when the codex CLI is absent)
tests/codex-jim-git-guard.test.sh         # .codex git-guard hook: worktree write fence, nested-eval fail-closed inspection, and its timing bound
tests/codex-jim-lavish.test.sh            # deterministic Lavish component/contract suite: decision-zone checkbox behavior, oat mermaid verification, and warm-component carriers
tests/codex-jim-recon-skills.test.sh      # adversarial recon (explore/scout/websearch) structure, sectioned triggers, MEASURED experiment rules, and effort contracts
tests/codex-jim-rig-atlas.test.sh         # rig-atlas: complete atlas, source re-derivation, live-file gates, adapted memories, leak scan, tamper verification, and module mutations
tests/codex-jim-submit-skills.test.sh     # submit/build skill triggers (five positive, three negative) and the 24 binary eval rules are enumerated
tests/pdw-effort-router.test.sh           # pdw effort router: Ultra gate, unsupported-fallback protection, and unknown-effort rejection
tests/pdw-external-launcher.test.sh       # pdw external codex exec launcher: HEAD/clean-descendant-commit requirement, nested-repo rejection, and sandbox-mode match to the role TOML
tests/pdw-report-back.test.sh             # pdw report-back transport and report-lock: dead-holder reclaim, live-holder protection, and the owning-task durable-retry wake contract
[ -f CLAUDE.md ] && [ ! -L CLAUDE.md ]   # CLAUDE.md is a frozen regular file, no longer a symlink to AGENTS.md
[ "$(readlink .claude/skills)" = "../.agents/skills" ]
tmp=$(mktemp -d) && printf 'done: smoke\n' > "$tmp/smoke.status" && FM_STATE_OVERRIDE="$tmp" FM_SIGNAL_GRACE=1 FM_POLL=1 FM_HEARTBEAT=999999 bin/fm-watch-arm.sh  # watcher re-arm smoke test (prints arm status, then an actionable signal)
```

## Questions

Open an issue, or talk to me on [Discord](https://discord.gg/Wsy2NpnZDu).

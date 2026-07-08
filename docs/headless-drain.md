# Headless board drain (poller becomes the first-class trigger)

How a David board message becomes a firstmate turn UNATTENDED, without depending on the interactive REPL volunteering.
This is Phase 0 of promoting the launchd poller from a nudge-producer into a trigger authority.

## The gap this closes

`docs/event-wake.md` describes the existing push: the poller types a `tmux send-keys` nudge into the live REPL's pane the instant a board wake lands.
That push is the ONLY thing that turns a queued wake into a turn, and it silently no-ops whenever the REPL is not there to receive it: an unresolvable or vacated pane, a wedged tmux server, a busy composer, a non-tmux session, or `FM_WAKE_INJECT=0`.
In all of those cases the wake just sits in the durable queue until a human happens to run a turn and drains it.
So "a David board message reliably wakes firstmate" depended on the REPL volunteering.

Phase 0 removes that dependency.
When there is un-drained board activity and no reachable REPL, the poller itself spawns a fresh, context-loaded `claude -p` turn that reads every unanswered David thread message and answers it.
The launchd poller plus a headless `claude -p` are now the first-class trigger; the interactive REPL is demoted to an optional attach and a fast path.

## The mechanism

- **Detection.** `bin/fm-poll.sh` `maybe_drain_headless` runs each cycle after `maybe_inject_wake`.
  It fires only when the durable queue's monotonic seq (`state/.wake-queue.seq`) has advanced past `state/.drain-attempted-seq` (there is board activity no drain has serviced yet) AND no interactive REPL is reachable.

- **REPL reachability.** `repl_reachable` short-circuits on a fresh presence heartbeat (`state/repl-presence.json`, written `busy`/`idle` by `bin/fm-repl-presence.sh` from the `UserPromptSubmit`/`Stop` hooks); absent or stale, it falls back to a timeout-guarded `fm_resolve_session_pane`.
  A stale/absent heartbeat AND an unresolvable pane read as "no REPL" - exactly when the headless drain must fire.
  When a REPL is reachable, the poller leaves the wake to the interactive fast path (`maybe_inject_wake` already pushed the nudge); the idempotency below makes any race harmless.

- **Single-flight lease.** `bin/fm-drain-worker.sh` takes an atomic `mkdir(2)` lease at `state/.drain-lease` carrying the drain pid and its process identity.
  The lease is free ONLY after the recorded pid is confirmed dead (identity-checked against pid reuse), never on elapsed time, so a legitimately long coalesced drain never lets a second drain start.
  The poller checks the lease before spawning only to avoid churn; the worker re-acquires it atomically and exits if it loses the race.

- **Detached, not loop-blocking.** The worker is spawned detached (`nohup`, double-forked) rather than under the poll loop's `run_with_timeout`.
  A multi-second `claude -p` turn must never stall the poll loop (the poller's core invariant is that one hang cannot wedge it), so the lease, not the loop, bounds concurrency.
  The worker bounds its own `claude -p` with `FM_DRAIN_TIMEOUT` (default 180s) via `timeout`/`gtimeout`/a perl alarm, so a hung turn cannot hold the lease forever.

- **Context-loaded throwaway turn.** The worker concatenates `AGENTS.md`, `CLAUDE.md`, and a machine-readable snapshot of every unanswered David message into a deterministic on-disk preamble, then pipes it to a fresh, capability-scoped `claude -p` (see "Capability scoping" below).
  It is a THROWAWAY turn, NOT `--resume`: resuming the interactive session's own `session_id` while the live REPL owns that file forks it.
  Because the headless path holds zero load-bearing state in any context window, a compaction of the interactive session cannot lose a board message.
  Same-session `--resume` (behind a single-holder lock) is a later phase.

## Capability scoping (why an unattended turn is not `--dangerously-skip-permissions`)

The headless turn is loaded with the full operating contract, whose autonomy grant lets firstmate merge non-project code, push to `main`, and dispatch workflows.
On an automatic, human-absent trigger the ONLY thing that may keep the turn to "just post a holding-ack" is a real permission boundary, never the prompt text: a prompt-confused or off-script turn must not inherit the whole toolset.
So the worker does NOT pass `--dangerously-skip-permissions`.
It runs the turn with a tight tool allowlist - `--allowedTools "Bash(<abs path to bin/fm-board-reply.sh>:*)"` - under the default (non-bypass) permission mode.
In headless `-p` mode a tool call outside the allowlist cannot raise an interactive prompt, so it is simply denied: arbitrary `Bash`, `Edit`/`Write`, `git`, network, MCP, and sub-agent tools are all structurally unavailable to the turn.
The turn can do exactly one thing: run `bin/fm-board-reply.sh` to post a board reply.

Residual risk (documented, accepted for Phase 0): the turn can post ANY text as a reply, to any existing board item id it is fed. The blast radius is "a board thread gets an odd firstmate-authored reply", which the `--once` idempotency and the holding-ack-only instruction further contain; it cannot edit files, run arbitrary shell, touch git, or reach the network.
`FM_DRAIN_CLAUDE_MODEL` pins the model when set (the real-binary acceptance test uses a cheap model to dodge a rate-limited default); unset means the account default.

- **Holding-ack only (Phase 0).** The turn is instructed to post a brief holding acknowledgement per item via `bin/fm-board-reply.sh <id> "<ack>" --your-court --once` and explicitly NOT to auto-close or fabricate a final answer.
  A context-blind wrong final answer is the real risk; a holding-ack fully satisfies "a board message becomes a firstmate turn" with zero risk.
  Trivial-ask auto-close from headless is a deliberate follow-up.

## The two seq markers

- `state/.drain-attempted-seq` - the highest queue seq a drain has SUCCESSFULLY serviced (an ack or a close-out).
  The worker advances it on success; the poller only spawns a drain when the queue seq exceeds it.
  This is what stops a holding-ack from making the poller re-spawn a drain every cycle.

- `state/.serviced-seq` - the highest queue seq fully CLOSED OUT (a real answer, never a holding-ack).
  Phase 0 posts only holding-acks, so this stays behind, and the pager SLA keeps escalating an un-answered item until the live orchestrator resolves it.

Splitting these two is a deliberate robustness choice over the original single-marker sketch, which would have re-spawned a drain every cycle for an un-serviced holding-ack.

## The real drain gate (anti-spin)

The queue seq only records "some check fired this cycle", not "a David message is waiting".
The live `board-threads.check.sh` and `board-actions.check.sh` can make the seq advance every cycle (the live `.seen`-based threads check emits "N new" every cycle whenever thread files are newer than its marker).
So the seq alone is NOT a safe spawn gate: against an un-demoted live check it would outrun `attempted-seq` every cycle and spawn a drain worker every cycle forever, and the first fire would mass-ack the whole current backlog unattended.
The robust gate is therefore the REAL signal: `bin/fm-poll.sh` `maybe_drain_headless` calls `has_unanswered_david` (an early-exit scan for a thread whose newest `*.md` is a david message with a body) and spawns a worker ONLY when one genuinely exists.
A bare seq bump with nothing unanswered just settles `attempted-seq` to the current seq and spawns nothing.
The worker itself re-checks the same condition and no-ops if nothing is unanswered, so the guard is defence-in-depth across both the poller and the worker.
This makes the `board-threads.check.sh` `.seen` -> `.enqueued` demotion (below) a tidiness optimization, NOT a hard deploy prerequisite: the committed poller no longer spin-spawns against the live un-demoted check.

## Idempotency (why double-answering is safe)

`bin/fm-board-reply.sh --once` derives a key from the item id and the newest David-authored filename in the thread and takes an atomic `mkdir` claim under `state/.reply-claims/<key>` before writing.
A second `--once` reply to the same David message is a clean no-op, so the headless drain and the interactive session can both try to answer the same message without double-posting.
A NEW David message changes the newest-file generation, so the next reply is not suppressed.
Interactive callers omit `--once` (they may legitimately post several replies to one thread); only the auto-drain uses it.
Residual: a crash after the claim but before the write suppresses that one auto-ack, but the David message file persists and `serviced-seq` stays un-advanced, so the pager SLA still escalates it - the message is never lost.

## Dead-letter and the off-box pager

- After `FM_DRAIN_MAX_FAILURES` (default 3) genuine failures (claude unresolvable, a turn error, or a turn that posted nothing), the worker appends the batch to `state/.dead-letter`, pages via `bin/fm-pager.sh`, and advances `attempted-seq` so it stops spinning on a batch a human now owns.
- `bin/fm-pager.sh ping` heartbeats an off-box dead-man's switch (healthchecks.io) every poll cycle; if the poller or the whole box dies, the pings stop and healthchecks.io alarms off-box.
- `bin/fm-pager.sh page <text>` sends one Pushover push on dead-letter or an age-SLA breach.
- The pager is the one genuinely-new external dependency the design flags, and it is a MINIMAL first cut: a daily acknowledged round-trip and a second-channel non-ack alarm are a deliberate fast-follow.
- Everything in the pager is INERT until `config/pager.env` is filled in (see `config/pager.env.example`), so Phase 0 ships without requiring any account.

## How it survives crash / restart / compaction

- Capture is the board-v2 thread `.md` file on disk plus the queue record; detection is thread-store based, so even a lost `.wake-queue` is re-derived from the persisted thread files.
- A poller crash is restarted by launchd `KeepAlive`; it re-scans and re-drains.
- A drain-worker crash mid-turn leaves a pid-live lease that is freed on the confirmed-dead pid, so the batch redelivers; `attempted-seq` advances only on success, and the `--once` claim makes the redelivered handle a no-op instead of a double-post.
- Compaction cannot lose a board message because the headless path holds zero load-bearing state in a context window: each drain is a fresh `claude -p` fed a deterministic on-disk preamble.

## The acceptance test

`tests/fm-poll-headless-drain-e2e.test.sh` runs the real poller against a throwaway `FM_ROOT` sandbox with no session-pane.env, no presence file, and `FM_WAKE_INJECT=0`, posts a David thread message, and asserts that a firstmate-authored holding-ack lands with no interactive session involved, `serviced-seq` left armed, and exactly one reply (no re-spawn, no double-post).
It uses a `claude` stub for the turn so it is hermetic and deterministic, which keeps it in the default suite as the fast logic regression.

`tests/fm-drain-worker-real-claude.test.sh` is the LOAD-BEARING proof of the one claim that matters: it runs `bin/fm-drain-worker.sh` with the REAL `claude` binary (no stub) against a sandboxed board and asserts that a real headless `claude -p` turn, under the scoped tool allowlist, actually posts a real holding-ack to an unanswered David thread and advances `attempted-seq` without touching `serviced-seq`.
Because a real LLM turn costs tokens and needs network/quota, it is opt-in: it self-skips unless `FM_TEST_REAL_CLAUDE=1` (and skips with a message if no `claude` is resolvable).
Run it with `FM_TEST_REAL_CLAUDE=1 FM_DRAIN_CLAUDE_MODEL=<cheap-model> bash tests/fm-drain-worker-real-claude.test.sh`.

`tests/fm-drain-worker.test.sh` covers the lease, marker, and dead-letter logic in isolation; `tests/fm-board-reply-idempotency.test.sh` covers `--once`.

## Deploying into the live runtime (not committed here)

The poller logic and the worker are tracked (`bin/fm-poll.sh`, `bin/fm-drain-worker.sh`), so they go live when the repo is deployed and the poller restarts.
Three runtime touch-points live in gitignored or untracked local files and are wired by hand into the live checkout, NOT forked into a branch:

- `state/board-threads.check.sh` should demote its `.seen` marker from a "serviced" watermark to a pure edge-dedup "already-enqueued-a-wake" marker (fire once per new thread file, advance a `.enqueued` marker), so real "serviced" state lives only in `state/.serviced-seq`.
  The demoted form is the fixture in `tests/fm-poll-headless-drain-e2e.test.sh`.
  This is an OPTIMIZATION, not a hard prerequisite: the anti-spin gate above means the committed poller does not spin-spawn even against the un-demoted live `.seen` check (it settles `attempted-seq` and spawns nothing when no David message is waiting).
  The demotion only trims the per-cycle `has_unanswered_david` scan on a churny board.
- `.claude/settings.json` should call `bin/fm-repl-presence.sh busy` on `UserPromptSubmit` and `bin/fm-repl-presence.sh idle` on `Stop`, so the poller's fast-path gate has a live heartbeat (without it, reachability falls back to pane resolution, which still works).
- A belt-and-suspenders extension of `bin/fm-turnend-guard.sh` to also refuse to end a turn with an unanswered David board message is a named follow-up.

## Known limitations (named, not fixed here)

- **A holding-ack disarms the age-SLA for that item.** The ack is a firstmate-authored post, so the thread's newest author flips to `firstmate`; `oldest_unanswered_age` (and the board's derived In-progress) only see a thread as unanswered while its newest message is david's.
  So once headless has acked an item, `maybe_pager` no longer counts it, even though `.serviced-seq` was deliberately left un-advanced (the ball is still firstmate's - the ack says "the live orchestrator will pick this up").
  Net for Phase 0: a headlessly-acked-but-unresolved item stops auto-escalating on age.
  This is a band-aid boundary, not a solved problem: the robust fix is a per-item "acked, awaiting a real answer" ledger that the pager escalates on independently of newest-author, which is a later phase.
  It never LOSES a message (the david file persists and `.serviced-seq` stays behind); it only means the second-order age pager does not fire on an already-acked item.
- **User LaunchAgent, not a pre-login daemon.** `launchd/com.firstmate.poller.plist` is a user LaunchAgent, so unattended reliability holds only while David is logged in.
  The FileVault-safe pre-login `/Library/LaunchDaemons` promotion is a later phase.

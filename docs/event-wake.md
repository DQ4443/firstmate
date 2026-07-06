# Event-driven wake (poller pushes into firstmate's pane)

How the launchd poller delivers a board event into the running firstmate session in seconds, instead of the session polling on a timer.

## The gap this closes

`bin/fm-poll.sh` (the launchd job `com.firstmate.poller`) detects David's board messages and actions within its poll interval and appends them to the durable wake queue (`bin/fm-wake-lib.sh`, `state/.wake-queue`).
But nothing delivered that queue into the live `claude` session.
A `claude` session only runs a turn when it is re-invoked - terminal input, an agent finishing, or a `ScheduleWakeup` it set for itself - so the session had to poll on a multi-minute timer to notice board activity.
That lag is the root of the "my messages pile up / the board is stale" pain.

The fix is a push: the instant a wake-worthy event lands in the queue, the poller types a one-line nudge into firstmate's own tmux pane with `tmux send-keys`, exactly as if David typed it, and the session wakes and drains the queue.

## The mechanism

- **Recording the pane.** `bin/fm-session-register.sh` runs at session start from `bin/fm-session-start.sh`, on the locked path only (a read-only second session never overwrites the record).
  It captures `$TMUX_PANE` (the pane the harness draws into), the tmux server socket (the first field of `$TMUX`), the absolute `tmux` binary path (`command -v tmux`), and the harness pid holding the lock, and writes them to `state/session-pane.env`.
  These are captured from inside the session because the launchd poller's environment has none of them: no `$TMUX`, and homebrew is not on its `PATH`, so a bare `tmux` would not even resolve.
  Subagents run in-process and share the same pane, so `$TMUX_PANE` is stable for the session's whole life.

- **Resolving the pane.** `bin/fm-inject-lib.sh` `fm_resolve_session_pane` reads `state/session-pane.env` and validates it: the pane must still exist on that server and the recorded harness pid must still be alive (or, if the pid is unknown, the pane's foreground command must still look like a harness).
  A pane that exists but whose harness has died - now a bare shell - fails validation, so a nudge is never typed into a pane the session has vacated.
  If the recorded record is missing or invalid, it falls back to discovery: match the lock's harness pid to the pane whose `pane_pid` is one of its ancestors (the harness is a child of its pane's shell).

- **Targeting the right server.** `bin/fm-tmux-lib.sh` gained one seam, `fm_tmux`, which runs `${FM_TMUX_BIN:-tmux}` with `-S "$FM_TMUX_SOCKET"` when a socket is set and a bare `tmux` otherwise.
  Every composer/submit primitive now goes through it.
  The default is unchanged (bare `tmux`, the session's own server via `$TMUX`), so `fm-send.sh` and the away-mode daemon are byte-for-byte identical in behavior; the injector sets `FM_TMUX_BIN`/`FM_TMUX_SOCKET` to reach firstmate's server from launchd.

- **Injecting safely.** `fm_inject_wake` reuses `fm-tmux-lib.sh`'s ghost-aware composer detection and verify-and-retry-Enter submit.
  If the composer holds real unsubmitted text (David mid-typing, or a prior swallowed injection), the push is deferred, not forced, so it can never corrupt a line being typed.
  The nudge itself is a single plain line that names itself a machine wake and points at the next action: `fm-wake: new board activity is queued. Run bin/fm-wake-drain.sh and handle it per AGENTS.md section 2.`

- **Debounce / no spam.** The queue's monotonic seq counter (`state/.wake-queue.seq`) is the "newest wake" marker; `state/.wake-inject-seq` records the seq the poller last nudged about.
  A burst of messages that lands within one sweep advances the seq once and injects once.
  A queue the poller has already nudged (same seq, the session simply slow to drain) is not re-nudged, so the session is never spammed.
  `FM_WAKE_INJECT_DEBOUNCE` (default 8s) caps how often a nudge can fire across cycles.

## Degradation

Every failure mode degrades to the pre-existing behavior and never loses a wake:

- No pane resolves (session not in tmux, pane vacated, tmux unreachable): the push is skipped, logged once per outage to `state/poller.log`, and the durable queue plus the session's own poll carry the event exactly as before.
- Composer busy with real input: deferred, retried on a later cycle.
- `FM_WAKE_INJECT=0`: the push is disabled entirely; the queue still fills and drains normally.

The push is strictly additive: it never mutates the wake queue, so the durable-queue safety matrix (`tests/fm-wake-queue.test.sh`) is untouched.

## Cutover (human step, after merge)

The poller plist (`launchd/com.firstmate.poller.plist`) is unchanged by this feature and is still loaded once as the documented cutover step.
Once the new `bin/fm-poll.sh` is live, verify the push end to end:

1. Confirm the session recorded its pane: `cat state/session-pane.env` shows the current pane id, socket, and tmux binary. If absent, re-run `bin/fm-session-start.sh` (or `bin/fm-session-register.sh`) from the session.
2. Post a message in any board thread and confirm the running session wakes within seconds (the `fm-wake:` nudge appears in the pane and the session drains).
3. Confirm graceful degrade: `state/poller.log` shows a single "no firstmate pane to push to" line if the pane cannot be resolved, and the session still catches the wake on its next poll.

## Tests

- `tests/fm-inject-wake.test.sh` - pane resolution, delivery, pending-input deferral, stale-record rejection, and discovery fallback against a private-socket tmux pane; plus pure-logic units (envget parsing, pid ancestry).
- `tests/fm-poll-inject-e2e.test.sh` - the real `bin/fm-poll.sh` pushing its synthetic startup wake and an appended board wake into a private-socket pane, the seq-tracking no-repeat guarantee, and `FM_WAKE_INJECT=0` disabling the push while the queue still fills.

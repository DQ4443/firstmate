# Liveness-derived board (In progress is computed, not hand-edited)

How the board's In progress section is made a computed fact - exactly the items with a live agent - instead of a hand-maintained list that drifts.

## The gap this closes

In progress used to be hand-edited: firstmate moved a row in when it dispatched work and was supposed to move it out when the work finished.
The move-out was a separate manual step that raced the board server and got forgotten, so In progress showed false spinners for work that had already landed.

The fix is to stop hand-editing In progress and derive it.
Firstmate records which board item each dispatched agent is working; `bin/fm-board-reconcile.sh` runs every poller cycle and rewrites `state/board.json` so In progress is exactly the items with a live agent, demoting everything else to its correct section.

Note on the board server: `board-v2` reads `state/board.json` (via its `BOARD_DATA` env) but never writes it - only firstmate and its agents do.
So the reconcile is the authority over In progress; there is no server auto-flip to race.
The write is still atomic (temp + rename) under a lock so a concurrent board read never sees a half-written file and a concurrent board-structure editor serializes.

## The registration contract firstmate follows

Owned by `bin/fm-item-agent.sh`, state in `state/item-agents.json`:

```
{ "items": { "<item-id>": {
    "agent": "<agent name or id>",
    "since": <epoch>, "beat": <epoch>, "done": <bool>, "rest": "<section>" } } }
```

- **On dispatch of an agent for a board item:** `bin/fm-item-agent.sh start <item-id> <agent-id> [rest-section]`.
  `rest-section` is where the item belongs once the agent is gone: `your_word` (default, waiting on David) or `landed`.
  It is recorded now so the reconcile can demote deterministically later.
  `holding` is never an auto-rest target - dependency-blocking is a human judgment.
  `start` rejects any value other than `your_word` or `landed` at registration, and the reconcile still falls back to `your_word` for an unknown recorded value (older records).
- **While a long agent runs:** it stays live past the staleness TTL through check-ins.
  The workflow orchestration already stamps `state/board-checkins.json` at every phase boundary (`bin/fm-board-checkin.sh`, AGENTS.md section 4), which the reconcile reads as a heartbeat, so no extra call is usually needed.
  `bin/fm-item-agent.sh beat <item-id>` exists for agents that do not check in.
- **On agent return (or when the item is no longer being worked):** `bin/fm-item-agent.sh done <item-id>`, which flips the item not-live so the next reconcile demotes it to its rest section.
  `remove` deletes the record outright.

## How liveness is determined

In progress means the ball is with firstmate, which is either of two signals; an item is live iff EITHER holds.

**Agent-live.** Its record is not `done` and its freshness is within `FM_AGENT_LIVE_TTL` (default 1800s).
Freshness is the newest of the record's `since`/`beat` and the item's stamp in `state/board-checkins.json`.

- A healthy long run stays live via its phase-boundary check-ins.
- A crashed or forgotten agent ages out of In progress on its own after the TTL, so a false spinner cannot persist indefinitely even if firstmate never marks it done.
- An explicit `done` demotes immediately.

**Message-live.** The newest message file in the item's thread (`data/board-threads/<id>/`) is authored by `david` - a fresh unanswered David message (AGENTS.md section 2).
This is derived straight from the thread with no bookkeeping: when firstmate replies, its reply becomes the newest file and the item drops out of message-live, demoting to Your word.
It is the same signal board-v2's auto-flip-on-send uses, so the reconcile agrees with the board's own flip instead of fighting it.
So an item David just messaged appears in In progress with no register call, and returns to Your word the moment firstmate answers - the exact "ball with firstmate vs ball with David" semantics, derived, not hand-maintained.

## The reconcile transform (idempotent)

`bin/fm-board-reconcile.sh`, run each poller cycle:

- Promote into In progress every row (from any section) whose item is live (agent-live OR message-live).
- Demote out of In progress every row whose item is not live, into its rest section, converting a row into a landed item when landing.
- Leave `your_word` / `holding` / `landed` rows otherwise untouched, only removing a row that got promoted so no item appears twice; a holding group emptied by a promotion is dropped.
- A live item that has no row anywhere cannot be shown - the reconcile moves rows, it does not invent them.

It writes only when the canonical board actually changed, so the cycle is a cheap no-op whenever nothing moved, and running it twice produces the same board.

## Safety

- **Adoption switch.** If `state/item-agents.json` does not exist, the reconcile is an exact no-op.
  The board stays exactly as firstmate left it until the registry is adopted, so turning the script on cannot wipe a hand-maintained board.
- **Board fail-safe.** A missing or unparseable `state/board.json` is left byte-for-byte untouched, never clobbered.
- **Registry fail-safe.** An unparseable `state/item-agents.json` aborts the reconcile with no write.
  Demoting the whole board on a parse error would be the worst possible failure, so the reconcile refuses.
  `bin/fm-item-agent.sh` likewise refuses to overwrite a present-but-corrupt registry.
- **Atomic + locked.** The write is temp + rename under `state/.board.json.lock`.

## Cutover (human step, after merge)

The reconcile is inert only until the FIRST `fm-item-agent.sh start` creates `state/item-agents.json`.
From that moment it is authoritative, and on the next cycle every In-progress row that is neither agent-live nor message-live is demoted.
So adoption is not a single `start` - it is registering the current reality in one batch, or the first `start` would demote all the other in-flight work.

1. Adoption batch: for EVERY item currently in In progress that represents live agent work, run `bin/fm-item-agent.sh start <item-id> <agent-id> [rest]` once, before or together with the first registration.
   Items that are in In progress only because of an unanswered David message need no registration - the message-live signal keeps them automatically.
2. The poller then runs the reconcile each cycle once the new `bin/fm-poll.sh` is live (`FM_BOARD_RECONCILE=0` disables it).
3. Verify: register a live item and confirm it appears in In progress within a cycle; mark it `done` and confirm it demotes to its rest section; post a David-authored thread message on a Your-word item and confirm it flips to In progress, then a firstmate reply returns it to Your word.
4. From here on, firstmate stops hand-editing In progress; it maintains the registry and lets the board derive from the registry plus the thread-author signal.
   `your_word` / `holding` / `landed` structural edits are still made the usual way (dispatched board-edit agents), and must go through the same board lock (`state/.board.json.lock`) to serialize with the reconcile.

## Tests

- `tests/fm-board-reconcile.test.sh` - adoption no-op, live/promote/demote/land movement, message-live (david-last-thread) union, TTL staleness vs check-in keep-alive, idempotence, both fail-safes, and the end-to-end `fm-item-agent.sh start`/`done` -> reconcile path.

# Meeting-sync schedule (design Phase 5, Decision 7a)

The trigger surface for `bin/fm-meeting-sync.sh`.
Source of truth for the design: `data/operating-model/meeting-sync-design.md`
(section 7, Decision 7a).

## The invariant this whole loop protects

`bin/fm-meeting-sync.sh` NEVER edits `src/components/narrative/content.ts` and
NEVER merges or deploys the MVP tracker.
Every narrative change is surfaced as a change-list and posted to David on the
tracker-sync board thread (`bin/fm-board-reply.sh --your-court`) for his gate.
The scheduler firing more often does not change that.
Narrative never self-merges.

## Do NOT turn the schedule on yet

Design Phase 5 gates the schedule on a hand-run proving one real meeting cycle.
Until firstmate has run the full pipeline by hand for at least one real meeting
(fetch a real slot's notes, produce the change-list, land the autonomous tier,
post the gated + narrative items to the board, and David confirms the result),
the cadence stays OFF.
Nothing in this leaf installs a cron entry or a launchd job.

Two blockers must clear before an UNATTENDED run is honest (design section 4):

- `bin/fm-gfetch.sh` needs a durable Google credential (open question 10).
  Absent it, Stage A takes the honest degrade (posts "paste the notes", exits 3).
- `bin/fm-reconcile.sh` (leaf L5) and `bin/fm-sync-audit.sh` (leaf L1) must be on
  `main`.
  Until then the orchestrator reports each as not-run rather than fabricating a
  result.

## The three cadence fires (Decision 7a: one entry per slot)

Each entry passes its OWN slot identity so Stage A selects slot-scoped docs, not
"the newest doc" (this is what prevents the cron-slot-vs-newest-doc mismatch).
Each is PINNED to `America/Los_Angeles`.
Each fires the sync as tracked background work (`TaskCreate`) so the firstmate
session keeps draining board wakes.

| Slot      | When (PT)        | Command                                                   |
| --------- | ---------------- | --------------------------------------------------------- |
| eod       | every day, 21:00 | `fm-meeting-sync.sh --slot $(date +%F)/eod --apply`       |
| morning   | Mon + Fri, 10:00 | `fm-meeting-sync.sh --slot $(date +%F)/morning --apply`   |
| reconcile | every day, 07:30 | `fm-meeting-sync.sh --slot $(date +%F)/reconcile --apply` |

`fm-meeting-sync.sh install-schedule` prints this same plan on demand and
installs nothing.

## Registering the cadence (CronCreate, the preferred trigger)

At the Phase 5 gate, register three `CronCreate` routines (harness cron), one per
row above, each:

- pinned to `America/Los_Angeles`,
- passing its slot identity in the prompt/command,
- launched as `TaskCreate` background work.

Start each entry at `--dry-run` and switch to `--apply` only after the hand-run
cycle passes.

## TIMEZONE / DST self-defense (Decision 7a)

Classification hinges on the 13:00 PT morning/eod boundary, so the trigger clock
cannot be left implicit.
Pin every entry to `America/Los_Angeles`.
If the scheduler primitive can only fire in UTC, the run self-defends: it converts
its fire-time to PT and re-derives the intended slot rather than trusting the
schedule label, so a fixed UTC fire cannot drift across the boundary at a DST
transition.

## launchd alternative (long-lived, ship-uninstalled)

The launchd form of the two meeting fires ships as uninstalled examples:

- `config/com.firstmate.meeting-sync-eod.plist.example`
- `config/com.firstmate.meeting-sync-morning.plist.example`

The meeting-LESS daily reconcile has its own launchd example on the L5 leaf
(`config/com.firstmate.reconcile-daily.plist.example`); it calls no Google MCP
and so runs cleanly from launchd.
The meeting ingest fires depend on `bin/fm-gfetch.sh` being credentialed.

Install steps live in each plist header.
Install only at the Phase 5 gate.
Verify with `launchctl list <label>`.

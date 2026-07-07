# Bugbot review guide for firstmate

Firstmate is a Claude Code orchestrator. It is almost entirely bash: `bin/*.sh`
scripts driving file-based state under `state/` and `data/`, woken by a launchd
poller (`bin/fm-poll.sh`) and a durable wake queue (`bin/fm-wake-lib.sh`).
There is no application server and no compiled code. Tests are colocated shell
files under `tests/` that source `tests/lib.sh` and must stay shellcheck-clean.
Review this repo as a shell-safety and concurrency codebase, not a web app.

## Prioritize these

- Shell correctness and safety. Unquoted expansions, word-splitting, and glob
  hazards; missing `set -u` (scripts use `set -u`, and libraries expect it);
  functions that swallow a failing exit code; `local` on every function-scoped
  variable. Flag any place a bad or empty value silently propagates.
- Atomic writes. State is written temp-then-`mv` (see the `.restore.$pid` pattern
  in `fm-wake-lib.sh`). Flag a direct in-place overwrite of a state file, a
  read-modify-write without the queue lock, or a partial-write window.
- Concurrency and TOCTOU races in the queue, poller, and reconcile paths
  (`fm-wake-lib.sh` lock helpers, `fm-poll.sh`, `fm-board-reconcile.sh`,
  `fm-item-agent.sh`). This is the sharpest risk class: symlink-based locks,
  stale-pid eviction, steal-lock handoff, and mtime freshness checks are subtle.
  Flag a claim/release path that can drop or double-deliver a wake, or leave a
  lock orphaned.
- Fail-closed vs fail-open discipline, per the comment at each boundary. The
  write fence and hook paths fail OPEN by design; the worktree teardown and
  landed checks fail CLOSED by design. Flag a change that inverts an intended
  direction, and read the header comment before assuming which one applies.
- Isolation and no-merge invariants. `bin/fm-write-fence.sh` must keep blocking
  writes under `~/dev/work/**` and `<root>/projects/**` except inside
  `.claude/worktrees/**` and `~/.treehouse/**`. Merge helpers
  (`fm-pr-merge.sh`, `fm-fleet-sync.sh`) must not gain an unguarded merge, force
  push, or write into a checkout. Treat any weakening of these as high severity.
- Bash 3.2 portability. macOS ships bash 3.2 and it is a target. Flag bash 4+
  only constructs: associative arrays (`declare -A`), `${var^^}`/`${var,,}`,
  `mapfile`/`readarray`, negative array indices, `&>>`. Prefer the portable
  `stat` and `date` branches already used (see `fm_path_mtime`).

## Ignore these

- Shared, stow-managed skill and doc files that show as modified in every
  worktree but are not the PR's real change: `.agents/skills/**`,
  `skills/stow/**`, and the symlink-shared `README.md` and `docs/*.md`. Do not
  review or flag these unless the PR's actual intent is to change them.
- Runtime artifacts and fixtures under `state/` and `data/` (wake queues,
  board JSON, check-in stamps, backlog). These are generated state, not source.
- Stylistic nits already enforced by shellcheck and the test harness. Do not
  restate shellcheck findings; focus on logic, safety, and races it cannot see.
- Deprecated escape-hatch scripts (`fm-spawn.sh`, `fm-send.sh`, `fm-peek.sh`,
  `fm-watch*.sh`, `fm-x-*.sh`) unless the PR touches them; they are retired for
  new dispatch and kept only as a documented fallback.

Keep findings concrete and high-signal. Plain prose, no em dashes, no emojis.

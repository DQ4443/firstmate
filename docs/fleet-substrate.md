# Fleet substrate

Status: DRAFT (2026-07-09). The plumbing described here is BUILT and gate-safe.
The dispatch-brief convention in section 3 is the one part still PENDING David's
design gate on shard boundaries and the parrot layer (decisions.md 2026-07-09 EOD
"multi-account fleet" pins). Nothing here decides shard boundaries, dispatch
routing, or where aggregation sits; it is only the substrate every design variant
of the sharded-orchestrator fleet needs.

## 1. What a node is

A NODE is an account-pinned Claude session home. Each node owns its own
`CLAUDE_CONFIG_DIR`: its own Keychain credential, its own signed-in identity, and
its own 5h / 7d / Fable usage quota. Running several nodes lets the fleet spread
load across multiple Claude subscriptions instead of starving a single account
(the 2026-07-09 cap-kill verdict). A node is NOT a task worktree and NOT a
firstmate-container window; it is a full standalone session that an orchestrator
runs inside.

The registry is `state/fleet-nodes.json` (gitignored, like all `state/`):

```json
{
  "updated_at": 1783650000,
  "nodes": {
    "<name>": {
      "name": "<name>",
      "config_dir": "<abs path to CLAUDE_CONFIG_DIR>",
      "harness": "claude",
      "registered_at": 1783640000
    }
  }
}
```

## 2. bin/fm-node.sh (the node lifecycle CLI)

| Command                                           | Effect                                                                                                                                                    |
| ------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `register <name> <config-dir> [--harness claude]` | Records a node. Config dir must be absolute; an existing dir is canonicalized, a not-yet-created one is allowed with a warning (David signs it in later). |
| `unregister <name>`                               | Removes a node from the registry.                                                                                                                         |
| `get <name>`                                      | The node's registry entry as JSON.                                                                                                                        |
| `list`                                            | Per node: signed-in identity, 5h / 7d / Fable utilization, live session pid. Hits the usage endpoint.                                                     |
| `usage [--pretty]`                                | The generic N-node usage reader, as one JSON doc (section 4).                                                                                             |
| `status`                                          | Registry plus session liveness only; no network.                                                                                                          |
| `spawn <name>`                                    | Launches the node's session (section 5).                                                                                                                  |

NO AUTO-LOGIN is a hard property: `fm-node.sh` never authenticates a node and
never writes or prints a credential. David signs each node in once, by hand, the
first time its session launches.

Identity and quota are read the same way the board's existing two-account widget
reads them (`~/.firstmate-board/usage-feed.sh`):

- Identity: `oauthAccount.emailAddress` in the home's `.claude.json` (the default
  `~/.claude` home keeps it one level up at `~/.claude.json`).
- Token: the macOS Keychain service `Claude Code-credentials` for the default
  home, or `Claude Code-credentials-<first 8 hex of sha256(CLAUDE_CONFIG_DIR)>`
  for an isolated home. Read straight into the usage `curl`, never printed.
- Utilization: one `GET https://api.anthropic.com/api/oauth/usage` call yields the
  5h window (`five_hour`), the 7d window (`seven_day`), and the per-model weekly
  quota (`limits[]` kind `weekly_scoped`, e.g. Fable).

## 3. Dispatch-brief format (CONVENTION, pending David's gate)

Every unit of work handed to a node-pinned orchestrator or one of its agents
rides a dispatch brief. This is the stable envelope; the routing policy that
decides WHICH node and WHICH shard owns a goal is the design-gate question and is
deliberately not fixed here.

A dispatch brief carries exactly:

- `goal id`: the durable identifier for the unit of work. It is the join key
  across the board, the backlog, and the item to agent registry
  (`state/item-agents.json`, now Postgres-backed on the new board), so any node
  can answer "who owns this" without shared conversation state.
- `brief path`: an absolute path to the human-readable brief on disk
  (`data/<goal-id>/brief.md` for the existing spawn machinery), never inline
  chat. A weaker downstream model needs the facts written down and cited by path
  (AGENTS.md, CONTEXT.md, the project verify skill).
- `evidence contract`: what the returning agent must produce - the exact
  command(s) it ran and their real output, artifact paths, branch, worktree path,
  and last commit sha, plus a `NEXT_STEP`. Same structured-return schema
  firstmate already enforces (AGENTS.md section 4); the node boundary does not
  weaken it.
- `board row`: the board item the work reports into. Results close the loop in
  that item's thread, and section placement (whose turn it is) is derived, not
  hand-set.
- `return path`: the wake queue (`bin/fm-wake-lib.sh`, drained by
  `bin/fm-wake-drain.sh` on the launchd poller). A finished or blocked node run
  enqueues a durable wake rather than assuming a live listener, so a compacted or
  restarted control plane still picks the result up.

OPEN (design gate, not specified here): shard boundaries (by goal or by repo),
cross-shard handoff, how `decisions.md` pins propagate to every node as shared
law, and where the aggregation / parrot layer sits (the board meta chat as
David's single pane, the thin router behind it). Those belong in the fleet design
doc under review, not in this substrate note.

## 4. The N-node usage reader (additive)

`fm-node.sh usage` walks `state/fleet-nodes.json` and emits one JSON doc:

```json
{
  "generated_at": 1783650000,
  "nodes": {
    "<name>": {
      "name": "<name>",
      "config_dir": "...",
      "harness": "claude",
      "identity": "<email or null>",
      "session": { "live": true, "pid": 4242 },
      "ok": true,
      "five_hour": {
        "used_percent": 86,
        "utilization": 86.0,
        "resets_at": 1783651800,
        "status": "warning"
      },
      "seven_day": {
        "used_percent": 36,
        "utilization": 36.0,
        "resets_at": 1784106000,
        "status": "normal"
      },
      "fable": {
        "used_percent": 9,
        "resets_at": 1784106000,
        "status": "normal",
        "source": "oauth/usage:weekly_scoped"
      }
    }
  }
}
```

This is ADDITIVE. It does not touch `~/.firstmate-board/usage-feed.sh`, so the
existing `accounts.work` / `accounts.personal` widget keeps rendering unchanged.
A later aggregator can merge this doc's `nodes` key into `state/usage.json`
alongside the two-account block; the per-node shape matches the account shape
(`five_hour` / `seven_day` / `fable`, each degrading independently) so the panel
can render nodes with the same bars. A node whose token is unreadable (not signed
in, expired, or network down) degrades to `ok: false` with an `error`, exactly
like a no-data account column.

## 5. Session spawn

`spawn <name>` creates a standalone tmux session `fm-node-<name>` and launches
`claude` inside it with `CLAUDE_CONFIG_DIR` exported to the node's home. It
reuses fm-spawn.sh's send SEQUENCE (export the per-session env, then the launch
command, then Enter) but deliberately NOT its container/worktree machinery: that
path exists for crewmate and scout task windows with a brief and an isolated
worktree, whereas a node is a full account-pinned home with neither. The session
is idempotent: a second `spawn` of a live node reports the running session
instead of recreating it. No brief, no worktree, no credentials are involved -
claude launches bare and David signs the node in himself if prompted.

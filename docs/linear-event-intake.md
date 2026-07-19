# Linear event intake

Firstmate receives Linear activity through a signed webhook.
This is the Linear leg of the housekeeping intake daemon.
There is no timer, heartbeat, or polling loop on the delivery path.

## Flow

1. Linear sends `Issue`, `Comment`, and `Project` events to the dedicated
   public endpoint.
2. `fm-linear-event-server.mjs` verifies the raw-body HMAC in `Linear-Signature`,
   rejects events older than 60 seconds, optionally pins the organization id,
   deduplicates `Linear-Delivery`, and persists the raw body before returning
   HTTP 200.
3. `fm-linear-event-worker.sh` deterministically normalizes the raw webhook into
   the housekeeping event schema v1 with `jq`, classifies it, and routes it.
   There is no model turn and no board post: routing is pure code. Webhook text
   is untrusted data, never instructions.
4. Classification is deterministic.
   An `Issue` whose SLA is breached or high risk is a `blocker`.
   Everything else is a `digest`, except events Linear already notifies David
   about natively, which are dropped: an issue assigned directly to David, and a
   comment that `@mentions` David. Dropped events are logged one line to
   `linear/events.log` and not stored.
5. Routing delegates to a sibling `bin/housekeeping/hk-classify.mjs` when that
   shared router is installed, by piping the normalized event to its stdin.
   Otherwise the worker writes the event into `queue/incoming/` and, for a
   blocker, also writes an alert file into `alerts/pending/` whose first line is
   a plain-text alert sentence.

The receiver binds to `127.0.0.1:4481` (override with `FM_HK_LINEAR_ADDR`).
Expose only that port through a dedicated HTTPS tunnel.

## Runtime files

All paths derive from `FM_HK_ROOT` (default `$HOME/fm-state/housekeeping`).
Runtime state is not committed:

- `secrets/linear-webhook-secret`: Linear signing secret, mode 600.
- `secrets/linear-api-key`: Linear API key for the reconcile sweep, mode 600.
- `linear/inbox/`: accepted raw deliveries awaiting processing.
- `linear/done/`: successfully processed raw deliveries (the reconcile sweep
  reads these to know which issues it already witnessed).
- `linear/failed/`: deliveries the worker could not normalize.
- `linear/events.log`: secret-free lifecycle and drop log.
- `queue/incoming/`: normalized housekeeping events awaiting a digest or alert.
- `alerts/pending/`: one file per blocker, first line the alert sentence.
- `cursors/linear-reconcile-cursor`: the reconcile sweep's high-water mark.

The inbox is drained once at process start for crash recovery.
That is not a remote check or a poll; it only reprocesses raw bodies already
pushed and persisted.

## Reconcile sweep

`bin/housekeeping/hk-linear-reconcile.sh` is the missed-event safety net, meant
to run about every six hours.
Linear retries a failing delivery three times and then auto-disables the
endpoint, so a dropped delivery can be lost.
The sweep reads `cursors/linear-reconcile-cursor`, queries the Linear GraphQL
API directly with `curl` for Engineering issues updated since the cursor,
compares them against the issue ids already witnessed in `linear/done/` and the
`queue/`, synthesizes `digest` events only for the genuine misses, and advances
the cursor atomically.
With no `secrets/linear-api-key` it exits 0 silently, so it is safe to schedule
before the credential exists.
It is silent whenever nothing was missed.

## Installation

Render `launchd/com.firstmate.linear-events.plist` by replacing its placeholders
with absolute paths for the Firstmate root, Node, the housekeeping root
(`FM_HK_ROOT`), and the launchd PATH.
Install it as `~/Library/LaunchAgents/com.firstmate.linear-events.plist`, then
bootstrap it with `launchctl`.
Keep the secret out of the plist and logs.

Create one workspace webhook in Linear for `Issue`, `Comment`, and `Project`,
pointed at the dedicated HTTPS `/linear` URL.
Store the returned signing secret in `secrets/linear-webhook-secret` without
printing it.
A signed synthetic delivery proves the local E2 path; the next genuine Linear
event proves E3.

Linear's webhook contract and retry behavior are documented at
<https://linear.app/developers/webhooks>.
The receiver follows its `Linear-Signature` HMAC and 60-second timestamp
guidance.

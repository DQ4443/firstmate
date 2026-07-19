# Linear event intake

Firstmate receives Linear activity through a signed webhook. There is no timer,
heartbeat, or polling loop.

## Flow

1. Linear sends `Issue` and `Comment` events to the dedicated public endpoint.
2. `fm-linear-event-server.mjs` verifies the raw-body HMAC in
   `Linear-Signature`, rejects events older than 60 seconds, optionally pins the
   organization id, deduplicates `Linear-Delivery`, and persists the event before
   returning HTTP 200.
3. `fm-linear-event-worker.sh` gives a bounded copy of the verified event to a
   fresh Claude print-mode turn with every tool disabled. Webhook text is
   explicitly untrusted data, not instructions.
4. The wrapper posts Claude's one-line implication summary to the board's
   `meta` thread through `fm-board-reply.sh`. The model cannot write Linear,
   mutate a repository, use credentials, or call a tool.

The receiver binds to `127.0.0.1:4481`. Expose only that port through a
dedicated HTTPS tunnel. Do not expose or alter the private board service on
`127.0.0.1:4478`.

## Runtime files

Runtime state lives under `state/linear-events/` and is not committed:

- `webhook-secret`: Linear signing secret, mode 600.
- `inbox/`: accepted events awaiting processing.
- `done/`: successfully processed deliveries.
- `failed/`: deliveries whose analysis or board post failed.
- `events.log`: secret-free lifecycle log.

The inbox is drained once at process start for crash recovery. That is not a
remote check or a poll; it only processes events already pushed and persisted.

## Installation

Render `launchd/com.firstmate.linear-events.plist` by replacing its placeholders
with absolute paths for the Firstmate root, Node, Claude, and the launchd PATH.
Install it as `~/Library/LaunchAgents/com.firstmate.linear-events.plist`, then
bootstrap it with `launchctl`. Keep the secret out of the plist and logs.

Create one workspace webhook in Linear for `Issue` and `Comment`, pointed at the
dedicated HTTPS `/linear` URL. Store the returned signing secret in
`state/linear-events/webhook-secret` without printing it. A signed synthetic
delivery proves the local E2 path; the next genuine Linear event proves E3.

Linear's webhook contract and retry behavior are documented at
<https://linear.app/developers/webhooks>. The receiver follows its
`Linear-Signature` HMAC and 60-second timestamp guidance.

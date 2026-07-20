# Housekeeping intake daemon (dqubuntu)

Runbook for the event-driven housekeeping daemon that watches David's Gmail (Gemini meeting notes only) and Linear, and wakes firstmate with alerts and twice-daily digests.
Design source is work/housekeeping-fm/event-driven-design.md.
This file is the operator runbook for the deploy kit under deploy/housekeeping/.

## Architecture (two legs)

The daemon runs on dqubuntu under the systemd user manager with linger enabled, so it survives logout and reboot.
It has two inbound legs, both terminating in one on-disk queue that firstmate drains.

Leg 1 is Gmail.
A Pub/Sub StreamingPull consumer (hk-gmail-pull.mjs) receives push notifications outbound over a streaming pull, so it needs no public ingress.
Its scope is structurally narrowed to Gemini meeting summaries only: a Gmail label filter plus a labelId filter on users.watch() and history.list make all other mail invisible to the daemon.
gemini-notes@google.com summaries become digest events of kind "notes"; meetings-noreply@google.com "Problem with the notes" failures become digest events of kind "notes-failure" sorted to the top of the digest.

Leg 2 is Linear.
fm-linear-event-server.mjs is an HMAC-gated HTTP listener on 127.0.0.1:4481.
It is the only leg that needs public ingress, so it sits behind a public Tailscale Funnel on port 10000 (see the port rationale below).
A Linear workspace webhook posts entity events to it; fm-linear-event-worker.sh is the serial worker that classifies and enqueues them.

Both legs write normalized v1 event JSON into the queue, classification sorts each event into blocker or digest, and delivery pushes genuine blockers through immediately while batching everything else into at most two digests per day.
Empty digests are never sent, and the daemon never relays what a native Linear or Gmail notification already pushes to David.

Two timer-driven sidecars keep the legs healthy.
hk-gmail-watch-renew renews the Gmail watch daily, because users.watch() expires about every seven days.
hk-linear-reconcile sweeps Linear every six hours as a safety net for any webhook delivery the listener missed.

## Runtime root and layout

The runtime root is the FM_HK_ROOT env, default $HOME/fm-state/housekeeping on the box.
The installer creates this tree and the daemon owns it.

    queue/incoming/    one JSON file per normalized event, named <utc-ts>-<source>-<id>.json
    queue/processed/   events already folded into a digest or an alert
    alerts/pending/    one file per blocker, first line is the alert sentence in plain text
    digests/pending/   digest markdown files named <YYYY-MM-DD>-<slot>.md
    secrets/           chmod 700 dir, 600 files (see below)
    cursors/           gmail-history-id, gmail-watch-expiry, linear-reconcile-cursor

Cursor writes are atomic (temp file plus rename) so a crash never leaves a half-written cursor.

### Secrets layout

The secrets/ directory is mode 700 and every file in it is mode 600.
The installer creates the directory with the right mode and never overwrites an existing secrets/ or cursors/ file.

    secrets/linear-webhook-secret     the Linear webhook signing secret (HMAC-SHA256 key)
    secrets/google-oauth-client.json  the INTERNAL OAuth client credentials from GCP
    secrets/google-token.json         the user OAuth token (refresh token) written by the Gmail bootstrap
    secrets/gcp-sa.json               the GCP service account key for Pub/Sub subscriber identity

hk-gmail-pull and hk-gmail-watch-renew carry ConditionPathExists on secrets/google-token.json, so they stay dead-quiet until the Gmail bootstrap has run.

## Funnel on port 10000, not 443 or 8443

The Linear webhook needs a public HTTPS URL, but Tailscale Funnel is keyed per-port and allows only ports 443, 8443, and 10000, and both 443 and 8443 already carry tailnet-only serve handlers that must never go public.
443 carries tailnet-only paths (/ to 127.0.0.1:4387, /out to 127.0.0.1:8790, /login to 127.0.0.1:6080), so funneling 443 would expose them.
8443 is already occupied too: the box runs a tailnet-only serve on 8443 (/ to 127.0.0.1:6080, a VNC-ish surface) that must never go public, and because Funnel is per-port, funneling 8443 would expose exactly that service (the 8443 collision, discovered 2026-07).
So the Linear webhook uses port 10000, the one remaining free Funnel port, which Funnel keys independently of the 443 and 8443 serve configs.

The public webhook URL is:

    https://dqubuntu.tailb6dce4.ts.net:10000/linear  ->  127.0.0.1:4481

deploy/housekeeping/funnel-setup.sh enables exactly this and then verifies, via tailscale serve status, that 10000 is public (Funnel on) exposing only /linear and that every other port is still tailnet-only.
Before enabling, a collision guard refuses to funnel port 10000 if any handler other than our /linear proxy is already bound to it.
It fails loudly if any other port ever shows Funnel on, or if the 10000 target does not proxy to 127.0.0.1:4481.

## Install

Run the installer from the Mac, not the box.
It is idempotent and safe to re-run.

    deploy/housekeeping/install.sh

The installer rsyncs the code subset to dqubuntu:~/firstmate/, creates the FM_HK_ROOT tree with correct modes, installs the systemd user units, reloads the daemon, enables the four timers, installs the Mac-side poller check, and prints a status table.
It never enables or starts a service whose code has not landed on the box yet, so it is safe to run before every daemon leg has merged.

The Mac-side poller check is deploy/housekeeping/housekeeping.check.sh in the repo, but the firstmate state/ dir is gitignored machine-local runtime, so the check cannot ride a git pull.
The installer copies it into this checkout's state/ dir as state/housekeeping.check.sh, where fm-poll.sh globs state/*.check.sh and runs it.
Run the installer from the live firstmate checkout (the machine whose poller should wake), or copy the file into that machine's state/ dir by hand.
It does not register the Linear webhook and does not run the Gmail OAuth bootstrap, because those are David-driven steps below.

Env overrides: HK_REMOTE (ssh alias, default dqubuntu), HK_REMOTE_REPO (repo path on the box, default firstmate), FM_HK_ROOT (custom runtime root, default $HOME/fm-state/housekeeping), and HK_RUN_FUNNEL=1 to also run the funnel setup over ssh.
A custom FM_HK_ROOT is honored end to end: the installer writes a systemd drop-in per service so ProtectSystem=strict still allows writes to the custom path.

To also enable the funnel in the same pass:

    HK_RUN_FUNNEL=1 deploy/housekeeping/install.sh

## Bootstrap sequence

Do these in order after the first install.
The Linear webhook is registered LAST, because it must point at a listener that is already live behind the funnel.

### 1. Gmail OAuth (David, about ten minutes)

Create the GCP project, an INTERNAL OAuth client, the Pub/Sub topic and pull subscription, and grant roles/pubsub.publisher to gmail-api-push@system.gserviceaccount.com.
Place secrets/google-oauth-client.json and secrets/gcp-sa.json into the runtime root's secrets/ directory on the box (mode 600).
Apply the Gmail filters and the gemini-notes label in David's own account so the daemon's scope stays structurally narrow.

Then run the Gmail OAuth consent flow.
The bootstrap runs on the box and listens for the OAuth redirect on a localhost port on the box, so forward that port from the Mac and open the auth URL in the Mac browser:

    ssh -L 9099:localhost:9099 dqubuntu     # forward the box callback port to the Mac
    # on the box, in that session, run the Gmail bootstrap; it prints an auth URL
    # open the printed URL in the Mac browser and approve
    # the redirect returns to localhost:9099 on the Mac and tunnels to the box listener

The callback port must match the redirect_uri configured in the OAuth client and in the bootstrap script; 9099 above is the convention, adjust the -L forward if the bootstrap uses a different port.
On success the bootstrap writes secrets/google-token.json, which un-gates the Gmail units.
Start the pull consumer:

    ssh dqubuntu 'systemctl --user start hk-gmail-pull'

### 2. Funnel (David approves the Tailscale grant, then run the script)

The funnel needs a Funnel grant in the tailnet ACL policy.
If the grant is missing, funnel-setup.sh errors and prints the exact one-line instruction; add the nodeAttrs funnel grant at https://login.tailscale.com/admin/acls/file and re-run.

    ssh dqubuntu 'bash ~/firstmate/deploy/housekeeping/funnel-setup.sh'

Confirm the post-check reports 10000 public (exposing only /linear) and every other port tailnet-only.

### 3. Linear webhook (David, one click, LAST)

Register the workspace webhook only after the intake server and the funnel are both live.
In Linear go to Settings, then API, then Webhooks, and create a webhook (David is a workspace admin).

    URL:     https://dqubuntu.tailb6dce4.ts.net:10000/linear
    Scope:   Issues, Comments, Projects to start (workspace / all public teams)
    Secret:  copy the signing secret into secrets/linear-webhook-secret (mode 600) on the box

David's Linear user id is 448a6290-609b-4651-b416-768eb0ac9c93 (david.qu@kronosai.co).
The Engineering team id is 41cab207-4ecd-4dad-9d57-1163a7a24507.
After saving, trigger a test event in Linear and confirm it lands in queue/incoming/ on the box.

## Recovery

Watch expired (Gmail stops delivering).
The daily hk-gmail-watch-renew timer renews it, but to renew immediately run:

    ssh dqubuntu 'systemctl --user start hk-gmail-watch-renew.service'
    ssh dqubuntu 'systemctl --user list-timers hk-gmail-watch-renew.timer'

historyId gap (Gmail history too old, a 404 on history.list).
The pull consumer must re-sync by re-issuing users.watch() and storing the fresh historyId in cursors/gmail-history-id.
Restart the consumer, which re-establishes the watch, then confirm cursors/gmail-history-id advanced:

    ssh dqubuntu 'systemctl --user restart hk-gmail-pull'
    ssh dqubuntu 'cat ~/fm-state/housekeeping/cursors/gmail-history-id'

Funnel down (Linear deliveries failing, webhook auto-disabled after persistent failure).
Re-run the funnel setup and confirm the post-check, then re-enable the webhook in Linear if it auto-disabled:

    ssh dqubuntu 'bash ~/firstmate/deploy/housekeeping/funnel-setup.sh'
    ssh dqubuntu 'tailscale serve status'

Box down or rebooted.
Linger keeps the user services running across reboot, so the daemon should come back on its own.
Verify after a reboot:

    ssh dqubuntu 'systemctl --user is-active hk-linear-intake hk-gmail-pull'
    ssh dqubuntu 'systemctl --user list-timers hk-*'

If a service did not come back, re-run the installer from the Mac; it is idempotent.

Mac-side wake path.
The poller check (source deploy/housekeeping/housekeeping.check.sh, installed as state/housekeeping.check.sh) runs on the firstmate poller and probes the box at most once per 120 seconds via the state/.hk-check-last marker.
It prints "housekeeping: N alert(s) pending" or "housekeeping: digest ready" only when there is something to deliver, and stays silent when the box is unreachable.
If firstmate is not waking on housekeeping events, confirm the poller is running and state/housekeeping.check.sh is present (re-run install.sh from the live checkout to reinstall it), and check ssh reachability with the same BatchMode probe the check uses.

## David-clicks checklist (real URLs)

1. GCP console to create the project, INTERNAL OAuth client, and Pub/Sub topic plus pull subscription: https://console.cloud.google.com
2. Gmail filters and the gemini-notes label in David's account: https://mail.google.com/mail/u/0/#settings/filters
3. Tailscale ACL policy to add the Funnel nodeAttrs grant for dqubuntu: https://login.tailscale.com/admin/acls/file
4. Linear webhook registration, pointing at the port-10000 funnel URL: https://linear.app/settings/api
   Webhook URL to paste: https://dqubuntu.tailb6dce4.ts.net:10000/linear

The two mail senders the daemon watches are gemini-notes@google.com (the meeting summaries) and meetings-noreply@google.com (the "Problem with the notes" failure notices).

---
name: sync
description: Reconcile firstmate with reality when the captain invokes /sync (or says "sync", "are you in sync", "catch up", "check the board", "you seem out of date"). Sweep board threads for unanswered David messages, find stalled or silently-idle In-progress items, verify the poller and drain wakes, check the deploy gap and in-flight runs, then report only what needs David or what you unstuck.
user-invocable: true
metadata:
  internal: true
---

# sync

David suspects firstmate has drifted from reality: a ghosted thread, a stalled item, a status that no longer matches. Reconcile fast, fix what is broken, report only the deltas. Run the checks below cheapest-first. Act on problems; stay silent on anything healthy.

1. Threads waiting on you. Scan every board thread for an unanswered David message (thread whose newest author is David). Answer them oldest-first BEFORE advancing any seen marker, a premature mark ghosts him. Thread replies post directly from this session. Confirm no waiting-on-David item is mis-parked in Holding (Holding is dependency-blocked ONLY).

2. Poller and wakes. `launchctl list com.firstmate.poller` (and com.firstmate.board-v2). If dead, restart and confirm it comes back. Drain queued wakes (`bin/fm-wake-drain.sh`) and re-read state/board.json so your view matches the board. Live poller plus zero queued wakes means the delivery path is in sync.

3. Stale or silently-idle In-progress. For each In-progress item, confirm the ball is really with firstmate: a live agent working it, or a fresh unanswered David message. Cross-check the item->agent registry (bin/fm-item-agent.sh) and each in-flight run's journal mtime against its phase budget (~15 min). A run whose journal has not advanced past budget is stalled: read the journal and restart the stalled agent from the script with its accumulated context, or escalate. An agent that pinged "idle/available" but never returned its result is done-not-delivered: pull the result yourself from git/artifacts, do not keep waiting. An item with neither a live agent nor an unanswered David message should not be In progress.

4. Deploy gap (merged is not deployed). `git -C ~/dev/personal/firstmate log --oneline HEAD..origin/main`. A merged PR changes nothing on the running command center until you fast-forward the checkout and restart the poller. If behind, confirm no incoming file overlaps David's dirty working tree, then `git merge --ff-only origin/main` and restart the poller.

5. Backlog vs reality. data/backlog.md is the source of truth for what is in flight, not this conversation. Every In-flight entry with a runId: confirm it is actually running; resume a stalled one via resumeFromRunId rather than redoing finished phases. Reconcile section placement (In progress = ball with firstmate; Your word = waiting on David).

6. PR and CI awareness. Refresh open PRs and CI for the active repos (`gh pr list --repo <repo> --state open --json number,title,statusCheckRollup,reviewDecision,mergeStateStatus`). Surface only what needs David: a red check on his PR, a review that unblocks a merge, a newly CLEAN mergeable PR. Never merge, push, or comment from this sweep.

7. Report. One concise digest, PT timestamps: what is waiting on David, what was stalled and what you did about it, anything newly needing his decision. Say nothing about healthy items. If everything is clean, say so in a single line.

This is read-and-reconcile, not new dispatch. Do not spawn new work beyond restarting a stalled run, and keep consent rules for anything destructive or outward-facing.

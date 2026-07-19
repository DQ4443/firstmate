#!/bin/sh
# Poller check (Mac side): wake firstmate when the dqubuntu housekeeping daemon
# has a NEW pending alert or a NEW pending digest. Prints ONE line on a
# wake-worthy event, silent otherwise. Alerts win over digests.
#
# Two markers keep this quiet:
#   state/.hk-check-last  rate-limits the ssh probe to one per 120s, so a busy
#                         poller loop never floods the box. Advanced on EVERY
#                         probe attempt (reachable or not) so a down box stays
#                         silent instead of wake-spamming.
#   state/.hk-check-seen  the set of pending basenames already announced. We wake
#                         only when the pending set GROWS (a filename we have not
#                         seen), so an alert that sits in alerts/pending until
#                         firstmate acts, or an undrained digest, is announced
#                         once, not every 120s forever.
#
# The ssh probe is bounded on both ends: ConnectTimeout caps connection setup and
# ServerAliveInterval/ServerAliveCountMax abort a hung post-auth session (a stuck
# remote find or half-open link), so this check always returns and never stalls
# the poller loop that globs state/*.check.sh. An outer timeout(1) adds a hard
# ceiling where the binary exists (it is not in the macOS base install).
#
# Box unreachable => silent (no output), rate-limit marker still advanced.
#
# This is the tracked canonical source. The firstmate state/ dir is gitignored
# (machine-local runtime), so install.sh copies this file to state/housekeeping.check.sh
# on the firstmate Mac, where the poller globs state/*.check.sh and runs it.
# At runtime $0 is state/housekeeping.check.sh, so the markers land in state/.
REMOTE="${HK_REMOTE:-dqubuntu}"
INTERVAL="${HK_CHECK_INTERVAL:-120}"

DIR="$(dirname "$0")"
MARKER="${DIR}/.hk-check-last"
SEEN="${DIR}/.hk-check-seen"

# Rate limit: skip the probe if we probed within INTERVAL seconds.
if [ -f "$MARKER" ]; then
  now="$(date +%s)"
  last="$(date -r "$MARKER" +%s 2>/dev/null || echo 0)"
  if [ "$((now - last))" -lt "$INTERVAL" ]; then
    exit 0
  fi
fi
# Advance the marker now, before probing, so a down box does not wake-spam.
touch "$MARKER" 2>/dev/null || true

# Prefer a hard outer timeout when a timeout binary is available (belt-and-
# suspenders on top of ssh's own ConnectTimeout + ServerAlive bounds).
TO=""
if command -v timeout >/dev/null 2>&1; then
  TO="timeout 15"
elif command -v gtimeout >/dev/null 2>&1; then
  TO="gtimeout 15"
fi

# One ssh round-trip: an "OK" sentinel line (so we can tell reachable-but-empty
# from unreachable), then one "A <basename>" line per pending alert and one
# "D <basename>" line per pending digest.
# SC2086: $TO is an intentional word-split (empty or "timeout 15").
# SC2016: the single-quoted remote command must expand $FM_HK_ROOT/$HOME on the
# box, not locally on the Mac.
# shellcheck disable=SC2086,SC2016
out="$($TO ssh -o BatchMode=yes -o ConnectTimeout=5 \
  -o ServerAliveInterval=5 -o ServerAliveCountMax=2 "$REMOTE" \
  'R="${FM_HK_ROOT:-$HOME/fm-state/housekeeping}"; printf "OK\n"; \
   find "$R/alerts/pending"  -type f -printf "A %f\n" 2>/dev/null; \
   find "$R/digests/pending" -type f -printf "D %f\n" 2>/dev/null' 2>/dev/null)" || exit 0

# Unreachable/empty => silent. The first line must be the OK sentinel; anything
# else is a malformed/partial response, so stay silent.
[ -n "$out" ] || exit 0
first="$(printf '%s\n' "$out" | head -n1)"
[ "$first" = "OK" ] || exit 0

# Current pending set (basenames with an A/D category prefix), sorted, blanks dropped.
CUR="$(mktemp 2>/dev/null)" || exit 0
trap 'rm -f "$CUR"' EXIT
printf '%s\n' "$out" | tail -n +2 | sed '/^$/d' | sort > "$CUR"

# New entries = pending lines not already announced in the seen set.
if [ -f "$SEEN" ]; then
  new="$(grep -Fxv -f "$SEEN" "$CUR" 2>/dev/null || true)"
else
  new="$(cat "$CUR")"
fi

# Persist the seen set atomically (tmp + rename) to exactly the current pending
# set, so a removed file can re-fire later and a still-pending one stays quiet.
if cp "$CUR" "${SEEN}.tmp" 2>/dev/null; then
  mv "${SEEN}.tmp" "$SEEN" 2>/dev/null || rm -f "${SEEN}.tmp" 2>/dev/null || true
fi

# Decide the wake. Alerts win over digests.
alerts="$(grep -c '^A ' "$CUR" 2>/dev/null)"
[ -n "$alerts" ] || alerts=0
if printf '%s\n' "$new" | grep -q '^A '; then
  printf 'housekeeping: %s alert(s) pending\n' "$alerts"
elif printf '%s\n' "$new" | grep -q '^D '; then
  printf 'housekeeping: digest ready\n'
fi
exit 0

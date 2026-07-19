#!/bin/sh
# Poller check (Mac side): wake firstmate when the dqubuntu housekeeping daemon
# has pending alerts or a pending digest. Prints ONE line on a wake-worthy
# event, silent otherwise. Alerts win over digests.
#
# Rate-limited to one ssh probe per 120s via state/.hk-check-last so a busy
# poller loop never floods the box. The marker advances on EVERY probe attempt,
# reachable or not, so an unreachable box stays silent instead of wake-spamming.
#
# Box unreachable => silent (no output), marker still advanced.
#
# This is the tracked canonical source. The firstmate state/ dir is gitignored
# (machine-local runtime), so install.sh copies this file to state/housekeeping.check.sh
# on the firstmate Mac, where the poller globs state/*.check.sh and runs it.
# At runtime $0 is state/housekeeping.check.sh, so the marker lands in state/.
REMOTE="${HK_REMOTE:-dqubuntu}"
INTERVAL="${HK_CHECK_INTERVAL:-120}"

DIR="$(dirname "$0")"
MARKER="${DIR}/.hk-check-last"

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

# One ssh round-trip: emit "<alerts> <digests>" counts from the box, or nothing.
counts="$(ssh -o BatchMode=yes -o ConnectTimeout=5 "$REMOTE" \
  'R="${FM_HK_ROOT:-$HOME/fm-state/housekeeping}"; \
   a=$(find "$R/alerts/pending" -type f 2>/dev/null | wc -l); \
   d=$(find "$R/digests/pending" -type f 2>/dev/null | wc -l); \
   printf "%s %s" "$a" "$d"' 2>/dev/null)" || exit 0

# Unreachable or malformed => silent.
[ -n "$counts" ] || exit 0
alerts="${counts% *}"
digests="${counts#* }"
case "$alerts" in *[!0-9]*|'') exit 0 ;; esac
case "$digests" in *[!0-9]*|'') exit 0 ;; esac

if [ "$alerts" -gt 0 ]; then
  printf 'housekeeping: %s alert(s) pending\n' "$alerts"
elif [ "$digests" -gt 0 ]; then
  printf 'housekeeping: digest ready\n'
fi
exit 0

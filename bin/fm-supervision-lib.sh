# shellcheck shell=bash
# Shared "supervision missing" predicate.
# Usage: . bin/fm-supervision-lib.sh
#
# True exactly when a firstmate home has in-flight work (a state/<id>.meta
# exists) but no supervisor has a fresh liveness beacon. Under the workflow
# paradigm the launchd poller (bin/fm-poll.sh, beacon state/.last-poller-beat) is
# the live supervisor; the old watcher (bin/fm-watch.sh, beacon
# state/.last-watcher-beat) remains a documented escape hatch. Either beacon
# within the grace window counts as supervised, so this predicate no longer false-
# alarms when the poller alone is up. bin/fm-guard.sh uses this grace-based warning
# predicate directly; bin/fm-turnend-guard.sh uses the status fields here for its
# banner but performs its end-of-turn block decision with the live supervisor
# checks in bin/fm-wake-lib.sh.

# Portable mtime; Linux stat lacks -f, macOS stat lacks -c.
fm_sup_stat_mtime() {
  if [ "$(uname)" = Darwin ]; then
    stat -f %m "$1" 2>/dev/null
  else
    stat -c %Y "$1" 2>/dev/null
  fi
}

# fm_supervision_status <state-dir> [grace-seconds]
# Populates, for the state dir at $1:
#   FM_SUP_IN_FLIGHT      count of state/*.meta (in-flight tasks)
#   FM_SUP_WATCHER_FRESH  true/false - the watcher beacon is within the grace window
#   FM_SUP_POLLER_FRESH   true/false - the poller beacon is within the grace window
#   FM_SUP_SUPERVISED     true/false - EITHER beacon is fresh (the health verdict)
#   FM_SUP_BEACON_DESC    freshest beacon, for banners: "poller 4s ago" /
#                         "watcher 12s ago" / "unknown" / "never"
#   FM_SUP_QUEUE_PENDING  true/false - state/.wake-queue has unread records
# grace-seconds defaults to $FM_GUARD_GRACE, then 300, matching fm-guard.sh.
# Always returns 0; callers read the vars, or use fm_supervision_unhealthy below.
fm_supervision_status() {
  local state=$1 grace=${2:-${FM_GUARD_GRACE:-300}} meta now
  local w_beat p_beat w_age p_age m best_age best_which
  FM_SUP_IN_FLIGHT=0
  FM_SUP_WATCHER_FRESH=false
  FM_SUP_POLLER_FRESH=false
  FM_SUP_SUPERVISED=false
  FM_SUP_BEACON_DESC=never
  FM_SUP_QUEUE_PENDING=false

  for meta in "$state"/*.meta; do
    [ -e "$meta" ] || continue
    FM_SUP_IN_FLIGHT=$((FM_SUP_IN_FLIGHT + 1))
  done

  now=$(date +%s)
  w_beat="$state/.last-watcher-beat"
  p_beat="$state/.last-poller-beat"
  w_age=
  p_age=
  if [ -e "$w_beat" ]; then
    m=$(fm_sup_stat_mtime "$w_beat")
    if [ -n "$m" ]; then
      w_age=$(( now - m ))
      [ "$w_age" -lt "$grace" ] && FM_SUP_WATCHER_FRESH=true
    fi
  fi
  if [ -e "$p_beat" ]; then
    m=$(fm_sup_stat_mtime "$p_beat")
    if [ -n "$m" ]; then
      p_age=$(( now - m ))
      [ "$p_age" -lt "$grace" ] && FM_SUP_POLLER_FRESH=true
    fi
  fi

  # Either supervisor's fresh beacon means the home is supervised.
  { [ "$FM_SUP_WATCHER_FRESH" = true ] || [ "$FM_SUP_POLLER_FRESH" = true ]; } \
    && FM_SUP_SUPERVISED=true

  # Describe the freshest (smallest-age) beacon so the banner names the real
  # supervisor. "never" when neither beacon exists, "unknown" when a beacon file
  # exists but its mtime is unreadable.
  best_age=
  best_which=
  if [ -n "$w_age" ]; then
    best_age=$w_age
    best_which=watcher
  fi
  if [ -n "$p_age" ] && { [ -z "$best_age" ] || [ "$p_age" -lt "$best_age" ]; }; then
    best_age=$p_age
    best_which=poller
  fi
  if [ -n "$best_age" ]; then
    FM_SUP_BEACON_DESC="$best_which ${best_age}s ago"
  elif [ -e "$w_beat" ] || [ -e "$p_beat" ]; then
    # shellcheck disable=SC2034 # Read by callers (fm-guard.sh) after sourcing.
    FM_SUP_BEACON_DESC=unknown
  fi

  # shellcheck disable=SC2034 # Read by callers (fm-guard.sh) after sourcing.
  [ -s "$state/.wake-queue" ] && FM_SUP_QUEUE_PENDING=true
  return 0
}

# fm_supervision_unhealthy <state-dir> [grace-seconds]
# Exit 0 (true) exactly in the dangerous state: in-flight work exists and no
# supervisor (neither watcher nor poller) has a fresh beacon. Exit 1 (false)
# otherwise, including zero in-flight.
fm_supervision_unhealthy() {
  fm_supervision_status "$@"
  [ "$FM_SUP_IN_FLIGHT" -gt 0 ] && [ "$FM_SUP_SUPERVISED" = false ]
}

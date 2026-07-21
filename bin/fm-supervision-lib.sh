# shellcheck shell=bash
# Shared "supervision missing" predicate.
# Usage: . bin/fm-supervision-lib.sh
#
# True exactly when a firstmate home has in-flight work (a state/<id>.meta
# exists) but no watcher has a fresh liveness beacon (state/.last-watcher-beat,
# touched every poll cycle, within the grace window). bin/fm-guard.sh uses this
# grace-based warning predicate directly; bin/fm-turnend-guard.sh uses the status
# fields here for its banner but performs its end-of-turn block decision with the
# live watcher lock check in bin/fm-wake-lib.sh.

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
#   FM_SUP_WATCHER_FRESH  true/false - a watcher beacon within the grace window
#   FM_SUP_BEACON_DESC    human-readable beacon age, for banners ("never" if absent)
#   FM_SUP_QUEUE_PENDING  true/false - state/.wake-queue has unread records
# grace-seconds defaults to $FM_GUARD_GRACE, then 300, matching fm-guard.sh.
# Always returns 0; callers read the vars, or use fm_supervision_unhealthy below.
fm_supervision_status() {
  local state=$1 grace=${2:-${FM_GUARD_GRACE:-300}} meta beat m age
  FM_SUP_IN_FLIGHT=0
  FM_SUP_WATCHER_FRESH=false
  FM_SUP_BEACON_DESC=never
  FM_SUP_QUEUE_PENDING=false

  for meta in "$state"/*.meta; do
    [ -e "$meta" ] || continue
    FM_SUP_IN_FLIGHT=$((FM_SUP_IN_FLIGHT + 1))
  done

  # Supervision beacon: freshest of the escape-hatch watcher's beat and the
  # launchd poller's beat (bin/fm-poll.sh, state/.last-poller-beat). The poller
  # replaced the watcher as the standing supervisor at the paradigm cutover;
  # recognizing only the watcher beat produced false SUPERVISION-OFF alarms
  # (found live 2026-07-08 when PR-merge meta files raised in-flight above 0).
  local freshest=
  for beat in "$state/.last-watcher-beat" "$state/.last-poller-beat"; do
    [ -e "$beat" ] || continue
    m=$(fm_sup_stat_mtime "$beat")
    [ -n "$m" ] || continue
    if [ -z "$freshest" ] || [ "$m" -gt "$freshest" ]; then freshest=$m; fi
  done
  if [ -n "$freshest" ]; then
    age=$(( $(date +%s) - freshest ))
    FM_SUP_BEACON_DESC="${age}s ago"
    [ "$age" -lt "$grace" ] && FM_SUP_WATCHER_FRESH=true
  elif [ -e "$state/.last-watcher-beat" ] || [ -e "$state/.last-poller-beat" ]; then
    # shellcheck disable=SC2034 # Read by callers (fm-guard.sh) after sourcing.
    FM_SUP_BEACON_DESC=unknown
  fi

  # shellcheck disable=SC2034 # Read by callers (fm-guard.sh) after sourcing.
  [ -s "$state/.wake-queue" ] && FM_SUP_QUEUE_PENDING=true
  return 0
}

# fm_supervision_unhealthy <state-dir> [grace-seconds]
# Exit 0 (true) exactly in the dangerous state: in-flight work exists and no
# watcher has a fresh beacon. Exit 1 (false) otherwise, including zero in-flight.
fm_supervision_unhealthy() {
  fm_supervision_status "$@"
  [ "$FM_SUP_IN_FLIGHT" -gt 0 ] && [ "$FM_SUP_WATCHER_FRESH" = false ]
}

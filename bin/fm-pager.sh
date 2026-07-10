#!/usr/bin/env bash
# fm-pager.sh - off-box escalation for the headless drain (Phase 0 minimal cut;
# see docs/headless-drain.md). Two subcommands:
#
#   ping          Heartbeat an off-box dead-man's switch (healthchecks.io) each
#                 poller cycle. If the whole laptop or the poller dies, the
#                 heartbeat stops and healthchecks.io alarms - the receipt-bearing
#                 proof that the trigger is alive, independent of this box.
#   page <text>   Send one push notification (Pushover) when the drain
#                 dead-letters or an un-answered David message breaches its age
#                 SLA. This is the ONE genuinely-new external dependency the
#                 design flags; it is INERT until config/pager.env is filled in.
#
# THIS IS A MINIMAL FIRST CUT. The design's fuller pager (a daily acknowledged
# round-trip and a second-channel non-ack alarm) is a deliberate fast-follow, not
# Phase 0. Everything here is best-effort and silent: with no config, no network,
# or no curl, it is a clean no-op so the poller is never blocked or broken by it.
#
# Config lives in an UNTRACKED config/pager.env (it holds tokens); see
# config/pager.env.example. Keys:
#   FM_PAGER_HEALTHCHECK_URL   healthchecks.io ping URL (ping curls this)
#   FM_PAGER_PUSHOVER_TOKEN    Pushover application token (page)
#   FM_PAGER_PUSHOVER_USER     Pushover user/group key   (page)
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
CONFIG="${FM_PAGER_CONFIG:-$FM_HOME/config/pager.env}"

# Load config if present. It only sets the fixed FM_PAGER_* tokens; parse-free
# sourcing is acceptable here because the file is operator-authored local config.
# shellcheck source=/dev/null
if [ -f "$CONFIG" ]; then . "$CONFIG" 2>/dev/null || true; fi

CURL_TIMEOUT=${FM_PAGER_CURL_TIMEOUT:-10}
case "$CURL_TIMEOUT" in ''|*[!0-9]*) CURL_TIMEOUT=10 ;; esac

cmd=${1:-}

do_ping() {
  [ -n "${FM_PAGER_HEALTHCHECK_URL:-}" ] || return 0
  command -v curl >/dev/null 2>&1 || return 0
  curl -fsS --max-time "$CURL_TIMEOUT" "$FM_PAGER_HEALTHCHECK_URL" >/dev/null 2>&1 || true
}

do_page() {  # <text>
  local text=${1:-firstmate pager alert}
  [ -n "${FM_PAGER_PUSHOVER_TOKEN:-}" ] || return 0
  [ -n "${FM_PAGER_PUSHOVER_USER:-}" ] || return 0
  command -v curl >/dev/null 2>&1 || return 0
  curl -fsS --max-time "$CURL_TIMEOUT" \
    --form-string "token=$FM_PAGER_PUSHOVER_TOKEN" \
    --form-string "user=$FM_PAGER_PUSHOVER_USER" \
    --form-string "message=$text" \
    https://api.pushover.net/1/messages.json >/dev/null 2>&1 || true
}

case "$cmd" in
  ping) do_ping ;;
  page) shift; do_page "$*" ;;
  *) echo "usage: fm-pager.sh {ping | page <text>}" >&2; exit 2 ;;
esac
exit 0

#!/usr/bin/env bash
# fm-repl-presence.sh {busy|idle} - record whether the interactive firstmate REPL
# is mid-turn (busy) or waiting (idle), as a heartbeat the launchd poller reads to
# decide whether a queued board wake can ride the fast tmux push or must fall to
# the headless drain (bin/fm-drain-worker.sh; see docs/headless-drain.md).
#
# Wired from .claude/settings.json hooks: `busy` on UserPromptSubmit (a turn is
# starting) and `idle` on Stop (the turn ended). The freshness of the file is the
# real signal - a REPL that crashed or closed stops heartbeating, so the poller
# treats a stale presence file as "no reachable REPL" and drains headlessly.
#
# Best-effort and side-effect-free beyond the one JSON file; never blocks a turn.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
OUT="$STATE/repl-presence.json"

status=${1:-}
case "$status" in
  busy|idle) ;;
  *) echo "usage: fm-repl-presence.sh {busy|idle}" >&2; exit 2 ;;
esac

mkdir -p "$STATE" 2>/dev/null || exit 0
ts=$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || true)
tmp="$OUT.tmp.$$"
if printf '{"status": "%s", "ts": "%s", "pid": %s, "epoch": %s}\n' \
     "$status" "$ts" "${PPID:-0}" "$(date +%s)" > "$tmp" 2>/dev/null; then
  mv "$tmp" "$OUT" 2>/dev/null || rm -f "$tmp" 2>/dev/null || true
fi
# Hooks must never fail the turn: always exit 0.
exit 0

#!/usr/bin/env bash
# Enable the public Tailscale Funnel for the Linear webhook, ON the box.
#
# The Linear webhook is the ONLY inbound leg that needs public ingress.
# It MUST use port 8443, never 443: the box already serves tailnet-only paths
# on 443 (/ -> 127.0.0.1:4387, /out -> 127.0.0.1:8790, /login -> 127.0.0.1:6080)
# and those must stay tailnet-only. Funnel is keyed per-port, so an 8443 funnel
# handler leaves the 443 handlers untouched; this script verifies that after.
#
# Public URL after this runs:
#   https://dqubuntu.tailb6dce4.ts.net:8443/linear  ->  127.0.0.1:4481
#
# Idempotent: re-running re-asserts the same handler and re-verifies.
set -euo pipefail

FUNNEL_PORT="${HK_FUNNEL_PORT:-8443}"
FUNNEL_PATH="${HK_FUNNEL_PATH:-/linear}"
FUNNEL_TARGET="${HK_FUNNEL_TARGET:-127.0.0.1:4481}"

log() { printf '%s\n' "$*"; }
err() { printf '%s\n' "$*" >&2; }

command -v tailscale >/dev/null 2>&1 || {
  err "tailscale not found on PATH; cannot set up the funnel."
  exit 1
}

# jq drives the post-check; the box has it, but fail clearly if it is missing.
command -v jq >/dev/null 2>&1 || {
  err "jq not found on PATH; the funnel post-check needs it."
  exit 1
}

# Confirm the node is up and logged in before touching serve config.
if ! tailscale status >/dev/null 2>&1; then
  err "tailscale is not up (tailscale status failed); run 'tailscale up' first."
  exit 1
fi

HOSTPORT=""
resolve_hostport() {
  # Base tailnet name from status; append the funnel port.
  local dns
  dns="$(tailscale status --json 2>/dev/null | jq -r '.Self.DNSName // ""' | sed 's/\.$//')"
  [ -n "$dns" ] || return 1
  HOSTPORT="${dns}:${FUNNEL_PORT}"
}
resolve_hostport || {
  err "Could not resolve this node's tailnet DNS name."
  exit 1
}

log "Enabling Funnel: https://${HOSTPORT}${FUNNEL_PATH} -> ${FUNNEL_TARGET}"

# The 1.98 syntax: expose HTTPS on the funnel port, append the path, proxy to
# the local target, in the background, without interactive prompts.
set +e
funnel_out="$(tailscale funnel --bg --yes \
  --https="${FUNNEL_PORT}" \
  --set-path="${FUNNEL_PATH}" \
  "${FUNNEL_TARGET}" 2>&1)"
funnel_rc=$?
set -e

if [ "$funnel_rc" -ne 0 ]; then
  err "tailscale funnel command failed (exit ${funnel_rc}):"
  err "${funnel_out}"
  err ""
  err "This is almost always a missing Funnel grant in the tailnet ACL policy."
  err "ACTION FOR DAVID (one time, in the Tailscale admin console):"
  err "  1. Open https://login.tailscale.com/admin/acls/file"
  err "  2. Ensure the policy has a nodeAttrs grant enabling Funnel for this node, e.g.:"
  err '       "nodeAttrs": [{ "target": ["dqubuntu"], "attr": ["funnel"] }]'
  err "  3. Also enable Funnel for the tailnet under Settings if prompted."
  err "  4. Save the policy, then re-run: deploy/housekeeping/funnel-setup.sh"
  exit 1
fi
[ -n "$funnel_out" ] && log "$funnel_out"

# Post-check: 8443 must be public (Funnel on), and 443 must stay tailnet-only.
status_json="$(tailscale serve status --json 2>/dev/null)"

# Keys in AllowFunnel are "<host>:<port>" and true when that port is funneled.
funnel_8443="$(printf '%s' "$status_json" \
  | jq -r --arg p ":${FUNNEL_PORT}" '(.AllowFunnel // {}) | to_entries[] | select(.key | endswith($p)) | .value' 2>/dev/null | head -1)"
funnel_443="$(printf '%s' "$status_json" \
  | jq -r '(.AllowFunnel // {}) | to_entries[] | select(.key | endswith(":443")) | .value' 2>/dev/null | head -1)"
linear_proxy="$(printf '%s' "$status_json" \
  | jq -r --arg hp "$HOSTPORT" --arg path "$FUNNEL_PATH" '(.Web[$hp].Handlers[$path].Proxy) // ""' 2>/dev/null)"

ok=1
if [ "$funnel_8443" != "true" ]; then
  err "POST-CHECK FAIL: port ${FUNNEL_PORT} is not showing Funnel on."
  ok=0
fi
if [ "$funnel_443" = "true" ]; then
  err "POST-CHECK FAIL: port 443 is now public (Funnel on); it MUST stay tailnet-only."
  ok=0
fi
if [ "$linear_proxy" != "http://${FUNNEL_TARGET}" ]; then
  err "POST-CHECK FAIL: ${FUNNEL_PATH} does not proxy to http://${FUNNEL_TARGET} (got '${linear_proxy}')."
  ok=0
fi

log ""
log "Serve status:"
tailscale serve status 2>&1 || true

if [ "$ok" -ne 1 ]; then
  err ""
  err "Funnel post-check FAILED. The 443 tailnet-only guarantee or the 8443 target"
  err "did not verify. Inspect 'tailscale serve status' above and re-run after fixing."
  exit 1
fi

log ""
log "OK: https://${HOSTPORT}${FUNNEL_PATH} is public (8443, Funnel on); 443 remains tailnet-only."

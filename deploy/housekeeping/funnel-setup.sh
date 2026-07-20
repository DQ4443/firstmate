#!/usr/bin/env bash
# Enable the public Tailscale Funnel for the Linear webhook, ON the box.
#
# The Linear webhook is the ONLY inbound leg that needs public ingress.
# Tailscale Funnel is keyed PER-PORT: enabling Funnel on a port exposes every
# serve handler bound to that exact port to the public internet.
# Handlers on all other ports are left untouched and stay tailnet-only.
# Funnel is allowed on only three ports: 443, 8443, and 10000.
# 443 already carries tailnet-only serve paths, so funneling it is out.
# 8443 is ALSO occupied: the box already runs a tailnet-only serve on 8443
# (/ -> 127.0.0.1:6080, a VNC-ish surface) that must NEVER go public.
# Funneling 8443 would expose that service, so 8443 is out too (the 8443
# collision, discovered 2026-07).
# That leaves 10000 as the one free Funnel port, so the webhook uses it.
# HK_FUNNEL_PORT is validated against an allowlist of exactly {10000}; 443 and
# 8443 are rejected outright for the reasons above.
#
# Public URL after this runs:
#   https://dqubuntu.tailb6dce4.ts.net:10000/linear  ->  127.0.0.1:4481
#
# A pre-check collision guard refuses to funnel the chosen port if any handler
# other than our own /linear proxy is already bound to it, and fails CLOSED if
# the serve status cannot be read.
# The post-check re-verifies that ONLY the chosen port is public, exposing ONLY
# the /linear path, and that every other port stays tailnet-only; on any
# post-check failure the just-enabled handler is reverted before exiting.
#
# Idempotent: re-running re-asserts the same handler and re-verifies.
set -euo pipefail

FUNNEL_PORT="${HK_FUNNEL_PORT:-10000}"
FUNNEL_PATH="${HK_FUNNEL_PATH:-/linear}"
FUNNEL_TARGET="${HK_FUNNEL_TARGET:-127.0.0.1:4481}"

log() { printf '%s\n' "$*"; }
err() { printf '%s\n' "$*" >&2; }

# Port allowlist: exactly {10000}. 443 and 8443 are structurally forbidden on
# this box, not merely discouraged, so reject them with the rationale.
case "$FUNNEL_PORT" in
  10000) ;;
  443)
    err "HK_FUNNEL_PORT=443 is FORBIDDEN: 443 already carries tailnet-only serve paths"
    err "(/ -> 127.0.0.1:4387, /out -> 127.0.0.1:8790, /login -> 127.0.0.1:6080)."
    err "Funnel is per-port, so funneling 443 would expose them all publicly."
    exit 1
    ;;
  8443)
    err "HK_FUNNEL_PORT=8443 is FORBIDDEN: 8443 already carries a tailnet-only serve"
    err "(/ -> 127.0.0.1:6080, a VNC-ish surface that must NEVER go public)."
    err "Funnel is per-port, so funneling 8443 would expose that service publicly."
    exit 1
    ;;
  *)
    err "HK_FUNNEL_PORT=${FUNNEL_PORT} is not on the allowlist; only 10000 is permitted on this box."
    exit 1
    ;;
esac

command -v tailscale >/dev/null 2>&1 || {
  err "tailscale not found on PATH; cannot set up the funnel."
  exit 1
}

# jq drives the collision guard and the post-check; the box has it, but fail
# clearly if it is missing.
command -v jq >/dev/null 2>&1 || {
  err "jq not found on PATH; the funnel collision guard and post-check need it."
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

# Pre-check COLLISION GUARD: Funnel is per-port, so before we enable it on the
# chosen port we must be certain that port carries nothing but our own /linear
# proxy. If any other handler is already bound there, funneling the port would
# expose it, so ABORT loudly and leave the serve config untouched.
# Fails CLOSED: if the serve status cannot be read or parsed, we refuse to
# enable the funnel blind rather than assume the port is free.
precheck_json="$(tailscale serve status --json 2>/dev/null || true)"
if [ -z "$precheck_json" ] || ! printf '%s' "$precheck_json" | jq -e . >/dev/null 2>&1; then
  err "COLLISION GUARD: could not read 'tailscale serve status --json' (empty or unparsable output)."
  err "Refusing to enable Funnel blind; the port could carry a tailnet-only handler we cannot see."
  err "A healthy node prints valid JSON even with no serve config, so fix tailscale first and re-run."
  err "The serve config was NOT modified."
  exit 1
fi
# Web handlers on the chosen host:port that are NOT our /linear -> target proxy.
foreign_web="$(printf '%s' "$precheck_json" \
  | jq -r --arg hp "$HOSTPORT" --arg path "$FUNNEL_PATH" --arg tgt "http://${FUNNEL_TARGET}" \
      '((.Web[$hp].Handlers // {}) | to_entries[]
         | select((.key != $path) or ((.value.Proxy // "") != $tgt))
         | "\(.key) -> \(.value.Proxy // (.value | tostring))")' 2>/dev/null || true)"
# Foreign TCP handlers on the chosen port. Our own HTTPS web serve makes
# tailscale write TCP[port]={"HTTPS":true}, which is the listener for our own
# handler, not a collision; only raw forwards (TCPForward, TerminateTLS) or a
# plain-HTTP listener count as foreign.
foreign_tcp="$(printf '%s' "$precheck_json" \
  | jq -r --arg p "$FUNNEL_PORT" \
      '((.TCP // {}) | to_entries[]
         | select(.key == $p)
         | select(((.value.TCPForward // "") != "") or ((.value.TerminateTLS // "") != "") or ((.value.HTTP // false) == true))
         | "TCP :\(.key) \(.value | tostring)")' 2>/dev/null || true)"
if [ -n "$foreign_web" ] || [ -n "$foreign_tcp" ]; then
  err "COLLISION GUARD: port ${FUNNEL_PORT} already carries a handler that is NOT our ${FUNNEL_PATH} proxy."
  err "Refusing to enable Funnel on ${FUNNEL_PORT}; funneling it would expose the conflicting handler(s) below:"
  [ -n "$foreign_web" ] && printf '%s\n' "$foreign_web" | while IFS= read -r line; do err "  web:  $line"; done
  [ -n "$foreign_tcp" ] && printf '%s\n' "$foreign_tcp" | while IFS= read -r line; do err "  tcp:  $line"; done
  err ""
  err "REMEDIATION: remove or relocate the conflicting handler first, then re-run."
  err "10000 is the only permitted Funnel port on this box (443 and 8443 carry"
  err "tailnet-only services), so the conflict must move, not the webhook."
  err "The serve config was NOT modified."
  exit 1
fi

# Revert helper: on any post-check failure, take down the handler this run just
# enabled so a bad exposure never stays live. Best-effort, with a manual
# fallback printed if the revert itself fails.
revert_funnel() {
  err "Reverting: disabling the funnel handler just enabled on port ${FUNNEL_PORT}${FUNNEL_PATH}."
  local revert_out revert_rc
  set +e
  revert_out="$(tailscale funnel --https="${FUNNEL_PORT}" --set-path="${FUNNEL_PATH}" off 2>&1)"
  revert_rc=$?
  set -e
  if [ "$revert_rc" -ne 0 ]; then
    err "REVERT FAILED (exit ${revert_rc}): ${revert_out}"
    err "The funnel may still be LIVE. Manually run on the box:"
    err "  tailscale funnel --https=${FUNNEL_PORT} --set-path=${FUNNEL_PATH} off"
  else
    err "Reverted: the ${FUNNEL_PORT}${FUNNEL_PATH} funnel handler was removed."
  fi
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

# Post-check: the chosen port must be public (Funnel on) exposing ONLY the
# /linear path, and EVERY other port must remain tailnet-only (Funnel off).
# Fails CLOSED: an unreadable status means the funnel is live but UNVERIFIED,
# so revert it rather than trust it.
status_json="$(tailscale serve status --json 2>/dev/null || true)"
if [ -z "$status_json" ] || ! printf '%s' "$status_json" | jq -e . >/dev/null 2>&1; then
  err "POST-CHECK FAIL: could not read 'tailscale serve status --json' after enabling;"
  err "the funnel state is UNVERIFIED and cannot be trusted."
  revert_funnel
  err "REMEDIATION: fix tailscale status output, then re-run this script."
  exit 1
fi

# Funnel state of the chosen host:port (AllowFunnel keys are "<host>:<port>").
funnel_chosen="$(printf '%s' "$status_json" \
  | jq -r --arg hp "$HOSTPORT" '(.AllowFunnel // {})[$hp] // false' 2>/dev/null)"
# Any OTHER host:port with Funnel on; this list MUST be empty.
other_funnel="$(printf '%s' "$status_json" \
  | jq -r --arg hp "$HOSTPORT" '(.AllowFunnel // {}) | to_entries[] | select(.value == true and .key != $hp) | .key' 2>/dev/null || true)"
# Paths exposed on the chosen port; this MUST be exactly FUNNEL_PATH.
chosen_paths="$(printf '%s' "$status_json" \
  | jq -r --arg hp "$HOSTPORT" '((.Web[$hp].Handlers // {}) | keys[])' 2>/dev/null || true)"
linear_proxy="$(printf '%s' "$status_json" \
  | jq -r --arg hp "$HOSTPORT" --arg path "$FUNNEL_PATH" '(.Web[$hp].Handlers[$path].Proxy) // ""' 2>/dev/null)"

ok=1
if [ "$funnel_chosen" != "true" ]; then
  err "POST-CHECK FAIL: port ${FUNNEL_PORT} is not showing Funnel on."
  ok=0
fi
if [ -n "$other_funnel" ]; then
  err "POST-CHECK FAIL: these ports are public (Funnel on) but MUST stay tailnet-only:"
  printf '%s\n' "$other_funnel" | while IFS= read -r k; do err "  $k"; done
  ok=0
fi
if [ "$chosen_paths" != "$FUNNEL_PATH" ]; then
  err "POST-CHECK FAIL: port ${FUNNEL_PORT} must expose ONLY ${FUNNEL_PATH} publicly, but exposes:"
  printf '%s\n' "${chosen_paths:-(none)}" | while IFS= read -r p; do err "  ${p:-(none)}"; done
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
  err "Funnel post-check FAILED. The tailnet-only guarantee for other ports, or the"
  err "${FUNNEL_PORT} target, did not verify. Not leaving a bad exposure standing:"
  revert_funnel
  err "REMEDIATION: inspect 'tailscale serve status' above; remove or fix the stray"
  err "handlers (or run 'tailscale serve reset' to clear everything), then re-run"
  err "this script."
  exit 1
fi

log ""
log "OK: https://${HOSTPORT}${FUNNEL_PATH} is public (${FUNNEL_PORT}, Funnel on); every other port remains tailnet-only."

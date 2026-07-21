#!/usr/bin/env bash
# Install / update the housekeeping intake daemon on dqubuntu. RUN FROM THE MAC.
#
# Idempotent and safe to re-run: it rsyncs the code subset, (re)creates the
# FM_HK_ROOT tree with correct modes WITHOUT touching existing secrets or
# cursors, installs the systemd user units, enables the timers, and prints a
# status table. It never enables or starts a service whose code has not landed
# yet, so it is safe to run at any stage of the daemon build.
#
# It does NOT register the Linear webhook and does NOT run the Gmail OAuth
# bootstrap; those are David-driven steps in docs/housekeeping-intake.md.
#
# Env overrides:
#   HK_REMOTE      ssh alias of the box            (default: dqubuntu)
#   HK_REMOTE_REPO repo path on the box, ~-relative (default: firstmate)
#   FM_HK_ROOT     runtime root on the box          (default: <box ~>/fm-state/housekeeping)
#   HK_RUN_FUNNEL  set to 1 to also run funnel-setup.sh over ssh (default: 0)
set -euo pipefail

REMOTE="${HK_REMOTE:-dqubuntu}"
REMOTE_REPO="${HK_REMOTE_REPO:-firstmate}"

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/../.." && pwd)"

SSH=(ssh -o BatchMode=yes -o ConnectTimeout=8 "$REMOTE")

log()  { printf '%s\n' "$*"; }
step() { printf '\n==> %s\n' "$*"; }
err()  { printf '%s\n' "$*" >&2; }

# ---- Preflight ------------------------------------------------------------
step "Preflight: checking ${REMOTE}"
if ! "${SSH[@]}" true 2>/dev/null; then
  err "Cannot reach ${REMOTE} over ssh (BatchMode). Fix ssh access and re-run."
  exit 1
fi

# Single quotes are intentional: $HOME must expand on the box, not locally.
# shellcheck disable=SC2016
REMOTE_HOME="$("${SSH[@]}" 'printf %s "$HOME"')"
[ -n "$REMOTE_HOME" ] || { err "Could not resolve remote \$HOME."; exit 1; }

DEFAULT_ROOT="${REMOTE_HOME}/fm-state/housekeeping"
HK_ROOT="${FM_HK_ROOT:-$DEFAULT_ROOT}"
case "$HK_ROOT" in
  /*) : ;;
  *)  err "FM_HK_ROOT must be an absolute path on the box (got '${HK_ROOT}')."; exit 1 ;;
esac

if ! "${SSH[@]}" 'command -v node >/dev/null 2>&1'; then
  err "node not found on ${REMOTE} PATH. Install node >=24 before deploying."
  exit 1
fi
NODE_VER="$("${SSH[@]}" 'node --version 2>/dev/null || true')"
# Single quotes are intentional: $USER must expand on the box, not locally.
# shellcheck disable=SC2016
LINGER="$("${SSH[@]}" 'loginctl show-user "$USER" -p Linger --value 2>/dev/null || echo unknown')"
log "remote home : ${REMOTE_HOME}"
log "hk root     : ${HK_ROOT}"
log "node        : ${NODE_VER}"
log "linger      : ${LINGER}"
if [ "$LINGER" != "yes" ]; then
  err "WARNING: linger is '${LINGER}'. User services will not run while logged out."
  err "         Enable with: loginctl enable-linger \$USER  (on the box)."
fi

# ---- Sync the code subset -------------------------------------------------
step "Syncing code subset to ${REMOTE}:~/${REMOTE_REPO}/"
"${SSH[@]}" "mkdir -p '${REMOTE_REPO}/bin/housekeeping' '${REMOTE_REPO}/deploy/housekeeping/units' '${REMOTE_REPO}/docs'"

SERVER_PRESENT=0
GMAIL_PRESENT=0

sync_dir() {  # sync_dir <relpath> ; mirrors a directory if it exists locally
  local rel="$1"
  if [ -d "${REPO_ROOT}/${rel}" ]; then
    rsync -a --delete "${REPO_ROOT}/${rel}/" "${REMOTE}:${REMOTE_REPO}/${rel}/"
    log "synced dir  ${rel}/"
  else
    log "SKIP (absent) ${rel}/  (daemon leg not landed yet)"
  fi
}
sync_file() {  # sync_file <relpath> ; copies a file if it exists locally
  local rel="$1"
  if [ -f "${REPO_ROOT}/${rel}" ]; then
    rsync -a "${REPO_ROOT}/${rel}" "${REMOTE}:${REMOTE_REPO}/${rel}"
    log "synced file ${rel}"
    return 0
  fi
  log "SKIP (absent) ${rel}  (daemon leg not landed yet)"
  return 1
}

sync_dir  "bin/housekeeping"
sync_file "bin/fm-linear-event-server.mjs" && SERVER_PRESENT=1
sync_file "bin/fm-linear-event-worker.sh"  || true
sync_dir  "deploy/housekeeping/units"
sync_file "deploy/housekeeping/funnel-setup.sh" || true
sync_file "docs/housekeeping-intake.md" || true

if "${SSH[@]}" "test -f '${REMOTE_REPO}/bin/housekeeping/hk-gmail-pull.mjs'"; then
  GMAIL_PRESENT=1
fi
# The funnel script must be executable on the box.
"${SSH[@]}" "chmod +x '${REMOTE_REPO}/deploy/housekeeping/funnel-setup.sh' 2>/dev/null || true"

# ---- Build the runtime tree (never clobber secrets or cursors) ------------
step "Ensuring runtime tree at ${HK_ROOT}"
"${SSH[@]}" "bash -s" -- "$HK_ROOT" <<'REMOTE_TREE'
set -eu
ROOT="$1"
mkdir -p \
  "$ROOT/queue/incoming" "$ROOT/queue/processed" \
  "$ROOT/alerts/pending" "$ROOT/digests/pending" \
  "$ROOT/secrets" "$ROOT/cursors"
# Single-user daemon: the whole runtime tree is private (700). The state holds
# Linear issue titles/bodies, email subjects, and distilled meeting notes, so no
# other local uid ever needs to list or read it. secrets stays 700 too.
chmod 700 "$ROOT" "$ROOT/queue" "$ROOT/queue/incoming" "$ROOT/queue/processed" \
  "$ROOT/alerts" "$ROOT/alerts/pending" "$ROOT/digests" "$ROOT/digests/pending" \
  "$ROOT/cursors" "$ROOT/secrets"
# Tighten any secret files ALREADY present to 600; never create or overwrite them.
find "$ROOT/secrets" -type f -exec chmod 600 {} + 2>/dev/null || true
printf 'tree ok: %s\n' "$ROOT"
REMOTE_TREE

# ---- Custom-root drop-ins (only when FM_HK_ROOT diverges from default) -----
# The base units bake %h/fm-state/housekeeping into Environment and
# ReadWritePaths. If a custom root was requested, ProtectSystem=strict would
# block writes without an override, so generate a drop-in per service.
UNIT_DIR=".config/systemd/user"
SERVICES=(hk-linear-intake hk-gmail-pull hk-gmail-watch-renew hk-linear-reconcile "hk-digest@")
if [ "$HK_ROOT" != "$DEFAULT_ROOT" ]; then
  step "Applying custom FM_HK_ROOT drop-ins (${HK_ROOT})"
  for svc in "${SERVICES[@]}"; do
    "${SSH[@]}" "mkdir -p '${UNIT_DIR}/${svc}.service.d'"
    "${SSH[@]}" "cat > '${UNIT_DIR}/${svc}.service.d/10-fm-hk-root.conf'" <<CONF
[Service]
Environment=FM_HK_ROOT=${HK_ROOT}
ReadWritePaths=${HK_ROOT}
CONF
    log "drop-in     ${svc}.service.d/10-fm-hk-root.conf"
  done
else
  # Remove any stale drop-in from a previous custom-root install so we do not
  # leave a divergent path baked in.
  for svc in "${SERVICES[@]}"; do
    "${SSH[@]}" "rm -f '${UNIT_DIR}/${svc}.service.d/10-fm-hk-root.conf' 2>/dev/null || true"
  done
fi

# ---- Install units + reload ------------------------------------------------
step "Installing systemd user units"
"${SSH[@]}" "mkdir -p '${UNIT_DIR}'"
rsync -a "${REPO_ROOT}/deploy/housekeeping/units/"*.service "${REMOTE}:${UNIT_DIR}/"
rsync -a "${REPO_ROOT}/deploy/housekeeping/units/"*.timer   "${REMOTE}:${UNIT_DIR}/"
"${SSH[@]}" "systemctl --user daemon-reload"
log "units installed and daemon reloaded"

# ---- Preflight: every unit's ExecStart target must exist on the box ---------
# A unit whose ExecStart points at a script the sibling leg never shipped (or a
# path that drifted) fails silently at runtime: ExecStart errors, the service
# never runs, and nothing surfaces until a digest or renewal is quietly missed.
# This is a cross-leg interface contract that no single-branch test exercises, so
# stat each installed unit's ExecStart script here and warn loudly on a miss.
step "Preflighting ExecStart targets"
"${SSH[@]}" "bash -s" -- "$UNIT_DIR" <<'REMOTE_PREFLIGHT'
set -u
UDIR="$1"
miss=0
for unit in "$HOME/$UDIR"/hk-*.service; do
  [ -f "$unit" ] || continue
  line="$(grep -m1 '^ExecStart=' "$unit" 2>/dev/null || true)"
  [ -n "$line" ] || continue
  # The script argument is the ExecStart token under the repo (%h -> $HOME); this
  # skips the interpreter (/usr/bin/env bash|node) and any trailing args (%i, a
  # subcommand like "renew").
  target=""
  for tok in $line; do
    case "$tok" in
      *%h/*) target="${tok/'%h'/$HOME}"; break ;;
    esac
  done
  [ -n "$target" ] || continue
  if [ ! -e "$target" ]; then
    printf 'MISSING ExecStart target: %s -> %s\n' "$(basename "$unit")" "$target" >&2
    miss=$((miss + 1))
  fi
done
if [ "$miss" -gt 0 ]; then
  printf 'WARNING: %s unit(s) point at a missing ExecStart script (leg not landed yet, or path drift).\n' "$miss" >&2
else
  printf 'preflight ok: all installed unit ExecStart targets present\n'
fi
REMOTE_PREFLIGHT

# ---- Enable timers and long-running services -------------------------------
step "Enabling timers"
if "${SSH[@]}" "systemctl --user enable --now \
  hk-gmail-watch-renew.timer hk-linear-reconcile.timer \
  hk-digest-morning.timer hk-digest-afternoon.timer"; then
  log "timers enabled"
else
  err "WARNING: enabling one or more timers failed (see above)."
fi

step "Enabling services"
# Gmail pull is enabled but not started: its ConditionPathExists keeps it dead
# until the OAuth bootstrap writes secrets/google-token.json.
if [ "$GMAIL_PRESENT" = 1 ]; then
  if "${SSH[@]}" "systemctl --user enable hk-gmail-pull.service"; then
    log "hk-gmail-pull enabled (stays dead until google-token.json exists)"
  else
    err "WARNING: enabling hk-gmail-pull failed."
  fi
else
  log "hk-gmail-pull NOT enabled: bin/housekeeping/hk-gmail-pull.mjs not on the box yet."
fi

# Linear intake is started now only if its server code has landed.
if [ "$SERVER_PRESENT" = 1 ]; then
  if "${SSH[@]}" "systemctl --user enable --now hk-linear-intake.service"; then
    log "hk-linear-intake enabled and started"
  else
    err "WARNING: starting hk-linear-intake failed; check: systemctl --user status hk-linear-intake"
  fi
else
  log "hk-linear-intake NOT started: bin/fm-linear-event-server.mjs not on the box yet."
fi

# ---- Install the Mac-side poller check -------------------------------------
# state/ is gitignored on the firstmate machine, so the poller check cannot ride
# a git pull. Install it into this checkout's state/ dir, where fm-poll.sh globs
# state/*.check.sh. Skipped if this checkout has no state/ dir (not the live one).
step "Installing Mac-side poller check"
if [ -d "${REPO_ROOT}/state" ]; then
  install -m 0755 "${SCRIPT_DIR}/housekeeping.check.sh" "${REPO_ROOT}/state/housekeeping.check.sh"
  log "installed ${REPO_ROOT}/state/housekeeping.check.sh (poller picks it up next cycle)"
else
  log "SKIP: ${REPO_ROOT}/state does not exist; copy housekeeping.check.sh into the live firstmate state/ dir by hand."
fi

# ---- Optional funnel setup -------------------------------------------------
if [ "${HK_RUN_FUNNEL:-0}" = 1 ]; then
  step "Running funnel-setup.sh on ${REMOTE}"
  "${SSH[@]}" "bash '${REMOTE_REPO}/deploy/housekeeping/funnel-setup.sh'" \
    || err "WARNING: funnel-setup.sh reported a problem; see its output above."
fi

# ---- Status table ----------------------------------------------------------
step "Status"
"${SSH[@]}" "bash -s" <<'REMOTE_STATUS'
set -u
units="hk-linear-intake.service hk-gmail-pull.service \
hk-gmail-watch-renew.service hk-gmail-watch-renew.timer \
hk-linear-reconcile.service hk-linear-reconcile.timer \
hk-digest@.service hk-digest-morning.timer hk-digest-afternoon.timer"
printf '%-32s %-10s %-10s\n' UNIT ENABLED ACTIVE
printf '%-32s %-10s %-10s\n' "----" "-------" "------"
for u in $units; do
  en="$(systemctl --user is-enabled "$u" 2>/dev/null || echo -)"
  ac="$(systemctl --user is-active  "$u" 2>/dev/null || echo -)"
  printf '%-32s %-10s %-10s\n' "$u" "$en" "$ac"
done
echo
echo "Next timer fires:"
systemctl --user list-timers 'hk-*' --no-pager 2>/dev/null | head -12 || true
REMOTE_STATUS

step "Done"
log "Deployed to ${REMOTE}:~/${REMOTE_REPO}. Runtime root: ${HK_ROOT}"
log "Remaining David-driven steps (see docs/housekeeping-intake.md):"
log "  1. Gmail OAuth bootstrap (writes secrets/google-token.json), then: systemctl --user start hk-gmail-pull"
log "  2. Funnel: HK_RUN_FUNNEL=1 re-run, or run deploy/housekeeping/funnel-setup.sh on the box"
log "  3. Register the Linear webhook LAST, pointing at https://dqubuntu.tailb6dce4.ts.net:10000/linear"

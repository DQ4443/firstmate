#!/bin/bash
# fm-fleet-view.sh: attach a viewer session with every live fleet node window.
# Links the fm-node-* and fm-parrot tmux windows into one "fleet-view" session
# (shared windows: keystrokes go to the real agent). Ctrl-b n cycles nodes,
# Ctrl-b d detaches. Safe to re-run; rebuilds the view from whatever is live.
set -u

sessions=$(tmux list-sessions -F '#{session_name}' 2>/dev/null \
  | grep -E '^(fm-node-|fm-parrot)') || {
  echo "no fleet sessions running (looked for fm-node-*, fm-parrot)" >&2
  exit 1
}

# Reuse a live viewer: killing it would dump every attached client (looks like
# a crash). Only build from scratch when no fleet-view session exists.
if tmux has-session -t fleet-view 2>/dev/null; then
  if [ -n "${TMUX:-}" ]; then exec tmux switch-client -t fleet-view
  else exec tmux attach -t fleet-view; fi
fi
tmux new-session -d -s fleet-view -n dummy
i=1
while IFS= read -r s; do
  if tmux link-window -s "$s:0" -t "fleet-view:$i"; then
    # Name the window after its node (fm-node-personal -> personal) and pin the
    # name so tmux does not auto-rename it back to the running command.
    name="${s#fm-node-}"; name="${name#fm-}"
    tmux rename-window -t "fleet-view:$i" "$name"
    tmux set-option -w -t "fleet-view:$i" automatic-rename off
    i=$((i + 1))
  fi
done <<< "$sessions"
tmux kill-window -t fleet-view:dummy 2>/dev/null

if [ -n "${TMUX:-}" ]; then
  exec tmux switch-client -t fleet-view
else
  exec tmux attach -t fleet-view
fi

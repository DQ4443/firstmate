#!/usr/bin/env bash
# fm-remote.sh - thin controller for firstmate sessions that live in tmux on the
# remote box (SSH alias `thinkpad`, override with FM_REMOTE_HOST).
#
# Each session is a detached tmux session on the box named fm-<task> running an
# interactive claude that receives its brief as the initial prompt. This script
# is a THIN controller: every subcommand is one or two ssh calls and returns
# immediately, holding no long-lived local process. The box owns the session;
# the Mac side only launches, peeks, steers, and tears down.
#
# The steer mechanics mirror bin/fm-send.sh's proven tmux TUI delivery: the text
# is typed ONCE in literal mode (send-keys -l), a short settle lets any harness
# completion popup close, then Enter submits. Slash-command messages get the
# longer settle fm-send.sh uses so the popup does not swallow the Enter.
#
# Subcommands:
#   launch <task> [--dir <remote-dir>] [--claude-args "<flags>"] <brief...>
#   ls
#   peek <task> [-n <lines>]
#   steer <task> <message...>
#   attach <task>
#   kill <task>
# Global flag: --dry-run prints the ssh command(s) instead of executing them.
set -eu

SSH_HOST="${FM_REMOTE_HOST:-thinkpad}"
# Default working directory and brief directory on the box. $HOME is kept literal
# (single quotes deliberate, SC2016) so the REMOTE shell, not this local one,
# expands it to the box's home when the command runs there.
# shellcheck disable=SC2016
DEFAULT_DIR='$HOME/dev/personal/firstmate'
# shellcheck disable=SC2016
BRIEF_DIR='$HOME/fm/briefs'

usage() {
  cat >&2 <<'EOF'
usage: fm-remote.sh [--dry-run] <command> [args]

commands:
  launch <task> [--dir <remote-dir>] [--claude-args "<flags>"] <brief...>
      Write the brief to ~/fm/briefs/<task>.md on the box, then start a detached
      tmux session fm-<task> running claude with the brief as its initial prompt.
  ls
      List the fm-* tmux sessions on the box.
  peek <task> [-n <lines>]
      Print the tail (default 40 lines) of the fm-<task> pane.
  steer <task> <message...>
      Deliver a message to the running claude TUI in fm-<task>.
  attach <task>
      Attach interactively to fm-<task> (exec's ssh -t).
  kill <task>
      Kill the fm-<task> tmux session.

global:
  --dry-run   Print the ssh command(s) instead of executing them.
EOF
  exit 2
}

die() { printf 'error: %s\n' "$1" >&2; exit 2; }

# Single-quote a string for safe use inside a remote shell command, escaping any
# embedded single quotes (the '\'' idiom). Mirrors bin/fm-spawn.sh's shell_quote.
shell_quote() {
  printf "'"
  printf '%s' "$1" | sed "s/'/'\\\\''/g"
  printf "'"
}

# Run a remote command string, or print the ssh invocation under --dry-run.
# The command string is built locally and expanded on the box, which is the whole
# point of this controller, so the client-side note (SC2029) is expected here.
ssh_run() {  # <remote-cmd>
  if [ "$DRY_RUN" = 1 ]; then
    printf 'ssh %s %s\n' "$SSH_HOST" "$1"
  else
    # shellcheck disable=SC2029
    ssh "$SSH_HOST" "$1"
  fi
}

# Pull the global --dry-run flag out of the argument list, wherever it appears,
# leaving the remaining args in ARGS for the subcommand dispatch below.
DRY_RUN=0
ARGS=()
for a in "$@"; do
  case "$a" in
    --dry-run) DRY_RUN=1 ;;
    *) ARGS+=("$a") ;;
  esac
done
[ "${#ARGS[@]}" -ge 1 ] || usage
CMD=${ARGS[0]}
REST=("${ARGS[@]:1}")

cmd_launch() {
  local task='' remote_dir="$DEFAULT_DIR" claude_args='' brief_parts=()
  # Parse the launch-specific flags, then collect the rest as the brief text.
  while [ "${#REST[@]}" -gt 0 ]; do
    case "${REST[0]}" in
      --dir)
        [ "${#REST[@]}" -ge 2 ] || die "--dir requires a value"
        remote_dir=${REST[1]}
        REST=("${REST[@]:2}")
        ;;
      --dir=*)
        remote_dir=${REST[0]#--dir=}
        REST=("${REST[@]:1}")
        ;;
      --claude-args)
        [ "${#REST[@]}" -ge 2 ] || die "--claude-args requires a value"
        claude_args=${REST[1]}
        REST=("${REST[@]:2}")
        ;;
      --claude-args=*)
        claude_args=${REST[0]#--claude-args=}
        REST=("${REST[@]:1}")
        ;;
      *)
        if [ -z "$task" ]; then
          task=${REST[0]}
        else
          brief_parts+=("${REST[0]}")
        fi
        REST=("${REST[@]:1}")
        ;;
    esac
  done
  [ -n "$task" ] || die "launch requires a <task> name"
  [ "${#brief_parts[@]}" -ge 1 ] || die "launch requires a <brief>"

  local ses="fm-$task"
  local brief_path="$BRIEF_DIR/$task.md"
  local brief="${brief_parts[*]}"

  # Write the brief via ssh stdin so no brief content ever passes through shell
  # quoting; the remote shell only ever sees the fixed mkdir/cat command.
  local write_cmd="mkdir -p $BRIEF_DIR && cat > $brief_path"

  # Build the interactive claude command tmux will run. The launch command is
  # kept single-quoted so the remote login shell hands it to tmux verbatim; tmux
  # then runs it via `sh -c`, where "$(cat <brief>)" expands to the brief text as
  # claude's single initial-prompt argument.
  local inner="claude"
  [ -n "$claude_args" ] && inner="claude $claude_args"
  inner="$inner \"\$(cat $brief_path)\""
  local launch_cmd="tmux new -d -s $ses -c $remote_dir '$inner'"

  if [ "$DRY_RUN" = 1 ]; then
    printf 'printf %%s <brief> | ssh %s %s\n' "$SSH_HOST" "$(shell_quote "$write_cmd")"
    printf 'ssh %s %s\n' "$SSH_HOST" "$launch_cmd"
    return 0
  fi
  # Brief content rides ssh stdin, so the remote shell only sees the fixed
  # mkdir/cat command; the write_cmd itself expands on the box (SC2029 expected).
  # shellcheck disable=SC2029
  printf '%s' "$brief" | ssh "$SSH_HOST" "$write_cmd"
  ssh_run "$launch_cmd"
  printf 'launched %s on %s (brief: %s)\n' "$ses" "$SSH_HOST" "$brief_path"
}

cmd_ls() {
  [ "${#REST[@]}" -eq 0 ] || die "ls takes no arguments"
  # List only the firstmate sessions; a box with no sessions must not error.
  ssh_run "tmux list-sessions -F '#{session_name}' 2>/dev/null | grep '^fm-' || true"
}

cmd_peek() {
  local task='' lines=40
  while [ "${#REST[@]}" -gt 0 ]; do
    case "${REST[0]}" in
      -n)
        [ "${#REST[@]}" -ge 2 ] || die "-n requires a value"
        lines=${REST[1]}
        REST=("${REST[@]:2}")
        ;;
      -n=*)
        lines=${REST[0]#-n=}
        REST=("${REST[@]:1}")
        ;;
      *)
        [ -z "$task" ] || die "peek takes a single <task>"
        task=${REST[0]}
        REST=("${REST[@]:1}")
        ;;
    esac
  done
  [ -n "$task" ] || die "peek requires a <task> name"
  case "$lines" in
    ''|*[!0-9]*) die "-n requires a positive integer, got '$lines'" ;;
  esac
  local ses="fm-$task"
  ssh_run "tmux capture-pane -p -t $ses | tail -n $lines"
}

cmd_steer() {
  [ "${#REST[@]}" -ge 1 ] || die "steer requires a <task> name"
  local task=${REST[0]}
  REST=("${REST[@]:1}")
  [ "${#REST[@]}" -ge 1 ] || die "steer requires a <message>"
  local msg="${REST[*]}"
  local ses="fm-$task"
  # Match fm-send.sh's settle policy: a slash command opens a completion popup in
  # some TUIs, so give it longer to close before the Enter; plain text is quick.
  local settle=0.3
  case "$msg" in
    /*) settle=1.2 ;;
  esac
  # Type once in literal mode, settle, then submit with Enter. The sleep runs on
  # the box so the whole steer is a single ssh round-trip.
  local q_msg
  q_msg=$(shell_quote "$msg")
  local steer_cmd="tmux send-keys -t $ses -l $q_msg; sleep $settle; tmux send-keys -t $ses Enter"
  ssh_run "$steer_cmd"
}

cmd_attach() {
  [ "${#REST[@]}" -eq 1 ] || die "attach requires exactly one <task> name"
  local ses="fm-${REST[0]}"
  if [ "$DRY_RUN" = 1 ]; then
    printf 'ssh -t %s tmux attach -t %s\n' "$SSH_HOST" "$ses"
    return 0
  fi
  exec ssh -t "$SSH_HOST" tmux attach -t "$ses"
}

cmd_kill() {
  [ "${#REST[@]}" -eq 1 ] || die "kill requires exactly one <task> name"
  local ses="fm-${REST[0]}"
  ssh_run "tmux kill-session -t $ses"
}

case "$CMD" in
  launch) cmd_launch ;;
  ls) cmd_ls ;;
  peek) cmd_peek ;;
  steer) cmd_steer ;;
  attach) cmd_attach ;;
  kill) cmd_kill ;;
  -h|--help|help) usage ;;
  *) die "unknown command '$CMD' (see fm-remote.sh --help)" ;;
esac

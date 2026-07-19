#!/usr/bin/env bash
# fm-remote.sh - thin controller for firstmate sessions that live in tmux on the
# remote box (SSH alias `thinkpad`, override with FM_REMOTE_HOST).
#
# Each session is a detached tmux session on the box named fm-<task> running an
# interactive claude. This script is a THIN controller: every subcommand is one
# or a few ssh calls and returns promptly, holding no long-lived local process.
# The box owns the session; the Mac side only launches, peeks, steers, and tears
# down. launch runs a bounded local loop of one-shot ssh pane captures to accept
# the one-time folder-trust dialog and DELIVER-VERIFY the brief pointer (see
# LAUNCH DESIGN); that loop is a sequence of one-shot ssh captures, not a held
# process.
#
# The steer/launch delivery mechanics mirror bin/fm-send.sh's proven tmux TUI
# delivery: the text is typed ONCE in literal mode (send-keys -l), a short settle
# lets any harness completion popup close, then Enter submits. Slash-command
# steer messages get the longer settle fm-send.sh uses so the popup does not
# swallow the Enter.
#
# LAUNCH DESIGN (why a pointer, not the brief as an argv): claude's first run in
# a not-yet-trusted folder shows a trust dialog BEFORE it consumes an initial
# prompt argument, so a brief passed as claude's argv is swallowed by the dialog
# and lost. Instead launch (a) writes the brief file, (b) starts claude with NO
# prompt argument (plus --add-dir <brief-dir> so the brief, which lives outside
# the working dir, reads without a permission prompt), (c) accepts the trust
# dialog if it appears, then (d) delivers a short pointer prompt over the live
# TUI telling claude to read and execute the brief file. The brief never rides
# claude's argv, so the dialog cannot eat it.
#
# DELIVERY-VERIFIED SENDING (not readiness-sniffing): claude 2.1.132's TUI never
# renders a stable "? for shortcuts" readiness sentinel, so a one-shot poll for
# it always times out and the pointer is sent blind and DROPPED. Instead launch
# loops (bounded): each pass captures the pane, accepts a visible trust dialog,
# and if the pointer is not yet delivered either submits a pointer already typed
# in the input box (Enter alone) or types a fresh pointer, then re-captures and
# checks for EVIDENCE OF SUBMISSION (the pointer no longer sitting in the input
# box, plus tool-use / read / working activity). The detectors below were
# derived empirically against claude 2.1.132's actual rendering.
#
# INPUT VALIDATION: <task> becomes a tmux session name and is interpolated into
# every remote command, so each subcommand rejects any task outside
# [A-Za-z0-9._-] (and any leading '-', which would read as a flag). --dir and
# --claude-args are likewise interpolated into the remote launch command, so
# they are validated against a strict ALLOWLIST charset before use. This blocks
# remote command injection through a hostile task name, working dir, or claude
# flag string.
#
# Subcommands:
#   launch <task> [--dir <remote-dir>] [--claude-args "<flags>"] <brief...>
#   ls
#   peek <task> [-n <lines>]
#   steer <task> <message...>
#   attach <task>
#   kill <task>
# Global flag: --dry-run (LEADING only, before the subcommand word) prints the
# ssh command(s) instead of executing them.
set -eu

SSH_HOST="${FM_REMOTE_HOST:-thinkpad}"
# Default working directory and brief directory on the box. $HOME is kept literal
# (single quotes deliberate, SC2016) so the REMOTE shell, not this local one,
# expands it to the box's home when the command runs there.
# shellcheck disable=SC2016
DEFAULT_DIR='$HOME/dev/personal/firstmate'
# shellcheck disable=SC2016
BRIEF_DIR='$HOME/fm/briefs'
# Bounded delivery-verified launch handshake (see LAUNCH DESIGN). ATTEMPTS is the
# max number of pointer sends; SEND_WAIT is the settle after each send before the
# pane is re-checked for evidence of submission.
LAUNCH_ATTEMPTS="${FM_REMOTE_LAUNCH_ATTEMPTS:-4}"
LAUNCH_SEND_WAIT="${FM_REMOTE_LAUNCH_SEND_WAIT:-4}"

usage() {
  cat >&2 <<'EOF'
usage: fm-remote.sh [--dry-run] <command> [args]

commands:
  launch <task> [--dir <remote-dir>] [--claude-args "<flags>"] <brief...>
      Write the brief to ~/fm/briefs/<task>.md on the box, start a detached tmux
      session fm-<task> running claude, accept the one-time folder-trust dialog
      if it appears, then deliver a pointer prompt telling claude to read and
      execute the brief file.
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
  --dry-run   Print the ssh command(s) instead of executing them. Recognized
              ONLY before the command word; anything after the command is a
              verbatim command argument (so a brief may safely contain the
              literal text --dry-run).
EOF
  exit 2
}

die() { printf 'error: %s\n' "$1" >&2; exit 2; }

# <task> is a tmux session name and is spliced into every remote command, so it
# must be a safe token. Reject anything outside [A-Za-z0-9._-], the empty string,
# and any leading '-' (which tmux/ssh would read as a flag) before it can reach
# the box.
validate_task() {  # <task>
  case "$1" in
    -*) die "invalid task name '$1' (must not start with '-')" ;;
    ''|*[!A-Za-z0-9._-]*) die "invalid task name '$1' (allowed: letters, digits, . _ -)" ;;
  esac
}

# --dir is interpolated unquoted into the remote `tmux ... -c <dir>`. Keep remote
# $HOME expansion working (so `$` and `~` are allowed), but reject anything that
# could open a command substitution or a second command: a leading metacharacter
# scan for `$(`, backtick, `;`, and whitespace, then a strict safe-charset check.
validate_dir() {  # <dir>
  # The single-quoted needles below are literal on purpose (SC2016): they match
  # the characters, they must not expand here.
  # shellcheck disable=SC2016
  case "$1" in
    *'$('*|*'`'*|*';'*|*[[:space:]]*) die "invalid --dir value (shell metacharacters not allowed): $1" ;;
  esac
  # `-` is placed right after `!` so it is a literal dash; keeping it away from
  # the trailing `$` also avoids the unquoted `$-` (shell option flags) expanding
  # the class and silently dropping `$` from the allowed set.
  case "$1" in
    ''|*[!-A-Za-z0-9._/~$]*) die "invalid --dir value (allowed: letters, digits, . _ / ~ \$ -): $1" ;;
  esac
}

# --claude-args is interpolated into the inner `sh -c` command tmux runs, so a
# blocklist is unsafe (it missed && || | & < > ( ) etc.). Use a strict ALLOWLIST
# mirroring validate_dir: permit only ordinary flag strings, meaning letters,
# digits, spaces, and . _ = / - (spaces separate flags, leading dashes flag them,
# '=' for --flag=value). Reject everything else, including quotes, & | < > ( ),
# backtick, $, and newlines, so no shell metacharacter can chain or substitute a
# command.
validate_claude_args() {  # <args>
  # The space and '-' in the class below are literal: '-' sits right after '!' so
  # it is not a range, and the space is an ordinary allowed character.
  case "$1" in
    *[!-A-Za-z0-9._=/\ ]*) die "invalid --claude-args value (allowed: letters, digits, space and . _ = / -): $1" ;;
  esac
}

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

# Execute a remote command string unconditionally (used only on the real launch
# handshake, which never runs under --dry-run). Client-side expansion is the
# point (SC2029 expected).
ssh_exec() {  # <remote-cmd>
  # shellcheck disable=SC2029
  ssh "$SSH_HOST" "$1"
}

# --- launch pane detectors (derived empirically against claude 2.1.132) -------
# claude 2.1.132's TUI renders the folder-trust dialog with a "Quick safety
# check" heading and a "Yes, I trust this folder" option (the older "do you
# trust" / "trust the files in this" wordings no longer appear), so match any of
# them case-insensitively.
launch_pane_is_trust() {  # <pane>
  printf '%s' "$1" | grep -qiE 'trust this folder|quick safety check|do you trust|trust the files in this'
}

# The launch pointer is still sitting UNSENT in the input box when the last
# prompt line (the '❯' line nearest the bottom) still holds the pointer's tail:
# send-keys -l typed it but the Enter has not landed. After submission the
# pointer scrolls up into history and the bottom '❯' line is the (empty) input
# box, so the last '❯' line no longer carries the tail.
launch_pointer_sitting() {  # <pane>
  local last_prompt
  last_prompt=$(printf '%s\n' "$1" | grep -F '❯' | tail -n1)
  case "$last_prompt" in
    *'execute it as your brief.'*) return 0 ;;
    *) return 1 ;;
  esac
}

# Evidence the pointer was SUBMITTED: post-submission activity that never appears
# in the idle prompt or in the pointer text itself ("Read the file" in the
# pointer is deliberately excluded; only "Read <n> file" / "Reading <n>" from an
# actual tool call match). Any of a working spinner, a tool-use bullet, a read of
# the brief, a tool-result glyph, or a permission prompt counts.
launch_delivered() {  # <pane>
  ! launch_pointer_sitting "$1" || return 1
  printf '%s' "$1" | grep -qiE 'esc to interrupt|churned for|working…|reading [0-9]|read [0-9]+ file|⎿|do you want to proceed|● (bash|read|write|edit|update|web|task|grep|glob|search|fetch|mcp|kill|todo)'
}

# Recognize --dry-run ONLY as a leading global flag, before the command word.
# Everything from the command word onward is passed verbatim, so a --dry-run
# appearing inside a brief (or any other subcommand argument) is never silently
# swallowed into a no-op.
DRY_RUN=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    --dry-run) DRY_RUN=1; shift ;;
    *) break ;;
  esac
done
ARGS=("$@")
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
  validate_task "$task"
  validate_dir "$remote_dir"
  [ -z "$claude_args" ] || validate_claude_args "$claude_args"
  [ "${#brief_parts[@]}" -ge 1 ] || die "launch requires a <brief>"

  local ses="fm-$task"
  local brief_path="$BRIEF_DIR/$task.md"
  local brief="${brief_parts[*]}"

  # Write the brief via ssh stdin so no brief content ever passes through shell
  # quoting; the remote shell only ever sees the fixed mkdir/cat command.
  local write_cmd="mkdir -p $BRIEF_DIR && cat > $brief_path"

  # Start claude with NO prompt argument (see LAUNCH DESIGN header): the brief is
  # delivered as a pointer over the live TUI after the trust dialog is handled,
  # so the dialog cannot swallow it. --add-dir <brief-dir> makes the brief file
  # (which lives outside the working dir) readable without a permission prompt,
  # so a fully hands-off launch does not stall on the Read approval. claude-args
  # (validated) follow. BRIEF_DIR keeps its literal $HOME for remote expansion.
  local inner="claude --add-dir $BRIEF_DIR"
  [ -n "$claude_args" ] && inner="$inner $claude_args"
  local launch_cmd="tmux new -d -s $ses -c $remote_dir '$inner'"

  # The pointer prompt claude reads once its input is up. Delivered with the same
  # literal-send-keys + settle + Enter mechanics steer uses.
  local pointer="You are FM session $ses. Read the file ~/fm/briefs/$task.md and execute it as your brief."
  local q_ptr
  q_ptr=$(shell_quote "$pointer")
  local pointer_cmd="tmux send-keys -t $ses -l $q_ptr; sleep 0.3; tmux send-keys -t $ses Enter"

  if [ "$DRY_RUN" = 1 ]; then
    printf '# brief -> %s on %s:\n%s\n' "$brief_path" "$SSH_HOST" "$brief"
    printf 'printf %%s <brief> | ssh %s %s\n' "$SSH_HOST" "$(shell_quote "$write_cmd")"
    printf 'ssh %s %s\n' "$SSH_HOST" "$launch_cmd"
    printf 'ssh %s %s   # delivery-verified loop: capture, accept trust dialog (Enter), check for submission\n' \
      "$SSH_HOST" "$(shell_quote "tmux capture-pane -p -t $ses")"
    printf 'ssh %s %s\n' "$SSH_HOST" "$pointer_cmd"
    return 0
  fi

  # Brief content rides ssh stdin, so the remote shell only sees the fixed
  # mkdir/cat command; the write_cmd itself expands on the box (SC2029 expected).
  # shellcheck disable=SC2029
  printf '%s' "$brief" | ssh "$SSH_HOST" "$write_cmd"
  ssh_run "$launch_cmd"

  # Delivery-verified handshake (see LAUNCH DESIGN). Bounded loop of one-shot ssh
  # pane captures, no held process: accept the one-time folder-trust dialog, then
  # DELIVER the pointer and confirm it was actually submitted, retrying the send
  # if the pane shows no evidence of submission. A hard iteration cap keeps a
  # slow or wedged box from spinning.
  local pane sends=0 iter=0 delivered=0 trust_done=0
  local max_iter=$((LAUNCH_ATTEMPTS * 2 + 4))
  while [ "$iter" -lt "$max_iter" ] && [ "$delivered" -eq 0 ] && [ "$sends" -lt "$LAUNCH_ATTEMPTS" ]; do
    iter=$((iter + 1))
    pane=$(ssh_exec "tmux capture-pane -p -t $ses" 2>/dev/null || true)
    # Accept the folder-trust dialog with Enter (once) and let the TUI redraw.
    if [ "$trust_done" -eq 0 ] && launch_pane_is_trust "$pane"; then
      ssh_exec "tmux send-keys -t $ses Enter" >/dev/null 2>&1 || true
      trust_done=1
      sleep 2
      continue
    fi
    # Already delivered (e.g. a prior send landed)? Done.
    if launch_delivered "$pane"; then delivered=1; break; fi
    # Not yet at the input prompt (still booting): wait and re-check without
    # burning a send.
    if ! printf '%s' "$pane" | grep -qF '❯'; then
      sleep 2
      continue
    fi
    # Ready: submit. If a pointer is already typed but unsent, just press Enter;
    # otherwise type a fresh pointer (literal send, settle, Enter).
    if launch_pointer_sitting "$pane"; then
      ssh_exec "tmux send-keys -t $ses Enter" >/dev/null 2>&1 || true
    else
      ssh_exec "$pointer_cmd" >/dev/null 2>&1 || true
    fi
    sends=$((sends + 1))
    sleep "$LAUNCH_SEND_WAIT"
    pane=$(ssh_exec "tmux capture-pane -p -t $ses" 2>/dev/null || true)
    if launch_delivered "$pane"; then delivered=1; break; fi
  done

  if [ "$delivered" -eq 1 ]; then
    printf 'launched %s on %s (brief: %s); pointed claude at the brief file and verified the pointer was submitted\n' \
      "$ses" "$SSH_HOST" "$brief_path"
  elif printf '%s' "$pane" | grep -qiE 'trust this folder|quick safety check|do you trust|trust the files in this|sign in to|log in to'; then
    printf 'warning: launched tmux %s on %s (brief written to %s) but it appears stuck on a trust or sign-in prompt; peek to verify (fm-remote.sh peek %s)\n' \
      "$ses" "$SSH_HOST" "$brief_path" "$task" >&2
  else
    printf 'warning: launched tmux %s on %s (brief written to %s) but could not confirm the pointer was submitted after %s attempt(s); peek to verify (fm-remote.sh peek %s)\n' \
      "$ses" "$SSH_HOST" "$brief_path" "$sends" "$task" >&2
  fi
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
  validate_task "$task"
  case "$lines" in
    ''|*[!0-9]*) die "-n requires a positive integer, got '$lines'" ;;
  esac
  local ses="fm-$task"
  ssh_run "tmux capture-pane -p -t $ses | tail -n $lines"
}

cmd_steer() {
  [ "${#REST[@]}" -ge 1 ] || die "steer requires a <task> name"
  local task=${REST[0]}
  validate_task "$task"
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
  validate_task "${REST[0]}"
  local ses="fm-${REST[0]}"
  if [ "$DRY_RUN" = 1 ]; then
    printf 'ssh -t %s tmux attach -t %s\n' "$SSH_HOST" "$ses"
    return 0
  fi
  exec ssh -t "$SSH_HOST" tmux attach -t "$ses"
}

cmd_kill() {
  [ "${#REST[@]}" -eq 1 ] || die "kill requires exactly one <task> name"
  validate_task "${REST[0]}"
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

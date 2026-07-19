#!/usr/bin/env bash
# tests/fm-remote.test.sh - network-free contract test for bin/fm-remote.sh, the
# thin controller for firstmate sessions living in tmux on the remote box.
#
# WHY NETWORK-FREE: every subcommand ultimately runs an ssh call against the box,
# which needs a reachable host and a live tmux server, so it cannot run in CI.
# This suite exercises only the --dry-run path (which prints the exact ssh
# command instead of executing it) plus the usage/exit-code contract, so the
# session naming, brief path, quoting, and settle policy are pinned on every
# machine with no host or network. Real end-to-end launch/peek/steer is verified
# by hand against the box (see the script header), not here.
#
# FM_REMOTE_HOST is pinned to a fixed test value so the asserted ssh host is
# deterministic and never depends on the developer's ssh config.
#
# Single quotes in the assertions below are deliberate (SC2016): the needles are
# literal '$HOME' / "$(cat ...)" strings meant to reach the REMOTE shell, so they
# must NOT expand in this local test.
# shellcheck disable=SC2016
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN="$ROOT/bin/fm-remote.sh"
export FM_REMOTE_HOST=testbox

fail() { printf 'not ok - %s\n' "$1" >&2; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }

# assert_has <label> <output> <needle>: the output must contain the needle.
assert_has() {
  case "$2" in
    *"$3"*) : ;;
    *) fail "$1: expected to find '$3' in:"$'\n'"$2" ;;
  esac
}

# assert_lacks <label> <output> <needle>: the output must NOT contain the needle.
assert_lacks() {
  case "$2" in
    *"$3"*) fail "$1: did not expect '$3' in:"$'\n'"$2" ;;
    *) : ;;
  esac
}

# expect_fail <label> <args...>: running fm-remote.sh with these args must exit
# non-zero (a usage/validation error).
expect_fail() {
  local label=$1; shift
  if "$BIN" "$@" >/dev/null 2>&1; then
    fail "$label: expected non-zero exit for: $*"
  fi
  pass "$label"
}

# --- launch: session name, brief path, detached tmux, claude prompt -----------

out=$("$BIN" --dry-run launch demo "Build the thing" "and test it")
assert_has "launch: brief written via ssh stdin" "$out" 'printf %s <brief> | ssh testbox'
assert_has "launch: brief mkdir+cat to per-task path" "$out" 'mkdir -p $HOME/fm/briefs && cat > $HOME/fm/briefs/demo.md'
assert_has "launch: detached tmux session named fm-<task>" "$out" 'tmux new -d -s fm-demo'
assert_has "launch: default remote dir" "$out" '-c $HOME/dev/personal/firstmate'
assert_has "launch: claude receives the brief as initial prompt" "$out" 'claude "$(cat $HOME/fm/briefs/demo.md)"'
pass "launch dry-run prints the brief write and detached tmux launch"

# --- launch: --dir and --claude-args ------------------------------------------

out=$("$BIN" --dry-run launch build7 --dir '$HOME/work/foo' --claude-args '--model opus --verbose' "do the work")
assert_has "launch --dir: custom working dir" "$out" '-c $HOME/work/foo'
assert_has "launch --claude-args: flags precede the prompt" "$out" 'claude --model opus --verbose "$(cat $HOME/fm/briefs/build7.md)"'
assert_has "launch --dir: session name still fm-<task>" "$out" 'tmux new -d -s fm-build7'
pass "launch dry-run threads --dir and --claude-args into the tmux command"

# --dir/--claude-args may also appear after the brief-less flags in --key=value form.
out=$("$BIN" --dry-run launch kv --dir=$'$HOME/x' --claude-args='--foo' "brief text")
assert_has "launch =form: --dir=" "$out" '-c $HOME/x'
assert_has "launch =form: --claude-args=" "$out" 'claude --foo "$(cat $HOME/fm/briefs/kv.md)"'
pass "launch dry-run accepts --dir= and --claude-args= forms"

# --- ls -----------------------------------------------------------------------

out=$("$BIN" --dry-run ls)
assert_has "ls: ssh to the box" "$out" 'ssh testbox'
assert_has "ls: filters fm-* sessions" "$out" "grep '^fm-'"
assert_has "ls: tolerates no sessions" "$out" '|| true'
pass "ls dry-run lists fm-* tmux sessions on the box"

# --- peek: default and -n override --------------------------------------------

out=$("$BIN" --dry-run peek demo)
assert_has "peek: capture-pane on fm-<task>" "$out" 'tmux capture-pane -p -t fm-demo'
assert_has "peek: default 40-line tail" "$out" 'tail -n 40'
pass "peek dry-run captures the fm-<task> pane with the default tail"

out=$("$BIN" --dry-run peek demo -n 12)
assert_has "peek -n: overrides the tail count" "$out" 'tail -n 12'
pass "peek dry-run honors -n <lines>"

# --- steer: literal-mode send, settle policy, Enter ---------------------------

out=$("$BIN" --dry-run steer demo "please continue")
assert_has "steer: literal-mode send-keys" "$out" "tmux send-keys -t fm-demo -l 'please continue'"
assert_has "steer: plain-text settle" "$out" 'sleep 0.3'
assert_has "steer: submits with Enter" "$out" 'tmux send-keys -t fm-demo Enter'
pass "steer dry-run types the message literally, settles, then submits Enter"

out=$("$BIN" --dry-run steer demo "/compact now")
assert_has "steer: slash command gets the longer settle" "$out" 'sleep 1.2'
assert_has "steer: slash message sent literally" "$out" "-l '/compact now'"
pass "steer dry-run uses the longer popup settle for a slash command"

# A single quote in the message must be safely escaped for the remote shell.
out=$("$BIN" --dry-run steer demo "don't stop")
assert_has "steer: single quote escaped" "$out" "-l 'don'\\''t stop'"
pass "steer dry-run single-quote-escapes the message for the remote shell"

# --- attach -------------------------------------------------------------------

out=$("$BIN" --dry-run attach demo)
assert_has "attach: interactive ssh -t" "$out" 'ssh -t testbox tmux attach -t fm-demo'
pass "attach dry-run is an interactive ssh -t attach to fm-<task>"

# --- kill ---------------------------------------------------------------------

out=$("$BIN" --dry-run kill demo)
assert_has "kill: kill-session on fm-<task>" "$out" 'ssh testbox tmux kill-session -t fm-demo'
pass "kill dry-run kills the fm-<task> session"

# --- --dry-run is positional-agnostic -----------------------------------------

out=$("$BIN" kill demo --dry-run)
assert_has "--dry-run after subcommand still dry" "$out" 'ssh testbox tmux kill-session -t fm-demo'
pass "--dry-run works when it trails the subcommand"

# --- usage / validation errors ------------------------------------------------

expect_fail "no arguments"
expect_fail "unknown command" --dry-run bogus demo
expect_fail "launch without a task" --dry-run launch
expect_fail "launch without a brief" --dry-run launch demo
expect_fail "launch --dir missing value" --dry-run launch demo --dir
expect_fail "launch --claude-args missing value" --dry-run launch demo --claude-args
expect_fail "peek without a task" --dry-run peek
expect_fail "peek -n missing value" --dry-run peek demo -n
expect_fail "peek -n non-numeric" --dry-run peek demo -n abc
expect_fail "peek with two tasks" --dry-run peek a b
expect_fail "steer without a task" --dry-run steer
expect_fail "steer without a message" --dry-run steer demo
expect_fail "attach without a task" --dry-run attach
expect_fail "attach with an extra arg" --dry-run attach a b
expect_fail "kill without a task" --dry-run kill

printf 'all fm-remote.sh dry-run and usage checks passed\n'

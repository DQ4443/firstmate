#!/usr/bin/env bash
# fm-write-fence.sh - PreToolUse write fence for the workflow paradigm.
#
# Wired as a PreToolUse hook on Edit|Write|NotebookEdit. It is the structural
# enforcement of AGENTS.md prime rule 2 and rule 3: an in-session agent (a
# workflow subagent, or firstmate itself) may write into an isolated worktree,
# never into David's own checkouts under ~/dev/work or the projects/ symlinks
# that point at them. A forgotten isolation flag then hits an error here instead
# of dirtying David's working tree.
#
# Policy (checked on the symlink-resolved real path, so projects/<name> ->
# ~/dev/work/<repo> is covered):
#   ALLOW  writes under ~/.treehouse/**
#   ALLOW  writes under ~/dev/work/<repo>/.claude/worktrees/**
#   BLOCK  every other write under ~/dev/work/**
#   ALLOW  everything else (this firstmate repo, /tmp scratch, etc.)
#
# Broadened from the old .claude/block-html-edits.sh, which only fenced *.html
# board structure. This fence covers all of David's work checkouts.
#
# Hook contract: PreToolUse reads a JSON payload on stdin; exit 2 with a reason
# on stderr blocks the tool call and returns the reason to the model, exit 0
# allows it. It fails OPEN (allows) when it cannot read the payload or extract a
# path, so a parse hiccup never wedges every edit - the fence blocks only a path
# it can positively identify as inside a fenced tree.
set -u

PAYLOAD=$(cat 2>/dev/null || true)
[ -n "$PAYLOAD" ] || exit 0
command -v jq >/dev/null 2>&1 || exit 0

# Edit/Write use file_path; NotebookEdit uses notebook_path; tolerate path too.
TARGET=$(printf '%s' "$PAYLOAD" | jq -r '.tool_input.file_path // .tool_input.notebook_path // .tool_input.path // empty' 2>/dev/null) || exit 0
[ -n "$TARGET" ] || exit 0

# Resolve to an absolute real path, following symlinks. A Write may create a new
# file, so when the target itself does not exist yet resolve its parent dir and
# re-attach the basename.
resolve() {
  local p=$1 dir base
  if [ -e "$p" ]; then
    ( cd "$(dirname "$p")" 2>/dev/null && printf '%s/%s\n' "$(pwd -P)" "$(basename "$p")" )
    return
  fi
  dir=$(dirname "$p")
  base=$(basename "$p")
  if [ -d "$dir" ]; then
    ( cd "$dir" 2>/dev/null && printf '%s/%s\n' "$(pwd -P)" "$base" )
  else
    printf '%s\n' "$p"
  fi
}

RP=$(resolve "$TARGET")
[ -n "$RP" ] || exit 0

HOME_REAL=$( ( cd "$HOME" 2>/dev/null && pwd -P ) || printf '%s' "$HOME" )
WORK="$HOME_REAL/dev/work"
TREE="$HOME_REAL/.treehouse"

# Allow: treehouse worktrees.
case "$RP" in
  "$TREE"/*) exit 0 ;;
esac

# Allow: an agent worktree inside a work repo (~/dev/work/<repo>/.claude/worktrees/**).
case "$RP" in
  "$WORK"/*/.claude/worktrees/*) exit 0 ;;
esac

# Block: anything else under ~/dev/work (this includes projects/ symlinks, which
# resolve into ~/dev/work).
case "$RP" in
  "$WORK"/*)
    reason="write fence: $RP is inside David's work checkout (~/dev/work). Agents write only in an isolated worktree (~/dev/work/<repo>/.claude/worktrees/** or ~/.treehouse/**). Re-dispatch this write with isolation:'worktree'."
    printf '%s\n' "$reason" >&2
    exit 2
    ;;
esac

exit 0

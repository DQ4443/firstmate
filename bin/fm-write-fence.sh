#!/usr/bin/env bash
# fm-write-fence.sh - PreToolUse write fence for the workflow paradigm.
#
# Wired as a PreToolUse hook on Edit|Write|NotebookEdit at the poller cutover
# (the same human-verified local step that loads the launchd poller; not in
# tracked settings, so a fresh clone of this shared-template repo does not
# silently broaden every user's fence before their cutover). It is the
# structural, best-effort enforcement of AGENTS.md prime rule 2 and rule 3:
# an in-session agent (a workflow subagent, or firstmate itself) may write into
# an isolated worktree, never into David's own checkouts under ~/dev/work nor
# into firstmate's own project clones under <FM_ROOT>/projects. A forgotten
# isolation flag then hits an error here instead of dirtying a working tree.
#
# Policy (checked on the symlink-resolved real path):
#   ALLOW  writes under ~/.treehouse/**
#   ALLOW  writes under ~/dev/work/<repo>/.claude/worktrees/**
#   ALLOW  writes under <FM_ROOT>/projects/<name>/.claude/worktrees/**
#   BLOCK  every other write under ~/dev/work/**
#   BLOCK  every other write under <FM_ROOT>/projects/**
#   ALLOW  everything else (this firstmate repo's own tree, /tmp scratch, etc.)
#
# projects/<name> entries are firstmate's own clones of the fleet repos (real
# directories under <FM_ROOT>/projects, not symlinks into ~/dev/work), so the
# ~/dev/work rule alone never covers them; they get their own explicit block.
#
# Broadened from the old .claude/block-html-edits.sh, which only fenced *.html
# board structure. This fence covers David's work checkouts and the project
# clones.
#
# Hook contract: PreToolUse reads a JSON payload on stdin; exit 2 with a reason
# on stderr blocks the tool call and returns the reason to the model, exit 0
# allows it. It fails OPEN (allows) when it cannot read the payload or extract a
# path, so a parse hiccup never wedges every edit - the fence blocks only a path
# it can positively identify as inside a fenced tree. It is defense-in-depth
# behind isolation, not the sole guarantee.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

PAYLOAD=$(cat 2>/dev/null || true)
[ -n "$PAYLOAD" ] || exit 0
command -v jq >/dev/null 2>&1 || exit 0

# Edit/Write use file_path; NotebookEdit uses notebook_path; tolerate path too.
TARGET=$(printf '%s' "$PAYLOAD" | jq -r '.tool_input.file_path // .tool_input.notebook_path // .tool_input.path // empty' 2>/dev/null) || exit 0
[ -n "$TARGET" ] || exit 0

# Resolve to an absolute real path, following symlinks. A Write may create a new
# file whose parent dirs do not exist yet, so peel not-yet-existing components
# until an existing ancestor is reached, resolve THAT with pwd -P (following
# symlinks), and re-attach the missing tail. A new file created under a
# symlinked directory then still resolves into the real tree instead of staying
# an unresolved literal that slips past the case matches below.
resolve() {
  local p=$1 tail=''
  while [ ! -e "$p" ]; do
    case "$p" in
      / | . | '') break ;;
    esac
    tail="/$(basename "$p")$tail"
    p=$(dirname "$p")
  done
  if [ -d "$p" ]; then
    printf '%s%s\n' "$( cd "$p" && pwd -P )" "$tail"
  elif [ -e "$p" ]; then
    printf '%s/%s%s\n' "$( cd "$(dirname "$p")" && pwd -P )" "$(basename "$p")" "$tail"
  else
    printf '%s%s\n' "$p" "$tail"
  fi
}

RP=$(resolve "$TARGET")
[ -n "$RP" ] || exit 0

HOME_REAL=$( ( cd "$HOME" 2>/dev/null && pwd -P ) || printf '%s' "$HOME" )
WORK="$HOME_REAL/dev/work"
TREE="$HOME_REAL/.treehouse"
# FM_ROOT is this fence's own repo root (bin/..); its projects/ dir holds the
# project clones. Resolved to a real path so it matches the pwd -P'd target.
FM_ROOT_REAL=$( ( cd "$SCRIPT_DIR/.." 2>/dev/null && pwd -P ) || true )
PROJECTS="${FM_ROOT_REAL:+$FM_ROOT_REAL/projects}"

# Allow: treehouse worktrees.
case "$RP" in
  "$TREE"/*) exit 0 ;;
esac

# Allow: an agent worktree inside a work repo (~/dev/work/<repo>/.claude/worktrees/**).
case "$RP" in
  "$WORK"/*/.claude/worktrees/*) exit 0 ;;
esac

# Allow: an agent worktree inside a project clone (projects/<name>/.claude/worktrees/**).
if [ -n "$PROJECTS" ]; then
  case "$RP" in
    "$PROJECTS"/*/.claude/worktrees/*) exit 0 ;;
  esac
fi

# Block: anything else under ~/dev/work (David's own checkouts).
case "$RP" in
  "$WORK"/*)
    reason="write fence: $RP is inside David's work checkout (~/dev/work). Agents write only in an isolated worktree (~/dev/work/<repo>/.claude/worktrees/** or ~/.treehouse/**). Re-dispatch this write with isolation:'worktree'."
    printf '%s\n' "$reason" >&2
    exit 2
    ;;
esac

# Block: anything else under <FM_ROOT>/projects (firstmate's own project clones).
if [ -n "$PROJECTS" ]; then
  case "$RP" in
    "$PROJECTS"/*)
      reason="write fence: $RP is inside a firstmate project clone (projects/). Agents write only in an isolated worktree (~/.treehouse/** or projects/<name>/.claude/worktrees/**). Re-dispatch this write with isolation:'worktree'."
      printf '%s\n' "$reason" >&2
      exit 2
      ;;
  esac
fi

exit 0

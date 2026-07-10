#!/usr/bin/env bash
# fm-workflow-lint.sh - PreToolUse hook that mechanically enforces the workflow
# authoring pins, so a rule that fires late in a long session rides a structural
# carrier instead of memory (AGENTS.md section 4, data/compact-note-jul3.md).
#
# Wired as a PreToolUse hook on the Workflow tool (settings.local.json, the same
# untracked local step that loads the write fence). It reads the tool-call JSON
# on stdin, pulls the workflow source from .tool_input.script (inline) or the
# file at .tool_input.scriptPath, and BLOCKS (exit 2, reason on stderr naming the
# pin) when the source violates one of:
#
#   (a) MODEL ROUTING (data/operating-model/decisions.md, 2026-07-10): every
#       agent(...) call carries an explicit `model:` field in its options object.
#       A bare agent() inherits the orchestrator seat (Fable) as a worker and is a
#       bug on sight. Escape per call: a `// model:inherit-approved` comment in
#       that call for the rare sanctioned inherit.
#   (b) ONE WRITER PER WORKTREE (AGENTS.md prime rule 3): the same literal
#       worktree path must not appear in two or more agent prompts that both look
#       like writer briefs (heuristic: the prompt contains 'worktree add' or
#       'commit before returning'). Two writers in one tree race each other.
#   (c) META BLOCK: the script carries an `export const meta` block (runId /
#       budget carrier; AGENTS.md section 4 pinning).
#
# Conservative by design: for (b) a false BLOCK is worse than a miss, so it fires
# only on an exact literal collision of a canonical `.claude/worktrees/<name>` or
# `.treehouse/<name>` path across two distinct writer-brief calls; anything
# fuzzier is a miss, not a block. It FAILS OPEN (exit 0) whenever it cannot read
# the payload or extract a script, so a parse hiccup never wedges a dispatch. It
# is defense-in-depth behind the authoring discipline, not the sole guarantee.
set -u

PAYLOAD=$(cat 2>/dev/null || true)
[ -n "$PAYLOAD" ] || exit 0
command -v jq >/dev/null 2>&1 || exit 0

# Pull the workflow source: inline .script, else the file at .scriptPath.
SCRIPT=$(printf '%s' "$PAYLOAD" | jq -r '.tool_input.script // empty' 2>/dev/null) || exit 0
if [ -z "$SCRIPT" ]; then
  SP=$(printf '%s' "$PAYLOAD" | jq -r '.tool_input.scriptPath // empty' 2>/dev/null) || exit 0
  if [ -n "$SP" ] && [ -f "$SP" ]; then
    SCRIPT=$(cat "$SP" 2>/dev/null || true)
  fi
fi
# Nothing to lint (not a Workflow call, or an empty script): fail open.
[ -n "$SCRIPT" ] || exit 0

REASONS=""
add_reason() { REASONS="${REASONS}$1"$'\n'; }

# --- (c) meta block ----------------------------------------------------------
# A word-boundary match so `export const metadata` does not satisfy it.
if ! printf '%s' "$SCRIPT" | grep -qE 'export[[:space:]]+const[[:space:]]+meta([[:space:]]|=|:)'; then
  add_reason "(c) missing meta block: a workflow script must carry an 'export const meta' block (runId/budget carrier, AGENTS.md section 4)."
fi

# --- walk the agent() calls for (a) and (b) ----------------------------------
# Line-oriented state machine: a new chunk opens on a line whose 'agent(' sits at
# a call position (start-of-line or a non-identifier char before it, so 'subagent('
# and 'myagent(' do not open one). Each chunk accumulates until the next call.
AGENT_IDX=0
CHUNK=""
IN=0
BARE=""       # newline list of "idx|snippet" for calls with no model: field
WT_LINES=""   # newline list of canonical worktree paths, one per chunk-unique hit

flush_chunk() {
  [ "$IN" -eq 1 ] || return 0
  local idx=$AGENT_IDX

  # (a) model routing: a call is OK if it carries a model: field OR the escape
  # comment (which itself contains 'model:'). Word-boundary to skip 'remodel:'.
  if ! printf '%s' "$CHUNK" | grep -qE '(^|[^a-zA-Z_])model[[:space:]]*:'; then
    local snippet
    snippet=$(printf '%s' "$CHUNK" | tr '\n' ' ' | cut -c1-70)
    BARE="${BARE}${idx}|${snippet}"$'\n'
  fi

  # (b) one writer per worktree: only writer-brief calls contribute a path.
  if printf '%s' "$CHUNK" | grep -qF 'worktree add' \
    || printf '%s' "$CHUNK" | grep -qF 'commit before returning'; then
    # Canonical worktree roots: <...>/.claude/worktrees/<name> and <...>.treehouse/<name>.
    # The class stops at the first '/' after <name>, so a subfile reference
    # normalizes to the same root. sort -u => one entry per chunk per path.
    local paths
    paths=$(printf '%s' "$CHUNK" \
      | grep -oE '(/\.claude/worktrees/|\.treehouse/)[A-Za-z0-9._-]+' \
      | sort -u)
    if [ -n "$paths" ]; then
      WT_LINES="${WT_LINES}${paths}"$'\n'
    fi
  fi
}

while IFS= read -r line; do
  case "$line" in
    *agent\(*)
      # Confirm a call-position 'agent(' (not subagent(/identifier).
      if printf '%s' "$line" | grep -qE '(^|[^a-zA-Z0-9_])agent\('; then
        flush_chunk
        AGENT_IDX=$((AGENT_IDX + 1))
        CHUNK="$line"$'\n'
        IN=1
        continue
      fi
      ;;
  esac
  [ "$IN" -eq 1 ] && CHUNK="${CHUNK}${line}"$'\n'
done <<EOF
$SCRIPT
EOF
flush_chunk

# (a) report bare agent() calls.
if [ -n "$BARE" ]; then
  n=$(printf '%s' "$BARE" | grep -c '|' || true)
  first=$(printf '%s' "$BARE" | head -1 | cut -d'|' -f2-)
  add_reason "(a) model-routing pin: ${n} agent() call(s) have no explicit model: field. Workers/scouts/gates run model:'opus' (Fable is the orchestrator seat only). First: agent($first...). Add model: 'opus', or the escape comment // model:inherit-approved for a sanctioned inherit."
fi

# (b) report worktree paths shared by two or more writer-brief calls.
if [ -n "$WT_LINES" ]; then
  dups=$(printf '%s' "$WT_LINES" | grep -v '^$' | sort | uniq -d)
  if [ -n "$dups" ]; then
    while IFS= read -r p; do
      [ -n "$p" ] || continue
      add_reason "(b) one-writer-per-worktree pin: worktree path '$p' appears in two or more writer-brief agent prompts. Give each writing agent its own isolated worktree."
    done <<EOF
$dups
EOF
  fi
fi

if [ -n "$REASONS" ]; then
  printf 'fm-workflow-lint blocked this Workflow dispatch:\n%s' "$REASONS" >&2
  exit 2
fi
exit 0

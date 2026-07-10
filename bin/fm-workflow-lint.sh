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
#   (d) SWARM-CONTRACT SIZE (data/operating-model/decisions.md, 2026-07-10
#       agent-task-sizing pin): a lone WRITER agent must not grind a multi-part
#       task. BLOCK when the script has exactly ONE writer-brief agent() call and
#       that call's PROMPT enumerates 3+ separate concerns (lines that start with
#       "(N)" or "N." for N=1..9). That is the named anti-pattern: one agent
#       sequentially grinding a many-concern task, optionally followed by a lone
#       reviewer at the end (the msync-fix shape). The pin says shard it into a
#       swarm of single-leaf agents (each its own worktree) plus an integrator,
#       with a check per leaf. Escape per call: a `// size:single-leaf-approved`
#       comment on the call line or the line directly above it, for the rare case
#       that the enumerated prompt truly is one focused leaf.
#
#       WHY "writer" and not "total agent() count": the pin's anti-pattern is
#       explicitly "one agent working ... followed by one review at the end", so
#       a build+gate pair (one writer, one read-only reviewer) is still the smell
#       and must block; a genuine swarm of multiple WRITERS is the point and must
#       not. A writer is identified by the same brief heuristic as (b): its RAW
#       prompt contains 'worktree add' or 'commit before returning'. A read-only
#       scout or reviewer never counts, so a lone Explore scout that enumerates
#       sub-questions is not blocked. Multi-writer scripts are never blocked by
#       (d) regardless of prompt shape.
#
# TEMPLATE-LITERAL MASKING (the round-2 robustness fix). The scanner is
# line-oriented, and a workflow script's agent prompts are backtick template
# literals whose PROSE routinely mentions `agent(` and `model:`. Read as code,
# that prose caused two real defects: a compliant script FALSE-BLOCKED when a
# prompt line said "agent(" (it opened a spurious chunk that stole the real
# call's `model:` line), and a bare agent() was FALSE-ALLOWED when its prompt
# said "model:". So before any scan we MASK every backtick template-literal
# region: each character of template TEXT is replaced with a placeholder byte,
# preserving line structure (newlines and length), while the backtick
# delimiters, `${...}` interpolation CODE, string/comment code, and the options
# object after the closing backtick are left intact. The mask feeds the (c)
# meta scan, the agent()-chunk-boundary walk, and the (a) model: scan, so only
# real code is read there. It is also the template-region detector rule (d)
# reuses: an enumerated marker line counts only when the RAW line matches
# "(N)"/"N." AND the MASKED line does NOT (i.e. the marker sits in template
# PROSE, where masking turned it into 'x', not in code). That cheaply excludes
# any enumeration in the return/schema code, which is never masked. Escaped
# backticks (\`) do not close a literal and
# nested ${...} interpolations are tracked with a brace/lexer stack; when the
# lexer is unsure it keeps masking (prose-as-code is the failure class, so
# over-masking prose is the safe bias).
#
# The (b) worktree scan is the deliberate exception: it reads the RAW (unmasked)
# chunk, because writer-brief markers ('worktree add', 'commit before
# returning') and the worktree path itself live INSIDE the brief prose a writer
# agent receives (see any real build brief), not in code. Masking would blind
# (b) entirely and break its whole purpose; the raw chunk keeps it working while
# the corrected chunk boundaries make it strictly more accurate.
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

# --- template-literal masker -------------------------------------------------
# Reads the source on stdin, prints it with every backtick template-literal TEXT
# character replaced by 'x', preserving line structure. A small stack-based JS
# lexer tracks: code vs template; single/double-quoted strings and // /* */
# comments in code (so a backtick or brace inside them is not mistaken for a
# delimiter); escaped backticks inside a template (\` does not close); and
# nested ${...} interpolations (their code is preserved, brace-depth found the
# matching }). 'x' carries no ':' or '(' so a masked run never forms a model:
# or agent( token. SQ is the single-quote char (the awk program is itself in
# shell single quotes, so a literal ' cannot appear inside it).
mask_template() {
  awk '
  BEGIN { SQ = sprintf("%c", 39); sp = 0; q = ""; esc = 0 }
  {
    line = $0; n = length(line); out = "";
    for (i = 1; i <= n; i++) {
      c = substr(line, i, 1);
      nxt = (i < n) ? substr(line, i + 1, 1) : "";
      top = (sp > 0) ? stk[sp] : "";
      if (q == "lc") { out = out c; continue }
      if (q == "bc") { if (c == "*" && nxt == "/") { out = out "*/"; i++; q = "" } else out = out c; continue }
      if (q == "sq") { if (esc) esc = 0; else if (c == "\\") esc = 1; else if (c == SQ) q = ""; out = out c; continue }
      if (q == "dq") { if (esc) esc = 0; else if (c == "\\") esc = 1; else if (c == "\"") q = ""; out = out c; continue }
      if (top == "T") {
        if (esc) { out = out "x"; esc = 0; continue }
        if (c == "\\") { out = out "x"; esc = 1; continue }
        if (c == "`") { out = out "`"; sp--; continue }
        if (c == "$" && nxt == "{") { out = out "${"; i++; sp++; stk[sp] = "I"; brace[sp] = 0; continue }
        out = out "x"; continue
      } else {
        if (c == "/" && nxt == "/") { q = "lc"; out = out c; continue }
        if (c == "/" && nxt == "*") { q = "bc"; out = out c; continue }
        if (c == SQ) { q = "sq"; out = out c; continue }
        if (c == "\"") { q = "dq"; out = out c; continue }
        if (c == "`") { sp++; stk[sp] = "T"; out = out c; continue }
        if (top == "I") {
          if (c == "{") { brace[sp]++; out = out c; continue }
          if (c == "}") { if (brace[sp] == 0) sp--; else brace[sp]--; out = out c; continue }
        }
        out = out c; continue
      }
    }
    if (q == "lc") q = "";
    esc = 0;
    print out;
  }
  '
}

# The masked full text drives the code-only scans; the raw source is kept for
# the (b) worktree scan. Both chunk walks below read the two views in lockstep.
MASKED=$(printf '%s\n' "$SCRIPT" | mask_template)

# --- (c) meta block ----------------------------------------------------------
# Scanned on the MASKED text so a prompt that merely mentions 'export const meta'
# cannot satisfy the requirement. A word-boundary match so 'export const
# metadata' does not satisfy it.
if ! printf '%s' "$MASKED" | grep -qE 'export[[:space:]]+const[[:space:]]+meta([[:space:]]|=|:)'; then
  add_reason "(c) missing meta block: a workflow script must carry an 'export const meta' block (runId/budget carrier, AGENTS.md section 4)."
fi

# --- walk the agent() calls for (a) and (b) ----------------------------------
# Line-oriented state machine over the MASKED and RAW views in lockstep. A new
# chunk opens on a MASKED line whose 'agent(' sits at a call position
# (start-of-line or a non-identifier char before it, so 'subagent(' and
# 'myagent(' do not open one, and masked prose can no longer open one). Each
# chunk accumulates a masked half (for the model: scan) and a raw half (for the
# worktree scan) until the next call.
AGENT_IDX=0
CHUNK_M=""    # masked chunk text: drives the (a) model: scan
CHUNK_R=""    # raw chunk text: drives the (b) worktree scan and the report snippet
IN=0
BARE=""       # newline list of "idx|snippet" for calls with no model: field
WT_LINES=""   # newline list of canonical worktree paths, one per chunk-unique hit
CHUNK_MARK=0  # (d) enumerated-concern marker lines seen in the current chunk's prompt
CHUNK_PREV="" # (d) the raw line directly above this call's opening (escape "line above")
PREV_R=""     # (d) the raw line before the current one (feeds CHUNK_PREV at each open)
WRITER_COUNT=0    # (d) number of writer-brief agent() calls in the whole script
D_WRITER_MARK=0   # (d) marker count of the sole writer (meaningful iff WRITER_COUNT==1)
D_WRITER_ESC=0    # (d) escape status of the sole writer

# (d) bump CHUNK_MARK when a line is an enumerated-concern marker in template
# PROSE. It qualifies when the RAW line ($1) starts (after whitespace) with
# "(N)" or "N." for N=1..9 AND the MASKED line ($2) does NOT (masking turned the
# marker into 'x', proving it sits in a template literal, not in code). That is
# the template-region reuse: return/schema/code enumerations are never masked, so
# raw==masked there and they are excluded.
D_MARK_RE='^[[:space:]]*(\([1-9]\)|[1-9]\.)'
mark_if_marker() {
  if printf '%s' "$1" | grep -qE "$D_MARK_RE" \
    && ! printf '%s' "$2" | grep -qE "$D_MARK_RE"; then
    CHUNK_MARK=$((CHUNK_MARK + 1))
  fi
}

flush_chunk() {
  [ "$IN" -eq 1 ] || return 0
  local idx=$AGENT_IDX

  # (a) model routing: a call is OK if it carries a model: field OR the escape
  # comment (which itself contains 'model:'). Read on the MASKED chunk so prompt
  # prose that says 'model:' cannot satisfy it. Word-boundary to skip 'remodel:'.
  if ! printf '%s' "$CHUNK_M" | grep -qE '(^|[^a-zA-Z_])model[[:space:]]*:'; then
    local snippet
    snippet=$(printf '%s' "$CHUNK_R" | tr '\n' ' ' | cut -c1-70)
    BARE="${BARE}${idx}|${snippet}"$'\n'
  fi

  # A writer-brief call: the RAW prompt carries a writer marker. Shared by (b)
  # (one path per writer) and (d) (the writer-count that scopes the size check).
  local is_writer=0
  if printf '%s' "$CHUNK_R" | grep -qF 'worktree add' \
    || printf '%s' "$CHUNK_R" | grep -qF 'commit before returning'; then
    is_writer=1
  fi

  # (b) one writer per worktree: only writer-brief calls contribute a path.
  # Read on the RAW chunk: the markers and path live in the brief prose.
  if [ "$is_writer" -eq 1 ]; then
    # Canonical worktree roots: <...>/.claude/worktrees/<name> and <...>.treehouse/<name>.
    # The class stops at the first '/' after <name>, so a subfile reference
    # normalizes to the same root. sort -u => one entry per chunk per path.
    local paths
    paths=$(printf '%s' "$CHUNK_R" \
      | grep -oE '(/\.claude/worktrees/|\.treehouse/)[A-Za-z0-9._-]+' \
      | sort -u)
    if [ -n "$paths" ]; then
      WT_LINES="${WT_LINES}${paths}"$'\n'
    fi
  fi

  # (d) tally writers and remember the sole writer's marker/escape state. These
  # snapshots are only consulted after the walk when WRITER_COUNT lands on 1.
  # The escape covers the call if // size:single-leaf-approved appears anywhere in
  # the call statement (CHUNK_R spans the opening 'agent(' line through its
  # closing options line, so a trailing comment on a multi-line call is caught)
  # OR on the line directly above the opening (CHUNK_PREV).
  if [ "$is_writer" -eq 1 ]; then
    WRITER_COUNT=$((WRITER_COUNT + 1))
    D_WRITER_MARK=$CHUNK_MARK
    if printf '%s' "$CHUNK_R" | grep -qF '// size:single-leaf-approved' \
      || printf '%s' "$CHUNK_PREV" | grep -qF '// size:single-leaf-approved'; then
      D_WRITER_ESC=1
    else
      D_WRITER_ESC=0
    fi
  fi
}

while IFS= read -r rline <&3 && IFS= read -r mline <&4; do
  case "$mline" in
    *agent\(*)
      # Confirm a call-position 'agent(' on the MASKED line (not subagent(/id).
      if printf '%s' "$mline" | grep -qE '(^|[^a-zA-Z0-9_])agent\('; then
        flush_chunk
        AGENT_IDX=$((AGENT_IDX + 1))
        CHUNK_M="$mline"$'\n'
        CHUNK_R="$rline"$'\n'
        IN=1
        CHUNK_MARK=0
        CHUNK_PREV="$PREV_R"   # (d) remember the line above for the escape check
        mark_if_marker "$rline" "$mline"
        PREV_R="$rline"
        continue
      fi
      ;;
  esac
  if [ "$IN" -eq 1 ]; then
    CHUNK_M="${CHUNK_M}${mline}"$'\n'
    CHUNK_R="${CHUNK_R}${rline}"$'\n'
    mark_if_marker "$rline" "$mline"
  fi
  PREV_R="$rline"
done 3< <(printf '%s\n' "$SCRIPT") 4< <(printf '%s\n' "$SCRIPT" | mask_template)
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
    done < <(printf '%s\n' "$dups")
  fi
fi

# (d) swarm-contract size: a lone writer agent grinding an enumerated multi-part
# prompt. Only fires with exactly one writer (a real multi-writer swarm is the
# point) and no escape comment. 3+ enumerated concerns is the grinding shape.
if [ "$WRITER_COUNT" -eq 1 ] && [ "$D_WRITER_ESC" -eq 0 ] && [ "$D_WRITER_MARK" -ge 3 ]; then
  add_reason "(d) agent-task-sizing pin: the script's single writer agent enumerates ${D_WRITER_MARK} separate concerns in one prompt ((1)/(2)/... or 1./2./...). One agent grinding a multi-part task is the named anti-pattern (decisions.md 2026-07-10). Shard it into a swarm of single-leaf agents (each its own worktree) plus an integrator, with a check per leaf; or add // size:single-leaf-approved on the call line if this genuinely is one focused leaf."
fi

if [ -n "$REASONS" ]; then
  printf 'fm-workflow-lint blocked this Workflow dispatch:\n%s' "$REASONS" >&2
  exit 2
fi
exit 0

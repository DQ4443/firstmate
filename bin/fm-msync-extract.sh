#!/usr/bin/env bash
# fm-msync-extract.sh - the Stage B EXTRACT producer for the meeting sync
# (meeting-sync-design.md Stage B, Decisions 2a/2b; wired into
# bin/fm-meeting-sync.sh --propose via FM_MSYNC_EXTRACT_BIN).
#
# WHAT THIS IS. Stage B is the LLM-judged step: from a slot's fetched notes +
# transcript it PROPOSES a structured, timecode-anchored, classify-to-destination
# change list; it does not act. The orchestrator consumes the proposal file this
# script writes (the FM_MSYNC_EXTRACT_FILE shape). Before this script existed the
# scheduled path had NO Stage B producer (FM_MSYNC_EXTRACT_FILE was only ever set
# by hand), so every scheduled fire classified nothing; this leaf closes that gap
# with the same headless `claude -p` pattern bin/fm-drain-worker.sh proved.
#
# SECURITY (the drain worker's scoping argument applies verbatim): this is an
# unattended, human-absent LLM turn, so the capability boundary is structural,
# not prompt text. The turn runs in default (non-bypass) permission mode with NO
# --allowedTools grant, so in headless -p mode every permission-requiring tool
# (Bash, Edit/Write, git, network, MCP, sub-agents) is denied with no prompt to
# satisfy. The turn is a pure text transform: notes in on stdin, JSON out on
# stdout. THIS script (not the model) writes the output file, after validating
# the output parses as the proposal schema.
#
# THE HONEST DEGRADE (mirrors fm-gfetch.sh, Decision 4b Option C): when claude
# is not resolvable, the turn times out, or the output does not validate, this
# script prints ONE machine-parseable line to stdout beginning with the stable
# token `extract-not-available: <reason>`, writes a recovery hint to stderr, and
# exits 3. It NEVER writes a partial/invalid proposal file, so a consumer can
# trust that an existing --out file parsed.
#
# OUTPUT SCHEMA (the FM_MSYNC_EXTRACT_FILE contract, consumed by
# fm-meeting-sync.sh classify_item): {"items":[{...}]} where each item carries:
#   category    DELIVERABLE | ACTION ITEM | STATUS CLAIM | DECISION | DESCOPE |
#               FYI | CLOSE | DEDUPE
#   destination linear-create | comment | state-transition | close | descope |
#               digest-only | narrative
#   title, description, owner (the SPOKEN name, "" when truly unstated; never
#   invented), eng (ENG-NNN only when explicitly stated), state (for a
#   state-transition), timecode (HH:MM:SS transcript anchor where present),
#   field + mvp_core (narrative items; MVP_DEADLINE marks mvp_core true).
# Owner resolution/tiering happens downstream in the orchestrator against
# data/roster-linear.md; this producer must never resolve or invent an id.
#
# HERMETIC TEST HOOKS: FM_MSYNC_EXTRACT_CLAUDE_BIN (the claude binary),
# FM_MSYNC_EXTRACT_MODEL (pin a model), FM_MSYNC_EXTRACT_TIMEOUT (seconds,
# default 480).
#
# USAGE:
#   fm-msync-extract.sh --slot YYYY-MM-DD/<morning|eod> --notes <file> --out <file>
#                       [--roster <file>]
#
# Exit codes: 0 ok (--out written and valid); 2 usage error;
#             3 extract-not-available (the honest degrade; --out untouched).
set -euo pipefail

SLOT="" NOTES="" OUT="" ROSTER=""
while [ $# -gt 0 ]; do
  case "$1" in
    --slot)   SLOT="${2:-}"; shift 2 ;;
    --notes)  NOTES="${2:-}"; shift 2 ;;
    --out)    OUT="${2:-}"; shift 2 ;;
    --roster) ROSTER="${2:-}"; shift 2 ;;
    -h|--help) sed -n '2,55p' "$0"; exit 0 ;;
    *) echo "fm-msync-extract: unknown argument $1" >&2; exit 2 ;;
  esac
done
if [ -z "$SLOT" ] || [ -z "$NOTES" ] || [ -z "$OUT" ]; then
  echo "fm-msync-extract: --slot, --notes and --out are required" >&2
  exit 2
fi
[ -f "$NOTES" ] || { echo "fm-msync-extract: notes file not found: $NOTES" >&2; exit 2; }

degrade() { # <reason> - one machine-parseable line, hint to stderr, exit 3
  printf 'extract-not-available: %s\n' "$1"
  echo "fm-msync-extract: recovery: run the extraction by hand and pass FM_MSYNC_EXTRACT_FILE, or paste the notes to firstmate" >&2
  exit 3
}

# --- claude resolution + bounded run (the fm-drain-worker.sh pattern) --------
resolve_claude() {
  local c
  for c in "${FM_MSYNC_EXTRACT_CLAUDE_BIN:-}" "$(command -v claude 2>/dev/null || true)" \
           "$HOME"/.nvm/versions/node/*/bin/claude \
           /opt/homebrew/bin/claude /usr/local/bin/claude; do
    [ -n "$c" ] && [ -x "$c" ] && { printf '%s' "$c"; return 0; }
  done
  return 1
}

run_bounded() { # <seconds> <cmd...> - wall-clock cap without coreutils
  local secs=$1; shift
  if command -v timeout >/dev/null 2>&1; then
    timeout "$secs" "$@"
  elif command -v gtimeout >/dev/null 2>&1; then
    gtimeout "$secs" "$@"
  else
    # shellcheck disable=SC2016  # single quotes deliberate: Perl expands its own vars.
    perl -e 'my $t = shift; my $pid = fork; die "fork failed" unless defined $pid; if (!$pid) { setpgrp(0, 0); exec @ARGV } local $SIG{ALRM} = sub { kill "TERM", -$pid; select undef, undef, undef, 0.2; kill "KILL", -$pid; exit 124 }; alarm $t; waitpid $pid, 0; exit($? >> 8)' "$secs" "$@"
  fi
}

CLAUDE_BIN=$(resolve_claude) || degrade "claude binary not resolvable"
TIMEOUT_S="${FM_MSYNC_EXTRACT_TIMEOUT:-480}"

# --- build the prompt (deterministic preamble + roster + notes) ---------------
PROMPT=$(mktemp "${TMPDIR:-/tmp}/fm-msync-extract.XXXXXX")
RAWOUT=$(mktemp "${TMPDIR:-/tmp}/fm-msync-extract-out.XXXXXX")
trap 'rm -f "$PROMPT" "$RAWOUT"' EXIT
{
  cat <<'PREAMBLE'
You are the Stage B EXTRACT step of an unattended meeting-sync pipeline.
From the meeting notes + transcript below, produce a structured change proposal.
You PROPOSE; you do not act. A downstream orchestrator classifies and gates every item.

OUTPUT: exactly one JSON object, nothing else. No markdown fences, no prose before or after.
Shape: {"items": [ ... ]}. Each item is an object with these fields:
  "category":    one of "DELIVERABLE", "ACTION ITEM", "STATUS CLAIM", "DECISION", "DESCOPE", "FYI", "CLOSE", "DEDUPE"
  "destination": one of "linear-create", "comment", "state-transition", "close", "descope", "digest-only", "narrative"
  "title":       short imperative title of the item
  "description": one-sentence context from the meeting
  "owner":       the SPOKEN owner name exactly as heard, or "" when no owner was stated. NEVER invent an owner.
  "eng":         "ENG-NNN" ONLY when a ticket id was explicitly mentioned; omit the field otherwise.
  "state":       for a state-transition, the spoken target state (e.g. "In Review", "blocked"); omit otherwise.
  "timecode":    the transcript timecode anchor "HH:MM:SS" for this item where the transcript carries one; omit otherwise.
  "field":       for a narrative item that names a specific field (e.g. "MVP_DEADLINE"); omit otherwise.
  "mvp_core":    true ONLY for a narrative change to MVP-core content (the MVP deadline, MVP scope); omit otherwise.

Routing rules (classify-to-destination):
- A deliverable or action item someone must do -> "linear-create" (or a comment on the stated ENG ticket if it only adds context).
- "I shipped X" / "I'm blocked on Y" -> "state-transition" on the stated or clearly-referenced ticket.
- A decision affecting an existing ticket -> "comment" on that ticket.
- A standing decision or anything changing the project narrative/deadline -> "narrative".
- Cutting scope from an item -> "descope". Closing/merging duplicate work -> "close" or "dedupe".
- Pure FYI with no action and no decision -> "digest-only".
- Unstated attributes stay absent or "". Never guess, never invent, never resolve names to ids.
- Every item gets a timecode when the transcript provides one; items without evidence in the text below must NOT be emitted.
If the notes contain no actionable content, emit {"items": []}.
PREAMBLE
  printf '\nMEETING SLOT: %s\n' "$SLOT"
  if [ -n "$ROSTER" ] && [ -f "$ROSTER" ]; then
    printf '\n===== TEAM ROSTER (for recognizing spoken names ONLY; ids resolve downstream) =====\n'
    cat "$ROSTER"
  fi
  printf '\n===== MEETING NOTES + TRANSCRIPT =====\n'
  cat "$NOTES"
} > "$PROMPT"

# --- the headless turn (default permission mode: every write tool denied) ----
set +e
if [ -n "${FM_MSYNC_EXTRACT_MODEL:-}" ]; then
  run_bounded "$TIMEOUT_S" "$CLAUDE_BIN" -p --model "$FM_MSYNC_EXTRACT_MODEL" \
    < "$PROMPT" > "$RAWOUT" 2>/dev/null
else
  run_bounded "$TIMEOUT_S" "$CLAUDE_BIN" -p < "$PROMPT" > "$RAWOUT" 2>/dev/null
fi
RC=$?
set -e
[ "$RC" -eq 124 ] && degrade "extraction timed out after ${TIMEOUT_S}s"
[ "$RC" -eq 0 ] || degrade "claude -p exited $RC"

# --- validate + write (THIS script owns the output file, never the model) ----
# Tolerates accidental fences/prose by slicing first '{' .. last '}', then
# requires a dict with an "items" list of dicts. Writes --out atomically.
if ! python3 - "$RAWOUT" "$OUT" <<'PYEOF'
import json
import os
import sys

raw_path, out_path = sys.argv[1], sys.argv[2]
with open(raw_path) as fh:
    raw = fh.read()
start, end = raw.find("{"), raw.rfind("}")
if start < 0 or end <= start:
    sys.exit(1)
try:
    data = json.loads(raw[start:end + 1])
except ValueError:
    sys.exit(1)
items = data.get("items") if isinstance(data, dict) else None
if not isinstance(items, list) or not all(isinstance(i, dict) for i in items):
    sys.exit(1)
tmp = out_path + ".tmp"
with open(tmp, "w") as fh:
    json.dump({"items": items}, fh, indent=2, ensure_ascii=False)
    fh.write("\n")
os.replace(tmp, out_path)
print(len(items))
PYEOF
then
  degrade "model output did not validate as an {\"items\": [...]} proposal"
fi

#!/usr/bin/env bash
# Hermetic tests for bin/fm-msync-extract.sh (the Stage B EXTRACT producer).
#
# No network, no real model: the headless claude turn is driven through the
# FM_MSYNC_EXTRACT_CLAUDE_BIN hook with fake binaries, so the load-bearing
# behavior is checked deterministically and offline:
#   - the prompt carries the slot, the roster, and the notes text;
#   - valid model JSON (even fenced/prosed) is validated and written to --out
#     by THIS script, atomically;
#   - garbage output / a failing model degrade with the machine-parseable
#     `extract-not-available` token, exit 3, and NO --out file;
#   - usage errors exit 2.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(dirname "$HERE")"
BIN="$REPO/bin/fm-msync-extract.sh"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
PASS=0 FAIL=0
ok()  { PASS=$((PASS+1)); printf 'ok   %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf 'FAIL %s\n' "$1"; }
chk() { if eval "$2"; then ok "$1"; else bad "$1 :: $2"; fi; }

printf 'MEETING NOTES fixture: David shipped the mesh exporter at 00:04:10\n' > "$WORK/notes.txt"
printf '| David | David Example | id | d@ex | david.example | yes |\n' > "$WORK/roster.md"

# --- fake claude: records the prompt, emits fenced JSON with prose around it --
cat > "$WORK/claude-good" <<MOCK
#!/usr/bin/env bash
# fake claude -p: swallow flags, capture stdin, emit a fenced+prosed proposal.
cat > "$WORK/prompt-received.txt"
cat <<'J'
Here is the extraction you asked for:
\`\`\`json
{"items": [{"category": "STATUS CLAIM", "title": "shipped mesh exporter",
            "owner": "David", "destination": "state-transition",
            "state": "In Review", "timecode": "00:04:10"}]}
\`\`\`
J
MOCK
cat > "$WORK/claude-garbage" <<'MOCK'
#!/usr/bin/env bash
cat >/dev/null
echo "I am sorry, I cannot produce JSON today."
MOCK
cat > "$WORK/claude-notalist" <<'MOCK'
#!/usr/bin/env bash
cat >/dev/null
echo '{"items": "nope"}'
MOCK
cat > "$WORK/claude-fails" <<'MOCK'
#!/usr/bin/env bash
cat >/dev/null
exit 7
MOCK
chmod +x "$WORK/claude-good" "$WORK/claude-garbage" "$WORK/claude-notalist" "$WORK/claude-fails"

# === 1. happy path: fenced model JSON is validated and written to --out ======
OUT="$(FM_MSYNC_EXTRACT_CLAUDE_BIN="$WORK/claude-good" \
  "$BIN" --slot 2026-07-06/morning --notes "$WORK/notes.txt" \
         --out "$WORK/proposal.json" --roster "$WORK/roster.md" 2>&1)"; RC=$?
chk "happy path exits 0"                      "[ $RC -eq 0 ]"
chk "proposal file written"                   "[ -f \"$WORK/proposal.json\" ]"
chk "proposal parses with the items list"     "python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); assert isinstance(d[\"items\"], list) and d[\"items\"][0][\"owner\"]==\"David\"' \"$WORK/proposal.json\""
chk "prompt carried the slot identity"        "grep -q 'MEETING SLOT: 2026-07-06/morning' \"$WORK/prompt-received.txt\""
chk "prompt carried the notes text"           "grep -q 'shipped the mesh exporter' \"$WORK/prompt-received.txt\""
chk "prompt carried the roster"               "grep -q 'david.example' \"$WORK/prompt-received.txt\""
chk "prompt forbids inventing owners"         "grep -q 'NEVER invent an owner' \"$WORK/prompt-received.txt\""
chk "prompt states propose-not-act"           "grep -q 'you do not act' \"$WORK/prompt-received.txt\""

# === 2. garbage model output: honest degrade, no partial file ================
OUT="$(FM_MSYNC_EXTRACT_CLAUDE_BIN="$WORK/claude-garbage" \
  "$BIN" --slot 2026-07-06/morning --notes "$WORK/notes.txt" \
         --out "$WORK/bad.json" 2>&1)"; RC=$?
chk "garbage output exits 3"                  "[ $RC -eq 3 ]"
chk "garbage output emits the degrade token"  "grep -q 'extract-not-available' <<<\"\$OUT\""
chk "garbage output writes NO out file"       "[ ! -e \"$WORK/bad.json\" ]"

# === 3. items is not a list: rejected the same way ===========================
OUT="$(FM_MSYNC_EXTRACT_CLAUDE_BIN="$WORK/claude-notalist" \
  "$BIN" --slot 2026-07-06/morning --notes "$WORK/notes.txt" \
         --out "$WORK/bad2.json" 2>&1)"; RC=$?
chk "non-list items exits 3"                  "[ $RC -eq 3 ]"
chk "non-list items writes NO out file"       "[ ! -e \"$WORK/bad2.json\" ]"

# === 4. model process failure: degrade names the exit code ===================
# shellcheck disable=SC2034  # OUT is consumed by the chk evals below via <<<"$OUT"
OUT="$(FM_MSYNC_EXTRACT_CLAUDE_BIN="$WORK/claude-fails" \
  "$BIN" --slot 2026-07-06/morning --notes "$WORK/notes.txt" \
         --out "$WORK/bad3.json" 2>&1)"; RC=$?
chk "failing model exits 3"                   "[ $RC -eq 3 ]"
chk "failing model degrade names the cause"   "grep -q 'extract-not-available: claude -p exited 7' <<<\"\$OUT\""
chk "failing model writes NO out file"        "[ ! -e \"$WORK/bad3.json\" ]"

# === 5. usage errors ==========================================================
"$BIN" --slot 2026-07-06/morning --notes "$WORK/notes.txt" >/dev/null 2>&1
chk "missing --out is a usage error (2)"      "[ $? -eq 2 ]"
"$BIN" --slot x --notes "$WORK/does-not-exist" --out "$WORK/o.json" >/dev/null 2>&1
chk "missing notes file is a usage error (2)" "[ $? -eq 2 ]"

echo "----"
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]

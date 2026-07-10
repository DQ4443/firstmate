#!/usr/bin/env bash
# Hermetic tests for bin/fm-meeting-sync.sh (meeting-sync orchestrator, leaf L6).
#
# No network, no siblings: the orchestrator is driven through its documented DI
# hooks (FM_MSYNC_STATE_DIR / _ROSTER_FILE / _EXTRACT_FILE / _GFETCH_BIN /
# _RECONCILE_BIN / _BOARD_REPLY_BIN / _NOW) with fixtures + mock binaries, so the
# load-bearing invariants are checked deterministically and offline:
#   - the tiered gate (Decision 5a): self-assign/comment/own-state -> AUTONOMOUS;
#     assign-another / other-state-flip / close / descope / unresolved owner -> GATED;
#     MVP_DEADLINE narrative -> HARD STOP.
#   - THE narrative invariant: content.ts is never written; narrative + gated go
#     to the board via fm-board-reply.sh --your-court.
#   - the backfill gap-scan, slot parsing, the honest degrade + exit 3, and the
#     install-schedule surface that installs nothing.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(dirname "$HERE")"
BIN="$REPO/bin/fm-meeting-sync.sh"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
PASS=0 FAIL=0
ok()  { PASS=$((PASS+1)); printf 'ok   %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf 'FAIL %s\n' "$1"; }
chk() { if eval "$2"; then ok "$1"; else bad "$1 :: $2"; fi; }

# --- roster fixture (subset of data/roster-linear.md shape) ----------------
# FULLY SYNTHETIC. This fixture must never carry a real Linear user id or a real
# teammate surname: DQ4443/firstmate is a PUBLIC repo (see the L3 roster
# template's PII note). The UUIDs are obviously-fake 000...000N sentinels and the
# surnames are all "Example". The canonical FIRST names are the join keys the
# tiered gate resolves owners by, so they stay; only ids/surnames/displayNames
# are synthesized.
cat > "$WORK/roster.md" <<'MD'
## Roster table (canonical name -> Linear user id)
| Canonical | Linear name | Linear user id (assigneeId) | email | displayName | eng assignee? |
|---|---|---|---|---|---|
| David | David Example | `00000000-0000-0000-0000-000000000001` | d@ex | david.example | yes |
| Eddie | Eddie Example | `00000000-0000-0000-0000-000000000002` | e@ex | eddie.example | yes |
| Rixi | Rixi Example | `00000000-0000-0000-0000-000000000003` | r@ex | rixi.example | yes |
| Yang | (no Linear account) | UNRESOLVED | - | - | no (gate) |

## Non-eng-assignee table
| Person | Linear name | Linear user id | email | displayName | why non-assignee |
|---|---|---|---|---|---|
| Yujie | Yujie Example | `00000000-0000-0000-0000-000000000004` | y@ex | yujie.example | PM, not eng assignee |

## Garble / alias table
| Alias / mis-hearing (any case) | Canonical |
|---|---|
| David, Dave, DQ | David |
| Eddie, Eddy, Ed | Eddie |
| Rixi, Rishi, Ricky | Rixi |
| Yang, Yeng | Yang (UNRESOLVED) |
| Yujie, Yuji | Yujie (non-eng) |
MD

# --- extraction proposal fixture (Decision 2a categories) ------------------
cat > "$WORK/extract.json" <<'JSON'
{"items": [
  {"category":"DELIVERABLE","title":"new mesh exporter","owner":"","destination":"linear-create","timecode":"00:04:10"},
  {"category":"DELIVERABLE","title":"solver kernel","owner":"Rishi","destination":"linear-create","timecode":"00:06:22"},
  {"category":"ACTION ITEM","title":"dataset upload","owner":"Yang","destination":"linear-create","timecode":"00:08:00"},
  {"category":"DECISION","title":"use adjoint method","owner":"David","eng":"ENG-210","destination":"comment","timecode":"00:10:00"},
  {"category":"STATUS CLAIM","title":"shipped mesh","owner":"David","eng":"ENG-200","destination":"state-transition","state":"In Review","timecode":"00:12:00"},
  {"category":"STATUS CLAIM","title":"eddie blocked","owner":"Eddie","eng":"ENG-201","destination":"state-transition","state":"blocked","timecode":"00:13:00"},
  {"category":"DESCOPE","title":"cut FDTD from solver","owner":"Rixi","eng":"ENG-202","destination":"descope","timecode":"00:14:00"},
  {"category":"FYI","title":"conference next week","owner":"","destination":"digest-only","timecode":"00:15:00"},
  {"category":"DECISION","title":"move MVP deadline to Aug 1","owner":"David","field":"MVP_DEADLINE","mvp_core":true,"destination":"narrative","timecode":"00:16:00"},
  {"category":"DECISION","title":"standing: adopt monorepo","owner":"David","destination":"narrative","timecode":"00:17:00"}
]}
JSON

# --- mock sibling binaries that record invocations (NEVER touch real Linear,
#     NEVER the real Google APIs: bin/fm-gfetch.sh may be credentialed on the
#     host, so every block pins FM_MSYNC_GFETCH_BIN to a mock or an absent path)
GF_ABSENT="$WORK/absent-gfetch"   # never created: forces the honest degrade
cat > "$WORK/board-reply.sh" <<MOCK
#!/usr/bin/env bash
echo "BOARD_REPLY_CALLED item=\$1 msg=\$2 args=\${*:3}" >> "$WORK/board.log"
MOCK
cat > "$WORK/gfetch.sh" <<MOCK
#!/usr/bin/env bash
# mock fm-gfetch.sh: one in-window morning doc (2026-07-06 18:30Z = 11:30 PT)
# plus one out-of-window doc, exercising the slot-scoped selection.
echo "GFETCH_CALLED \$*" >> "$WORK/gfetch.log"
case "\${1:-}" in
  files)
    cat <<'J'
{"query": "Kronos Tech Sync", "files": [
  {"id": "doc-1", "name": "Notes - Kronos Tech Sync", "createdTime": "2026-07-06T18:30:00Z", "modifiedTime": "2026-07-06T19:00:00Z"},
  {"id": "doc-old", "name": "Notes - Kronos Tech Sync (eod)", "createdTime": "2026-07-05T23:30:00Z", "modifiedTime": "2026-07-05T23:40:00Z"}
]}
J
    ;;
  doc)
    echo "MOCK NOTES + TRANSCRIPT for \${2:-} (fixture text)"
    ;;
esac
MOCK
cat > "$WORK/extractor.sh" <<MOCK
#!/usr/bin/env bash
# mock fm-msync-extract.sh: records the call, emits the fixture proposal.
echo "EXTRACT_CALLED \$*" >> "$WORK/extract.log"
out="" prev=""
for a in "\$@"; do [ "\$prev" = "--out" ] && out="\$a"; prev="\$a"; done
[ -n "\$out" ] && cp "$WORK/extract.json" "\$out"
MOCK
cat > "$WORK/linear.sh" <<MOCK
#!/usr/bin/env bash
# mock fm-linear.sh: logs every call AND maintains a per-state-dir REMOTE store,
# so the orchestrator's read-before-write remote idempotency guard (get_issue /
# list_issues before add_comment / create_issue) is exercised hermetically. The
# remote lives under <state-dir>/mock-remote unless overridden, so each test
# block is auto-isolated by its own FM_MSYNC_STATE_DIR.
echo "LINEAR_CALLED \$*" >> "$WORK/linear.log"
REMOTE="\${FM_MSYNC_MOCK_REMOTE:-\${FM_MSYNC_STATE_DIR:-$WORK}/mock-remote}"
mkdir -p "\$REMOTE" 2>/dev/null || true
_cmd="\${1:-}"; shift || true
case "\$_cmd" in
  get_issue)
    _id="\${1:-}"
    [ -n "\$_id" ] && [ -f "\$REMOTE/\$_id.comments" ] && cat "\$REMOTE/\$_id.comments"
    ;;
  list_issues)
    [ -f "\$REMOTE/issues.txt" ] && cat "\$REMOTE/issues.txt"
    ;;
  add_comment)
    _id="\${1:-}"; shift || true
    _body=""; _prev=""
    for _a in "\$@"; do [ "\$_prev" = "--body" ] && _body="\$_a"; _prev="\$_a"; done
    printf '%s\n' "\$_body" >> "\$REMOTE/\$_id.comments"
    ;;
  create_issue)
    printf 'create_issue %s\n' "\$*" >> "\$REMOTE/issues.txt"
    ;;
esac
MOCK
cat > "$WORK/reconcile.sh" <<MOCK
#!/usr/bin/env bash
echo "RECONCILE_CALLED \$*" >> "$WORK/reconcile.log"
MOCK
cat > "$WORK/audit.sh" <<MOCK
#!/usr/bin/env bash
echo "AUDIT_CALLED \$*" >> "$WORK/audit.log"
MOCK
chmod +x "$WORK/board-reply.sh" "$WORK/linear.sh" "$WORK/reconcile.sh" \
         "$WORK/audit.sh" "$WORK/gfetch.sh" "$WORK/extractor.sh"

run() {
  FM_MSYNC_STATE_DIR="$WORK/state" \
  FM_MSYNC_ROSTER_FILE="$WORK/roster.md" \
  FM_MSYNC_BOARD_REPLY_BIN="$WORK/board-reply.sh" \
  FM_MSYNC_GFETCH_BIN="$GF_ABSENT" \
  FM_MSYNC_RECONCILE_BIN="$WORK/reconcile.sh" \
  FM_MSYNC_NOW="2026-07-06T20:00:00Z" \
  "$BIN" "$@"
}

# === 1. degrade + acceptance shape (no proposal, no gfetch) =================
OUT="$(run --slot 2026-07-06/morning --dry-run 2>&1)"; RC=$?
chk "degrade prints a change-list"           "grep -q 'MEETING SYNC CHANGE-LIST' <<<\"\$OUT\""
chk "degrade contains 'narrative'"           "grep -qi 'narrative' <<<\"\$OUT\""
chk "degrade emits notes-not-fetchable"      "grep -q 'notes-not-fetchable' <<<\"\$OUT\""
chk "degrade exit code is 3"                  "[ $RC -eq 3 ]"

# === 2. full classification via the proposal ================================
OUT="$(FM_MSYNC_EXTRACT_FILE="$WORK/extract.json" run --slot 2026-07-06/morning --dry-run 2>&1)"
# AUTONOMOUS: unstated-owner create (David), David comment, David own-ticket state
chk "unstated create -> autonomous David"    "grep -A6 'AUTONOMOUS' <<<\"\$OUT\" | grep -q 'net-new, David'"
chk "David comment -> autonomous"            "grep -A8 'AUTONOMOUS' <<<\"\$OUT\" | grep -q 'add_comment'"
chk "David own-state -> GATED (set_state unwired)" "grep -A16 'GATED / NEEDS-DAVID' <<<\"\$OUT\" | grep -q 'ENG-200'"
# GATED: assign-another(Rixi via 'Rishi' alias), Eddie state flip, descope, Yang unresolved
chk "Rishi->Rixi create -> gated"            "grep -A14 'GATED / NEEDS-DAVID' <<<\"\$OUT\" | grep -qi 'another person'"
chk "Eddie foreign state flip -> gated"      "grep -A16 'GATED / NEEDS-DAVID' <<<\"\$OUT\" | grep -q 'ENG-201'"
chk "descope -> gated"                       "grep -A16 'GATED / NEEDS-DAVID' <<<\"\$OUT\" | grep -q 'descope'"
chk "Yang unresolved owner -> gated"         "grep -A16 'GATED / NEEDS-DAVID' <<<\"\$OUT\" | grep -qi 'unresolved'"
# NARRATIVE: MVP_DEADLINE is HARD STOP; standing decision is GATED; neither applied
chk "MVP_DEADLINE narrative -> HARD STOP"    "grep -A4 'NARRATIVE' <<<\"\$OUT\" | grep -q 'HARD STOP'"
chk "standing decision narrative surfaced"   "grep -q 'adopt monorepo' <<<\"\$OUT\""
chk "narrative summary count >= 2"           "grep -q 'narrative=2' <<<\"\$OUT\""

# === 3. THE invariant: content.ts never written; autonomous tier lands via the
#        mock wrappers; narrative + gated go to the board -----------------------
rm -f "$WORK/board.log" "$WORK/linear.log" "$WORK/reconcile.log" "$WORK/audit.log"
FM_MSYNC_STATE_DIR="$WORK/state" FM_MSYNC_ROSTER_FILE="$WORK/roster.md" \
FM_MSYNC_BOARD_REPLY_BIN="$WORK/board-reply.sh" FM_MSYNC_LINEAR_BIN="$WORK/linear.sh" \
FM_MSYNC_RECONCILE_BIN="$WORK/reconcile.sh" FM_MSYNC_AUDIT_BIN="$WORK/audit.sh" \
FM_MSYNC_GFETCH_BIN="$GF_ABSENT" \
FM_MSYNC_EXTRACT_FILE="$WORK/extract.json" FM_MSYNC_NOW="2026-07-06T20:00:00Z" \
  "$BIN" --slot 2026-07-06/morning --apply >/dev/null 2>&1
chk "apply posts to the board (--your-court)" "grep -q 'your-court' \"$WORK/board.log\""
chk "board post targets tracker-sync item"    "grep -q 'item=tracker-sync' \"$WORK/board.log\""
chk "apply lands the autonomous David comment" "grep -q 'add_comment ENG-210' \"$WORK/linear.log\""
chk "apply comment carries the [sync:slot] marker" "grep -q 'sync:2026-07-06/morning' \"$WORK/linear.log\""
chk "apply runs reconcile --apply for tracker"  "grep -q 'RECONCILE_CALLED --apply' \"$WORK/reconcile.log\""
chk "apply does NOT flip a foreign ticket (ENG-201 gated)" "! grep -q 'ENG-201' \"$WORK/linear.log\""
chk "apply audits the comment write"            "grep -q 'AUDIT_CALLED append' \"$WORK/audit.log\""
# the orchestrator writes no source file anywhere under the repo tree
chk "no content.ts written by the run"        "! find \"$WORK\" -name content.ts | grep -q ."

# === 4. backfill gap-scan ===================================================
OUT="$(FM_MSYNC_NOW='2026-07-06T20:00:00Z' FM_MSYNC_STATE_DIR="$WORK/s2" \
      FM_MSYNC_GFETCH_BIN="$GF_ABSENT" FM_MSYNC_RECONCILE_BIN="$WORK/reconcile.sh" \
      FM_MSYNC_ROSTER_FILE="$WORK/roster.md" "$BIN" --slot 2026-07-06/eod --lookback 3 --dry-run 2>&1)"
chk "backfill lists an earlier unrecorded slot" "grep -q '2026-07-03/morning' <<<\"\$OUT\""
chk "backfill excludes the target slot itself"  "! grep -A40 'backfill gap-scan' <<<\"\$OUT\" | grep -q '2026-07-06/eod'"
OUT="$(FM_MSYNC_STATE_DIR="$WORK/s2" FM_MSYNC_ROSTER_FILE="$WORK/roster.md" \
      FM_MSYNC_GFETCH_BIN="$GF_ABSENT" FM_MSYNC_RECONCILE_BIN="$WORK/reconcile.sh" \
      "$BIN" --slot 2026-07-06/eod --no-backfill --dry-run 2>&1)"
chk "--no-backfill suppresses the scan"         "grep -q 'no unrecorded slot' <<<\"\$OUT\""

# === 5. reconcile slot skips the meeting fetch (degenerate case) ============
OUT="$(run --slot 2026-07-06/reconcile --dry-run 2>&1)"; RC=$?
chk "reconcile slot does not degrade to fetch" "[ $RC -ne 3 ]"
chk "reconcile slot notes it skips B-D"        "grep -q 'skips B-D' <<<\"\$OUT\""

# === 6b. idempotency: a second --apply of the SAME slot re-applies NOTHING ===
# (regression guard for the blocking finding: two --apply runs duplicated every
#  create_issue/add_comment because slot state was never persisted.)
IDEM_ENV=(FM_MSYNC_STATE_DIR="$WORK/idem" FM_MSYNC_ROSTER_FILE="$WORK/roster.md"
          FM_MSYNC_BOARD_REPLY_BIN="$WORK/board-reply.sh" FM_MSYNC_LINEAR_BIN="$WORK/linear.sh"
          FM_MSYNC_RECONCILE_BIN="$WORK/reconcile.sh" FM_MSYNC_AUDIT_BIN="$WORK/audit.sh"
          FM_MSYNC_GFETCH_BIN="$GF_ABSENT"
          FM_MSYNC_EXTRACT_FILE="$WORK/extract.json" FM_MSYNC_NOW="2026-07-06T20:00:00Z")
rm -f "$WORK/linear.log" "$WORK/reconcile.log"
env "${IDEM_ENV[@]}" "$BIN" --slot 2026-07-06/morning --apply >/dev/null 2>&1
N1_LIN=$(wc -l < "$WORK/linear.log" | tr -d ' ')
# count only reconcile WRITES (--apply); the Stage E --dry-run reflect is a read
# that runs every pass and is not an idempotency concern.
N1_REC=$(grep -c 'RECONCILE_CALLED --apply' "$WORK/reconcile.log")
chk "run1 made Linear writes"                 "[ \"$N1_LIN\" -ge 2 ]"
chk "run1 persisted state.json"               "[ -f \"$WORK/idem/state.json\" ]"
chk "run1 recorded the comment in writeSet"   "grep -q 'comment:ENG-210' \"$WORK/idem/state.json\""
chk "run1 recorded slot outcome complete"     "grep -q '\"outcome\": \"complete\"' \"$WORK/idem/state.json\""
chk "run1 comment body has no doubled label"  "! grep -q 'meeting-context: meeting-context' \"$WORK/linear.log\""
chk "run1 comment body has no literal <slot>" "! grep -q '<slot>' \"$WORK/linear.log\""
# shellcheck disable=SC2034  # OUT2 is consumed by the chk evals below via <<<"$OUT2"
OUT2="$(env "${IDEM_ENV[@]}" "$BIN" --slot 2026-07-06/morning --apply 2>&1)"
N2_LIN=$(wc -l < "$WORK/linear.log" | tr -d ' ')
N2_REC=$(grep -c 'RECONCILE_CALLED --apply' "$WORK/reconcile.log")
chk "run2 adds ZERO new Linear writes"        "[ \"$N2_LIN\" -eq \"$N1_LIN\" ]"
chk "run2 adds ZERO new reconcile applies"    "[ \"$N2_REC\" -eq \"$N1_REC\" ]"
chk "run2 reports the idempotent skip"        "grep -qi 'idempotent' <<<\"\$OUT2\""
# a completed slot is no longer re-listed by a later backfill gap-scan
# shellcheck disable=SC2034  # OUT3 is consumed by the chk eval below via <<<"$OUT3"
OUT3="$(env "${IDEM_ENV[@]}" "$BIN" --slot 2026-07-07/eod --lookback 5 --dry-run 2>&1)"
chk "completed slot dropped from backfill"    "! grep -A40 'backfill gap-scan' <<<\"\$OUT3\" | grep -q '2026-07-06/morning'"

# === 6c. dry-run persists NOTHING (state dir stays absent) ==================
rm -rf "$WORK/dryonly"
env FM_MSYNC_STATE_DIR="$WORK/dryonly" FM_MSYNC_ROSTER_FILE="$WORK/roster.md" \
    FM_MSYNC_GFETCH_BIN="$GF_ABSENT" FM_MSYNC_RECONCILE_BIN="$WORK/reconcile.sh" \
    FM_MSYNC_EXTRACT_FILE="$WORK/extract.json" FM_MSYNC_NOW="2026-07-06T20:00:00Z" \
    "$BIN" --slot 2026-07-06/morning --dry-run >/dev/null 2>&1
chk "dry-run writes no state dir"             "[ ! -e \"$WORK/dryonly\" ]"

# === 6d. REMOTE idempotency guard: the crash window (the MEDIUM finding) =====
# Simulate a crash BETWEEN the remote Linear write and the local ledger flush:
# the [sync:<slot>] comment is already ON the remote issue (and a prior
# self-assigned ticket is already on the remote) but the persisted writeSet is
# empty. A re-run must READ the remote (get_issue / list_issues), detect the
# marker, and re-apply NOTHING (no duplicate comment, no duplicate ticket),
# backfilling the ledger from the remote. The local ledger alone cannot guard
# this window; the durable remote can.
rm -rf "$WORK/crash"; mkdir -p "$WORK/crash/mock-remote"
printf '[sync:2026-07-06/morning] meeting-context: prior landed comment @00:10:00\n' \
  > "$WORK/crash/mock-remote/ENG-210.comments"
printf 'create_issue --title new mesh exporter --description [sync:2026-07-06/morning] ...\n' \
  > "$WORK/crash/mock-remote/issues.txt"
rm -f "$WORK/linear.log"
CRASH_ENV=(FM_MSYNC_STATE_DIR="$WORK/crash" FM_MSYNC_ROSTER_FILE="$WORK/roster.md"
           FM_MSYNC_BOARD_REPLY_BIN="$WORK/board-reply.sh" FM_MSYNC_LINEAR_BIN="$WORK/linear.sh"
           FM_MSYNC_RECONCILE_BIN="$WORK/reconcile.sh" FM_MSYNC_AUDIT_BIN="$WORK/audit.sh"
           FM_MSYNC_GFETCH_BIN="$GF_ABSENT"
           FM_MSYNC_EXTRACT_FILE="$WORK/extract.json" FM_MSYNC_NOW="2026-07-06T20:00:00Z")
# shellcheck disable=SC2034  # OUT4 consumed by the chk evals below via <<<"$OUT4"
OUT4="$(env "${CRASH_ENV[@]}" "$BIN" --slot 2026-07-06/morning --apply 2>&1)"
chk "crash re-run READS the remote issue"       "grep -q 'get_issue ENG-210' \"$WORK/linear.log\""
chk "crash re-run does NOT duplicate the comment" "! grep -q 'add_comment ENG-210' \"$WORK/linear.log\""
chk "crash re-run searches before create"        "grep -q 'list_issues' \"$WORK/linear.log\""
chk "crash re-run does NOT duplicate the create"  "! grep -q 'LINEAR_CALLED create_issue' \"$WORK/linear.log\""
chk "crash re-run surfaces the remote-detected skip" "grep -qi 'remote-detected' <<<\"\$OUT4\""
chk "crash re-run backfills the ledger from remote"  "grep -q 'comment:ENG-210' \"$WORK/crash/state.json\""

# === 6e. concurrency lock: a held apply lock refuses to double-apply ========
rm -rf "$WORK/lk"; mkdir -p "$WORK/lk/apply.lock"
# shellcheck disable=SC2034
LK_OUT="$(env FM_MSYNC_STATE_DIR="$WORK/lk" FM_MSYNC_ROSTER_FILE="$WORK/roster.md" \
  FM_MSYNC_LINEAR_BIN="$WORK/linear.sh" FM_MSYNC_RECONCILE_BIN="$WORK/reconcile.sh" \
  FM_MSYNC_AUDIT_BIN="$WORK/audit.sh" FM_MSYNC_EXTRACT_FILE="$WORK/extract.json" \
  FM_MSYNC_NOW="2026-07-06T20:00:00Z" "$BIN" --slot 2026-07-06/morning --apply 2>&1)"
chk "held lock refuses to double-apply"       "grep -qi 'holds the lock' <<<\"\$LK_OUT\""
chk "held lock lands NO Linear write"          "[ ! -f \"$WORK/lk/mock-remote/ENG-210.comments\" ]"
chk "held lock does not finalize the slot"     "[ ! -f \"$WORK/lk/state.json\" ] || ! grep -q '\"outcome\": \"complete\"' \"$WORK/lk/state.json\""
# a STALE lock (older than the steal threshold) is reclaimed, never a deadlock.
touch -t 200001010000 "$WORK/lk/apply.lock"
# shellcheck disable=SC2034
STALE_OUT="$(env FM_MSYNC_STATE_DIR="$WORK/lk" FM_MSYNC_ROSTER_FILE="$WORK/roster.md" \
  FM_MSYNC_LINEAR_BIN="$WORK/linear.sh" FM_MSYNC_RECONCILE_BIN="$WORK/reconcile.sh" \
  FM_MSYNC_AUDIT_BIN="$WORK/audit.sh" FM_MSYNC_EXTRACT_FILE="$WORK/extract.json" \
  FM_MSYNC_LOCK_STALE_SEC=60 FM_MSYNC_NOW="2026-07-06T20:00:00Z" \
  "$BIN" --slot 2026-07-06/morning --apply 2>&1)"
chk "stale lock is stolen, not a deadlock"    "grep -qi 'stale' <<<\"\$STALE_OUT\""

# === 7. THE SCHEDULED PATH (--propose): real fetch + real extract, up to the
#         proposal, applying NOTHING (the cadence never auto-applies) ==========
rm -f "$WORK/board.log" "$WORK/linear.log" "$WORK/reconcile.log" "$WORK/extract.log" "$WORK/gfetch.log"
PROP_ENV=(FM_MSYNC_STATE_DIR="$WORK/prop" FM_MSYNC_ROSTER_FILE="$WORK/roster.md"
          FM_MSYNC_BOARD_REPLY_BIN="$WORK/board-reply.sh" FM_MSYNC_LINEAR_BIN="$WORK/linear.sh"
          FM_MSYNC_RECONCILE_BIN="$WORK/reconcile.sh" FM_MSYNC_AUDIT_BIN="$WORK/audit.sh"
          FM_MSYNC_GFETCH_BIN="$WORK/gfetch.sh" FM_MSYNC_EXTRACT_BIN="$WORK/extractor.sh"
          FM_MSYNC_NOW="2026-07-06T20:00:00Z")
# shellcheck disable=SC2034  # POUT consumed by the chk evals below via <<<"$POUT"
POUT="$(env "${PROP_ENV[@]}" "$BIN" --slot 2026-07-06/morning --propose 2>&1)"; PRC=$?
chk "propose exits 0 on success"                "[ $PRC -eq 0 ]"
chk "propose fetches the slot docs (Stage A)"   "grep -q 'GFETCH_CALLED files' \"$WORK/gfetch.log\""
chk "propose reads the in-window doc text"      "grep -q 'GFETCH_CALLED doc doc-1' \"$WORK/gfetch.log\""
chk "propose excludes the out-of-window doc"    "! grep -q 'doc doc-old' \"$WORK/gfetch.log\""
chk "propose runs the Stage B extractor"        "grep -q 'EXTRACT_CALLED --slot 2026-07-06/morning' \"$WORK/extract.log\""
chk "propose builds the classified change list" "grep -q 'net-new, David' <<<\"\$POUT\""
chk "propose posts the proposal (--your-court)" "grep -q 'okay to apply' \"$WORK/board.log\""
chk "proposal post targets tracker-sync"        "grep -q 'item=tracker-sync' \"$WORK/board.log\""
chk "proposal post is your-court"               "grep -q 'your-court' \"$WORK/board.log\""
chk "propose persists the extraction proposal"  "[ -f \"$WORK/prop/proposals/2026-07-06-morning.extract.json\" ]"
chk "propose persists the full change-list"     "[ -f \"$WORK/prop/proposals/2026-07-06-morning.changelist.txt\" ]"
chk "propose applies NO Linear write"           "[ ! -s \"$WORK/linear.log\" ]"
chk "propose runs NO reconcile --apply"         "! grep -q 'RECONCILE_CALLED --apply' \"$WORK/reconcile.log\" 2>/dev/null"
chk "propose does not mark the slot complete"   "! grep -q '\"outcome\": \"complete\"' \"$WORK/prop/state.json\""
# a re-fire of the same slot with an unchanged change-list posts NOTHING new
env "${PROP_ENV[@]}" "$BIN" --slot 2026-07-06/morning --propose >/dev/null 2>&1
N_PROP=$(grep -c 'okay to apply' "$WORK/board.log")
chk "unchanged proposal is not re-posted"       "[ \"$N_PROP\" -eq 1 ]"
# the re-fire reuses the persisted extraction instead of re-running the LLM
N_EXTRACT=$(grep -c 'EXTRACT_CALLED' "$WORK/extract.log")
chk "re-fire reuses the persisted extraction"   "[ \"$N_EXTRACT\" -eq 1 ]"
# a reconcile / empty slot posts NO daily proposal (no your-court spam)
N_BOARD=$(wc -l < "$WORK/board.log" | tr -d ' ')
env "${PROP_ENV[@]}" "$BIN" --slot 2026-07-06/reconcile --propose >/dev/null 2>&1; RRC=$?
N_BOARD_AFTER=$(wc -l < "$WORK/board.log" | tr -d ' ')
chk "reconcile-slot propose exits 0"            "[ $RRC -eq 0 ]"
chk "reconcile-slot propose posts nothing"      "[ \"$N_BOARD_AFTER\" -eq \"$N_BOARD\" ]"
# the persisted proposal feeds the human-okayed apply (the tracker-sync gate)
rm -f "$WORK/linear.log"
env "${PROP_ENV[@]}" FM_MSYNC_EXTRACT_FILE="$WORK/prop/proposals/2026-07-06-morning.extract.json" \
    "$BIN" --slot 2026-07-06/morning --apply >/dev/null 2>&1
chk "okayed apply from the persisted proposal lands" "grep -q 'add_comment ENG-210' \"$WORK/linear.log\""
# once applied (complete), a propose re-fire never re-proposes
N_BOARD=$(wc -l < "$WORK/board.log" | tr -d ' ')
env "${PROP_ENV[@]}" "$BIN" --slot 2026-07-06/morning --propose >/dev/null 2>&1
N_BOARD_AFTER=$(wc -l < "$WORK/board.log" | tr -d ' ')
chk "a completed slot is never re-proposed"     "[ \"$N_BOARD_AFTER\" -eq \"$N_BOARD\" ]"

# === 8. SILENT DEGRADE fixed: a failed fetch posts ONE loud board line per slot
rm -f "$WORK/board.log"
DEG_ENV=(FM_MSYNC_STATE_DIR="$WORK/deg" FM_MSYNC_ROSTER_FILE="$WORK/roster.md"
         FM_MSYNC_BOARD_REPLY_BIN="$WORK/board-reply.sh" FM_MSYNC_LINEAR_BIN="$WORK/linear.sh"
         FM_MSYNC_RECONCILE_BIN="$WORK/reconcile.sh" FM_MSYNC_GFETCH_BIN="$GF_ABSENT"
         FM_MSYNC_NOW="2026-07-06T20:00:00Z")
env "${DEG_ENV[@]}" "$BIN" --slot 2026-07-06/morning --propose >/dev/null 2>&1; DRC=$?
chk "degraded propose still exits 3"            "[ $DRC -eq 3 ]"
chk "degrade posts the loud board line"         "grep -q 'could not fetch the 2026-07-06/morning notes' \"$WORK/board.log\""
chk "degrade line says what to do"              "grep -q 'paste them or fix the credential' \"$WORK/board.log\""
chk "degrade post is your-court"                "grep -q 'your-court' \"$WORK/board.log\""
chk "degrade is recorded for dedupe"            "grep -q 'degradePosts' \"$WORK/deg/state.json\""
# a second failing fire of the SAME slot does not spam (one post per slot)
env "${DEG_ENV[@]}" "$BIN" --slot 2026-07-06/morning --propose >/dev/null 2>&1
N_DEG=$(grep -c 'could not fetch the 2026-07-06/morning notes' "$WORK/board.log")
chk "repeated degrade posts once per slot"      "[ \"$N_DEG\" -eq 1 ]"
# a DIFFERENT slot's degrade still posts (dedupe is per slot, not global)
env "${DEG_ENV[@]}" "$BIN" --slot 2026-07-06/eod --propose >/dev/null 2>&1
chk "a different slot's degrade still posts"    "grep -q 'could not fetch the 2026-07-06/eod notes' \"$WORK/board.log\""
# an unavailable Stage B extractor degrades loudly too (exit 3, board line)
rm -f "$WORK/board.log"
env FM_MSYNC_STATE_DIR="$WORK/deg2" FM_MSYNC_ROSTER_FILE="$WORK/roster.md" \
    FM_MSYNC_BOARD_REPLY_BIN="$WORK/board-reply.sh" FM_MSYNC_RECONCILE_BIN="$WORK/reconcile.sh" \
    FM_MSYNC_GFETCH_BIN="$WORK/gfetch.sh" FM_MSYNC_EXTRACT_BIN="$WORK/absent-extractor" \
    FM_MSYNC_NOW="2026-07-06T20:00:00Z" \
    "$BIN" --slot 2026-07-06/morning --propose >/dev/null 2>&1; XRC=$?
chk "missing extractor degrades with exit 3"    "[ $XRC -eq 3 ]"
chk "missing extractor posts the loud line"     "grep -q 'extractor' \"$WORK/board.log\""

# === 9. an EXPLICIT --dry-run still touches nothing (flag honored) ===========
rm -f "$WORK/board.log" "$WORK/linear.log"
rm -rf "$WORK/dry2"
env FM_MSYNC_STATE_DIR="$WORK/dry2" FM_MSYNC_ROSTER_FILE="$WORK/roster.md" \
    FM_MSYNC_BOARD_REPLY_BIN="$WORK/board-reply.sh" FM_MSYNC_LINEAR_BIN="$WORK/linear.sh" \
    FM_MSYNC_RECONCILE_BIN="$WORK/reconcile.sh" FM_MSYNC_GFETCH_BIN="$WORK/gfetch.sh" \
    FM_MSYNC_EXTRACT_BIN="$WORK/extractor.sh" FM_MSYNC_NOW="2026-07-06T20:00:00Z" \
    "$BIN" --slot 2026-07-06/morning --dry-run >/dev/null 2>&1
chk "explicit dry-run posts nothing"            "[ ! -s \"$WORK/board.log\" ]"
chk "explicit dry-run writes no state"          "[ ! -e \"$WORK/dry2\" ]"
chk "explicit dry-run lands no Linear write"    "[ ! -s \"$WORK/linear.log\" ]"

# === 10. the scheduled path can NEVER auto-apply (FM_MSYNC_SCHEDULED guard) ===
rm -f "$WORK/linear.log"
env FM_MSYNC_SCHEDULED=1 FM_MSYNC_STATE_DIR="$WORK/sched" FM_MSYNC_ROSTER_FILE="$WORK/roster.md" \
    FM_MSYNC_LINEAR_BIN="$WORK/linear.sh" FM_MSYNC_RECONCILE_BIN="$WORK/reconcile.sh" \
    FM_MSYNC_GFETCH_BIN="$GF_ABSENT" FM_MSYNC_EXTRACT_FILE="$WORK/extract.json" \
    FM_MSYNC_NOW="2026-07-06T20:00:00Z" \
    "$BIN" --slot 2026-07-06/morning --apply >/dev/null 2>"$WORK/sched.err"; SRC=$?
chk "scheduled --apply is rejected (exit 2)"    "[ $SRC -eq 2 ]"
chk "scheduled --apply names the rule"          "grep -q 'never auto-applies' \"$WORK/sched.err\""
chk "scheduled --apply lands NO write"          "[ ! -s \"$WORK/linear.log\" ]"

# === 6. usage + schedule surface ============================================
"$BIN" --slot bad-slot --dry-run >/dev/null 2>&1; chk "bad slot -> usage error" "[ $? -ne 0 ]"
# shellcheck disable=SC2034  # OUT is consumed by the chk evals below via <<<"$OUT"
OUT="$("$BIN" install-schedule 2>&1)"
chk "install-schedule pins America/Los_Angeles" "grep -q 'America/Los_Angeles' <<<\"\$OUT\""
chk "install-schedule installs nothing"         "grep -q 'NOT INSTALLED' <<<\"\$OUT\""
chk "install-schedule lists the 3 cadence fires" "[ \$(grep -c 'fm-meeting-sync.sh --slot' <<<\"\$OUT\") -ge 3 ]"

echo "----"
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]

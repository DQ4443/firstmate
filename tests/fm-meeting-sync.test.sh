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

# --- mock sibling binaries that record invocations (NEVER touch real Linear) --
cat > "$WORK/board-reply.sh" <<MOCK
#!/usr/bin/env bash
echo "BOARD_REPLY_CALLED item=\$1 args=\${*:3}" >> "$WORK/board.log"
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
chmod +x "$WORK/board-reply.sh" "$WORK/linear.sh" "$WORK/reconcile.sh" "$WORK/audit.sh"

run() {
  FM_MSYNC_STATE_DIR="$WORK/state" \
  FM_MSYNC_ROSTER_FILE="$WORK/roster.md" \
  FM_MSYNC_BOARD_REPLY_BIN="$WORK/board-reply.sh" \
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
      FM_MSYNC_ROSTER_FILE="$WORK/roster.md" "$BIN" --slot 2026-07-06/eod --lookback 3 --dry-run 2>&1)"
chk "backfill lists an earlier unrecorded slot" "grep -q '2026-07-03/morning' <<<\"\$OUT\""
chk "backfill excludes the target slot itself"  "! grep -A40 'backfill gap-scan' <<<\"\$OUT\" | grep -q '2026-07-06/eod'"
OUT="$(FM_MSYNC_STATE_DIR="$WORK/s2" FM_MSYNC_ROSTER_FILE="$WORK/roster.md" \
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

#!/usr/bin/env bash
# Hermetic tests for bin/fm-reconcile.sh (meeting-sync Phase 1 reconcile).
#
# No network: the reconcile is fed fixture files through its documented DI hooks
# (FM_RECONCILE_MODEL_FILE / _LINEAR_FILE / _RELATIONS_FILE / _PR_FILE), so every
# pinned mapping (status/group/blocked/edge/soft-retire), the drift-hold, the
# skip set, the tiering, and the "zero Linear writes / audit reachable"
# acceptance invariants are checked deterministically and offline.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(dirname "$HERE")"
BIN="$REPO/bin/fm-reconcile.sh"
AUDIT="$REPO/bin/fm-sync-audit.sh"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
PASS=0 FAIL=0
ok()   { PASS=$((PASS+1)); printf 'ok   %s\n' "$1"; }
bad()  { FAIL=$((FAIL+1)); printf 'FAIL %s\n' "$1"; }
chk()  { if eval "$2"; then ok "$1"; else bad "$1 :: $2"; fi; }

# --- fixtures --------------------------------------------------------------
cat > "$WORK/model.json" <<'JSON'
{
  "masterList": [
    {"num": 1, "itemHtml": "ENG-100 alpha widget rendering pipeline", "ownerHtml": "David", "group": "active"},
    {"num": 2, "itemHtml": "ENG-102 beta ingest worker", "ownerHtml": "Rixi", "group": "active"},
    {"num": 3, "itemHtml": "ENG-205 gamma queue consumer", "ownerHtml": "Nate", "group": "active"},
    {"num": 7, "itemHtml": "ENG-103 zeta live progress item", "ownerHtml": "Rixi", "group": "active"},
    {"num": 4, "itemHtml": "ENG-101 delta agent prompt loop", "ownerHtml": "Eddie", "group": "active"},
    {"num": 5, "itemHtml": "ENG-252 narrower-scope drift item", "ownerHtml": "David", "group": "active"},
    {"num": 6, "itemHtml": "epsilon untagged coherent narrative serif font rewrite", "ownerHtml": "Eddie", "group": "active"}
  ],
  "graph": {
    "clusters": [{"id": "optics", "label": "Optics"}, {"id": "agent", "label": "Agent"}, {"id": "frontend", "label": "Frontend"}],
    "nodes": [
      {"id": "n100", "bold": "ENG-100", "desc": "alpha", "owner": "David", "cluster": "frontend", "status": "working"},
      {"id": "n102", "bold": "ENG-102", "desc": "beta", "owner": "Rixi", "cluster": "agent", "status": "working"},
      {"id": "n205", "bold": "ENG-205", "desc": "gamma", "owner": "Nate", "cluster": "agent", "status": "queued"},
      {"id": "n103", "bold": "ENG-103", "desc": "zeta", "owner": "Rixi", "cluster": "agent", "status": "queued"},
      {"id": "n201", "bold": "ENG-201", "desc": "blocker", "owner": "David", "cluster": "optics", "status": "done"},
      {"id": "n252", "bold": "ENG-252", "desc": "drift", "owner": "David", "cluster": "optics", "status": "done"}
    ],
    "edges": [
      {"from": "n201", "to": "n205", "kind": "formal"}
    ]
  }
}
JSON

cat > "$WORK/linear.json" <<'JSON'
{"issues": [
  {"id": "ENG-100", "title": "alpha widget rendering pipeline", "status": "Done", "statusType": "completed", "assignee": "David", "cycleId": "c1"},
  {"id": "ENG-102", "title": "beta ingest worker", "status": "In Progress", "statusType": "started", "assignee": "Rixi", "startedAt": "2099-01-01T00:00:00.000Z", "updatedAt": "2099-01-01T00:00:00.000Z"},
  {"id": "ENG-205", "title": "gamma queue consumer", "status": "In Progress", "statusType": "started", "assignee": "Nate", "startedAt": "2099-01-01T00:00:00.000Z"},
  {"id": "ENG-101", "title": "delta agent prompt loop", "status": "Backlog", "statusType": "backlog", "assignee": "Eddie", "cycleId": "c1"},
  {"id": "ENG-103", "title": "zeta live progress item", "status": "In Progress", "statusType": "started", "assignee": "Rixi", "startedAt": "2099-01-01T00:00:00.000Z"},
  {"id": "ENG-252", "title": "narrower-scope drift item", "status": "In Progress", "statusType": "started", "assignee": "David"},
  {"id": "ENG-201", "title": "blocker done", "status": "Done", "statusType": "completed", "assignee": "David"},
  {"id": "ENG-777", "title": "brand new frontend display widget with no row yet", "status": "In Progress", "statusType": "started", "assignee": "Eddie", "startedAt": "2099-01-01T00:00:00.000Z"},
  {"id": "ENG-999", "title": "SapSim non-mvp research spike", "status": "In Progress", "statusType": "started", "assignee": "Francis", "startedAt": "2099-01-01T00:00:00.000Z"}
]}
JSON

# ENG-205 blocked by ENG-204 (not done) -> blocked. ENG-100 blocked by ENG-201
# (done) with NO existing edge -> add_edge. The n201->n205 edge's Linear relation
# is gone and ENG-201 is Done -> soft-retire proposal.
cat > "$WORK/relations.json" <<'JSON'
{
  "ENG-100": {"blocks": [], "blockedBy": [{"id": "ENG-201", "title": "blocker"}]},
  "ENG-205": {"blocks": [], "blockedBy": [{"id": "ENG-204", "title": "unresolved"}]},
  "ENG-102": {"blocks": [], "blockedBy": []},
  "ENG-103": {"blocks": [], "blockedBy": [{"id": "ENG-102", "title": "beta"}]},
  "ENG-201": {"blocks": [], "blockedBy": []}
}
JSON

# ENG-102 has a merged PR -> node should go to done even though Linear=In Progress.
cat > "$WORK/prs.json" <<'JSON'
[
  {"number": 1, "title": "feat: beta worker", "headRefName": "eng-102-beta-ingest", "state": "MERGED", "mergedAt": "2026-07-01T00:00:00Z"},
  {"number": 2, "title": "wip alpha", "headRefName": "eng-100-alpha", "state": "OPEN", "mergedAt": null}
]
JSON

run() {
  FM_RECONCILE_MODEL_FILE="$WORK/model.json" \
  FM_RECONCILE_LINEAR_FILE="$WORK/linear.json" \
  FM_RECONCILE_RELATIONS_FILE="$WORK/relations.json" \
  FM_RECONCILE_PR_FILE="$WORK/prs.json" \
  FM_RECONCILE_AUDIT_BIN="$AUDIT" \
  FM_SYNC_AUDIT_DIR="$WORK/audit" \
  FM_RECONCILE_TRACKER_ENV="$WORK/nonexistent.env" \
    "$BIN" "$@"
}

# --- acceptance invariants -------------------------------------------------
OUT="$(run --dry-run 2>&1)"; RC=$?
printf '%s\n' "$OUT" > "$WORK/out.txt"

chk "dry-run exits 0"                       "[ $RC -eq 0 ]"
chk "prints a change-list"                  "grep -qE 'change-list|would' \"$WORK/out.txt\""
chk "ZERO Linear write verbs in output"     "! grep -qiE 'save_issue|create_issue|update_issue' \"$WORK/out.txt\""
chk "dry-run states zero writes"            "grep -qi 'zero Linear writes' \"$WORK/out.txt\""

# --- pinned status mapping -------------------------------------------------
chk "Done -> node done (ENG-100)"           "grep -q 'set_node_status ENG-100 working -> done' \"$WORK/out.txt\""
chk "Done -> group done (ENG-100)"          "grep -q 'move_group ENG-100 active -> done' \"$WORK/out.txt\""
chk "merged PR -> done (ENG-102)"           "grep -qE 'set_node_status ENG-102 working -> done.*merged PR observed' \"$WORK/out.txt\""
chk "In Progress+recent -> working (ENG-103)" "grep -qE 'set_node_status ENG-103 queued -> working.*recent activity' \"$WORK/out.txt\""
chk "blocked signal -> blocked (ENG-205)"   "grep -qE 'set_node_status ENG-205 queued -> blocked.*open blocked-by ENG-204' \"$WORK/out.txt\""
# blocked-by a merged-but-not-Done issue (ENG-102) is NOT blocked: done-detection
# matches the classifier (status Done OR completed OR merged PR), never bare status.
chk "merged-PR blocker not treated as open (ENG-103)" \
  "grep -qE 'set_node_status ENG-103 queued -> working' \"$WORK/out.txt\" && ! grep -qE 'ENG-103 .*-> blocked' \"$WORK/out.txt\""

# --- add_node / add_edge with type+cluster ---------------------------------
chk "add_node only with existing row (ENG-101)" "grep -qE 'add_node ENG-101 .*node n101 in agent' \"$WORK/out.txt\""
chk "add_edge formal from Linear rel (ENG-100)" "grep -qE 'add_edge ENG-201->ENG-100 .*edge n201->n100 .formal.' \"$WORK/out.txt\""

# --- soft-retire is a PROPOSAL, never autonomous (no tracker retire op) -----
chk "soft-retire is NEEDS-DAVID not autonomous" \
  "awk '/NEEDS-DAVID/{d=1} /DRIFT-HOLD/{d=0} d&&/soft_retire_edge ENG-201->ENG-205/{f=1} END{exit !f}' \"$WORK/out.txt\""
chk "soft-retire NOT in autonomous tier" \
  "awk '/AUTONOMOUS tracker/{a=1} /NEEDS-DAVID/{a=0} a&&/soft_retire/{f=1} END{exit f}' \"$WORK/out.txt\""

# --- drift-hold preserved (open Q4) ----------------------------------------
chk "ENG-252 is DRIFT-HOLD, not moved" \
  "awk '/DRIFT-HOLD/{d=1} /NOTES/{d=0} d&&/ENG-252/{f=1} END{exit !f}' \"$WORK/out.txt\""
chk "no autonomous op touches ENG-252" \
  "awk '/AUTONOMOUS tracker/{a=1} /NEEDS-DAVID/{a=0} a&&/ENG-252/{f=1} END{exit f}' \"$WORK/out.txt\""

# --- skip set --------------------------------------------------------------
chk "skip-set drops SapSim research (ENG-999)" \
  "! grep -qE '(move_group|set_node_status|add_node) ENG-999' \"$WORK/out.txt\" && grep -q 'ENG-999 skipped' \"$WORK/out.txt\""

# --- coverage gap gated, not auto (ENG-777: no row, no node) ----------------
chk "no-row ticket is NEEDS-DAVID add_master_row (ENG-777)" \
  "awk '/NEEDS-DAVID/{d=1} /DRIFT-HOLD/{d=0} d&&/add_master_row ENG-777/{f=1} END{exit !f}' \"$WORK/out.txt\""
chk "no autonomous add_node for a rowless ticket (ENG-777)" \
  "awk '/AUTONOMOUS tracker/{a=1} /NEEDS-DAVID/{a=0} a&&/add_node ENG-777/{f=1} END{exit f}' \"$WORK/out.txt\""

# --- audit substrate reachable + empty on a dry run ------------------------
AUD="$(FM_SYNC_AUDIT_DIR="$WORK/audit" "$AUDIT" read "$(date +%F)/reconcile" 2>/dev/null)"
chk "audit read returns a JSON array"       "printf '%s' \"$AUD\" | jq -e 'length>=0' >/dev/null"
chk "dry-run wrote nothing to the audit log" "printf '%s' \"$AUD\" | jq -e 'length==0' >/dev/null"

# --- apply without EDIT_PASSWORD refuses cleanly (exit 3), still no writes ---
run --apply >/dev/null 2>&1; ARC=$?
chk "apply without EDIT_PASSWORD exits 3"   "[ $ARC -eq 3 ]"
chk "apply refusal wrote nothing to audit"  \
  "printf '%s' \"$(FM_SYNC_AUDIT_DIR="$WORK/audit" "$AUDIT" read "$(date +%F)/reconcile" 2>/dev/null)\" | jq -e 'length==0' >/dev/null"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]

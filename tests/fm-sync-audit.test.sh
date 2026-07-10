#!/usr/bin/env bash
# tests/fm-sync-audit.test.sh - behavior test for bin/fm-sync-audit.sh, the
# append-only per-write audit-log substrate (meeting-sync-design.md 9a/9b).
#
# Fully offline and hermetic: FM_SYNC_AUDIT_DIR points at a throwaway temp dir,
# so the suite never touches the real data/meeting-sync-audit logs. It exercises
# the whole contract every later sync phase and the reverse-run rollback lean
# on: append writes one crash-correct line per op, read returns a JSON array
# oldest-first, read --newest-first reverses it for rollback, the secret guard
# refuses to log a credential, slot ids that would escape the log dir are
# rejected, and a torn trailing line is tolerated on read.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN="$ROOT/bin/fm-sync-audit.sh"

TMP="$(mktemp -d "${TMPDIR:-/tmp}/fm-sync-audit.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
export FM_SYNC_AUDIT_DIR="$TMP/audit"

fail() { printf 'not ok - %s\n' "$1" >&2; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }

command -v jq >/dev/null 2>&1 || fail "jq is required for this test"

SLOT="2026-07-06/eod"

# 1. usage/exit-code contract -------------------------------------------------
"$BIN" --help >/dev/null 2>&1 || fail "--help should exit 0"
pass "--help exits 0"

"$BIN" >/dev/null 2>&1; rc=$?
[ "$rc" -eq 2 ] || fail "no args should exit 2, got $rc"
pass "no args exits 2"

"$BIN" bogus_subcommand >/dev/null 2>&1; rc=$?
[ "$rc" -eq 2 ] || fail "unknown subcommand should exit 2, got $rc"
pass "unknown subcommand exits 2"

"$BIN" append "$SLOT" ENG-1 >/dev/null 2>&1; rc=$?
[ "$rc" -eq 2 ] || fail "append missing <op> should exit 2, got $rc"
pass "append with too few args exits 2"

# 2. read of an unseen slot is an empty JSON array ----------------------------
out="$("$BIN" read never-seen-slot 2>/dev/null)" \
  || fail "read of an unseen slot should exit 0"
echo "$out" | jq -e '. == []' >/dev/null \
  || fail "read of an unseen slot should print []"
pass "read of an unseen slot prints an empty array"

# 3. the design's acceptance case: one append, then read .[-1] ---------------
"$BIN" append "$SLOT" ENG-260 set_state \
  --before Todo --after Done --evidence '12:34' >/dev/null 2>&1 \
  || fail "the acceptance append should exit 0"
"$BIN" read "$SLOT" | jq -e \
  '.[-1].after=="Done" and .[-1].before=="Todo" and (.[-1].evidence|length>0)' \
  >/dev/null || fail "acceptance: last entry must carry before/after/evidence"
"$BIN" read "$SLOT" | jq -e \
  '.[-1].target=="ENG-260" and .[-1].op=="set_state" and .[-1].slot=="2026-07-06/eod"' \
  >/dev/null || fail "acceptance: last entry must carry target/op/slot"
"$BIN" read "$SLOT" | jq -e '.[-1].run=="2026-07-06/eod"' >/dev/null \
  || fail "run should default to the slot id"
"$BIN" read "$SLOT" | jq -e '.[-1].ts | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T")' \
  >/dev/null || fail "each entry should carry an ISO-8601 timestamp"
pass "append then read satisfies the design acceptance case"

# 4. the log file lives at data/meeting-sync-audit/<slot-id>.jsonl -----------
p="$("$BIN" path "$SLOT")"
[ "$p" = "$FM_SYNC_AUDIT_DIR/2026-07-06/eod.jsonl" ] \
  || fail "path should resolve slot id to <dir>/2026-07-06/eod.jsonl, got $p"
[ -f "$p" ] || fail "append should have created the jsonl file at $p"
[ "$(wc -l <"$p")" -eq 1 ] || fail "one append should write exactly one line"
pass "log path resolves the slot id under the audit dir"

# 5. ordering: appends accrete oldest-first; --newest-first reverses ---------
"$BIN" append "$SLOT" ENG-260 add_comment \
  --after '[sync:2026-07-06/eod]' --evidence '13:00' >/dev/null 2>&1 \
  || fail "second append should exit 0"
"$BIN" append "$SLOT" node-abc set_node_status \
  --before working --after "done" --evidence '13:05' >/dev/null 2>&1 \
  || fail "third append should exit 0"

"$BIN" read "$SLOT" | jq -e 'length == 3' >/dev/null \
  || fail "read should return all three appended entries"
# oldest-first (append order): set_state, add_comment, set_node_status
"$BIN" read "$SLOT" | jq -e \
  '[.[].op] == ["set_state","add_comment","set_node_status"]' >/dev/null \
  || fail "default read must be oldest-first (file/append order)"
# newest-first: the exact order the reverse-run rollback (9b) consumes
"$BIN" read "$SLOT" --newest-first | jq -e \
  '[.[].op] == ["set_node_status","add_comment","set_state"]' >/dev/null \
  || fail "--newest-first must reverse to newest-first for rollback"
"$BIN" read "$SLOT" --newest-first | jq -e '.[0].op == "set_node_status"' \
  >/dev/null || fail "--newest-first first element must be the newest write"
pass "read is oldest-first; --newest-first reverses for the rollback consumer"

# 6. filters ------------------------------------------------------------------
"$BIN" read "$SLOT" --target ENG-260 | jq -e 'length == 2' >/dev/null \
  || fail "--target ENG-260 should match the two ENG-260 writes"
"$BIN" read "$SLOT" --op set_node_status | jq -e \
  'length == 1 and .[0].target == "node-abc"' >/dev/null \
  || fail "--op set_node_status should match exactly the node write"
pass "--target and --op filter the read"

# 7. two slots are isolated; slots lists them --------------------------------
"$BIN" append "2026-07-06/morning" ENG-7 set_state \
  --before Backlog --after Todo --evidence '09:10' >/dev/null 2>&1 \
  || fail "append to a second slot should exit 0"
"$BIN" read "2026-07-06/morning" | jq -e 'length == 1' >/dev/null \
  || fail "the morning slot must hold only its own single write"
"$BIN" read "$SLOT" | jq -e 'length == 3' >/dev/null \
  || fail "the eod slot must be unaffected by the morning append"
"$BIN" slots | grep -qx "2026-07-06/eod" || fail "slots should list the eod slot"
"$BIN" slots | grep -qx "2026-07-06/morning" \
  || fail "slots should list the morning slot"
pass "slots are isolated per file; slots lists every logged slot"

# 8. --run records a distinct backfill run id --------------------------------
"$BIN" append "$SLOT" ENG-99 set_state \
  --before Todo --after Done --evidence '14:00' --run backfill-2026-07-08 \
  >/dev/null 2>&1 || fail "append with --run should exit 0"
"$BIN" read "$SLOT" --newest-first | jq -e '.[0].run == "backfill-2026-07-08"' \
  >/dev/null || fail "--run should record the distinct run id"
pass "--run records a backfill run distinct from the slot"

# 9. secret guard: refuse to log a value matching a sensitive env var --------
( export EDIT_PASSWORD="hunter2secret"
  "$BIN" append "$SLOT" ENG-5 set_state --after "hunter2secret" >/dev/null 2>&1
) ; rc=$?
[ "$rc" -eq 3 ] || fail "logging a value equal to EDIT_PASSWORD should exit 3, got $rc"
# ... and a Bearer header anywhere in a field
"$BIN" append "$SLOT" ENG-5 add_comment --note "Authorization: Bearer abc.def" \
  >/dev/null 2>&1; rc=$?
[ "$rc" -eq 3 ] || fail "logging a Bearer header should exit 3, got $rc"
# the refused appends must NOT have been written
"$BIN" read "$SLOT" | jq -e 'length == 4' >/dev/null \
  || fail "a refused append must not touch the log"
# the offending value must never appear in the log or the error output
errout="$(EDIT_PASSWORD="hunter2secret" "$BIN" append "$SLOT" ENG-5 set_state \
  --after "hunter2secret" 2>&1 || true)"
echo "$errout" | grep -q "hunter2secret" \
  && fail "the secret guard must not echo the offending value"
grep -rq "hunter2secret" "$FM_SYNC_AUDIT_DIR" \
  && fail "no refused secret value may reach any log file"
pass "secret guard refuses (exit 3) without echoing or writing the value"

# 10. path-traversal slot ids are rejected -----------------------------------
for bad in "../escape" "a/../../b" "/abs/slot" "." ".."; do
  "$BIN" append "$bad" ENG-1 set_state --after Done >/dev/null 2>&1; rc=$?
  [ "$rc" -eq 2 ] || fail "traversal slot id '$bad' should exit 2, got $rc"
done
# nothing escaped the audit dir
[ -z "$(find "$TMP" -name escape.jsonl 2>/dev/null)" ] \
  || fail "a traversal slot id must not create a file outside the audit dir"
pass "path-traversal slot ids are rejected before any write"

# 11. torn trailing line is tolerated on read (crash mid-append) -------------
torn="$FM_SYNC_AUDIT_DIR/torn/slot.jsonl"
mkdir -p "$(dirname "$torn")"
printf '%s\n' '{"ts":"2026-07-06T00:00:00Z","slot":"torn/slot","op":"a","target":"ENG-1"}' >"$torn"
printf '%s' '{"ts":"2026-07-06T00:00:01Z","slot":"torn/slot","op":"b","target":"EN' >>"$torn"
out="$("$BIN" read "torn/slot" 2>/dev/null)" \
  || fail "read must tolerate a torn trailing line and still exit 0"
echo "$out" | jq -e 'length == 1 and .[0].op == "a"' >/dev/null \
  || fail "read should keep the intact line and drop only the torn trailing one"
pass "read tolerates a torn trailing line from a crash mid-append"

echo "# all fm-sync-audit assertions passed"

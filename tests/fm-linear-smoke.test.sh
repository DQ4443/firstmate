#!/usr/bin/env bash
# tests/fm-linear-smoke.test.sh - network-free smoke test for bin/fm-linear.sh,
# the deterministic Linear read/write wrapper (meeting-sync-design.md Phase 0).
#
# WHY NETWORK-FREE: the write and read subcommands hit Linear's live hosted MCP
# and depend on a cached OAuth token, so they cannot run in CI. This suite
# exercises only the parts that need NO token and NO network: the usage/exit-code
# contract and the --dry-run write path (create_issue/add_comment --dry-run print
# the exact tool call and exit 0 WITHOUT resolving a token). That dry-run path is
# the substrate the tiered-gate change-list (Decision 5a) builds on, so keeping it
# green offline guards the wrapper's argument-mapping and CLI contract on every
# machine. Real read/write connectivity is verified by hand against the live API
# (see the wrapper header and the delivery evidence), not here.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN="$ROOT/bin/fm-linear.sh"

fail() { printf 'not ok - %s\n' "$1" >&2; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }

# Force the no-token env so an accidental network/token dependency in a path
# that is supposed to be offline surfaces as a failure instead of silently
# reaching Linear. --dry-run must still succeed with no token.
export LINEAR_API_KEY=""

# 1. usage/exit-code contract -------------------------------------------------
"$BIN" --help >/dev/null 2>&1 || fail "--help should exit 0"
pass "--help exits 0"

"$BIN" >/dev/null 2>&1; rc=$?
[ "$rc" -eq 2 ] || fail "no args should exit 2, got $rc"
pass "no args exits 2"

"$BIN" bogus_subcommand >/dev/null 2>&1; rc=$?
[ "$rc" -eq 2 ] || fail "unknown subcommand should exit 2, got $rc"
pass "unknown subcommand exits 2"

# 2. create_issue --dry-run (offline: no token, no network) -------------------
out="$("$BIN" create_issue --title "smoke test issue" --team Engineering \
  --assignee "David Qu" --labels Bug,Feature --priority 2 --dry-run 2>&1)" \
  || fail "create_issue --dry-run should exit 0 offline"
printf '%s' "$out" | grep -q '"title": "smoke test issue"' \
  || fail "dry-run create should echo the title"
printf '%s' "$out" | grep -q '"team": "Engineering"' \
  || fail "dry-run create should echo the team"
printf '%s' "$out" | grep -q '"assignee": "David Qu"' \
  || fail "dry-run create should echo the assignee"
printf '%s' "$out" | grep -q '"priority": 2' \
  || fail "dry-run create should coerce --priority to a number"
printf '%s' "$out" | grep -q '"labels"' \
  || fail "dry-run create should split --labels into a list"
pass "create_issue --dry-run maps flags to save_issue args offline"

# create_issue with no --title is a usage error, checked before any token use.
"$BIN" create_issue --team Engineering --dry-run >/dev/null 2>&1; rc=$?
[ "$rc" -eq 2 ] || fail "create_issue without --title should exit 2, got $rc"
pass "create_issue without --title exits 2"

# 3. add_comment --dry-run (offline) ------------------------------------------
out="$("$BIN" add_comment ENG-1 --body "smoke comment" --dry-run 2>&1)" \
  || fail "add_comment --dry-run should exit 0 offline"
printf '%s' "$out" | grep -q '"issueId": "ENG-1"' \
  || fail "dry-run comment should echo the issueId"
printf '%s' "$out" | grep -q '"body": "smoke comment"' \
  || fail "dry-run comment should echo the body"
pass "add_comment --dry-run maps flags to save_comment args offline"

"$BIN" add_comment ENG-1 --dry-run >/dev/null 2>&1; rc=$?
[ "$rc" -eq 2 ] || fail "add_comment without --body should exit 2, got $rc"
pass "add_comment without --body exits 2"

echo "# all fm-linear smoke assertions passed"

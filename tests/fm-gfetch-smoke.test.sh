#!/usr/bin/env bash
# tests/fm-gfetch-smoke.test.sh - network-free smoke test for bin/fm-gfetch.sh,
# the deterministic Gmail/Drive/Calendar fetch wrapper (meeting-sync-design.md
# Decision 4b, Phase 0b).
#
# WHY NETWORK-FREE: the fetch subcommands hit Google's live REST APIs and depend
# on a durable OAuth credential that, per design open question 10, does NOT yet
# exist on David's machine. So CI cannot exercise the happy path. This suite
# exercises what needs NO credential and NO network: the usage/exit-code
# contract, and (the load-bearing behavior of this leaf) the HONEST DEGRADE -
# with no credential reachable, every fetch subcommand must print the
# machine-parseable `notes-not-fetchable ... paste-them` line to STDOUT and exit
# 3 (Decision 4b Option C), never hang, never leak a token. Real fetch
# connectivity is verified by hand against the live API once a credential is
# wired (see the wrapper header), not here.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN="$ROOT/bin/fm-gfetch.sh"

fail() { printf 'not ok - %s\n' "$1" >&2; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }

# Force the no-credential env: empty the explicit token and point the credential
# file at a guaranteed-absent path so the offline degrade path is deterministic
# regardless of the runner's real credentials. gcloud/mcp sources are checked
# after these and are absent in CI. The whole point is that the degrade fires
# and NOTHING reaches the network.
export FM_GOOGLE_ACCESS_TOKEN=""
export FM_GOOGLE_CRED_FILE="/nonexistent/fm-gfetch/credentials.json"
# Neutralize gcloud so a configured dev machine still exercises the degrade path.
export PATH="/usr/bin:/bin"

# 1. usage/exit-code contract -------------------------------------------------
"$BIN" --help >/dev/null 2>&1 || fail "--help should exit 0"
pass "--help exits 0"

"$BIN" >/dev/null 2>&1; rc=$?
[ "$rc" -eq 2 ] || fail "no args should exit 2, got $rc"
pass "no args exits 2"

"$BIN" bogus_subcommand >/dev/null 2>&1; rc=$?
[ "$rc" -eq 2 ] || fail "unknown subcommand should exit 2, got $rc"
pass "unknown subcommand exits 2"

# positional-required subcommands are usage errors before any credential use
"$BIN" thread >/dev/null 2>&1; rc=$?
[ "$rc" -eq 2 ] || fail "thread with no id should exit 2, got $rc"
"$BIN" doc >/dev/null 2>&1; rc=$?
[ "$rc" -eq 2 ] || fail "doc with no id should exit 2, got $rc"
"$BIN" event >/dev/null 2>&1; rc=$?
[ "$rc" -eq 2 ] || fail "event with no id should exit 2, got $rc"
pass "missing positional args exit 2 before any credential/network use"

# 2. the honest degrade: no credential => machine-parseable line + exit 3 ------
# This is the acceptance behavior (Decision 4b Option C). Test every fetch cmd.
for spec in \
  "threads --query 'Kronos Tech Sync' --limit 1" \
  "thread T-abc123" \
  "files --query 'Kronos Tech Sync'" \
  "doc FILEID123" \
  "events --query 'Kronos Tech Sync'" \
  "event EVENTID123"
do
  # shellcheck disable=SC2086
  out="$(eval "\"$BIN\" $spec" 2>/dev/null)"; rc=$?
  cmd="${spec%% *}"
  [ "$rc" -eq 3 ] || fail "$cmd without credential should exit 3, got $rc"
  printf '%s' "$out" | grep -q '^notes-not-fetchable ' \
    || fail "$cmd should print the 'notes-not-fetchable' degrade line to stdout"
  printf '%s' "$out" | grep -q 'paste-them' \
    || fail "$cmd degrade line should carry the 'paste-them' token"
  printf '%s' "$out" | grep -q "subcommand=$cmd" \
    || fail "$cmd degrade line should name the subcommand"
  # the token must never appear anywhere in output (there is none set, but the
  # line must also never echo credential-shaped material)
  printf '%s' "$out" | grep -qi 'bearer\|access_token\|refresh_token' \
    && fail "$cmd degrade output must not contain credential-shaped strings"
  pass "$cmd honest-degrade: notes-not-fetchable line + exit 3, no leak"
done

# 3. status with no credential exits 3 and never prints a token ---------------
out="$("$BIN" status 2>&1)"; rc=$?
[ "$rc" -eq 3 ] || fail "status without credential should exit 3, got $rc"
printf '%s' "$out" | grep -q 'NONE reachable' \
  || fail "status should report no credential reachable"
printf '%s' "$out" | grep -qi 'bearer \|access_token=\|refresh_token=' \
  && fail "status must not print credential-shaped strings"
pass "status without credential exits 3, reports none, no leak"

echo "# all fm-gfetch smoke assertions passed"

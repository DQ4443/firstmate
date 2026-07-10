#!/usr/bin/env bash
# Behavior tests for bin/fm-node.sh - the fleet NODE lifecycle CLI.
#
# All cases are hermetic: state lives under an FM_STATE_OVERRIDE temp dir, and the
# host tools the script shells out to (tmux, security, curl) are shadowed by a
# fakebin on PATH, driven by FM_FAKE_* env. No real Keychain, network, or tmux is
# touched. Coverage:
#   - register round-trip (registry read back via get), harness default + override
#   - register validation: bad name, relative config-dir, missing args
#   - unregister removes the node
#   - list renders identity + 5h/7d/Fable utilization + live session pid from the
#     faked usage endpoint and faked tmux
#   - usage emits the additive N-node JSON; a node with no token degrades to ok:false
#   - status reports session liveness with no network call
#   - spawn creates the fm-node-<name> tmux session and sends the CLAUDE_CONFIG_DIR
#     export + a bare `claude` launch (no auto-login), and is idempotent when the
#     session already exists
#   - spawn auto-accepts the trust-folder dialog (one Enter) when the pane shows
#     it, and sends nothing when the composer is already up (FM_FAKE_PANE drives
#     the faked capture-pane; FM_NODE_TRUST_WAIT bounds the poll)
#   - a corrupt registry is a hard refusal, never a silent reset
#   - unknown command / no command exits 2
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v jq >/dev/null 2>&1 || { pass "fm-node tests skipped: jq not installed"; exit 0; }

NODE="$ROOT/bin/fm-node.sh"
TMP_ROOT=$(fm_test_tmproot fm-node)

# A fakebin shadowing tmux/security/curl. Behavior is driven by FM_FAKE_* env read
# at call time, so a single fakebin serves every case.
make_fakebin() {  # <dir> -> echoes fakebin path
  local dir=$1 fb="$1/fakebin"
  mkdir -p "$fb"
  cat > "$fb/tmux" <<SH
#!/usr/bin/env bash
set -u
[ -z "\${FM_FAKE_TMUX_LOG:-}" ] || printf '%s\n' "\$*" >> "\$FM_FAKE_TMUX_LOG"
case "\${1:-}" in
  display-message)
    [ -n "\${FM_FAKE_SESSION_PID:-}" ] || exit 1
    printf '%s\n' "\$FM_FAKE_SESSION_PID" ;;
  has-session)
    [ "\${FM_FAKE_HAS_SESSION:-0}" = 1 ] && exit 0 || exit 1 ;;
  new-session) exit 0 ;;
  send-keys) exit 0 ;;
  capture-pane) printf '%s\n' "\${FM_FAKE_PANE:-}" ;;
esac
exit 0
SH
  cat > "$fb/security" <<SH
#!/usr/bin/env bash
set -u
[ "\${FM_FAKE_NOTOK:-0}" = 1 ] && exit 1
printf '%s\n' '{"claudeAiOauth":{"accessToken":"faketok-abc"}}'
SH
  cat > "$fb/curl" <<SH
#!/usr/bin/env bash
set -u
[ "\${FM_FAKE_NOTOK:-0}" = 1 ] && { printf ''; exit 0; }
cat <<'J'
{"five_hour":{"utilization":86.0,"resets_at":"2026-07-10T03:50:00+00:00"},
 "seven_day":{"utilization":36.0,"resets_at":"2026-07-15T11:00:00+00:00"},
 "limits":[{"kind":"session","percent":86,"severity":"warning","resets_at":"2026-07-10T03:50:00+00:00"},
           {"kind":"weekly_all","percent":36,"severity":"normal","resets_at":"2026-07-15T11:00:00+00:00"},
           {"kind":"weekly_scoped","percent":9,"severity":"normal","resets_at":"2026-07-15T11:00:00+00:00","scope":{"model":{"display_name":"Fable"}}}]}
J
SH
  chmod +x "$fb/tmux" "$fb/security" "$fb/curl"
  printf '%s\n' "$fb"
}

# A case dir with its own state/, a node config dir carrying a fake identity file,
# and a fakebin. Echoes the case dir.
new_case() {  # <name> -> echoes case dir
  local d="$TMP_ROOT/$1"
  mkdir -p "$d/state" "$d/cfg"
  cat > "$d/cfg/.claude.json" <<'J'
{"oauthAccount":{"emailAddress":"node1@example.com","displayName":"Node One"}}
J
  make_fakebin "$d" >/dev/null
  printf '%s\n' "$d"
}

# Run fm-node.sh for a case dir with its fakebin on PATH and state redirected.
run_node() {  # <case-dir> <args...>
  local d=$1; shift
  PATH="$d/fakebin:$PATH" FM_STATE_OVERRIDE="$d/state" "$NODE" "$@"
}

# --- register round-trip -----------------------------------------------------

test_register_roundtrip() {
  local d; d=$(new_case roundtrip)
  run_node "$d" register alpha "$d/cfg" >/dev/null
  # register canonicalizes an existing dir (pwd -P), so compare the canonical path
  # (/var -> /private/var on macOS).
  local cfg_canon; cfg_canon=$(cd "$d/cfg" && pwd -P)
  local out; out=$(run_node "$d" get alpha)
  assert_contains "$out" '"name": "alpha"' "get returns the registered name"
  assert_contains "$out" "$cfg_canon" "get returns the config dir"
  assert_contains "$out" '"harness": "claude"' "harness defaults to claude"
  pass "register writes an entry the registry reads back"
}

test_register_harness_override() {
  local d; d=$(new_case harness-override)
  # Only claude is a supported node harness; a bogus one must be refused.
  local rc=0
  run_node "$d" register beta "$d/cfg" --harness codex >/dev/null 2>&1 || rc=$?
  expect_code 2 "$rc" "unsupported harness is refused"
  # The supported value is accepted explicitly.
  run_node "$d" register beta "$d/cfg" --harness claude >/dev/null
  assert_contains "$(run_node "$d" get beta)" '"harness": "claude"' "explicit claude harness recorded"
  pass "register enforces the supported harness set"
}

test_register_rejects_bad_name() {
  local d rc=0; d=$(new_case bad-name)
  run_node "$d" register 'Bad Name' "$d/cfg" >/dev/null 2>&1 || rc=$?
  expect_code 2 "$rc" "an invalid node name exits 2"
  pass "register rejects an invalid node name"
}

test_register_rejects_relative_dir() {
  local d rc=0; d=$(new_case relative-dir)
  run_node "$d" register gamma cfg >/dev/null 2>&1 || rc=$?
  expect_code 2 "$rc" "a relative config-dir exits 2"
  pass "register requires an absolute config-dir"
}

test_register_missing_args() {
  local d rc=0; d=$(new_case missing-args)
  run_node "$d" register onlyname >/dev/null 2>&1 || rc=$?
  expect_code 2 "$rc" "register with no config-dir exits 2"
  pass "register with missing args is a usage error"
}

test_register_nonexistent_dir_warns_but_registers() {
  local d; d=$(new_case nonexistent-dir)
  local err; err=$(run_node "$d" register delta /no/such/home 2>&1 >/dev/null)
  assert_contains "$err" "does not exist yet" "a not-yet-created home warns"
  assert_contains "$(run_node "$d" get delta)" '"config_dir": "/no/such/home"' "still registered for later sign-in"
  pass "register allows a not-yet-created home with a warning"
}

test_unregister_removes() {
  local d; d=$(new_case unregister)
  run_node "$d" register eps "$d/cfg" >/dev/null
  run_node "$d" unregister eps >/dev/null
  local rc=0
  run_node "$d" get eps >/dev/null 2>&1 || rc=$?
  expect_code 2 "$rc" "get on a removed node exits 2"
  pass "unregister removes the node"
}

# --- list / usage (identity + utilization + liveness) ------------------------

test_list_renders_identity_and_utilization() {
  local d; d=$(new_case list-render)
  run_node "$d" register alpha "$d/cfg" >/dev/null
  local out
  out=$(FM_FAKE_SESSION_PID=4242 run_node "$d" list)
  assert_contains "$out" "node1@example.com" "list shows the signed-in identity"
  assert_contains "$out" "86%" "list shows the 5h utilization"
  assert_contains "$out" "36%" "list shows the 7d utilization"
  assert_contains "$out" "9%" "list shows the Fable weekly quota"
  assert_contains "$out" "live pid 4242" "list shows the live session pid"
  pass "list renders identity, 5h/7d/Fable utilization, and live pid"
}

test_usage_json_shape() {
  local d; d=$(new_case usage-json)
  run_node "$d" register alpha "$d/cfg" >/dev/null
  local out
  out=$(FM_FAKE_SESSION_PID=777 run_node "$d" usage)
  # Valid JSON with the expected node fields.
  printf '%s' "$out" | jq -e '.nodes.alpha.ok == true
    and .nodes.alpha.five_hour.used_percent == 86
    and .nodes.alpha.seven_day.used_percent == 36
    and .nodes.alpha.fable.used_percent == 9
    and .nodes.alpha.identity == "node1@example.com"
    and .nodes.alpha.session.live == true
    and .nodes.alpha.session.pid == 777' >/dev/null \
    || fail "usage JSON missing expected node fields:"$'\n'"$out"
  pass "usage emits the additive per-node JSON with utilization and liveness"
}

test_usage_degrades_when_not_signed_in() {
  local d; d=$(new_case usage-notok)
  run_node "$d" register alpha "$d/cfg" >/dev/null
  local out
  out=$(FM_FAKE_NOTOK=1 run_node "$d" usage)
  printf '%s' "$out" | jq -e '.nodes.alpha.ok == false and (.nodes.alpha.error | test("unreadable"))' >/dev/null \
    || fail "an unreadable token should degrade to ok:false with an error:"$'\n'"$out"
  pass "usage degrades a node with no readable token to ok:false"
}

# --- status (liveness only, no network) --------------------------------------

test_status_reports_liveness() {
  local d; d=$(new_case status)
  run_node "$d" register alpha "$d/cfg" >/dev/null
  assert_contains "$(FM_FAKE_SESSION_PID=99 run_node "$d" status)" "live pid=99" "status shows a live session"
  assert_contains "$(run_node "$d" status)" "down" "status shows a down session"
  pass "status reports session liveness"
}

test_status_empty_registry() {
  local d; d=$(new_case status-empty)
  assert_contains "$(run_node "$d" status)" "no nodes registered" "empty registry is reported"
  pass "status handles an empty registry"
}

# --- spawn -------------------------------------------------------------------

test_spawn_creates_session_and_launches_claude() {
  local d; d=$(new_case spawn)
  run_node "$d" register alpha "$d/cfg" >/dev/null
  local log="$d/tmux.log"
  : > "$log"
  local out
  out=$(FM_FAKE_TMUX_LOG="$log" FM_FAKE_HAS_SESSION=0 FM_NODE_TRUST_WAIT=0 run_node "$d" spawn alpha)
  assert_contains "$out" "spawned node alpha session=fm-node-alpha" "spawn reports the session"
  assert_grep "new-session -d -s fm-node-alpha" "$log" "spawn creates the fm-node-alpha session"
  assert_grep "export CLAUDE_CONFIG_DIR=" "$log" "spawn seeds CLAUDE_CONFIG_DIR"
  assert_grep "send-keys -t fm-node-alpha claude Enter" "$log" "spawn launches bare claude (no auto-login)"
  pass "spawn creates the node session and launches claude with the config dir"
}

test_spawn_accepts_trust_dialog() {
  local d; d=$(new_case spawn-trust)
  run_node "$d" register alpha "$d/cfg" >/dev/null
  local log="$d/tmux.log"
  : > "$log"
  local out
  out=$(FM_FAKE_TMUX_LOG="$log" FM_FAKE_HAS_SESSION=0 FM_NODE_TRUST_WAIT=3 \
        FM_FAKE_PANE='Do you trust the files in this folder?' run_node "$d" spawn alpha 2>&1)
  assert_contains "$out" "accepted claude trust-folder dialog" "spawn reports the accept"
  assert_grep "send-keys -t fm-node-alpha Enter" "$log" "spawn presses Enter to accept the trust dialog"
  pass "spawn auto-accepts the trust-folder dialog when it appears"
}

test_spawn_stops_poll_when_composer_up() {
  local d; d=$(new_case spawn-composer)
  run_node "$d" register alpha "$d/cfg" >/dev/null
  local log="$d/tmux.log"
  : > "$log"
  local out
  out=$(FM_FAKE_TMUX_LOG="$log" FM_FAKE_HAS_SESSION=0 FM_NODE_TRUST_WAIT=30 \
        FM_FAKE_PANE='> _  ? for shortcuts' run_node "$d" spawn alpha 2>&1)
  assert_contains "$out" "spawned node alpha" "spawn completes"
  assert_no_grep "send-keys -t fm-node-alpha Enter" "$log" "no stray Enter when the composer is already up"
  pass "spawn stops polling early when the composer is up with no dialog"
}

test_spawn_idempotent_when_running() {
  local d; d=$(new_case spawn-running)
  run_node "$d" register alpha "$d/cfg" >/dev/null
  local log="$d/tmux.log"
  : > "$log"
  local out
  out=$(FM_FAKE_TMUX_LOG="$log" FM_FAKE_HAS_SESSION=1 FM_FAKE_SESSION_PID=555 run_node "$d" spawn alpha)
  assert_contains "$out" "already running" "spawn is idempotent when the session exists"
  assert_no_grep "new-session" "$log" "spawn does not recreate a live session"
  pass "spawn refuses to recreate an already-running node session"
}

test_spawn_unknown_node() {
  local d rc=0; d=$(new_case spawn-unknown)
  run_node "$d" spawn ghost >/dev/null 2>&1 || rc=$?
  expect_code 2 "$rc" "spawning an unregistered node exits 2"
  pass "spawn refuses an unregistered node"
}

# --- safety / dispatch -------------------------------------------------------

test_corrupt_registry_is_hard_error() {
  local d rc=0; d=$(new_case corrupt)
  printf 'not json' > "$d/state/fleet-nodes.json"
  run_node "$d" register alpha "$d/cfg" >/dev/null 2>&1 || rc=$?
  expect_code 2 "$rc" "a corrupt registry refuses the write"
  assert_grep "not json" "$d/state/fleet-nodes.json" "the corrupt file is left untouched, not reset"
  pass "a corrupt registry is a hard refusal, not a silent reset"
}

test_unknown_command() {
  local d rc=0; d=$(new_case unknown-cmd)
  run_node "$d" bogus >/dev/null 2>&1 || rc=$?
  expect_code 2 "$rc" "an unknown command exits 2"
  run_node "$d" >/dev/null 2>&1 || rc=$?
  expect_code 2 "$rc" "no command exits 2"
  pass "unknown / missing command is a usage error"
}

test_register_roundtrip
test_register_harness_override
test_register_rejects_bad_name
test_register_rejects_relative_dir
test_register_missing_args
test_register_nonexistent_dir_warns_but_registers
test_unregister_removes
test_list_renders_identity_and_utilization
test_usage_json_shape
test_usage_degrades_when_not_signed_in
test_status_reports_liveness
test_status_empty_registry
test_spawn_creates_session_and_launches_claude
test_spawn_accepts_trust_dialog
test_spawn_stops_poll_when_composer_up
test_spawn_idempotent_when_running
test_spawn_unknown_node
test_corrupt_registry_is_hard_error
test_unknown_command

echo "all fm-node tests passed"

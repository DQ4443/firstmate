#!/usr/bin/env bash
# tests/fm-drain-worker.test.sh - the headless board drain worker in isolation.
#
# Proves bin/fm-drain-worker.sh:
#   - single-flights on a live-pid lease (a second drain no-ops while one holds it)
#   - reclaims a lease held by a dead pid
#   - on a successful ack: advances .drain-attempted-seq, never touches
#     .serviced-seq (a holding-ack is not a close-out), leaves the SLA armed
#   - no-ops (advancing attempted) when no David message is actually unanswered
#   - dead-letters after FM_DRAIN_MAX_FAILURES genuine failures and then advances
#     attempted so it stops spinning
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }

WORKER="$ROOT/bin/fm-drain-worker.sh"

# --- fixture builders --------------------------------------------------------
new_sandbox() {  # echoes a fresh sandbox root with AGENTS/CLAUDE and dirs
  local sb; sb=$(fm_test_tmproot fm-drain-unit)
  mkdir -p "$sb/state" "$sb/data/board-threads"
  printf '# a\n' > "$sb/AGENTS.md"; printf '# c\n' > "$sb/CLAUDE.md"
  printf '%s' "$sb"
}

post_david() {  # <sandbox> <item> <body>
  local sb=$1 item=$2 body=$3 dir ts ms
  dir="$sb/data/board-threads/$item"; mkdir -p "$dir"
  ts=$(date -u +%Y-%m-%dT%H:%M:%SZ); ms=$(( $(date +%s) * 1000 ))
  {
    printf '{"thread_id": "%s", "parent_ref": null, "author": "david", "ts": "%s"}\n' "$item" "$ts"
    printf '\n%s\n' "$body"
  } > "$dir/$ms.md"
}

seed_seq() { printf '%s\n' "$2" > "$1/state/.wake-queue.seq"; }  # <sandbox> <seq>

# A stub claude that POSTS an ack for each UNANSWERED_ITEM (success path).
make_success_claude() {  # <sandbox> -> echoes stub path
  local sb=$1 stub; stub="$sb/claude-ok"
  cat > "$stub" <<STUB
#!/usr/bin/env bash
p=\$(cat)
printf '%s\n' "\$p" | grep '^UNANSWERED_ITEM: ' | sed 's/^UNANSWERED_ITEM: //' | while IFS= read -r id; do
  FM_ROOT_OVERRIDE="$sb" "$ROOT/bin/fm-board-reply.sh" "\$id" "Captured; holding for the orchestrator." --your-court --once >/dev/null 2>&1 || true
done
STUB
  chmod +x "$stub"; printf '%s' "$stub"
}

# A stub claude that FAILS (posts nothing, exits 1).
make_failing_claude() {  # <sandbox> -> echoes stub path
  local sb=$1 stub; stub="$sb/claude-fail"
  printf '#!/usr/bin/env bash\ncat >/dev/null\nexit 1\n' > "$stub"
  chmod +x "$stub"; printf '%s' "$stub"
}

run_worker() {  # <sandbox> <claude-bin>
  FM_ROOT_OVERRIDE="$1" FM_DRAIN_CLAUDE_BIN="$2" bash "$WORKER" >/dev/null 2>&1
}

firstmate_replies() {  # <sandbox> <item>
  local d=$1/data/board-threads/$2 f n=0 a
  for f in "$d"/*.md; do
    [ -e "$f" ] || continue
    a=$(head -n1 "$f" 2>/dev/null | jq -r '.author // ""' 2>/dev/null || true)
    [ "$a" = firstmate ] && n=$((n + 1))
  done
  printf '%s' "$n"
}

# --- 1. single-flight on a live-pid lease ------------------------------------
sb=$(new_sandbox)
post_david "$sb" alpha "hi"
seed_seq "$sb" 1
mkdir -p "$sb/state/.drain-lease"
sleep 30 & LIVE=$!
disown "$LIVE" 2>/dev/null || true                     # keep job control from printing "Terminated" on kill
printf '%s\n' "$LIVE" > "$sb/state/.drain-lease/pid"   # live holder, no identity => held
run_worker "$sb" "$(make_success_claude "$sb")"
kill "$LIVE" 2>/dev/null || true
[ "$(firstmate_replies "$sb" alpha)" -eq 0 ] || fail "worker drained despite a live lease holder (single-flight broken)"
[ "$(cat "$sb/state/.drain-attempted-seq" 2>/dev/null || echo 0)" = 0 ] || fail "attempted-seq advanced while lease was held"
pass "single-flight: a live-pid lease blocks a second drain"

# --- 2. reclaim a dead-pid lease ---------------------------------------------
sb=$(new_sandbox)
post_david "$sb" beta "hi"
seed_seq "$sb" 1
mkdir -p "$sb/state/.drain-lease"
printf '999999\n' > "$sb/state/.drain-lease/pid"        # dead pid => reclaimable
run_worker "$sb" "$(make_success_claude "$sb")"
[ "$(firstmate_replies "$sb" beta)" -eq 1 ] || fail "worker did not reclaim a dead-pid lease and drain"
pass "reclaim: a dead-pid lease is taken over and the drain proceeds"

# --- 3. success advances attempted-seq, never serviced-seq -------------------
sb=$(new_sandbox)
post_david "$sb" gamma "hi"
seed_seq "$sb" 7
run_worker "$sb" "$(make_success_claude "$sb")"
[ "$(firstmate_replies "$sb" gamma)" -eq 1 ] || fail "success path posted no ack"
[ "$(cat "$sb/state/.drain-attempted-seq")" = 7 ] || fail "attempted-seq not advanced to the queue seq on success"
assert_absent "$sb/state/.serviced-seq" "serviced-seq must stay unwritten for a holding-ack (SLA armed)"
pass "success advances attempted-seq to the queue seq and leaves serviced-seq armed"

# --- 4. no unanswered David message: no-op advance, claude never called -------
sb=$(new_sandbox)
# a thread whose newest file is firstmate-authored (already answered)
mkdir -p "$sb/data/board-threads/delta"
ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
printf '{"author":"firstmate","thread_id":"delta","parent_ref":null,"ts":"%s"}\n\ndone\n' "$ts" \
  > "$sb/data/board-threads/delta/$(( $(date +%s) * 1000 )).md"
seed_seq "$sb" 3
NEVER="$sb/claude-never"
printf '#!/usr/bin/env bash\ntouch "%s/state/.claude-was-called"\n' "$sb" > "$NEVER"; chmod +x "$NEVER"
run_worker "$sb" "$NEVER"
assert_absent "$sb/state/.claude-was-called" "claude was invoked with nothing unanswered"
[ "$(cat "$sb/state/.drain-attempted-seq")" = 3 ] || fail "attempted-seq not advanced on an empty drain"
pass "empty drain: no claude turn, attempted-seq still advances"

# --- 5. dead-letter after K genuine failures ---------------------------------
sb=$(new_sandbox)
post_david "$sb" epsilon "hi"
seed_seq "$sb" 1
FAILCLAUDE=$(make_failing_claude "$sb")
FM_DRAIN_MAX_FAILURES=3
k=0
while [ "$k" -lt 3 ]; do
  FM_ROOT_OVERRIDE="$sb" FM_DRAIN_MAX_FAILURES=3 FM_DRAIN_CLAUDE_BIN="$FAILCLAUDE" bash "$WORKER" >/dev/null 2>&1
  k=$((k + 1))
  if [ "$k" -lt 3 ]; then
    [ -f "$sb/state/.dead-letter" ] && fail "dead-lettered too early (after $k of 3 failures)"
    [ "$(cat "$sb/state/.drain-attempted-seq" 2>/dev/null || echo 0)" = 0 ] || fail "attempted-seq advanced before the failure cap"
  fi
done
assert_present "$sb/state/.dead-letter" "no dead-letter after $FM_DRAIN_MAX_FAILURES failures"
assert_grep "epsilon" "$sb/state/.dead-letter" "dead-letter does not name the un-drained item"
[ "$(cat "$sb/state/.drain-attempted-seq")" = 1 ] || fail "attempted-seq not advanced after dead-letter (would spin)"
[ "$(firstmate_replies "$sb" epsilon)" -eq 0 ] || fail "failing claude somehow posted a reply"
pass "dead-letter fires after K failures, then advances attempted-seq to stop spinning"

echo "all fm-drain-worker tests passed"

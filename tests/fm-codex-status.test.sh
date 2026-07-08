#!/usr/bin/env bash
# tests/fm-codex-status.test.sh - Codex worker registry and status CLI.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }

STATUS="$ROOT/bin/fm-codex-status.sh"
BUILD="$ROOT/bin/fm-codex-build.sh"
REVIEW="$ROOT/bin/fm-codex-review.sh"
TMP_ROOT=$(fm_test_tmproot fm-codex-status)

make_repo() {
  local repo=$1
  fm_git_init_commit "$repo"
  git -C "$repo" branch -M main
}

make_fake_codex() {
  local fakebin=$1
  cat > "$fakebin/codex" <<'SH'
#!/usr/bin/env bash
msg=
worktree=
while [ "$#" -gt 0 ]; do
  case "$1" in
    -o)
      msg=$2
      shift 2
      ;;
    -C)
      worktree=$2
      shift 2
      ;;
    *)
      shift
      ;;
  esac
done
printf 'codex stdout for %s\n' "${FM_CODEX_TASK_ID:-missing-task}"
printf 'final line for %s\n' "${FM_CODEX_TASK_ID:-missing-task}"
[ -n "$worktree" ] || exit 1
if [ -n "$msg" ]; then
  printf '{"findings":[],"verdict":"pass"}\n' > "$msg"
else
  printf 'OK\n' > "$worktree/SMOKE.txt"
fi
exit 0
SH
  chmod +x "$fakebin/codex"
}

make_no_codex_path() {
  local dir=$1 tool path
  mkdir -p "$dir"
  for tool in bash basename dirname git mkdir python3 tr; do
    path=$(command -v "$tool") || fail "required test tool missing: $tool"
    ln -sf "$path" "$dir/$tool"
  done
  printf '%s\n' "$dir"
}

run_review() {
  local state=$1 repo=$2 brief=$3 task=$4 fakebin=$5
  FM_STATE_OVERRIDE="$state" FM_CODEX_TASK_ID="$task" PATH="$fakebin:$PATH" \
    "$REVIEW" "$repo" "$brief" --diff-base main
}

# --- missing registry status ------------------------------------------------
state="$TMP_ROOT/state-missing"
mkdir -p "$state"
out=$(FM_STATE_OVERRIDE="$state" "$STATUS")
[ "$out" = "no codex workers yet" ] || fail "missing registry output changed: $out"
pass "missing registry prints the exact no-workers line"

# --- corrupt registry status is readable ------------------------------------
state="$TMP_ROOT/state-status-corrupt"
mkdir -p "$state"
printf 'not json{\n' > "$state/codex-workers.json"
set +e
err=$(FM_STATE_OVERRIDE="$state" "$STATUS" 2>&1 >/dev/null)
rc=$?
set -u
expect_code 1 "$rc" "status against corrupt registry"
assert_contains "$err" "fm-codex-status: registry is invalid:" "status corrupt-registry error was not concise"
assert_not_contains "$err" "Traceback" "status corrupt-registry error leaked a Python traceback"
pass "corrupt registry status fails cleanly without a traceback"

# --- corrupt registry is fail-soft for workers ------------------------------
repo="$TMP_ROOT/repo"
brief="$TMP_ROOT/review brief.md"
fakebin=$(fm_fakebin "$TMP_ROOT")
make_repo "$repo"
make_fake_codex "$fakebin"
printf 'review this\n' > "$brief"
state="$TMP_ROOT/state-corrupt"
mkdir -p "$state"
printf 'not json{\n' > "$state/codex-workers.json"
out=$(run_review "$state" "$repo" "$brief" alpha "$fakebin") || fail "review failed against a corrupt registry"
verdict=$(printf '%s\n' "$out" | jq -r '.verdict')
[ "$verdict" = pass ] || fail "review JSON contract changed on corrupt registry"
jq -e '.workers[] | select(.task_id=="alpha" and .kind=="review" and .status=="ok")' "$state/codex-workers.json" >/dev/null \
  || fail "registry did not recover from corrupt JSON with an ok review record"
log_path=$(jq -r '.workers[] | select(.task_id=="alpha") | .log' "$state/codex-workers.json")
[ -f "$log_path" ] || fail "review stdout log was not durable: $log_path"
assert_grep "final line for alpha" "$log_path" "durable review log missed stdout"
pass "corrupt registry is fail-soft and review keeps its stdout JSON contract"

# --- build failure records without launching codex --------------------------
state="$TMP_ROOT/state-build-fail"
mkdir -p "$state"
no_codex_path=$(make_no_codex_path "$TMP_ROOT/no-codex-bin")
set +e
out=$(FM_STATE_OVERRIDE="$state" PATH="$no_codex_path" \
  "$BUILD" build-no-codex "$repo" "$brief" --base main 2>/dev/null)
rc=$?
set -u
expect_code 1 "$rc" "build with codex missing"
[ "$(printf '%s\n' "$out" | jq -r '.status')" = failed ] \
  || fail "build failure did not preserve stdout JSON contract"
jq -e '.workers[] | select(.task_id=="build-no-codex" and .kind=="build" and .status=="failed")' \
  "$state/codex-workers.json" >/dev/null \
  || fail "build failure did not update the registry"
jq -e '.workers[] | select(.task_id=="build-no-codex") | .reason | contains("codex is not installed")' \
  "$state/codex-workers.json" >/dev/null \
  || fail "build failure registry reason did not explain the missing codex"
pass "build early failure is recorded without changing stdout JSON"

# --- build success preserves stdout contract and quiet stderr ----------------
state="$TMP_ROOT/state-build-ok"
mkdir -p "$state"
stderr="$TMP_ROOT/build-ok.stderr"
set +e
out=$(FM_STATE_OVERRIDE="$state" FM_CODEX_TASK_ID=build-ok PATH="$fakebin:$PATH" \
  "$BUILD" build-ok "$repo" "$brief" --base main 2>"$stderr")
rc=$?
set -u
expect_code 0 "$rc" "build success smoke"
[ ! -s "$stderr" ] || fail "build success wrote unexpected stderr: $(cat "$stderr")"
[ "$(printf '%s\n' "$out" | jq -r '.status')" = ok ] \
  || fail "build success did not preserve stdout JSON contract"
jq -e '.workers[] | select(.task_id=="build-ok" and .kind=="build" and .status=="ok")' \
  "$state/codex-workers.json" >/dev/null \
  || fail "build success did not update the registry"
jq -e '.workers[] | select(.task_id=="build-ok") | .last_line == "final line for build-ok"' \
  "$state/codex-workers.json" >/dev/null \
  || fail "build success registry missed the final stdout line"
pass "build success records status without stderr noise"

# --- stale owner-token lock recovery -----------------------------------------
state="$TMP_ROOT/state-stale-lock"
mkdir -p "$state/.codex-workers.lock"
cat > "$state/.codex-workers.lock/owner.json" <<'JSON'
{"pid":999999999,"token":"dead","created_at":0}
JSON
python3 - "$state/.codex-workers.lock" <<'PY'
import os
import sys
import time

old = time.time() - 120
os.utime(sys.argv[1], (old, old))
PY
FM_STATE_OVERRIDE="$state" FM_CODEX_TASK_ID=stale-lock \
  FM_CODEX_REGISTRY_LOCK_STALE_SECONDS=1 PATH="$fakebin:$PATH" \
  "$REVIEW" "$repo" "$brief" --diff-base main >/dev/null \
  || fail "review failed while recovering a stale registry lock"
jq -e '.workers[] | select(.task_id=="stale-lock" and .status=="ok")' \
  "$state/codex-workers.json" >/dev/null \
  || fail "registry did not recover from a stale owner-token lock directory"
pass "stale owner-token registry lock is recovered"

# --- status detail and 50-record cap ----------------------------------------
state="$TMP_ROOT/state-cap"
mkdir -p "$state"
i=1
while [ "$i" -le 51 ]; do
  task=$(printf 'task-%02d' "$i")
  run_review "$state" "$repo" "$brief" "$task" "$fakebin" >/dev/null \
    || fail "review run $task failed"
  i=$((i + 1))
done
count=$(jq '.workers | length' "$state/codex-workers.json")
[ "$count" = 50 ] || fail "registry cap expected 50 workers, got $count"
jq -e '.workers | map(.task_id) | index("task-51")' "$state/codex-workers.json" >/dev/null \
  || fail "registry cap dropped the newest worker"
detail=$(FM_STATE_OVERRIDE="$state" "$STATUS" task-51)
assert_contains "$detail" '"task_id": "task-51"' "detail view did not include the full worker record"
assert_contains "$detail" "last 40 log lines:" "detail view did not print log tail heading"
assert_contains "$detail" "final line for task-51" "detail view did not include the log tail"
table=$(FM_STATE_OVERRIDE="$state" "$STATUS")
assert_contains "$table" "task_id" "table view missing header"
assert_contains "$table" "task-51" "table view missing newest task"
pass "status detail works and registry keeps only the newest 50 records"

echo "all fm-codex-status tests passed"

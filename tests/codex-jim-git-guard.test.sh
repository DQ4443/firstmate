#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
GUARD="$ROOT/.codex/hooks/git-guard.py"
HOOKS="$ROOT/.codex/hooks.json"
TMP=$(mktemp -d "${TMPDIR:-/tmp}/codex-git-guard.XXXXXX")
TMP=$(cd "$TMP" && pwd -P)
trap 'rm -rf "$TMP"' EXIT

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

pass() {
  printf 'PASS: %s\n' "$*"
}

payload() {
  local cwd=$1
  local command=$2
  jq -nc \
    --arg cwd "$cwd" \
    --arg command "$command" \
    '{session_id:"schema-fixture",transcript_path:"/tmp/transcript.jsonl",cwd:$cwd,hook_event_name:"PreToolUse",permission_mode:"never",tool_name:"Bash",tool_input:{command:$command},tool_use_id:"call-fixture"}'
}

run_guard() {
  local expected=$1
  local cwd=$2
  local command=$3
  local output
  local status
  set +e
  output=$(payload "$cwd" "$command" | python3 "$GUARD" 2>&1)
  status=$?
  set -e
  [[ "$status" -eq "$expected" ]] || fail "expected $expected for [$command], got $status: $output"
  if [[ "$expected" -eq 2 ]]; then
    [[ "$output" == BLOCKED:* ]] || fail "blocked command had no Codex stderr reason: $command"
  fi
}

git init --bare "$TMP/remote.git" >/dev/null
git init -b main "$TMP/repo" >/dev/null
git -C "$TMP/repo" config user.name Test
git -C "$TMP/repo" config user.email test@example.com
printf 'base\n' >"$TMP/repo/file.txt"
git -C "$TMP/repo" add file.txt
git -C "$TMP/repo" commit -m base >/dev/null
git -C "$TMP/repo" remote add origin "$TMP/remote.git"
git -C "$TMP/repo" push -u origin main >/dev/null 2>&1

run_guard 2 "$TMP/repo" 'git push'
run_guard 2 "$TMP/repo" 'git push origin HEAD:refs/heads/main'
run_guard 2 "$TMP/repo" 'git --no-pager push origin main'
run_guard 2 "$TMP/repo" '/usr/bin/git push --force origin feature:master'
run_guard 2 "$TMP/repo" 'git push --force-with-lease origin feature:master'
run_guard 2 "$TMP/repo" 'git push origin --delete main'
run_guard 2 "$TMP" "cd '$TMP/repo' && git push origin main"
run_guard 2 "$TMP" "git -C '$TMP/repo' push --all origin"
run_guard 2 "$TMP/repo" "bash -c 'git push origin main'"
run_guard 2 "$TMP/repo" "bash -lc 'git push origin main'"
run_guard 2 "$TMP/repo" "bash -O extglob -c 'git push origin main'"
run_guard 2 "$TMP/repo" "bash -o posix -c 'git push origin main'"
run_guard 2 "$TMP/repo" "sh -lc 'git push origin main'"
run_guard 2 "$TMP/repo" "zsh -c \"gh pr create --title nested\""
run_guard 2 "$TMP/repo" "eval 'git push origin master'"
run_guard 2 "$TMP/repo" "eval -- 'git push origin master'"
# shellcheck disable=SC2016  # literal payload: the guard must inspect expansion inside eval
run_guard 2 "$TMP/repo" 'cmd="git push origin main"; eval "$cmd"'
# shellcheck disable=SC2016  # literal payload: the guard must inspect expansion inside sh -c
run_guard 2 "$TMP/repo" 'cmd="git push origin main"; sh -c "$cmd"'
# shellcheck disable=SC2016  # literal payload: the guard must inspect an expanded PR action
run_guard 2 "$TMP/repo" 'cmd="gh pr create --title variable-bypass"; eval "$cmd"'
# shellcheck disable=SC2016  # literal payload: safe expanded commands must remain allowed
run_guard 0 "$TMP/repo" 'cmd="git status --short"; eval "$cmd"'
# shellcheck disable=SC2016  # literal payload: recursive expansion must fail closed
run_guard 2 "$TMP/repo" 'cmd='"'"'eval "$cmd"'"'"'; eval "$cmd"'
# shellcheck disable=SC2016  # literal payload: the guard must resolve the assigned command name
run_guard 2 "$TMP/repo" 'G=git; "$G" push origin main'
# shellcheck disable=SC2016  # literal payload: the guard must resolve the assigned command name
run_guard 0 "$TMP/repo" 'G=git; "$G" status --short'

git -C "$TMP/repo" config alias.publish push
git -C "$TMP/repo" config alias.shell-publish '!git push'
run_guard 2 "$TMP/repo" 'git publish origin main'
run_guard 2 "$TMP/repo" 'git shell-publish origin main'
run_guard 2 "$TMP/repo" 'git -c alias.inline-publish=push inline-publish origin main'
run_guard 2 "$TMP/repo" 'git config alias.staged-publish push && git staged-publish origin main'
run_guard 0 "$TMP/repo" 'git config alias.inspect status && git inspect --short'
run_guard 2 "$TMP/repo" "bash -lc 'eval -- \"zsh -lc '\"'\"'git push origin main'\"'\"'\"'"

git -C "$TMP/repo" switch -c feature >/dev/null 2>&1
printf 'feature\n' >>"$TMP/repo/file.txt"
git -C "$TMP/repo" commit -am feature >/dev/null
run_guard 0 "$TMP/repo" 'git push origin feature'
run_guard 0 "$TMP/repo" 'git push origin main:feature-copy'
run_guard 2 "$TMP/repo" 'git push origin feature:refs/heads/main'
run_guard 2 "$TMP/repo" 'git push origin refs/heads/*:refs/heads/*'
run_guard 2 "$TMP/repo" 'git push origin feature:refs/heads/m*'
run_guard 0 "$TMP/repo" 'git push origin refs/heads/feature*:refs/heads/release/*'
run_guard 0 "$TMP/repo" 'git commit --amend --no-edit'

git -C "$TMP/repo" push -u origin feature >/dev/null 2>&1
git -C "$TMP/repo" config --add remote.origin.push HEAD:refs/heads/main
run_guard 2 "$TMP/repo" 'git push origin'
run_guard 2 "$TMP/repo" 'git push'
git -C "$TMP/repo" config --unset-all remote.origin.push
git -C "$TMP/repo" config --add remote.origin.push HEAD:refs/heads/release
run_guard 0 "$TMP/repo" 'git push origin'
git -C "$TMP/repo" config --unset-all remote.origin.push
run_guard 2 "$TMP/repo" 'git commit --amend --no-edit'
run_guard 2 "$TMP/repo" 'git commit -m "fix" -m "Co-Authored-By: Bot <bot@example.com>"'
run_guard 2 "$TMP/repo" 'git commit -m "Generated-by automation"'
printf 'subject\n\nGenerated with Codex\n' >"$TMP/repo/message.txt"
run_guard 2 "$TMP/repo" 'git commit -F message.txt'
run_guard 2 "$TMP/repo" 'git commit -F -'
run_guard 2 "$TMP/repo" 'git commit -F-'
run_guard 2 "$TMP/repo" 'git commit --file=-'
run_guard 2 "$TMP/repo" 'git commit --file /dev/stdin'
run_guard 0 "$TMP/repo" 'git commit -m "ordinary message"'
pass 'push, attribution, and pushed-amend policies resist adversarial command shapes'

sentinel=$(git -C "$TMP/repo" rev-parse --git-path codex-submit-pr-go)
[[ "$sentinel" = /* ]] || sentinel="$TMP/repo/$sentinel"
run_guard 2 "$TMP/repo" 'gh pr create --title test'
run_guard 2 "$TMP/repo" 'gh api -X POST repos/example/project/pulls -f title=test'
run_guard 2 "$TMP/repo" 'gh-axi api repos/example/project/pulls -f title=test -f head=feature'
run_guard 2 "$TMP/repo" 'gh api graphql -f query="mutation { createPullRequest(input: {}) { pullRequest { id } } }"'
# shellcheck disable=SC2016  # literal payload: the guard must resolve the assigned command name
run_guard 2 "$TMP/repo" 'GH=gh; "$GH" api --method POST repos/example/project/pulls'
run_guard 0 "$TMP/repo" 'gh api repos/example/project/pulls'
run_guard 0 "$TMP/repo" 'gh-axi api --method GET repos/example/project/pulls'
run_guard 0 "$TMP/repo" 'gh api graphql -f query="{ viewer { login } }"'
touch "$sentinel"
run_guard 0 "$TMP/repo" 'gh pr create --title test'
[[ ! -e "$sentinel" ]] || fail 'submit sentinel was not consumed'
touch "$sentinel"
run_guard 0 "$TMP/repo" 'gh-axi api --method POST repos/example/project/pulls -f title=approved'
[[ ! -e "$sentinel" ]] || fail 'submit sentinel was not consumed by raw pull-request creation'
run_guard 2 "$TMP/repo" 'gh pr create --title second'
run_guard 2 "$TMP/repo" 'gh pr ready 42'
touch "$sentinel"
run_guard 0 "$TMP/repo" 'gh pr ready 42'
[[ ! -e "$sentinel" ]] || fail 'submit sentinel was not consumed by gh pr ready'
run_guard 2 "$TMP/repo" 'gh-axi pr ready 42'
touch "$sentinel"
run_guard 0 "$TMP/repo" 'gh-axi pr ready 42'
[[ ! -e "$sentinel" ]] || fail 'submit sentinel was not consumed by gh-axi pr ready'
run_guard 2 "$TMP/repo" 'npx -y gh-axi pr create --title house-cli'
run_guard 2 "$TMP/repo" 'npx -y gh-axi@latest pr create --title versioned-house-cli'
touch "$sentinel"
run_guard 0 "$TMP/repo" 'npx -y gh-axi@1.2.3 pr ready 42'
[[ ! -e "$sentinel" ]] || fail 'submit sentinel was not consumed by versioned npx gh-axi pr ready'
touch "$sentinel"
run_guard 2 "$TMP/repo" 'gh pr create --title one && gh-axi pr ready 42'
[[ -e "$sentinel" ]] || fail 'ambiguous multiple-action command consumed the sentinel'
rm -f "$sentinel"
run_guard 0 "$TMP/repo" 'gh pr view 42'

custom_sentinel="$TMP/custom-submit-go"
touch "$custom_sentinel"
export CODEX_SUBMIT_SENTINEL="$custom_sentinel"
run_guard 0 "$TMP/repo" 'gh-axi pr create --title configured'
unset CODEX_SUBMIT_SENTINEL
[[ ! -e "$custom_sentinel" ]] || fail 'configured submit sentinel was not consumed'
pass 'pull-request sentinel is project-local, one-shot, and cannot authorize two actions'

set +e
printf '{not-json' | python3 "$GUARD" >/dev/null 2>&1
invalid_status=$?
set -e
[[ "$invalid_status" -eq 0 ]] || fail 'malformed hook input did not fail open'

compatibility=$(jq -nc --arg cwd "$TMP/repo" '{cwd:$cwd,tool_input:{cmd:"git push origin main"}}')
set +e
compatibility_output=$(printf '%s\n' "$compatibility" | python3 "$GUARD" 2>&1)
compatibility_status=$?
set -e
[[ "$compatibility_status" -eq 2 && "$compatibility_output" == BLOCKED:* ]] || fail 'unified-exec cmd compatibility input failed'
canonical_priority=$(jq -nc --arg cwd "$TMP/repo" '{cwd:$cwd,tool_input:{command:"git status --short",cmd:"git push origin main"}}')
set +e
printf '%s\n' "$canonical_priority" | python3 "$GUARD" >/dev/null 2>&1
canonical_priority_status=$?
set -e
[[ "$canonical_priority_status" -eq 0 ]] || fail 'compatibility cmd overrode canonical command input'
pass 'canonical Codex command payload and secondary unified-exec cmd payload are both handled'

GUARD="$GUARD" REPO="$TMP/repo" python3 - <<'PY'
import json
import os
import subprocess
import time

command = "eval -- " * 80 + "git status --short"
payload = json.dumps({"cwd": os.environ["REPO"], "tool_input": {"command": command}})
started = time.monotonic()
result = subprocess.run(
    ["python3", os.environ["GUARD"]],
    input=payload,
    capture_output=True,
    text=True,
    timeout=2,
    check=False,
)
elapsed = time.monotonic() - started
assert result.returncode == 2, result
assert "safe inspection depth" in result.stderr, result.stderr
assert elapsed < 2, elapsed
print(f"PASS: nested eval inspection failed closed in {elapsed:.3f}s")
PY

jq -e '
  (.hooks | keys == ["PreToolUse"]) and
  (.hooks.PreToolUse | length == 1) and
  (.hooks.PreToolUse[0].matcher == "Bash") and
  (.hooks.PreToolUse[0].hooks[0].type == "command") and
  (.hooks.PreToolUse[0].hooks[0].command == "python3 \"$(git rev-parse --show-toplevel)/.codex/hooks/git-guard.py\"") and
  (.hooks.PreToolUse[0].hooks[0].timeout == 10)
' "$HOOKS" >/dev/null || fail 'project hook declaration does not match the proven Codex schema'

hook_command=$(jq -r '.hooks.PreToolUse[0].hooks[0].command' "$HOOKS")
set +e
subdir_status=$(cd "$ROOT/tests" && payload "$ROOT" 'git status --short' | sh -c "$hook_command"; printf '%s' "$?")
set -e
[[ "$subdir_status" -eq 0 ]] || fail 'project-root hook command failed from a repository subdirectory'
pass 'project declaration installs only the load-bearing PreToolUse hook'

if command -v codex >/dev/null 2>&1; then
  CODEX_HOME_PROBE="$TMP/codex-home"
  PROJECT_PROBE="$CODEX_HOME_PROBE/project"
  mkdir -p "$PROJECT_PROBE/.codex"
  cp "$HOOKS" "$PROJECT_PROBE/.codex/hooks.json"
  cat >"$CODEX_HOME_PROBE/hooks.json" <<'JSON'
{"hooks":{"SessionStart":[{"matcher":"","hooks":[{"type":"command","command":"global-probe","timeout":10}]}]}}
JSON
  cat >"$CODEX_HOME_PROBE/config.toml" <<EOF
[projects."$PROJECT_PROBE"]
trust_level = "trusted"
[features]
hooks = true
EOF

  CODEX_HOME="$CODEX_HOME_PROBE" PROJECT_PROBE="$PROJECT_PROBE" python3 - <<'PY'
import json
import os
import selectors
import subprocess
import time

process = subprocess.Popen(
    ["codex", "app-server", "--stdio"],
    cwd=os.environ["PROJECT_PROBE"],
    env=os.environ,
    stdin=subprocess.PIPE,
    stdout=subprocess.PIPE,
    stderr=subprocess.DEVNULL,
    text=True,
)
messages = [
    {"id": 1, "method": "initialize", "params": {"clientInfo": {"name": "hook-test", "version": "1"}, "capabilities": {}}},
    {"method": "initialized", "params": {}},
    {"id": 2, "method": "hooks/list", "params": {}},
]
for message in messages:
    assert process.stdin is not None
    process.stdin.write(json.dumps(message) + "\n")
    process.stdin.flush()

assert process.stdout is not None
selector = selectors.DefaultSelector()
selector.register(process.stdout, selectors.EVENT_READ)
deadline = time.monotonic() + 5
response = None
while response is None and time.monotonic() < deadline:
    events = selector.select(deadline - time.monotonic())
    if not events:
        break
    line = process.stdout.readline()
    if not line:
        break
    message = json.loads(line)
    if message.get("id") == 2:
        response = message
process.terminate()
process.communicate(timeout=3)
assert response is not None
entry = response["result"]["data"][0]
assert entry["warnings"] == []
assert entry["errors"] == []
hooks = entry["hooks"]
assert [(hook["source"], hook["command"]) for hook in hooks] == [
    ("user", "global-probe"),
    ("project", 'python3 "$(git rev-parse --show-toplevel)/.codex/hooks/git-guard.py"'),
]
assert [hook["displayOrder"] for hook in hooks] == [0, 1]
PY
  pass 'Codex app-server proves project hooks compose after existing global hooks'
else
  pass 'Codex app-server hook composition probe skipped because codex CLI is absent'
fi

if rg -n '\.claude|CLAUDE|Claude|SessionStart|UserPromptSubmit|session-title|pre-commit-install' "$GUARD" "$HOOKS"; then
  fail 'forbidden Claude artifact or unproven optional hook landed'
fi
for optional in session-title.sh session-rename-nudge.sh pre-commit-install.sh; do
  [[ ! -e "$ROOT/.codex/hooks/$optional" ]] || fail "unproven optional hook landed: $optional"
done
pass 'no Claude artifact or unproven optional hook landed'

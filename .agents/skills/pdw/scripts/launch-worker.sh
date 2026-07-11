#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: launch-worker.sh --worktree DIR --role-file FILE --model MODEL --effort LEVEL
                        --sandbox MODE --prompt-file FILE --events-file FILE
                        --last-message-file FILE --evidence-file FILE [options]

Options:
  --parallel-lanes N    Required with Ultra and must be at least two.
  --require-commit      Require a clean worktree and a new commit before return.
  --base-sha SHA        Starting SHA used with --require-commit.

The carrier pins command-line controls but records effective controls as unverified
unless the launched process itself returns evidence that proves them.
EOF
}

worktree=""
role_file=""
model=""
effort=""
sandbox=""
prompt_file=""
events_file=""
last_message_file=""
evidence_file=""
parallel_lanes=0
require_commit=false
base_sha=""

while (($#)); do
  case "$1" in
    --worktree) worktree=${2:-}; shift 2 ;;
    --role-file) role_file=${2:-}; shift 2 ;;
    --model) model=${2:-}; shift 2 ;;
    --effort) effort=${2:-}; shift 2 ;;
    --sandbox) sandbox=${2:-}; shift 2 ;;
    --prompt-file) prompt_file=${2:-}; shift 2 ;;
    --events-file) events_file=${2:-}; shift 2 ;;
    --last-message-file) last_message_file=${2:-}; shift 2 ;;
    --evidence-file) evidence_file=${2:-}; shift 2 ;;
    --parallel-lanes) parallel_lanes=${2:-}; shift 2 ;;
    --require-commit) require_commit=true; shift ;;
    --base-sha) base_sha=${2:-}; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) printf 'unknown argument: %s\n' "$1" >&2; usage >&2; exit 2 ;;
  esac
done

for required in worktree role_file model effort sandbox prompt_file events_file last_message_file evidence_file; do
  [[ -n ${!required} ]] || { printf 'missing required option: %s\n' "$required" >&2; exit 2; }
done
[[ -d "$worktree" && "$worktree" == */.claude/worktrees/* ]] || { printf 'worktree must be an existing target-repo .claude/worktrees path\n' >&2; exit 2; }
git -C "$worktree" rev-parse --is-inside-work-tree >/dev/null 2>&1 || { printf 'worktree is not a git worktree\n' >&2; exit 2; }
[[ -f "$role_file" ]] || { printf 'role file not found\n' >&2; exit 2; }
[[ -f "$prompt_file" ]] || { printf 'prompt file not found\n' >&2; exit 2; }
[[ "$parallel_lanes" =~ ^[0-9]+$ ]] || { printf 'parallel lanes must be a non-negative integer\n' >&2; exit 2; }
case "$sandbox" in
  read-only|workspace-write) ;;
  *) printf 'unsupported worker sandbox: %s\n' "$sandbox" >&2; exit 2 ;;
esac

fallback_applied=false
case "$effort" in
  light) codex_effort=low ;;
  medium) codex_effort=medium ;;
  high) codex_effort=high ;;
  max) codex_effort=xhigh ; fallback_applied=true ;;
  ultra)
    ((parallel_lanes >= 2)) || { printf 'Ultra requires at least two explicit independent lanes\n' >&2; exit 2; }
    codex_effort=xhigh
    fallback_applied=true
    ;;
  *) printf 'unknown requested effort: %s\n' "$effort" >&2; exit 2 ;;
esac

if [[ "$require_commit" == true ]]; then
  [[ -n "$base_sha" ]] || { printf 'base SHA is required with --require-commit\n' >&2; exit 2; }
  git -C "$worktree" rev-parse --verify "$base_sha^{commit}" >/dev/null 2>&1 || { printf 'base SHA is not a commit\n' >&2; exit 2; }
fi

role_instructions=$(awk '
  /^developer_instructions = """$/ {inside=1; next}
  inside && /^"""$/ {exit}
  inside {print}
' "$role_file")
[[ -n "$role_instructions" ]] || { printf 'role file has no developer_instructions block\n' >&2; exit 2; }
role_toml=$(jq -Rn --arg value "$role_instructions" '$value')
mkdir -p "$(dirname "$events_file")" "$(dirname "$last_message_file")" "$(dirname "$evidence_file")"

set +e
codex exec \
  --json \
  --color never \
  --model "$model" \
  -c "model_reasoning_effort=\"$codex_effort\"" \
  -c 'approval_policy="never"' \
  -c "developer_instructions=$role_toml" \
  --sandbox "$sandbox" \
  -C "$worktree" \
  --output-last-message "$last_message_file" \
  - <"$prompt_file" >"$events_file" 2>"$events_file.stderr"
launch_exit=$?
set -e

last_commit_sha=$(git -C "$worktree" rev-parse HEAD)
worktree_clean=false
[[ -z $(git -C "$worktree" status --porcelain) ]] && worktree_clean=true
commit_requirement_met=true
if [[ "$require_commit" == true ]]; then
  if [[ "$worktree_clean" != true || "$last_commit_sha" == "$base_sha" ]]; then
    commit_requirement_met=false
  fi
fi

jq -n \
  --arg requested_model "$model" \
  --arg requested_effort "$effort" \
  --arg carrier_effort "$codex_effort" \
  --arg requested_sandbox "$sandbox" \
  --arg role_file "$role_file" \
  --arg worktree "$worktree" \
  --arg events_file "$events_file" \
  --arg last_message_file "$last_message_file" \
  --arg last_commit_sha "$last_commit_sha" \
  --arg effective_model "unverified_from_process_output" \
  --arg effective_effort "unverified_from_process_output" \
  --arg effective_sandbox "unverified_from_process_output" \
  --argjson launch_exit "$launch_exit" \
  --argjson fallback_applied "$fallback_applied" \
  --argjson worktree_clean "$worktree_clean" \
  --argjson commit_requirement_met "$commit_requirement_met" \
  '{requested_model: $requested_model, requested_effort: $requested_effort, carrier_effort: $carrier_effort, requested_sandbox: $requested_sandbox, role_file: $role_file, worktree: $worktree, events_file: $events_file, last_message_file: $last_message_file, launch_exit: $launch_exit, fallback_applied: $fallback_applied, effective_model: $effective_model, effective_effort: $effective_effort, effective_sandbox: $effective_sandbox, enforcement_verified: false, worktree_clean: $worktree_clean, commit_requirement_met: $commit_requirement_met, last_commit_sha: $last_commit_sha}' >"$evidence_file"

if ((launch_exit != 0)); then
  printf 'codex exec failed; see %s and %s.stderr\n' "$events_file" "$events_file" >&2
  exit "$launch_exit"
fi
if [[ "$commit_requirement_met" != true ]]; then
  printf 'writer returned without a new clean commit\n' >&2
  exit 1
fi
cat "$evidence_file"

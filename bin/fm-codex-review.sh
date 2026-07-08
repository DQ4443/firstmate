#!/usr/bin/env bash
# Run a read-only Codex review fan-out over a repository diff.
# Usage: fm-codex-review.sh <repo-dir> <review-brief-file> [--diff-base <ref>]
set -euo pipefail

usage() {
  cat >&2 <<'EOF'
Usage: fm-codex-review.sh <repo-dir> <review-brief-file> [--diff-base <ref>]

Runs Codex in read-only mode and emits:
{repo, diff_base, findings: [{severity, file, summary}], verdict}
EOF
}

die_usage() {
  echo "error: $1" >&2
  usage
  exit 2
}

json_escape() {
  local s=${1:-}
  s=${s//\\/\\\\}
  s=${s//\"/\\\"}
  s=${s//$'\n'/\\n}
  s=${s//$'\r'/\\r}
  s=${s//$'\t'/\\t}
  printf '%s' "$s"
}

compact_text() {
  printf '%s' "${1:-}" | tr '\r\n\t' '   '
}

emit_manual_failure() {
  local severity=$1 file=$2 summary=$3
  printf '{"repo":"%s","diff_base":"%s","findings":[{"severity":"%s","file":"%s","summary":"%s"}],"verdict":"concerns"}\n' \
    "$(json_escape "${REPO:-}")" \
    "$(json_escape "${DIFF_BASE:-}")" \
    "$(json_escape "$severity")" \
    "$(json_escape "$file")" \
    "$(json_escape "$(compact_text "$summary")")"
}

canonical_dir() {
  local path=$1
  [ -d "$path" ] || return 1
  cd "$path" && pwd -P
}

canonical_file() {
  local path=$1 dir base
  [ -f "$path" ] || return 1
  dir=$(dirname "$path")
  base=$(basename "$path")
  dir=$(canonical_dir "$dir") || return 1
  printf '%s/%s\n' "$dir" "$base"
}

repo_root() {
  local path=$1 top
  top=$(git -C "$path" rev-parse --show-toplevel 2>/dev/null) || return 1
  canonical_dir "$top"
}

ref_has_safe_shape() {
  case "$1" in
    ''|-*|*[$'\n\r\t ']*)
      return 1
      ;;
  esac
  return 0
}

shell_quote() {
  printf "'"
  printf '%s' "$1" | sed "s/'/'\\\\''/g"
  printf "'"
}

make_temp_file() {
  mktemp "${TMPDIR:-/tmp}/fm-codex-review.XXXXXX"
}

cleanup() {
  [ -z "${STDOUT_FILE:-}" ] || rm -f "$STDOUT_FILE"
  [ -z "${STDERR_FILE:-}" ] || rm -f "$STDERR_FILE"
  [ -z "${MSG_FILE:-}" ] || rm -f "$MSG_FILE"
}
trap cleanup EXIT

REPO_ARG=${1:-}
BRIEF_ARG=${2:-}
[ "$#" -ge 2 ] || die_usage "missing required arguments"
shift 2

DIFF_BASE=main
while [ "$#" -gt 0 ]; do
  case "$1" in
    --diff-base)
      [ "$#" -ge 2 ] || die_usage "--diff-base requires a value"
      DIFF_BASE=$2
      shift 2
      ;;
    --diff-base=*)
      DIFF_BASE=${1#--diff-base=}
      [ -n "$DIFF_BASE" ] || die_usage "--diff-base requires a value"
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      die_usage "unknown argument: $1"
      ;;
  esac
done

ref_has_safe_shape "$DIFF_BASE" || die_usage "--diff-base must be a non-empty git ref without whitespace or a leading dash"
REPO=$(canonical_dir "$REPO_ARG") || die_usage "repo-dir does not exist or is not a directory: $REPO_ARG"
REPO=$(repo_root "$REPO") || die_usage "repo-dir is not inside a git repository: $REPO_ARG"
BRIEF=$(canonical_file "$BRIEF_ARG") || die_usage "review-brief-file does not exist or is not a file: $BRIEF_ARG"
[ -r "$BRIEF" ] || die_usage "review-brief-file is not readable: $BRIEF"

if ! command -v jq >/dev/null 2>&1; then
  emit_manual_failure high "" "jq is required to normalize Codex review output"
  exit 1
fi
if ! command -v codex >/dev/null 2>&1; then
  emit_manual_failure high "" "codex is not installed or not on PATH"
  exit 1
fi
if ! git -C "$REPO" rev-parse --verify "$DIFF_BASE^{commit}" >/dev/null 2>&1; then
  emit_manual_failure high "" "diff base does not resolve to a commit: $DIFF_BASE"
  exit 1
fi

REVIEW_BRIEF=$(cat "$BRIEF")
DIFF_BASE_ARG=$(shell_quote "$DIFF_BASE")
PROMPT=$(cat <<EOF
You are the GPT-5.5 review parent for firstmate.
Run a read-only review of this repository diff.

Repository: $REPO
Diff base ref: $DIFF_BASE

Review brief:
$REVIEW_BRIEF

Use Codex native parallel subagents.
Spawn three read-only subagents in parallel: correctness, security, and regressions.
Each subagent should inspect the current diff with git diff --stat $DIFF_BASE_ARG...HEAD -- and git diff --no-ext-diff $DIFF_BASE_ARG...HEAD --, then read any relevant surrounding files.
Consolidate duplicate findings.
Return only JSON, with no markdown and no prose.
The JSON may be either a findings array or an object with findings and verdict.
Each finding must have severity, file, and summary.
Use verdict "pass" only when there are no findings, otherwise use "concerns".
EOF
)

STDOUT_FILE=$(make_temp_file)
STDERR_FILE=$(make_temp_file)
MSG_FILE=$(make_temp_file)

# --output-last-message writes ONLY the agent's final message (the JSON we asked
# for), stripping the session/tool/token chatter that codex exec prints to stdout
# and that would otherwise make jq fail on every run (review reported as a false
# "concerns" failure). We parse that file, not raw stdout.
CODEX_RC=0
if codex exec --model gpt-5.5 -c model_reasoning_effort=xhigh --sandbox read-only \
  --skip-git-repo-check -o "$MSG_FILE" -C "$REPO" "$PROMPT" >"$STDOUT_FILE" 2>"$STDERR_FILE"; then
  CODEX_RC=0
else
  CODEX_RC=$?
fi

if [ "$CODEX_RC" -ne 0 ]; then
  STDERR_TAIL=$(tail -20 "$STDERR_FILE" 2>/dev/null || true)
  emit_manual_failure high "" "codex review failed with exit $CODEX_RC: $STDERR_TAIL"
  exit 1
fi

NORMALIZED=$(jq -c '
  def as_text: if . == null then "" else tostring end;
  if type == "array" then
    {findings: ., verdict: (if length == 0 then "pass" else "concerns" end)}
  elif type == "object" then
    {findings: (.findings // []), verdict: (.verdict // "")}
  else
    error("expected object or array")
  end
  | if (.findings | type) != "array" then error("findings must be an array") else . end
  # rawcount is the count BEFORE dropping non-object entries, so a malformed
  # non-empty findings array cannot be filtered down to empty and reported as a
  # false "pass". Any findings at all (valid or malformed) => concerns (fail closed).
  | .rawcount = (.findings | length)
  | .findings = [
      .findings[]
      | select(type == "object")
      | {
          severity: ((.severity // "medium") | as_text),
          file: ((.file // "") | as_text),
          summary: ((.summary // .message // .title // "") | as_text)
        }
    ]
  | .verdict =
      (if (.rawcount == 0 and .verdict != "concerns") then "pass" else "concerns" end)
  | del(.rawcount)
' < <(sed -e 's/^[[:space:]]*```[a-zA-Z]*[[:space:]]*$//' "$MSG_FILE") 2>/dev/null) || {
  MSG_TAIL=$(tail -20 "$MSG_FILE" 2>/dev/null || true)
  emit_manual_failure high "" "codex review returned invalid JSON: $MSG_TAIL"
  exit 1
}

jq -c -n \
  --arg repo "$REPO" \
  --arg diff_base "$DIFF_BASE" \
  --argjson review "$NORMALIZED" \
  '{repo: $repo, diff_base: $diff_base, findings: $review.findings, verdict: $review.verdict}'

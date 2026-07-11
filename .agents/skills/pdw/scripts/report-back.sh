#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: report-back.sh [--state-dir DIR] COMMAND [arguments]

Commands:
  prepare --report FILE [--queue]
  claim --key REPORT_KEY
  drain
  ack --key REPORT_KEY
  receive --key REPORT_KEY [--receipt FILE]

The adapter stores at-least-once delivery state and prints payloads for the
parent to send with the native send_message_to_thread tool.
It never calls that tool itself.
EOF
}

state_dir="state/report-delivery"
if [[ ${1:-} == --state-dir ]]; then
  state_dir=${2:-}
  shift 2
fi
command=${1:-}
[[ -n "$command" ]] || { usage >&2; exit 2; }
shift

for dependency in jq shasum; do
  command -v "$dependency" >/dev/null || { printf 'missing dependency: %s\n' "$dependency" >&2; exit 2; }
done

config="$state_dir/config.json"
[[ -f "$config" ]] || { printf 'missing report configuration: %s\n' "$config" >&2; exit 2; }
jq -e '
  (.retry_max_attempts | type == "number" and . >= 1 and floor == .) and
  (.claim_ttl_seconds | type == "number" and . >= 1 and floor == .) and
  (.drain_batch_size | type == "number" and . >= 1 and floor == .)
' "$config" >/dev/null || { printf 'invalid report configuration: %s\n' "$config" >&2; exit 2; }

retry_max=$(jq -r '.retry_max_attempts' "$config")
claim_ttl=$(jq -r '.claim_ttl_seconds' "$config")
drain_batch=$(jq -r '.drain_batch_size' "$config")
for dir in pending retry inflight sent exhausted received tmp; do
  mkdir -p "$state_dir/$dir"
done

now_epoch() {
  date +%s
}

now_iso() {
  date -u +%Y-%m-%dT%H:%M:%SZ
}

atomic_write() {
  local destination=$1
  local content_file=$2
  local temporary
  temporary="$state_dir/tmp/.$(basename "$destination").$$"
  cp "$content_file" "$temporary"
  mv "$temporary" "$destination"
}

lock() {
  local lock_dir="$state_dir/.lock"
  mkdir "$lock_dir" 2>/dev/null || { printf 'report state is busy\n' >&2; exit 1; }
  trap 'rmdir "$lock_dir" 2>/dev/null || true' EXIT
}

unlock() {
  rmdir "$state_dir/.lock" 2>/dev/null || true
  trap - EXIT
}

parse_key() {
  local value=""
  while (($#)); do
    case "$1" in
      --key) value=${2:-}; shift 2 ;;
      *) printf 'unknown argument: %s\n' "$1" >&2; exit 2 ;;
    esac
  done
  [[ "$value" =~ ^[a-f0-9]{64}$ ]] || { printf 'invalid report key\n' >&2; exit 2; }
  printf '%s' "$value"
}

case "$command" in
  prepare)
    report_file=""
    queue=false
    while (($#)); do
      case "$1" in
        --report) report_file=${2:-}; shift 2 ;;
        --queue) queue=true; shift ;;
        *) printf 'unknown argument: %s\n' "$1" >&2; exit 2 ;;
      esac
    done
    [[ -f "$report_file" ]] || { printf 'missing report file\n' >&2; exit 2; }
    jq -e '
      (.task_id | type == "string" and length > 0) and
      (.return_thread_id | type == "string" and length > 0) and
      (.return_host_id | type == "string" and length > 0) and
      (.status | IN("COMPLETE", "BLOCKED", "NEEDS DECISION")) and
      (.requested_status | IN("COMPLETE", "BLOCKED", "NEEDS DECISION")) and
      (.effective_status | IN("COMPLETE", "BLOCKED", "NEEDS DECISION")) and
      (.summary | type == "string" and length > 0) and
      (.commands | type == "array") and
      (.artifacts | type == "array") and
      (.branch | type == "string") and
      (.worktree | type == "string") and
      (.last_commit_sha | type == "string") and
      (.requested_model | type == "string" and length > 0) and
      (.effective_model | type == "string" and length > 0) and
      (.requested_effort | IN("light", "medium", "high", "max", "ultra")) and
      (.effective_effort | IN("light", "medium", "high", "max", "ultra", "unavailable_to_pin_in_native_subagent_api", "unverified_from_process_output")) and
      (.routing_rationale | type == "string" and length > 0) and
      (.identifiers | type == "object") and
      (.child_returns | type == "array") and
      (.NEXT_STEP | type == "string" and length > 0)
    ' "$report_file" >/dev/null || { printf 'invalid structured return\n' >&2; exit 2; }
    canonical=$(jq -Sc . "$report_file")
    key=$(printf '%s' "$canonical" | shasum -a 256 | awk '{print $1}')
    prompt=$(printf '%s\n\nREPORT_KEY: %s' "$canonical" "$key")
    destination=queued
    target_dir=retry
    if [[ "$queue" == false ]]; then
      destination=pending
      target_dir=pending
    fi
    lock
    if [[ -f "$state_dir/sent/$key.json" ]]; then
      unlock
      jq -n --arg key "$key" '{status: "already-acknowledged", report_key: $key}'
      exit 0
    fi
    if [[ -f "$state_dir/exhausted/$key.json" ]]; then
      unlock
      jq -n --arg key "$key" '{status: "already-exhausted", report_key: $key}'
      exit 0
    fi
    for existing_state in pending retry inflight; do
      if [[ -f "$state_dir/$existing_state/$key.json" ]]; then
        unlock
        jq -n --arg key "$key" --arg state "$existing_state" '{status: ("already-" + $state), report_key: $key}'
        exit 0
      fi
    done
    envelope=$(mktemp "$state_dir/tmp/prepare.XXXXXX")
    jq -n \
      --arg report_key "$key" \
      --arg thread_id "$(jq -r '.return_thread_id' "$report_file")" \
      --arg host_id "$(jq -r '.return_host_id' "$report_file")" \
      --arg prompt "$prompt" \
      --arg prepared_at "$(now_iso)" \
      --argjson report "$canonical" \
      '{report_key: $report_key, thread_id: $thread_id, host_id: $host_id, prompt: $prompt, prepared_at: $prepared_at, attempts: 0, report: $report}' >"$envelope"
    atomic_write "$state_dir/$target_dir/$key.json" "$envelope"
    rm -f "$envelope"
    unlock
    jq -n --arg status "$destination" --arg key "$key" --arg path "$state_dir/$target_dir/$key.json" '{status: $status, report_key: $key, path: $path}'
    ;;
  claim)
    key=$(parse_key "$@")
    lock
    if [[ -f "$state_dir/pending/$key.json" ]]; then
      mv "$state_dir/pending/$key.json" "$state_dir/retry/$key.json"
    fi
    source_file="$state_dir/retry/$key.json"
    [[ -f "$source_file" ]] || { unlock; printf 'retry not found: %s\n' "$key" >&2; exit 1; }
    attempts=$(jq -r '.attempts + 1' "$source_file")
    if ((attempts > retry_max)); then
      mv "$source_file" "$state_dir/exhausted/$key.json"
      unlock
      jq -n --arg key "$key" '{status: "exhausted", report_key: $key}'
      exit 0
    fi
    claimed=$(mktemp "$state_dir/tmp/claim.XXXXXX")
    jq --argjson attempts "$attempts" --argjson claimed_at_epoch "$(now_epoch)" --arg claimed_at "$(now_iso)" '.attempts = $attempts | .claimed_at_epoch = $claimed_at_epoch | .claimed_at = $claimed_at' "$source_file" >"$claimed"
    atomic_write "$state_dir/inflight/$key.json" "$claimed"
    rm -f "$claimed" "$source_file"
    unlock
    jq -c '. + {status: "claimed"}' "$state_dir/inflight/$key.json"
    ;;
  drain)
    (($# == 0)) || { printf 'drain takes no arguments\n' >&2; exit 2; }
    lock
    current=$(now_epoch)
    for pending in "$state_dir"/pending/*.json; do
      [[ -e "$pending" ]] || continue
      key=$(basename "$pending" .json)
      mv "$pending" "$state_dir/retry/$key.json"
    done
    for inflight in "$state_dir"/inflight/*.json; do
      [[ -e "$inflight" ]] || continue
      claimed_at=$(jq -r '.claimed_at_epoch // 0' "$inflight")
      if ((current - claimed_at >= claim_ttl)); then
        key=$(basename "$inflight" .json)
        jq 'del(.claimed_at_epoch, .claimed_at)' "$inflight" >"$state_dir/tmp/stale.$key.json"
        mv "$state_dir/tmp/stale.$key.json" "$state_dir/retry/$key.json"
        rm -f "$inflight"
      fi
    done
    output=$(mktemp "$state_dir/tmp/drain.XXXXXX")
    printf '[]\n' >"$output"
    count=0
    for retry in "$state_dir"/retry/*.json; do
      [[ -e "$retry" ]] || continue
      ((count < drain_batch)) || break
      key=$(basename "$retry" .json)
      attempts=$(jq -r '.attempts + 1' "$retry")
      if ((attempts > retry_max)); then
        mv "$retry" "$state_dir/exhausted/$key.json"
        continue
      fi
      claimed=$(mktemp "$state_dir/tmp/drain-claim.XXXXXX")
      jq --argjson attempts "$attempts" --argjson claimed_at_epoch "$current" --arg claimed_at "$(now_iso)" '.attempts = $attempts | .claimed_at_epoch = $claimed_at_epoch | .claimed_at = $claimed_at' "$retry" >"$claimed"
      atomic_write "$state_dir/inflight/$key.json" "$claimed"
      jq --slurpfile item "$claimed" '. + [($item[0] + {status: "claimed"})]' "$output" >"$output.next"
      mv "$output.next" "$output"
      rm -f "$claimed" "$retry"
      count=$((count + 1))
    done
    unlock
    cat "$output"
    rm -f "$output"
    ;;
  ack)
    key=$(parse_key "$@")
    lock
    source_file=""
    for candidate in "$state_dir/inflight/$key.json" "$state_dir/pending/$key.json"; do
      [[ -f "$candidate" ]] && source_file=$candidate
    done
    [[ -n "$source_file" ]] || { unlock; printf 'pending or inflight report not found: %s\n' "$key" >&2; exit 1; }
    acknowledged=$(mktemp "$state_dir/tmp/ack.XXXXXX")
    jq --arg acknowledged_at "$(now_iso)" '. + {acknowledged_at: $acknowledged_at}' "$source_file" >"$acknowledged"
    atomic_write "$state_dir/sent/$key.json" "$acknowledged"
    rm -f "$acknowledged" "$state_dir/pending/$key.json" "$state_dir/retry/$key.json" "$state_dir/inflight/$key.json"
    unlock
    jq -n --arg key "$key" '{status: "acknowledged", report_key: $key}'
    ;;
  receive)
    key=""
    receipt_file=""
    while (($#)); do
      case "$1" in
        --key) key=${2:-}; shift 2 ;;
        --receipt) receipt_file=${2:-}; shift 2 ;;
        *) printf 'unknown argument: %s\n' "$1" >&2; exit 2 ;;
      esac
    done
    [[ "$key" =~ ^[a-f0-9]{64}$ ]] || { printf 'invalid report key\n' >&2; exit 2; }
    if [[ -n "$receipt_file" ]]; then
      [[ -f "$receipt_file" ]] || { printf 'receipt file not found\n' >&2; exit 2; }
      jq -e . "$receipt_file" >/dev/null || { printf 'receipt file is not JSON\n' >&2; exit 2; }
    fi
    lock
    destination="$state_dir/received/$key.json"
    if [[ -f "$destination" ]]; then
      unlock
      jq -n --arg key "$key" '{status: "duplicate-suppressed", report_key: $key, apply_side_effects: false}'
      exit 0
    fi
    received=$(mktemp "$state_dir/tmp/receive.XXXXXX")
    if [[ -n "$receipt_file" ]]; then
      jq --arg key "$key" --arg received_at "$(now_iso)" '{report_key: $key, received_at: $received_at, receipt: .}' "$receipt_file" >"$received"
    else
      jq -n --arg key "$key" --arg received_at "$(now_iso)" '{report_key: $key, received_at: $received_at}' >"$received"
    fi
    atomic_write "$destination" "$received"
    rm -f "$received"
    unlock
    jq -n --arg key "$key" '{status: "received", report_key: $key, apply_side_effects: true}'
    ;;
  *)
    printf 'unknown command: %s\n' "$command" >&2
    usage >&2
    exit 2
    ;;
esac

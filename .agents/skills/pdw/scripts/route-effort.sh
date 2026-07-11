#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: route-effort.sh --task-kind KIND [options]

Options:
  --requested LEVEL       User override: light, medium, high, max, or ultra.
  --supported CSV         Supported levels in ascending capability order.
  --parallel-lanes N      Count of explicit independent lanes.
  --quota-state VALUE     Recorded for audit only and never changes routing.
  --enforced-effort LEVEL Effective level proven by the selected launcher.

Task kinds:
  mechanical, lookup, formatting, routine, summary, implementation,
  debugging, review, consequential, deep, large-parallel
EOF
}

task_kind=""
requested_override=""
supported_csv="light,medium,high,max,ultra"
parallel_lanes=0
quota_state="unspecified"
enforced_effort=""

while (($#)); do
  case "$1" in
    --task-kind) task_kind=${2:-}; shift 2 ;;
    --requested) requested_override=${2:-}; shift 2 ;;
    --supported) supported_csv=${2:-}; shift 2 ;;
    --parallel-lanes) parallel_lanes=${2:-}; shift 2 ;;
    --quota-state) quota_state=${2:-}; shift 2 ;;
    --enforced-effort) enforced_effort=${2:-}; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) printf 'unknown argument: %s\n' "$1" >&2; usage >&2; exit 2 ;;
  esac
done

case "$task_kind" in
  mechanical|lookup|formatting)
    classified=light
    rationale="low-ambiguity mechanical work"
    ;;
  routine|summary|implementation)
    classified=medium
    rationale="routine bounded work"
    ;;
  debugging|review|consequential)
    classified=high
    rationale="consequential work where mistakes are materially costly"
    ;;
  deep)
    classified=max
    rationale="one tightly coupled problem benefits from deeper single-agent exploration"
    ;;
  large-parallel)
    classified=ultra
    rationale="large objective has explicit independent parallel lanes"
    ;;
  *)
    printf 'unknown task kind: %s\n' "$task_kind" >&2
    exit 2
    ;;
esac

requested=${requested_override:-$classified}
case "$requested" in
  light|medium|high|max|ultra) ;;
  *) printf 'unknown requested effort: %s\n' "$requested" >&2; exit 2 ;;
esac

if [[ ! "$parallel_lanes" =~ ^[0-9]+$ ]]; then
  printf 'parallel lanes must be a non-negative integer\n' >&2
  exit 2
fi

override_applied=false
if [[ -n "$requested_override" ]]; then
  override_applied=true
  rationale="user override: $requested_override"
fi

ultra_gate_applied=false
if [[ "$requested" == ultra && "$parallel_lanes" -lt 2 ]]; then
  routed=max
  ultra_gate_applied=true
  rationale="$rationale; Ultra denied because fewer than two independent lanes were supplied"
else
  routed=$requested
fi

IFS=',' read -r -a supported <<<"$supported_csv"
for level in "${supported[@]}"; do
  case "$level" in
    light|medium|high|max|ultra) ;;
    *) printf 'unknown supported effort: %s\n' "$level" >&2; exit 2 ;;
  esac
done
if ((${#supported[@]} == 0)); then
  printf 'supported effort list must not be empty\n' >&2
  exit 2
fi

is_supported() {
  local wanted=$1
  local candidate
  for candidate in "${supported[@]}"; do
    [[ "$candidate" == "$wanted" ]] && return 0
  done
  return 1
}

rank() {
  case "$1" in
    light) printf '0' ;;
    medium) printf '1' ;;
    high) printf '2' ;;
    max) printf '3' ;;
    ultra) printf '4' ;;
  esac
}

effective=$routed
fallback_applied=false
if ! is_supported "$routed"; then
  target_rank=$(rank "$routed")
  best=""
  best_distance=99
  for candidate in light medium high max ultra; do
    is_supported "$candidate" || continue
    if [[ "$ultra_gate_applied" == true && "$candidate" == ultra ]]; then
      continue
    fi
    candidate_rank=$(rank "$candidate")
    distance=$((candidate_rank - target_rank))
    ((distance < 0)) && distance=$((-distance))
    if ((distance < best_distance)) || { ((distance == best_distance)) && ((candidate_rank < target_rank)); }; then
      best=$candidate
      best_distance=$distance
    fi
  done
  if [[ -z "$best" ]]; then
    printf 'no supported effort satisfies the Ultra parallel-lane gate\n' >&2
    exit 2
  fi
  effective=$best
  fallback_applied=true
  rationale="$rationale; $routed is unsupported, so $effective is the nearest supported fallback"
fi

selected_effort=$effective
effective="unavailable_to_pin_in_native_subagent_api"
enforcement_available=false
if [[ -n "$enforced_effort" ]]; then
  case "$enforced_effort" in
    light|medium|high|max|ultra) ;;
    *) printf 'unknown enforced effort: %s\n' "$enforced_effort" >&2; exit 2 ;;
  esac
  if [[ "$enforced_effort" != "$selected_effort" ]]; then
    printf 'enforced effort does not match selected effort\n' >&2
    exit 2
  fi
  effective=$enforced_effort
  enforcement_available=true
fi

jq -n \
  --arg requested_effort "$requested" \
  --arg selected_effort "$selected_effort" \
  --arg effective_effort "$effective" \
  --arg routing_rationale "$rationale" \
  --arg quota_state "$quota_state" \
  --argjson override_applied "$override_applied" \
  --argjson ultra_gate_applied "$ultra_gate_applied" \
  --argjson fallback_applied "$fallback_applied" \
  --argjson enforcement_available "$enforcement_available" \
  --argjson parallel_lanes "$parallel_lanes" \
  '{requested_effort: $requested_effort, selected_effort: $selected_effort, effective_effort: $effective_effort, routing_rationale: $routing_rationale, override_applied: $override_applied, ultra_gate_applied: $ultra_gate_applied, fallback_applied: $fallback_applied, enforcement_available: $enforcement_available, parallel_lanes: $parallel_lanes, quota_state: $quota_state, quota_changed_routing: false}'

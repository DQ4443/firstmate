#!/usr/bin/env bash
# Linear reconcile sweep: the missed-event safety net for the housekeeping
# daemon, meant to run about every six hours. Linear webhooks retry three times
# then auto-disable a persistently failing endpoint, so a dropped delivery can
# be lost. This sweep asks Linear directly for Engineering issues updated since
# the last cursor, compares them against the deliveries already on disk, and
# synthesizes digest events only for the genuine misses.
#
# It is silent when nothing was missed. With no API key it exits 0 without a
# word, so it is safe to schedule before the credential exists.
set -eu

HK_ROOT="${FM_HK_ROOT:-$HOME/fm-state/housekeeping}"
ENGINEERING_TEAM_ID="41cab207-4ecd-4dad-9d57-1163a7a24507"
GRAPHQL_ENDPOINT="${FM_HK_LINEAR_GRAPHQL:-https://api.linear.app/graphql}"

api_key_file="$HK_ROOT/secrets/linear-api-key"
cursor_file="$HK_ROOT/cursors/linear-reconcile-cursor"
incoming_dir="$HK_ROOT/queue/incoming"
processed_dir="$HK_ROOT/queue/processed"
done_dir="$HK_ROOT/linear/done"

die() { echo "hk-linear-reconcile: $1" >&2; exit "${2:-1}"; }
command -v jq >/dev/null 2>&1 || die "jq is required"
command -v curl >/dev/null 2>&1 || die "curl is required"

# No credential: silent no-op. The sweep can be scheduled before the key lands.
[ -r "$api_key_file" ] || exit 0
api_key=$(tr -d '\r\n' < "$api_key_file")
[ -n "$api_key" ] || exit 0

mkdir -p "$incoming_dir" "$(dirname "$cursor_file")"

run_ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
# Default lookback when there is no cursor yet: the last 24 hours.
cursor=$(cat "$cursor_file" 2>/dev/null || true)
if [ -z "$cursor" ]; then
  cursor=$(date -u -v-24H +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d '24 hours ago' +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo "1970-01-01T00:00:00Z")
fi

read -r -d '' query <<'GRAPHQL' || true
query Reconcile($teamId: ID!, $since: DateTimeOrDuration!) {
  issues(
    first: 250
    orderBy: updatedAt
    filter: { team: { id: { eq: $teamId } }, updatedAt: { gt: $since } }
  ) {
    nodes { id identifier title url updatedAt assignee { id name } state { name } }
    pageInfo { hasNextPage }
  }
}
GRAPHQL

payload=$(jq -n --arg q "$query" --arg teamId "$ENGINEERING_TEAM_ID" --arg since "$cursor" \
  '{query: $q, variables: {teamId: $teamId, since: $since}}')

response=$(curl -sS -X POST "$GRAPHQL_ENDPOINT" \
  -H "Authorization: $api_key" \
  -H "Content-Type: application/json" \
  --data "$payload") || die "Linear GraphQL request failed" 4

if printf '%s' "$response" | jq -e '.errors' >/dev/null 2>&1; then
  die "Linear GraphQL returned errors: $(printf '%s' "$response" | jq -c '.errors' | head -c 400)" 4
fi

nodes=$(printf '%s' "$response" | jq -c '.data.issues.nodes // []')
has_next=$(printf '%s' "$response" | jq -r '.data.issues.pageInfo.hasNextPage // false')
count=$(printf '%s' "$nodes" | jq 'length')

# Build the set of issue ids already witnessed on disk: raw deliveries in the
# Linear done/ tree (data.id and data.issue.id) plus normalized events already
# in the queue (their id field). done/ is authoritative; the queue is a second
# lens for events not yet folded into a digest.
seen_file=$(mktemp "${TMPDIR:-/tmp}/hk-reconcile-seen.XXXXXX")
trap 'rm -f "$seen_file"' EXIT

if [ -d "$done_dir" ]; then
  find "$done_dir" -type f -name '*.json' -print0 \
    | xargs -0 -r -n1 jq -r '[.data.id?, .data.issue.id?] | .[] | select(. != null)' 2>/dev/null >> "$seen_file" || true
fi
for dir in "$incoming_dir" "$processed_dir"; do
  [ -d "$dir" ] || continue
  find "$dir" -type f -name '*.json' -print0 \
    | xargs -0 -r -n1 jq -r '.id // empty' 2>/dev/null >> "$seen_file" || true
done
sort -u "$seen_file" -o "$seen_file"

synthesized=0
newest="$cursor"
for i in $(seq 0 $((count - 1))); do
  [ "$count" -gt 0 ] || break
  node=$(printf '%s' "$nodes" | jq -c ".[$i]")
  id=$(printf '%s' "$node" | jq -r '.id')
  updated=$(printf '%s' "$node" | jq -r '.updatedAt')
  # Track the newest updatedAt across the page for cursor advancement.
  if [ "$updated" \> "$newest" ]; then newest="$updated"; fi

  if grep -qxF "$id" "$seen_file"; then
    continue
  fi

  event=$(printf '%s' "$node" | jq -c '{
    v: 1,
    source: "linear",
    id: .id,
    ts: .updatedAt,
    kind: "issue",
    action: "update",
    actor: "reconcile",
    title: ((.identifier // "") + " " + (.title // "") | gsub("^\\s+|\\s+$"; "")),
    url: (.url // ""),
    severity: "digest",
    detail: ("reconcile: missed update, state " + (.state.name // "unknown"))
  }')

  ts_compact=$(printf '%s' "$updated" | tr -d ':-')
  id_safe=$(printf '%s' "$id" | tr -c 'A-Za-z0-9_.-' '_')
  target="$incoming_dir/${ts_compact}-linear-${id_safe}.json"
  tmp="$target.tmp.$$.$(date +%s)"
  printf '%s\n' "$event" > "$tmp"
  mv -f "$tmp" "$target"
  synthesized=$((synthesized + 1))
done

# Advance the cursor atomically. If a further page exists, resume from the newest
# updatedAt already fetched so the next sweep continues the backlog; otherwise
# jump to this run's start time, since everything up to it has been examined.
if [ "$has_next" = "true" ]; then
  new_cursor="$newest"
else
  new_cursor="$run_ts"
fi
cursor_tmp="$cursor_file.tmp.$$.$(date +%s)"
printf '%s\n' "$new_cursor" > "$cursor_tmp"
mv -f "$cursor_tmp" "$cursor_file"

# Silent unless something was actually missed.
if [ "$synthesized" -gt 0 ]; then
  echo "hk-linear-reconcile: synthesized $synthesized missed digest event(s)"
fi

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
query Reconcile($teamId: ID!, $since: DateTimeOrDuration!, $after: String) {
  issues(
    first: 250
    after: $after
    orderBy: updatedAt
    filter: { team: { id: { eq: $teamId } }, updatedAt: { gt: $since } }
  ) {
    nodes { id identifier title url updatedAt assignee { id name } state { name } }
    pageInfo { hasNextPage endCursor }
  }
}
GRAPHQL

# The API key never rides curl's argv, where any local account could read it via
# ps or /proc/<pid>/cmdline every time the sweep runs. It goes into a 0600 temp
# file that curl reads with its -H @file form; printf is a shell builtin, so the
# key is never an external process argument on that path either.
header_file=$(mktemp "${TMPDIR:-/tmp}/hk-reconcile-hdr.XXXXXX")
seen_file=$(mktemp "${TMPDIR:-/tmp}/hk-reconcile-seen.XXXXXX")
trap 'rm -f "$header_file" "$seen_file"' EXIT
chmod 600 "$header_file"
printf 'Authorization: %s\n' "$api_key" > "$header_file"

# Build the set of issue ids already witnessed on disk before fetching: raw
# deliveries in the Linear done/ tree (data.id and data.issue.id) plus
# normalized events already in the queue (their id field). done/ is
# authoritative; the queue is a second lens for events not yet folded into a
# digest.
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

# Walk every matching page within the run. Advancing the cursor to a single
# page's newest updatedAt would permanently skip the older, un-fetched misses
# under Linear's default descending order, defeating the reconcile in exactly
# the scenario it exists for: a webhook auto-disabled while more than one page
# of Engineering issues changed in a single window. Draining all pages and only
# then advancing the cursor to this run's start time is order-independent and
# never skips a miss. The page cap is a pure anti-runaway canary that a real
# Engineering team cannot legitimately reach; hitting it leaves the cursor
# unadvanced so the next run retries from the same point.
synthesized=0
after=""
page=0
page_cap=500
while :; do
  page=$((page + 1))
  if [ "$page" -gt "$page_cap" ]; then
    die "reconcile exceeded $page_cap pages; cursor left unadvanced for next run" 4
  fi

  payload=$(jq -n --arg q "$query" --arg teamId "$ENGINEERING_TEAM_ID" --arg since "$cursor" --arg after "$after" \
    '{query: $q, variables: {teamId: $teamId, since: $since, after: (if $after == "" then null else $after end)}}')

  response=$(curl -sS -X POST "$GRAPHQL_ENDPOINT" \
    -H @"$header_file" \
    -H "Content-Type: application/json" \
    --data "$payload") || die "Linear GraphQL request failed" 4

  if printf '%s' "$response" | jq -e '.errors' >/dev/null 2>&1; then
    die "Linear GraphQL returned errors: $(printf '%s' "$response" | jq -c '.errors' | head -c 400)" 4
  fi

  nodes=$(printf '%s' "$response" | jq -c '.data.issues.nodes // []')
  has_next=$(printf '%s' "$response" | jq -r '.data.issues.pageInfo.hasNextPage // false')
  end_cursor=$(printf '%s' "$response" | jq -r '.data.issues.pageInfo.endCursor // ""')
  count=$(printf '%s' "$nodes" | jq 'length')

  i=0
  while [ "$i" -lt "$count" ]; do
    node=$(printf '%s' "$nodes" | jq -c ".[$i]")
    i=$((i + 1))
    id=$(printf '%s' "$node" | jq -r '.id')
    updated=$(printf '%s' "$node" | jq -r '.updatedAt')

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

  if [ "$has_next" = "true" ] && [ -n "$end_cursor" ] && [ "$end_cursor" != "null" ]; then
    after="$end_cursor"
  else
    break
  fi
done

# Every matching page has been drained, so everything updated up to this run's
# start time has been examined. Advance the cursor to run_ts atomically.
cursor_tmp="$cursor_file.tmp.$$.$(date +%s)"
printf '%s\n' "$run_ts" > "$cursor_tmp"
mv -f "$cursor_tmp" "$cursor_file"

# Silent unless something was actually missed.
if [ "$synthesized" -gt 0 ]; then
  echo "hk-linear-reconcile: synthesized $synthesized missed digest event(s)"
fi

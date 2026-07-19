#!/usr/bin/env bash
# Housekeeping Linear worker.
# Deterministically normalizes one verified Linear webhook into the housekeeping
# event schema v1, classifies it, and routes it. There is no model turn and no
# board delivery: routing is pure code. Drop-rule events (things Linear already
# notifies David about natively) are logged and discarded; everything else is
# either handed to the sibling hk-classify.mjs router when present, or written
# straight into the contract's queue/incoming (and alerts/pending for blockers).
set -eu

# Everything this worker writes (normalized events, blocker alerts, the log, and
# the directories holding them) carries Linear content and must stay owner-only.
# The fallback path here runs when the shared classifier is absent, so it cannot
# lean on hk-classify.mjs's 0600 writes; a restrictive umask makes every file
# and directory created below owner-only regardless.
umask 077

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HK_ROOT="${FM_HK_ROOT:-$HOME/fm-state/housekeeping}"
CLASSIFY_BIN="${FM_HK_CLASSIFY_BIN:-$SCRIPT_DIR/housekeeping/hk-classify.mjs}"

# Contract identifiers (deterministic classification, never prose).
DAVID_ID="448a6290-609b-4651-b416-768eb0ac9c93"
DAVID_EMAIL="david.qu@kronosai.co"
ENGINEERING_TEAM_ID="41cab207-4ecd-4dad-9d57-1163a7a24507"

incoming_dir="$HK_ROOT/queue/incoming"
alerts_dir="$HK_ROOT/alerts/pending"
log_file="$HK_ROOT/linear/events.log"

event_file=${1:-}

die() { echo "fm-linear-event-worker: $1" >&2; exit 2; }
[ -n "$event_file" ] && [ -f "$event_file" ] || die "event file is required"
command -v jq >/dev/null 2>&1 || die "jq is required"

mkdir -p "$incoming_dir" "$alerts_dir" "$(dirname "$log_file")"

log_line() {
  printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$1" >> "$log_file"
}

# Atomic write: tmp in the same directory, then rename. Content on stdin. The
# tmp is forced to 0600 before the rename so the destination is owner-only even
# if the caller loosened the umask; the file holds Linear event or alert content.
atomic_write() {
  local target=$1 tmp
  tmp="$target.tmp.$$.$(date +%s 2>/dev/null || echo 0)"
  cat > "$tmp"
  chmod 600 "$tmp"
  mv -f "$tmp" "$target"
}

# Normalize + classify in one deterministic jq pass. Output is a decision:
#   {"decision":"drop","reason":"...","id":"...","title":"..."}
#   {"decision":"route","event":{schema v1...},"alert":"<sentence or null>"}
# The Engineering team id is passed for parity with the contract even though the
# current rules key on assignment and mentions rather than team.
decision=$(
  jq -c \
    --arg david "$DAVID_ID" \
    --arg davidEmail "$DAVID_EMAIL" \
    --arg eng "$ENGINEERING_TEAM_ID" \
    '
    def lc: if type == "string" then ascii_downcase else "" end;

    # Event timestamp: prefer the webhook delivery time, fall back to the
    # entity createdAt, then to now. Always emitted as ISO 8601 UTC.
    def event_ts:
      (.webhookTimestamp // null) as $w
      | if ($w | type) == "number" then ($w / 1000 | todate)
        elif ($w | type) == "string" and ($w | test("^[0-9]+$")) then (($w | tonumber) / 1000 | todate)
        else (.createdAt // (now | todate))
        end;

    (.type | lc) as $type
    | (.action | lc) as $action
    | (.data // {}) as $d
    | (.updatedFrom // {}) as $from

    # SLA signal. The dedicated convenience webhook is type IssueSLA with
    # action set/highRisk/breached; older issue payloads carry the state in
    # slaStatus/slaType/sla.status. The classifier recomputes severity from
    # kind and action, so an SLA event must keep kind IssueSLA and its SLA
    # action instead of flattening to issue/update. Only breached or high-risk
    # is a blocker: an SLA merely being set, or a future slaBreachesAt
    # timestamp, is not an emergency.
    | ([ ($d.slaStatus | lc), ($d.slaType | lc), ($d.sla.status | lc) ]) as $sla_fields
    | (($sla_fields | map(select(test("breach"))) | length) > 0) as $sla_breach_field
    | (($sla_fields | map(select(test("high[_ ]?risk"))) | length) > 0) as $sla_risk_field
    | (($type == "issuesla")
        or ($action | test("^(set|high[_-]?risk|breached)$"))
        or $sla_breach_field or $sla_risk_field) as $sla_event
    | (if ($action == "breached") or $sla_breach_field then "breached"
       elif ($action | test("^high[_-]?risk$")) or $sla_risk_field then "highRisk"
       else "set" end) as $sla_action
    | ($sla_event and ($sla_action != "set")) as $sla_blocker

    # Assignee of the entity, either the expanded object id or the flat id.
    | (($d.assignee.id // $d.assigneeId) // null) as $assignee_id
    | (($from | has("assigneeId")) or ($from | has("assignee"))) as $assignee_changed

    # Drop rule 1: an issue directly assigned to David. Linear notifies him.
    | (($type == "issue") and ($assignee_id == $david)
        and (($action == "create") or $assignee_changed)) as $drop_assign

    # Drop rule 2: a comment that @mentions David. Linear notifies him.
    | (($type == "comment")
        and (($d.body // "") | (contains($david) or contains($davidEmail)))) as $drop_mention

    | (if $sla_blocker then "blocker" else "digest" end) as $severity

    # Human title, one line, per entity kind.
    | (if $type == "comment" then
         ("Comment on " + ($d.issue.identifier // "issue") + " " + ($d.issue.title // ""))
       elif $type == "project" then
         ("Project: " + ($d.name // ($d.id // "")))
       elif ($d.identifier != null) then
         (($d.identifier // "") + " " + ($d.title // ""))
       else
         ((.type // "Linear") + ": " + ($d.title // $d.name // ($d.id // "")))
       end | gsub("^\\s+|\\s+$"; "") | gsub("\\s+"; " ")) as $title

    | ((($d.url // .url) // ($d.issue.url // "")) // "") as $url
    | (.actor.name // .actor.email // "") as $actor

    # Short detail line, deterministic per change kind.
    | (if $type == "comment" then
         (($d.body // "") | gsub("\\s+"; " ") | .[0:140])
       elif $sla_event then
         ("SLA " + ([ ($d.slaStatus // ""), ($d.slaType // ""), (.action // "") ]
           | map(select(. != "")) | (.[0] // "at risk")))
       elif (($type == "issue") and ($from | has("stateId"))) then
         ("State: " + ($d.state.name // ""))
       elif (($type == "issue") and $assignee_changed) then
         ("Assignee: " + ($d.assignee.name // "unassigned"))
       else "" end | gsub("^\\s+|\\s+$"; "")) as $detail

    | (if ($action | test("^(create|update|remove)$")) then $action else "update" end) as $norm_action

    | {
        v: 1,
        source: "linear",
        id: ($d.id // .id // ""),
        ts: event_ts,
        kind: (if $sla_event then "IssueSLA"
               elif $type == "" then "linear"
               else $type end),
        action: (if $sla_event then $sla_action else $norm_action end),
        actor: $actor,
        title: $title,
        url: $url,
        severity: $severity,
        detail: $detail
      } as $event

    # Blocker always routes; it is never dropped as native-notified noise.
    | if ($sla_blocker | not) and ($drop_assign or $drop_mention) then
        { decision: "drop",
          reason: (if $drop_assign then "issue-assigned-to-david" else "comment-mentions-david" end),
          id: $event.id, title: $event.title }
      else
        { decision: "route",
          event: $event,
          alert: (if $severity == "blocker" then
                    (["Linear blocker:", $title, $detail, $url]
                      | map(select(. != null and . != "")) | join(" "))
                  else null end) }
      end
    ' "$event_file"
) || die "failed to normalize event JSON"

decision_kind=$(printf '%s' "$decision" | jq -r '.decision')

if [ "$decision_kind" = "drop" ]; then
  reason=$(printf '%s' "$decision" | jq -r '.reason')
  id=$(printf '%s' "$decision" | jq -r '.id')
  title=$(printf '%s' "$decision" | jq -r '.title')
  log_line "dropped $reason id=$id title=$title"
  exit 0
fi

event=$(printf '%s' "$decision" | jq -c '.event')

# Delegate final routing to the shared classifier when it is installed. It reads
# the normalized event on stdin and owns queue/alert placement from there.
if [ -x "$CLASSIFY_BIN" ]; then
  printf '%s\n' "$event" | "$CLASSIFY_BIN"
  exit $?
fi

# No shared router: write the event straight into the contract's queue.
severity=$(printf '%s' "$event" | jq -r '.severity')
id=$(printf '%s' "$event" | jq -r '.id')
ts=$(printf '%s' "$event" | jq -r '.ts')
ts_compact=$(printf '%s' "$ts" | tr -d ':-')
id_safe=$(printf '%s' "$id" | tr -c 'A-Za-z0-9_.-' '_')
base="${ts_compact}-linear-${id_safe}"

printf '%s\n' "$event" | atomic_write "$incoming_dir/$base.json"

if [ "$severity" = "blocker" ]; then
  alert=$(printf '%s' "$decision" | jq -r '.alert // ""')
  {
    printf '%s\n' "$alert"
    printf '%s\n' "$event"
  } | atomic_write "$alerts_dir/$base.txt"
fi

printf 'routed %s severity=%s -> %s.json\n' "$id" "$severity" "$base"

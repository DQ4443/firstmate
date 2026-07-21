#!/usr/bin/env bash
# fm-openai-usage.sh - emit an OpenAI (codex / ChatGPT subscription) usage account
# in the same shape the board usage panel already renders for Claude, so it can be
# merged into state/usage.json as accounts["openai"].
#
# Source of truth: codex records the API's rate-limit snapshot in every session
# rollout under ~/.codex/sessions/<Y>/<M>/<D>/rollout-*.jsonl as an event_msg with
# payload.type == "token_count" and payload.rate_limits:
#   primary   : the short window  (window_minutes 300  == 5 hours)  -> five_hour
#   secondary : the long window   (window_minutes 10080 == 7 days)  -> seven_day
# each carrying used_percent (0..100) and resets_at (epoch seconds), plus plan_type.
# We take the newest rollout that has such a record and use its LAST snapshot, so
# the numbers are as fresh as the most recent codex run. No API call is made (unlike
# the Claude feed, which must poll); codex already logged this for free.
#
# Usage: fm-openai-usage.sh            # prints the account JSON object to stdout
# Exit 0 with a {"ok":false,...} object if no snapshot is found (fail soft, the
# panel already handles not-ok accounts).
set -euo pipefail

SESSIONS_DIR="${CODEX_HOME:-$HOME/.codex}/sessions"

python3 - "$SESSIONS_DIR" <<'PY'
import sys, os, json, glob

sessions_dir = sys.argv[1]

def emit(obj):
    print(json.dumps(obj))
    raise SystemExit(0)

if not os.path.isdir(sessions_dir):
    emit({"ok": False, "label": "OpenAI", "reason": "no codex sessions dir"})

rollouts = sorted(
    glob.glob(os.path.join(sessions_dir, "**", "rollout-*.jsonl"), recursive=True),
    key=lambda p: os.path.getmtime(p),
    reverse=True,
)

def last_rate_limits(path):
    found = None
    try:
        with open(path) as fh:
            for line in fh:
                line = line.strip()
                if not line or "rate_limits" not in line:
                    continue
                try:
                    o = json.loads(line)
                except Exception:
                    continue
                payload = o.get("payload") or {}
                if payload.get("type") == "token_count":
                    rl = payload.get("rate_limits")
                    if isinstance(rl, dict) and rl.get("primary"):
                        found = (rl, o.get("timestamp"))
    except OSError:
        return None
    return found

snap = None
for path in rollouts:
    snap = last_rate_limits(path)
    if snap:
        break

if not snap:
    emit({"ok": False, "label": "OpenAI", "reason": "no rate_limits snapshot in codex rollouts"})

rl, ts = snap

def window(w):
    if not isinstance(w, dict):
        return None
    up = w.get("used_percent")
    if up is None:
        return None
    return {
        "used_percent": int(round(up)),
        "utilization": round(up / 100.0, 4),
        "resets_at": w.get("resets_at"),
        "status": "allowed" if up < 90 else "allowed_warning",
    }

five = window(rl.get("primary"))       # window_minutes 300  == 5h
seven = window(rl.get("secondary"))    # window_minutes 10080 == weekly

# The binding window is whichever is more used (what actually gates work).
rep = "seven_day"
if five and seven:
    rep = "five_hour" if five["used_percent"] >= seven["used_percent"] else "seven_day"
elif five:
    rep = "five_hour"

acct = {
    "ok": True,
    "label": "OpenAI",
    "plan_type": rl.get("plan_type"),
    "representative": rep,
    "as_of": ts,
}
if five:
    acct["five_hour"] = five
if seven:
    acct["seven_day"] = seven
emit(acct)
PY

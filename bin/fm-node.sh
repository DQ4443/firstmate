#!/usr/bin/env bash
# fm-node.sh - the fleet NODE lifecycle CLI (GATE-SAFE substrate).
#
# WHAT A NODE IS: an account-pinned Claude session home. Each node owns its own
# CLAUDE_CONFIG_DIR (its own keychain credential, its own signed-in identity and
# usage quota), so the fleet can run several Claude subscriptions side by side
# instead of starving one account (decisions.md 2026-07-09 EOD: "account-pinned
# worker sessions, own CLAUDE_CONFIG_DIR each"). This script is ONLY the plumbing
# every design variant of the sharded-orchestrator fleet needs: register a node,
# read its identity + utilization, spawn its session, report liveness. It makes
# NO architecture choice about shard boundaries, dispatch routing, or the parrot
# layer - those ride David's design gate (docs/fleet-substrate.md, DRAFT).
#
# NO AUTO-LOGIN: this script never signs a node in. David signs in once per node
# himself (each node's config dir is a fresh Claude home). `spawn` launches
# `claude` bare in the node's session; if the node is not yet authenticated,
# claude shows its own login flow and David completes it. No credential is ever
# written or printed by this script.
#
# Registry: state/fleet-nodes.json (gitignored, like all state/). Shape:
#   { "updated_at": <epoch>,
#     "nodes": { "<name>": {
#       "name": "<name>",
#       "config_dir": "<abs path to CLAUDE_CONFIG_DIR>",
#       "harness": "claude",
#       "registered_at": <epoch> } } }
#
# Usage:
#   fm-node.sh register <name> <config-dir> [--harness <name>]
#   fm-node.sh unregister <name>
#   fm-node.sh get <name>            # the node's registry entry as JSON
#   fm-node.sh list                  # per node: identity, 5h/7d util, live pid (hits the usage API)
#   fm-node.sh usage [--pretty]      # the generic N-node usage reader, as JSON (additive to the widget feed)
#   fm-node.sh status                # registry + session liveness only (no network)
#   fm-node.sh spawn <name>          # tmux session fm-node-<name> running claude with CLAUDE_CONFIG_DIR set
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
FILE="$STATE/fleet-nodes.json"
REG_LOCK="$STATE/.fleet-nodes.json.lock"

# Locking mirrors fm-item-agent.sh: serialize the registry read-modify-write so a
# concurrent register/unregister cannot last-writer-wins away another node.
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"

# Node names are the same strict slug the board enforces for item ids, so a typo
# cannot register a ghost node or collide with a tmux session name.
NAME_RE='^[a-z0-9][a-z0-9-]{0,63}$'
# The OAuth usage endpoint the Claude Code statusline and claude.ai usage board
# both read (see ~/.firstmate-board/usage-feed.sh): one call yields the 5h window
# (top-level five_hour), the 7d window (seven_day), and the per-model weekly
# quota (limits[] kind weekly_scoped, e.g. Fable).
USAGE_ENDPOINT="https://api.anthropic.com/api/oauth/usage"

die() { echo "fm-node: $1" >&2; exit 2; }

command -v jq >/dev/null 2>&1 || die "jq is required to maintain $FILE"

valid_name() { printf '%s' "$1" | grep -qE "$NAME_RE"; }

mkdir -p "$STATE"

# Load the registry, or a fresh skeleton for a missing file. A PRESENT but
# unparseable file is a hard error (never silently reset it and drop every node),
# exactly the fm-item-agent.sh safety posture.
load() {
  if [ -f "$FILE" ]; then
    if ! jq -e . "$FILE" >/dev/null 2>&1; then
      die "existing $FILE is not valid JSON; refusing to overwrite it (fix or remove it by hand)"
    fi
    cat "$FILE"
  else
    printf '{"nodes":{}}\n'
  fi
}

# Atomically replace the registry with the jq program applied to it. Extra
# --arg/--argjson pairs pass through. Every jq program below references jq's own
# $-variables, never shell parameters, so SC2016 is disabled where they appear.
write_transform() {
  local prog=$1
  shift
  local cur tmp
  fm_lock_acquire_wait "$REG_LOCK"
  cur=$(load) || { fm_lock_release "$REG_LOCK"; exit 2; }
  tmp="$STATE/.fleet-nodes.json.tmp.$$"
  if printf '%s' "$cur" | jq "$@" "$prog" > "$tmp"; then
    mv "$tmp" "$FILE"
    fm_lock_release "$REG_LOCK"
  else
    rm -f "$tmp" 2>/dev/null || true
    fm_lock_release "$REG_LOCK"
    die "jq transform failed"
  fi
}

# --- node property helpers ---------------------------------------------------

node_default_config_dir() { printf '%s/.claude' "$HOME"; }

node_session_name() { printf 'fm-node-%s' "$1"; }

# The macOS Keychain service that holds a config dir's OAuth token. Claude Code
# uses the bare "Claude Code-credentials" for the default ~/.claude home, and
# "Claude Code-credentials-<first 8 hex of sha256(CLAUDE_CONFIG_DIR)>" for any
# isolated home (verified: ~/.claude-personal -> -338d7248). We hash the exact
# absolute path we store and set as CLAUDE_CONFIG_DIR, so the derivation always
# matches the string Claude itself hashed.
node_keychain_service() { # <config_dir_abs>
  local dir=$1 h
  if [ "$dir" = "$(node_default_config_dir)" ]; then
    printf 'Claude Code-credentials'
  else
    h=$(printf '%s' "$dir" | shasum -a 256 | awk '{print $1}' | cut -c1-8)
    printf 'Claude Code-credentials-%s' "$h"
  fi
}

# The signed-in identity for a node: oauthAccount.emailAddress in the home's
# .claude.json. The default ~/.claude home keeps that file one level up at
# ~/.claude.json, so fall back to <parent>/.claude.json only for a `.claude`
# basename. Prints the email on success, nothing on failure.
node_identity_email() { # <config_dir_abs>
  local dir=$1 f=""
  if [ -f "$dir/.claude.json" ]; then
    f="$dir/.claude.json"
  elif [ "$(basename "$dir")" = ".claude" ] && [ -f "$(dirname "$dir")/.claude.json" ]; then
    f="$(dirname "$dir")/.claude.json"
  fi
  [ -n "$f" ] || return 1
  python3 -c 'import json,sys
try:
    d=json.load(open(sys.argv[1]))
    e=((d.get("oauthAccount") or {}).get("emailAddress") or "").strip()
except Exception:
    e=""
print(e)
sys.exit(0 if e else 1)' "$f" 2>/dev/null
}

# The OAuth access token for a service, read from the Keychain and NEVER printed
# by any caller (it is consumed straight into the usage curl). Empty on failure.
node_token() { # <keychain_service>
  security find-generic-password -s "$1" -w 2>/dev/null \
    | python3 -c 'import sys,json
try: print(json.load(sys.stdin)["claudeAiOauth"]["accessToken"])
except Exception: pass' 2>/dev/null
}

# The raw usage-endpoint body for a token (empty on any failure; the parser
# degrades each node independently).
node_usage_raw() { # <token>
  curl -sS --max-time 20 "$USAGE_ENDPOINT" \
    -H "authorization: Bearer $1" \
    -H "anthropic-beta: oauth-2025-04-20" 2>/dev/null || true
}

# The live session pid for a node, if its tmux session exists. Empty otherwise.
node_session_pid() { # <name>
  tmux display-message -p -t "$(node_session_name "$1")" '#{pane_pid}' 2>/dev/null || true
}

# Single-quote a string for safe reuse inside a shell command line sent to a
# pane (same helper shape as fm-spawn.sh).
shell_quote() {
  printf "'"
  printf '%s' "$1" | sed "s/'/'\\\\''/g"
  printf "'"
}

# --- the generic N-node usage reader (item 2) --------------------------------
#
# Walks the registry and emits ONE JSON doc describing every node: identity,
# session liveness, and the 5h/7d/Fable usage in the same shape the board's
# work/personal widget already renders. This is ADDITIVE: it does not touch
# ~/.firstmate-board/usage-feed.sh, so the existing two-account widget keeps
# working unchanged. A later aggregator can merge this doc's `nodes` key into
# state/usage.json alongside accounts.work / accounts.personal.
nodes_usage_json() {
  local raw names name out
  raw=$(mktemp)
  names=$(load | jq -r '.nodes | keys[]?' 2>/dev/null || true)
  # Field-separated records (\x1e between fields, \x1d between records) exactly as
  # usage-feed.sh does, so the python assembler never has to shell-quote anything.
  while IFS= read -r name; do
    [ -n "$name" ] || continue
    local cfg harness svc tok ident pid usage
    cfg=$(load | jq -r --arg n "$name" '.nodes[$n].config_dir // ""')
    harness=$(load | jq -r --arg n "$name" '.nodes[$n].harness // "claude"')
    svc=$(node_keychain_service "$cfg")
    tok=$(node_token "$svc")
    ident=$(node_identity_email "$cfg" || true)
    pid=$(node_session_pid "$name")
    usage=""
    [ -z "$tok" ] || usage=$(node_usage_raw "$tok")
    printf '%s\x1e%s\x1e%s\x1e%s\x1e%s\x1e%s\x1d' \
      "$name" "$cfg" "$harness" "$ident" "$pid" "$usage" >> "$raw"
  done <<EOF
$names
EOF

  out=$(python3 - "$raw" <<'PY'
import sys, json, time, datetime

raw = open(sys.argv[1]).read()

def iso_to_epoch(s):
    if not s:
        return None
    try:
        return int(datetime.datetime.fromisoformat(s.replace("Z", "+00:00")).timestamp())
    except Exception:
        return None

def severity_by_kind(limits):
    out = {}
    if isinstance(limits, list):
        for lim in limits:
            if isinstance(lim, dict) and lim.get("kind"):
                out[lim["kind"]] = lim.get("severity")
    return out

def window(d, key, severity):
    o = d.get(key)
    if not isinstance(o, dict):
        return None
    u = o.get("utilization")
    return {
        "used_percent": round(u) if isinstance(u, (int, float)) else None,
        "utilization": float(u) if isinstance(u, (int, float)) else None,
        "resets_at": iso_to_epoch(o.get("resets_at")),
        "status": severity,
    }

def parse_fable(limits):
    if not isinstance(limits, list):
        return None
    scoped = [l for l in limits if isinstance(l, dict) and l.get("kind") == "weekly_scoped"]
    if not scoped:
        return None
    def is_fable(l):
        model = ((l.get("scope") or {}).get("model") or {})
        return (model.get("display_name") or "").strip().lower() == "fable"
    lim = next((l for l in scoped if is_fable(l)), scoped[0])
    pct = lim.get("percent")
    return {
        "used_percent": round(pct) if isinstance(pct, (int, float)) else None,
        "resets_at": iso_to_epoch(lim.get("resets_at")),
        "status": lim.get("severity"),
        "source": "oauth/usage:weekly_scoped",
    }

nodes = {}
for rec in filter(None, raw.split("\x1d")):
    parts = rec.split("\x1e")
    name = parts[0]
    cfg = parts[1] if len(parts) > 1 else ""
    harness = parts[2] if len(parts) > 2 else "claude"
    ident = parts[3] if len(parts) > 3 else ""
    pid = parts[4] if len(parts) > 4 else ""
    usage_body = parts[5] if len(parts) > 5 else ""

    entry = {
        "name": name,
        "config_dir": cfg,
        "harness": harness,
        "identity": ident or None,
        "session": {"live": bool(pid), "pid": int(pid) if pid.isdigit() else None},
    }
    ok = False
    try:
        d = json.loads(usage_body) if usage_body else None
    except Exception:
        d = None
    if isinstance(d, dict):
        sev = severity_by_kind(d.get("limits"))
        five = window(d, "five_hour", sev.get("session"))
        seven = window(d, "seven_day", sev.get("weekly_all"))
        fable = parse_fable(d.get("limits"))
        ok = five is not None or seven is not None
        entry["five_hour"] = five
        entry["seven_day"] = seven
        if fable is not None:
            entry["fable"] = fable
    entry["ok"] = ok
    if not ok:
        entry["error"] = "usage unreadable (not signed in / token expired / network)"
    nodes[name] = entry

doc = {"generated_at": int(time.time()), "nodes": nodes}
print(json.dumps(doc, indent=2))
PY
)
  rm -f "$raw"
  printf '%s\n' "$out"
}

# --- subcommands -------------------------------------------------------------

cmd_register() {
  local name=${1:-} dir=${2:-} harness=claude
  shift 2 2>/dev/null || true
  while [ $# -gt 0 ]; do
    case "$1" in
      --harness) harness=${2:-}; [ -n "$harness" ] || die "--harness requires a value"; shift 2 ;;
      --harness=*) harness=${1#--harness=}; shift ;;
      *) die "register: unknown argument '$1'" ;;
    esac
  done
  [ -n "$name" ] || die "usage: register <name> <config-dir> [--harness <name>]"
  [ -n "$dir" ] || die "usage: register <name> <config-dir> [--harness <name>]"
  valid_name "$name" || die "invalid node name: '$name' (must match $NAME_RE)"
  case "$dir" in
    /*) : ;;
    *) die "config-dir must be an absolute path: '$dir'" ;;
  esac
  # Normalize an existing dir to its canonical absolute path so the keychain-service
  # hash matches whatever CLAUDE_CONFIG_DIR resolves to. A not-yet-created home is
  # allowed (David signs in later, which creates it) but warned about.
  if [ -d "$dir" ]; then
    dir=$(cd "$dir" && pwd -P)
  else
    echo "fm-node: warning: config dir does not exist yet: $dir (register anyway; it is created when David signs the node in)" >&2
    case "$dir" in */) dir=${dir%/} ;; esac
  fi
  case "$harness" in
    claude) : ;;
    *) die "unsupported harness '$harness' for a node (only 'claude' is supported: a node is a CLAUDE_CONFIG_DIR-pinned Claude home)" ;;
  esac
  local now
  now=$(date +%s)
  # shellcheck disable=SC2016
  write_transform '.nodes[$n] = ((.nodes[$n] // {}) + {name:$n, config_dir:$dir, harness:$h, registered_at:(.nodes[$n].registered_at // $now)}) | .updated_at = $now' \
    --arg n "$name" --arg dir "$dir" --arg h "$harness" --argjson now "$now"
  echo "registered node: $name -> $dir (harness=$harness)"
}

cmd_unregister() {
  local name=${1:-}
  [ -n "$name" ] || die "usage: unregister <name>"
  valid_name "$name" || die "invalid node name: '$name'"
  local now
  now=$(date +%s)
  # shellcheck disable=SC2016
  write_transform 'del(.nodes[$n]) | .updated_at = $now' --arg n "$name" --argjson now "$now"
  echo "unregistered node: $name"
}

cmd_get() {
  local name=${1:-}
  [ -n "$name" ] || die "usage: get <name>"
  load | jq -e --arg n "$name" '.nodes[$n] // empty' \
    || die "no such node: $name"
}

cmd_usage() {
  if [ "${1:-}" = "--pretty" ]; then
    nodes_usage_json | jq .
  else
    nodes_usage_json
  fi
}

cmd_list() {
  local doc tmp
  doc=$(nodes_usage_json)
  tmp=$(mktemp)
  printf '%s' "$doc" > "$tmp"
  # Quoted heredoc: python may use its own quotes freely, and % formatting avoids
  # backslashes-in-f-strings (a SyntaxError before python 3.12).
  python3 - "$tmp" <<'PY'
import json, sys
doc = json.load(open(sys.argv[1]))
nodes = doc.get("nodes", {})
if not nodes:
    print("no nodes registered (fm-node.sh register <name> <config-dir>)")
    sys.exit(0)

def pct(w):
    if not isinstance(w, dict):
        return "  -"
    v = w.get("used_percent")
    return ("%3d%%" % v) if isinstance(v, int) else "  -"

width = max(len(n) for n in nodes)
hdr = "%-*s  %-28s  %4s  %4s  %5s  %s" % (width, "NODE", "IDENTITY", "5H", "7D", "FABLE", "SESSION")
print(hdr)
print("-" * len(hdr))
for name in sorted(nodes):
    e = nodes[name]
    ident = e.get("identity") or ("(unreadable)" if not e.get("ok") else "-")
    fable = e.get("fable") or {}
    fv = fable.get("used_percent")
    fs = ("%3d%%" % fv) if isinstance(fv, int) else "  -"
    sess = e.get("session") or {}
    s = ("live pid %s" % sess.get("pid")) if sess.get("live") else "-"
    print("%-*s  %-28s  %4s  %4s  %5s  %s" % (
        width, name, ident, pct(e.get("five_hour")), pct(e.get("seven_day")), fs, s))
PY
  rm -f "$tmp"
}

cmd_status() {
  local names name any=0 cfg harness pid
  names=$(load | jq -r '.nodes | keys[]?' 2>/dev/null || true)
  while IFS= read -r name; do
    [ -n "$name" ] || continue
    any=1
    cfg=$(load | jq -r --arg n "$name" '.nodes[$n].config_dir // ""')
    harness=$(load | jq -r --arg n "$name" '.nodes[$n].harness // "claude"')
    pid=$(node_session_pid "$name")
    if [ -n "$pid" ]; then
      echo "$name  harness=$harness  session=$(node_session_name "$name")  live pid=$pid  config_dir=$cfg"
    else
      echo "$name  harness=$harness  session=$(node_session_name "$name")  down  config_dir=$cfg"
    fi
  done <<EOF
$names
EOF
  [ "$any" -eq 1 ] || echo "no nodes registered (fm-node.sh register <name> <config-dir>)"
}

# Spawn a node's session. A node is a STANDALONE tmux session (fm-node-<name>),
# not a window in the firstmate task container and not a task worktree: it is a
# full account-pinned Claude home, so it deliberately does NOT go through
# fm-spawn.sh's container/worktree machinery (that path exists for crewmate/scout
# task windows with a brief). It reuses fm-spawn's send SEQUENCE - export the
# per-session env, then the launch command, then Enter - which is the verified way
# to seed a pane's shell before the agent starts. No brief, no worktree, no
# credentials: claude launches bare and David signs the node in himself if
# prompted (NO AUTO-LOGIN).
cmd_spawn() {
  local name=${1:-}
  [ -n "$name" ] || die "usage: spawn <name>"
  valid_name "$name" || die "invalid node name: '$name'"
  local cfg harness ses
  cfg=$(load | jq -r --arg n "$name" '.nodes[$n].config_dir // ""')
  harness=$(load | jq -r --arg n "$name" '.nodes[$n].harness // ""')
  [ -n "$cfg" ] || die "no such node: $name (register it first: fm-node.sh register $name <config-dir>)"
  [ "$harness" = claude ] || die "spawn supports only claude nodes (node '$name' has harness=$harness)"
  ses=$(node_session_name "$name")
  if tmux has-session -t "$ses" 2>/dev/null; then
    local pid
    pid=$(node_session_pid "$name")
    echo "node $name already running: session=$ses${pid:+ pid=$pid}"
    return 0
  fi
  [ -d "$cfg" ] || echo "fm-node: warning: config dir does not exist yet: $cfg (claude will create it; sign in if prompted)" >&2
  tmux new-session -d -s "$ses" -c "$HOME"
  # Seed CLAUDE_CONFIG_DIR into the session's shell, then launch claude. The
  # brief sleeps let each keystroke line land before the next, mirroring
  # fm-spawn.sh's send cadence.
  tmux send-keys -t "$ses" "export CLAUDE_CONFIG_DIR=$(shell_quote "$cfg")" Enter
  sleep 0.3
  tmux send-keys -t "$ses" "claude" Enter
  echo "spawned node $name session=$ses config_dir=$cfg (sign in if claude prompts; NO auto-login)"
}

# --- dispatch ----------------------------------------------------------------

cmd=${1:-}
[ -n "$cmd" ] || die "usage: register|unregister|get|list|usage|status|spawn (see header)"
shift || true
case "$cmd" in
  register)   cmd_register "$@" ;;
  unregister) cmd_unregister "$@" ;;
  get)        cmd_get "$@" ;;
  list)       cmd_list "$@" ;;
  usage)      cmd_usage "$@" ;;
  status)     cmd_status "$@" ;;
  spawn)      cmd_spawn "$@" ;;
  *)          die "unknown command: '$cmd' (register|unregister|get|list|usage|status|spawn)" ;;
esac

#!/usr/bin/env bash
# fm-linear.sh - deterministic Linear read/write for dispatched agents.
#
# THE PROBLEM THIS SOLVES (meeting-sync-design.md Decision 4a, Phase 0): the
# linear-kronos MCP does NOT reliably load into workflow subagents. `claude mcp
# get linear-kronos` frequently returns "No MCP server named linear-kronos", so
# an agent briefed to create/comment on ENG tickets cannot depend on the
# mcp__linear__* tools being present. Every reconcile artifact then ends in a
# ticket PLAN a human has to execute by hand. This wrapper removes that
# per-runtime MCP-loading roulette: it drives Linear's hosted MCP endpoint
# (https://mcp.linear.app/mcp) directly with the already-authorized OAuth token,
# exposing the reads and writes the meeting-sync pipeline needs as plain CLI
# subcommands that work identically from a subagent brief, a scheduled run, or
# an interactive shell.
#
# TRANSPORT: JSON-RPC over the MCP "streamable HTTP" transport (a POST per call;
# initialize -> notifications/initialized -> tools/call). Responses come back as
# either application/json or a text/event-stream frame; both are parsed. The
# Linear MCP is effectively stateless (no Mcp-Session-Id is required between
# calls), so each invocation is a fresh, self-contained session.
#
# TOKEN RESOLUTION (never printed, never logged), first hit wins:
#   1. $LINEAR_API_KEY            - explicit override / durable fallback.
#   2. macOS Keychain             - `security find-generic-password -s
#      "Claude Code-credentials"`, JSON -> mcpOAuth -> the linear-kronos entry's
#      accessToken. THIS is where Claude Code actually stores the live token;
#      the ~/.claude/.credentials.json file mirror usually has an EMPTY
#      accessToken, which is why the file alone is not enough.
#   3. ~/.claude/.credentials.json - same JSON shape, used if the Keychain read
#      fails (e.g. Linux) and the file happens to carry a non-empty token.
#
# EXPIRY / REFRESH: the cached OAuth access token is short-lived (Linear issues
# ~24h tokens) and Claude Code refreshes it whenever the main session touches
# Linear. This wrapper deliberately does NOT auto-refresh: Linear ROTATES the
# refresh token on use, so a background refresh here would silently invalidate
# the copy Claude Code holds and desync the main session's auth. On an expired
# or rejected token it fails cleanly (exit 3) and tells the operator how to
# recover (use Linear once in the main Claude session to refresh, or set
# LINEAR_API_KEY). A consent-gated persisting refresh can be added later.
#
# SAFETY: read subcommands are free; write subcommands (create_issue,
# update_issue, add_comment) support --dry-run, which prints the exact tool call
# that WOULD be made and exits 0 without touching Linear. This is the substrate
# the tiered-gate design (Decision 5a) builds its change-list dry run on.
#
# USAGE:
#   fm-linear.sh status
#   fm-linear.sh list_users [--query NAME] [--team T] [--limit N]
#   fm-linear.sh get_user <name|email|id|me>
#   fm-linear.sh list_issues [--assignee X] [--query Q] [--team T] [--state S]
#                            [--project P] [--label L] [--cycle C]
#                            [--priority N] [--parent ID] [--limit N]
#   fm-linear.sh get_issue <ENG-NNN> [--relations]
#   fm-linear.sh create_issue --title T [--team Engineering] [--description D]
#                             [--assignee A] [--labels a,b,c] [--project P]
#                             [--priority N] [--parent ENG-NNN] [--state S]
#                             [--due YYYY-MM-DD] [--estimate N] [--dry-run]
#   fm-linear.sh update_issue <ENG-NNN> [--title ..] [--description ..]
#                             [--assignee ..] [--state ..] [--labels ..]
#                             [--project ..] [--priority N] [--parent ..]
#                             [--due ..] [--estimate N] [--dry-run]
#   fm-linear.sh add_comment <ENG-NNN> --body TEXT [--dry-run]
#   fm-linear.sh call <tool> --args '<json>'      # generic escape hatch
#
# Exit codes: 0 ok; 2 usage error; 3 auth/token unavailable-or-expired;
#             4 Linear returned a tool error; 5 network/transport error.
set -euo pipefail

exec python3 - "$@" <<'PYEOF'
import json
import os
import subprocess
import sys
import urllib.error
import urllib.request

MCP_URL = "https://mcp.linear.app/mcp"
KEYCHAIN_SERVICE = "Claude Code-credentials"
CRED_FILE = os.path.expanduser("~/.claude/.credentials.json")
DEFAULT_TEAM = os.environ.get("FM_LINEAR_TEAM", "Engineering")

E_USAGE, E_AUTH, E_TOOL, E_NET = 2, 3, 4, 5


def die(code, msg):
    sys.stderr.write("fm-linear: " + msg + "\n")
    sys.exit(code)


# --- token resolution (never printed) ---------------------------------------

def _linear_entry(cred):
    """Pick the linear-kronos OAuth entry (or any linear entry with a token)."""
    mc = cred.get("mcpOAuth", {})
    if not isinstance(mc, dict):
        return None
    for key in mc:
        if key.startswith("linear-kronos|"):
            e = mc[key]
            if isinstance(e, dict) and e.get("accessToken"):
                return e
    # fall back to any linear entry that actually carries a token
    for key, e in mc.items():
        if "linear" in key and isinstance(e, dict) and e.get("accessToken"):
            return e
    return None


def _keychain_cred():
    try:
        raw = subprocess.check_output(
            ["security", "find-generic-password", "-s", KEYCHAIN_SERVICE, "-w"],
            text=True, stderr=subprocess.DEVNULL).strip()
    except Exception:
        return None
    try:
        return json.loads(raw)
    except Exception:
        return None


def _file_cred():
    try:
        with open(CRED_FILE) as fh:
            return json.load(fh)
    except Exception:
        return None


def resolve_token():
    """Return (token, source, expires_at_ms_or_None). Never logs the token."""
    env = os.environ.get("LINEAR_API_KEY")
    if env:
        return env.strip(), "LINEAR_API_KEY env", None
    for cred, src in ((_keychain_cred(), "macOS Keychain (Claude Code-credentials)"),
                      (_file_cred(), CRED_FILE)):
        if not cred:
            continue
        entry = _linear_entry(cred)
        if entry:
            return entry["accessToken"], src, entry.get("expiresAt")
    return None, None, None


def token_or_die(require_fresh=True):
    tok, src, exp = resolve_token()
    if not tok:
        die(E_AUTH,
            "no Linear token reachable.\n"
            "  Provide access one of two ways:\n"
            "    1. Use the linear-kronos MCP once in the main Claude Code "
            "session (opens/refreshes the cached OAuth token), or\n"
            "    2. export LINEAR_API_KEY=<a Linear API token> and re-run.\n"
            "  Checked: $LINEAR_API_KEY, macOS Keychain, " + CRED_FILE)
    if require_fresh and exp is not None:
        import time
        if exp / 1000.0 <= time.time():
            die(E_AUTH,
                "cached OAuth token is EXPIRED (source: " + src + ").\n"
                "  Refresh it by using linear-kronos once in the main Claude "
                "Code session, or export LINEAR_API_KEY and re-run.\n"
                "  This wrapper will not auto-refresh: Linear rotates the "
                "refresh token, so a background refresh would desync the main "
                "session's auth.")
    return tok, src, exp


# --- MCP transport ----------------------------------------------------------

_RID = [0]


def _rpc(tok, method, params=None, notif=False):
    _RID[0] += 1
    body = {"jsonrpc": "2.0", "method": method}
    if params is not None:
        body["params"] = params
    if not notif:
        body["id"] = _RID[0]
    req = urllib.request.Request(
        MCP_URL, data=json.dumps(body).encode(),
        headers={
            "Authorization": "Bearer " + tok,
            "Content-Type": "application/json",
            "Accept": "application/json, text/event-stream",
        },
        method="POST")
    try:
        resp = urllib.request.urlopen(req, timeout=60)
    except urllib.error.HTTPError as ex:
        detail = ex.read().decode(errors="replace")[:400]
        if ex.code in (401, 403):
            die(E_AUTH, "Linear rejected the token (HTTP %d). Refresh the "
                        "OAuth token or set LINEAR_API_KEY.\n  %s"
                        % (ex.code, detail))
        die(E_NET, "MCP HTTP %d: %s" % (ex.code, detail))
    except urllib.error.URLError as ex:
        die(E_NET, "network error reaching Linear MCP: %s" % ex.reason)
    payload = resp.read().decode()
    if notif:
        return None
    ctype = resp.headers.get("Content-Type", "")
    if "text/event-stream" in ctype:
        out = None
        for line in payload.splitlines():
            if line.startswith("data:"):
                out = json.loads(line[5:].strip())
        return out
    return json.loads(payload) if payload else None


def _session(tok):
    _rpc(tok, "initialize", {
        "protocolVersion": "2025-06-18",
        "capabilities": {},
        "clientInfo": {"name": "fm-linear.sh", "version": "1.0"},
    })
    _rpc(tok, "notifications/initialized", notif=True)


def call_tool(tok, name, args):
    """Invoke an MCP tool, returning its text payload (raw JSON string)."""
    res = _rpc(tok, "tools/call", {"name": name, "arguments": args})
    if res is None or "result" not in res:
        err = (res or {}).get("error")
        die(E_TOOL, "tool %s failed: %s" % (name, json.dumps(err) if err else "no result"))
    result = res["result"]
    text = "".join(b.get("text", "") for b in result.get("content", [])
                   if b.get("type") == "text")
    if result.get("isError"):
        die(E_TOOL, "Linear rejected %s: %s" % (name, text.strip()))
    return text


def emit(text):
    """Pretty-print a JSON payload if possible, else pass through."""
    try:
        sys.stdout.write(json.dumps(json.loads(text), indent=2) + "\n")
    except Exception:
        sys.stdout.write(text.rstrip("\n") + "\n")


# --- argument helpers -------------------------------------------------------

def opts(argv):
    """Parse a flat [--flag value | --bool | positional] list.

    Returns (positionals, flags-dict). --dry-run/--relations are booleans.
    """
    BOOL = {"--dry-run", "--relations"}
    pos, flags, i = [], {}, 0
    while i < len(argv):
        a = argv[i]
        if a.startswith("--"):
            key = a[2:]
            if a in BOOL:
                flags[key] = True
                i += 1
            else:
                if i + 1 >= len(argv):
                    die(E_USAGE, "flag %s needs a value" % a)
                flags[key] = argv[i + 1]
                i += 2
        else:
            pos.append(a)
            i += 1
    return pos, flags


def as_num(flags, key):
    if key in flags:
        try:
            v = float(flags[key])
            return int(v) if v.is_integer() else v
        except ValueError:
            die(E_USAGE, "--%s must be a number" % key)
    return None


def issue_write_args(flags, is_update):
    """Build the save_issue argument map from CLI flags."""
    args = {}
    if "title" in flags:
        args["title"] = flags["title"]
    if "description" in flags:
        args["description"] = flags["description"]
    if "team" in flags:
        args["team"] = flags["team"]
    elif not is_update:
        args["team"] = DEFAULT_TEAM
    if "assignee" in flags:
        args["assignee"] = flags["assignee"]
    if "state" in flags:
        args["state"] = flags["state"]
    if "project" in flags:
        args["project"] = flags["project"]
    if "parent" in flags:
        args["parentId"] = flags["parent"]
    if "due" in flags:
        args["dueDate"] = flags["due"]
    if "cycle" in flags:
        args["cycle"] = flags["cycle"]
    pr = as_num(flags, "priority")
    if pr is not None:
        args["priority"] = pr
    est = as_num(flags, "estimate")
    if est is not None:
        args["estimate"] = est
    if "labels" in flags:
        args["labels"] = [s.strip() for s in flags["labels"].split(",") if s.strip()]
    return args


# --- subcommands ------------------------------------------------------------

def cmd_status(argv):
    tok, src, exp = resolve_token()
    if not tok:
        print("token: NONE reachable")
        print("  checked: $LINEAR_API_KEY, macOS Keychain, " + CRED_FILE)
        print("  remedy: use linear-kronos once in the main Claude session, "
              "or export LINEAR_API_KEY")
        sys.exit(E_AUTH)
    print("token: present (source: %s)" % src)
    if exp is not None:
        import datetime
        import time
        left = exp / 1000.0 - time.time()
        when = datetime.datetime.fromtimestamp(exp / 1000.0).isoformat()
        state = "EXPIRED" if left <= 0 else "valid (%.1f h left)" % (left / 3600.0)
        print("  expires: %s  [%s]" % (when, state))
    else:
        print("  expires: n/a (no expiry recorded for this source)")
    # live connectivity probe (read-only)
    _session(tok)
    teams = json.loads(call_tool(tok, "list_teams", {"limit": 10}))
    names = [t.get("name") for t in teams.get("teams", [])]
    print("  connectivity: OK, teams=%s" % names)


def cmd_list_users(argv):
    pos, f = opts(argv)
    args = {"limit": int(f.get("limit", 50))}
    if "query" in f:
        args["query"] = f["query"]
    if "team" in f:
        args["team"] = f["team"]
    tok, _, _ = token_or_die()
    _session(tok)
    emit(call_tool(tok, "list_users", args))


def cmd_get_user(argv):
    pos, f = opts(argv)
    if not pos:
        die(E_USAGE, "get_user needs a <name|email|id|me> argument")
    tok, _, _ = token_or_die()
    _session(tok)
    emit(call_tool(tok, "get_user", {"query": pos[0]}))


def cmd_list_issues(argv):
    pos, f = opts(argv)
    args = {"limit": int(f.get("limit", 50))}
    for k in ("assignee", "query", "team", "state", "project", "label",
              "cycle", "parent"):
        if k in f:
            args["parentId" if k == "parent" else k] = f[k]
    pr = as_num(f, "priority")
    if pr is not None:
        args["priority"] = pr
    tok, _, _ = token_or_die()
    _session(tok)
    emit(call_tool(tok, "list_issues", args))


def cmd_get_issue(argv):
    pos, f = opts(argv)
    if not pos:
        die(E_USAGE, "get_issue needs an <ENG-NNN> argument")
    args = {"id": pos[0]}
    if f.get("relations"):
        args["includeRelations"] = True
    tok, _, _ = token_or_die()
    _session(tok)
    emit(call_tool(tok, "get_issue", args))


def _write_or_dry(flags, tool, args):
    if flags.get("dry-run"):
        print("DRY-RUN: would call %s with:" % tool)
        print(json.dumps(args, indent=2))
        return
    tok, _, _ = token_or_die()
    _session(tok)
    emit(call_tool(tok, tool, args))


def cmd_create_issue(argv):
    pos, f = opts(argv)
    if "title" not in f:
        die(E_USAGE, "create_issue needs --title")
    args = issue_write_args(f, is_update=False)
    _write_or_dry(f, "save_issue", args)


def cmd_update_issue(argv):
    pos, f = opts(argv)
    if not pos:
        die(E_USAGE, "update_issue needs an <ENG-NNN> argument")
    args = issue_write_args(f, is_update=True)
    if not args:
        die(E_USAGE, "update_issue needs at least one attribute flag")
    args["id"] = pos[0]
    _write_or_dry(f, "save_issue", args)


def cmd_add_comment(argv):
    pos, f = opts(argv)
    if not pos:
        die(E_USAGE, "add_comment needs an <ENG-NNN> argument")
    if "body" not in f:
        die(E_USAGE, "add_comment needs --body")
    args = {"issueId": pos[0], "body": f["body"]}
    _write_or_dry(f, "save_comment", args)


def cmd_call(argv):
    """Generic escape hatch: call <tool> --args '<json>'."""
    pos, f = opts(argv)
    if not pos:
        die(E_USAGE, "call needs a <tool> name")
    try:
        args = json.loads(f.get("args", "{}"))
    except json.JSONDecodeError as ex:
        die(E_USAGE, "--args must be valid JSON: %s" % ex)
    if f.get("dry-run"):
        print("DRY-RUN: would call %s with:" % pos[0])
        print(json.dumps(args, indent=2))
        return
    tok, _, _ = token_or_die()
    _session(tok)
    emit(call_tool(tok, pos[0], args))


USAGE = ("usage: fm-linear.sh {status|list_users|get_user|list_issues|"
         "get_issue|create_issue|update_issue|add_comment|call} [args]\n"
         "  see the header of bin/fm-linear.sh for full flag documentation")

COMMANDS = {
    "status": cmd_status,
    "list_users": cmd_list_users,
    "get_user": cmd_get_user,
    "list_issues": cmd_list_issues,
    "get_issue": cmd_get_issue,
    "create_issue": cmd_create_issue,
    "update_issue": cmd_update_issue,
    "add_comment": cmd_add_comment,
    "call": cmd_call,
}


def main():
    argv = sys.argv[1:]
    if not argv or argv[0] in ("-h", "--help", "help"):
        print(USAGE)
        sys.exit(0 if argv else E_USAGE)
    cmd = argv[0]
    if cmd not in COMMANDS:
        die(E_USAGE, "unknown subcommand %r\n%s" % (cmd, USAGE))
    COMMANDS[cmd](argv[1:])


if __name__ == "__main__":
    main()
PYEOF

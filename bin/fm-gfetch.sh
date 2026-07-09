#!/usr/bin/env bash
# fm-gfetch.sh - deterministic Gmail/Drive/Calendar fetch for the meeting sync.
#
# THE PROBLEM THIS SOLVES (meeting-sync-design.md Decision 4b, Phase 0b): the
# Gemini-notes FETCH (Stage A) has the IDENTICAL per-runtime MCP-loading failure
# the Linear wrapper (bin/fm-linear.sh, Decision 4a) was built to fix. Section 1
# of the design records that recent crewmate runs had NO Google access and
# firstmate HAND-PLACED the exported markdown; a scheduled, unattended sync
# cannot rest on a fetch path that only works when a Google MCP happens to load
# and otherwise needs a human to paste the notes. This wrapper is the Google
# analogue of fm-linear.sh: it drives Google's own REST APIs (Gmail v1, Drive v3,
# Calendar v3) directly with a durable OAuth access token, exposing exactly the
# reads the pipeline needs as plain CLI subcommands that behave identically from
# a subagent brief (cited by path), a scheduled cron run, or an interactive
# shell. No per-session MCP-loading roulette.
#
# THE READS IT EXPOSES (the three Stage A needs, plus a Drive search to find a
# doc id and a status probe):
#   - threads   : search Gmail for the "Kronos Tech Sync" Gemini notes threads.
#   - thread    : read one thread's messages (subject/from/date headers).
#   - files     : search Drive for the notes doc (by name / full text).
#   - doc       : read a Drive doc's structured notes + transcript (plain text).
#   - events    : list calendar events in a window (slot selection).
#   - event     : read one calendar event: attendees + UTC start, and a computed
#                 morning|eod slot_hint per data/meetings-cadence.md.
#   - status    : credential probe (presence + source only; never the token).
#
# THE HONEST DEGRADE (meeting-sync-design.md Decision 4b, OPTION C - this is the
# LOAD-BEARING behavior of this leaf, not an afterthought). Open question 10 is
# UNRESOLVED: unlike Linear there is NO already-cached, proven-headless Google
# OAuth token. So the durable credential this wrapper needs may be ABSENT or
# EXPIRED. When it is, a FETCH subcommand does NOT hang and does NOT silently
# return nothing. It prints ONE machine-parseable line to stdout beginning with
# the stable token `notes-not-fetchable` (so a caller / the scheduled run can
# grep for it and post "paste the notes" to the board), writes a human recovery
# hint to stderr, and exits non-zero (code 3). This is the design's explicit
# failure behavior until David settles the credential (open question 10); it is
# the real, robust degrade, NOT a claim of unattended fetch autonomy that does
# not yet exist. The scheduled-autonomy claim becomes true only once a durable
# credential is wired below and proven headless.
#
# CREDENTIAL RESOLUTION (never printed, never logged), first hit wins. Every
# candidate is a way to obtain a Google OAuth ACCESS token for the Gmail/Drive/
# Calendar read scopes; which one David settles on is open question 10.
#   1. $FM_GOOGLE_ACCESS_TOKEN   - an explicit durable access token (override).
#   2. $FM_GOOGLE_CRED_FILE (or ~/.config/fm-gfetch/credentials.json) - a JSON
#      credential file, in either shape:
#        (a) {"access_token": "...", "expiry": "<ISO8601 | epoch-seconds>"}
#            - used directly; treated as expired if past `expiry`.
#        (b) {"client_id","client_secret","refresh_token"[,"token_uri"]}
#            (also the gcloud "authorized_user" application-default shape) - the
#            wrapper MINTS a fresh access token from the refresh token via the
#            OAuth token endpoint. Google refresh tokens do NOT rotate on use
#            (unlike Linear's), so this refresh is safe and desyncs nothing; it
#            is the durable UNATTENDED path the design wants once a credential
#            with a refresh_token exists.
#   3. gcloud                    - `gcloud auth print-access-token` when a gcloud
#      account is configured (convenience; scopes depend on the gcloud login).
#   4. macOS Keychain / ~/.claude/.credentials.json mcpOAuth - a `google`/
#      `gmail`/`drive`/`calendar` entry's accessToken, the analogue of the
#      linear-kronos entry fm-linear.sh reads, for if/when a Google MCP is
#      OAuth-authorized in the main Claude Code session.
# As of this leaf NONE of these is populated on David's machine (only linear and
# supabase live in the mcpOAuth store, and gcloud has no account), so the live
# path today is the honest degrade above. That is expected and is exactly what
# open question 10 tracks.
#
# SAFETY: read-only. There are NO write subcommands - this wrapper never mutates
# Gmail, Drive, or Calendar. The credential is never printed (status reports only
# presence + source); the machine-parseable degrade line never contains it.
#
# TRANSPORT: plain HTTPS GET against the Google REST APIs with an
# `Authorization: Bearer <token>` header; JSON responses. Every network call
# carries a timeout so a fetch can never hang the scheduled run.
#
# USAGE:
#   fm-gfetch.sh status
#   fm-gfetch.sh threads --query 'Kronos Tech Sync' [--limit N]
#   fm-gfetch.sh thread <threadId>
#   fm-gfetch.sh files  --query 'Kronos Tech Sync' [--limit N] [--name-only]
#   fm-gfetch.sh doc    <fileId> [--format text|json]
#   fm-gfetch.sh events --query Q [--from ISO] [--to ISO] [--calendar CAL] [--limit N]
#   fm-gfetch.sh event  <eventId> [--calendar CAL]
# Common: --raw prints the unmodified Google JSON for a read subcommand.
#
# Exit codes: 0 ok; 2 usage error; 3 credential unavailable/expired/rejected
#             (the honest degrade for a fetch subcommand); 4 Google API returned
#             an error; 5 network/transport error.
set -euo pipefail

exec python3 - "$@" <<'PYEOF'
import json
import os
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

GMAIL = "https://gmail.googleapis.com/gmail/v1"
DRIVE = "https://www.googleapis.com/drive/v3"
CALENDAR = "https://www.googleapis.com/calendar/v3"
DEFAULT_TOKEN_URI = "https://oauth2.googleapis.com/token"
KEYCHAIN_SERVICE = "Claude Code-credentials"
CRED_FILE = os.environ.get(
    "FM_GOOGLE_CRED_FILE",
    os.path.expanduser("~/.config/fm-gfetch/credentials.json"))
CLAUDE_CRED_FILE = os.path.expanduser("~/.claude/.credentials.json")
HTTP_TIMEOUT = 30

E_USAGE, E_AUTH, E_API, E_NET = 2, 3, 4, 5

# Diagnostics recorded during credential resolution, surfaced by the degrade
# line and by `status`. Never holds a token value.
_CHECKED = []
_REASON = "no-credential"


def die(code, msg):
    sys.stderr.write("fm-gfetch: " + msg + "\n")
    sys.exit(code)


# --- credential resolution (never printed) ----------------------------------

def _note(src):
    if src not in _CHECKED:
        _CHECKED.append(src)


def _read_json_file(path):
    try:
        with open(path) as fh:
            return json.load(fh)
    except Exception:
        return None


def _expiry_epoch(val):
    """Coerce an ISO8601 or epoch-seconds expiry to epoch seconds, or None."""
    if val is None:
        return None
    if isinstance(val, (int, float)):
        return float(val)
    s = str(val).strip()
    if not s:
        return None
    try:
        return float(s)
    except ValueError:
        pass
    import datetime
    try:
        s2 = s.replace("Z", "+00:00")
        dt = datetime.datetime.fromisoformat(s2)
        if dt.tzinfo is None:
            dt = dt.replace(tzinfo=datetime.timezone.utc)
        return dt.timestamp()
    except Exception:
        return None


def _mint_from_refresh(cred):
    """Mint an access token from a refresh_token credential. Never prints it."""
    data = urllib.parse.urlencode({
        "client_id": cred.get("client_id", ""),
        "client_secret": cred.get("client_secret", ""),
        "refresh_token": cred.get("refresh_token", ""),
        "grant_type": "refresh_token",
    }).encode()
    uri = cred.get("token_uri") or DEFAULT_TOKEN_URI
    req = urllib.request.Request(
        uri, data=data,
        headers={"Content-Type": "application/x-www-form-urlencoded"},
        method="POST")
    try:
        resp = urllib.request.urlopen(req, timeout=HTTP_TIMEOUT)
    except urllib.error.HTTPError:
        # A rejected refresh token behaves exactly like an expired credential.
        return None, None
    except urllib.error.URLError:
        return None, None
    try:
        body = json.loads(resp.read().decode())
    except Exception:
        return None, None
    tok = body.get("access_token")
    if not tok:
        return None, None
    exp = None
    if body.get("expires_in"):
        try:
            exp = time.time() + float(body["expires_in"])
        except (TypeError, ValueError):
            exp = None
    return tok, exp


def _from_cred_file(path, label):
    global _REASON
    cred = _read_json_file(path)
    if not cred:
        return None
    # gcloud application-default nests the authorized_user under no key or under
    # the top level; accept either the flat shape or a nested dict.
    if "access_token" in cred:
        exp = _expiry_epoch(cred.get("expiry") or cred.get("expiry_date"))
        if exp is not None and exp <= time.time():
            _REASON = "credential-expired"
            return None
        return (cred["access_token"], label, exp)
    if cred.get("refresh_token"):
        tok, exp = _mint_from_refresh(cred)
        if tok:
            return (tok, label + " (refreshed)", exp)
        _REASON = "credential-expired"
        return None
    return None


def _from_gcloud():
    try:
        tok = subprocess.check_output(
            ["gcloud", "auth", "print-access-token"],
            text=True, stderr=subprocess.DEVNULL, timeout=HTTP_TIMEOUT).strip()
    except Exception:
        return None
    return (tok, "gcloud auth print-access-token", None) if tok else None


def _google_mcp_entry(cred):
    mc = cred.get("mcpOAuth", {}) if isinstance(cred, dict) else {}
    if not isinstance(mc, dict):
        return None
    wanted = ("google", "gmail", "drive", "calendar", "gsuite", "workspace")
    for key, e in mc.items():
        low = key.lower()
        if any(w in low for w in wanted):
            if isinstance(e, dict) and e.get("accessToken"):
                exp = e.get("expiresAt")
                exp = float(exp) / 1000.0 if isinstance(exp, (int, float)) else None
                return (e["accessToken"], "mcpOAuth " + key.split("|")[0], exp)
    return None


def _keychain_json():
    try:
        raw = subprocess.check_output(
            ["security", "find-generic-password", "-s", KEYCHAIN_SERVICE, "-w"],
            text=True, stderr=subprocess.DEVNULL, timeout=HTTP_TIMEOUT).strip()
        return json.loads(raw)
    except Exception:
        return None


def resolve_token():
    """Return (token, source, expiry_epoch|None) or (None, None, None).

    Never logs the token. Records the sources it checked in _CHECKED and the
    failure reason in _REASON for the degrade line / status.
    """
    global _REASON
    _note("env")
    env = os.environ.get("FM_GOOGLE_ACCESS_TOKEN")
    if env and env.strip():
        return env.strip(), "FM_GOOGLE_ACCESS_TOKEN env", None

    _note("credfile")
    hit = _from_cred_file(CRED_FILE, CRED_FILE)
    if hit:
        return hit

    _note("gcloud")
    hit = _from_gcloud()
    if hit:
        return hit

    _note("mcpstore")
    for cred in (_keychain_json(), _read_json_file(CLAUDE_CRED_FILE)):
        if not cred:
            continue
        hit = _google_mcp_entry(cred)
        if hit:
            exp = hit[2]
            if exp is not None and exp <= time.time():
                _REASON = "credential-expired"
                continue
            return hit
    return None, None, None


def _degrade_and_exit(cmd):
    """Emit the machine-parseable 'notes-not-fetchable, paste them' degrade line
    on stdout, a human recovery hint on stderr, and exit non-zero (Decision 4b
    Option C). The credential is never referenced in either stream."""
    sys.stdout.write(
        "notes-not-fetchable paste-them reason=%s subcommand=%s checked=%s\n"
        % (_REASON, cmd, ",".join(_CHECKED)))
    sys.stdout.flush()
    phrase = {"credential-expired": "is EXPIRED",
              "credential-rejected": "was REJECTED by Google (expired/insufficient scope)",
              }.get(_REASON, "is UNAVAILABLE")
    sys.stderr.write(
        "fm-gfetch: Google credential %s; cannot fetch the meeting notes.\n"
        "  This is the designed honest degrade (meeting-sync-design.md "
        "Decision 4b Option C): the run should PASTE the notes by hand.\n"
        "  To make the fetch autonomous, provide a durable Google credential "
        "(open question 10), one of:\n"
        "    - export FM_GOOGLE_ACCESS_TOKEN=<a Gmail/Drive/Calendar access token>, or\n"
        "    - write %s with {client_id,client_secret,refresh_token} (or a\n"
        "      {access_token,expiry} pair), or\n"
        "    - configure gcloud (`gcloud auth login` with the needed scopes).\n"
        % (phrase, CRED_FILE))
    sys.exit(E_AUTH)


def token_or_degrade(cmd):
    tok, src, exp = resolve_token()
    if not tok:
        _degrade_and_exit(cmd)
    return tok, src, exp


# --- HTTP transport ----------------------------------------------------------

def _get(tok, url, cmd, accept_text=False):
    req = urllib.request.Request(
        url, headers={"Authorization": "Bearer " + tok}, method="GET")
    try:
        resp = urllib.request.urlopen(req, timeout=HTTP_TIMEOUT)
    except urllib.error.HTTPError as ex:
        detail = ex.read().decode(errors="replace")[:400]
        if ex.code in (401, 403):
            # An expired/rejected token in the middle of a call is the same
            # honest-degrade condition as a missing one.
            global _REASON
            _REASON = "credential-rejected"
            _degrade_and_exit(cmd)
        die(E_API, "Google API HTTP %d: %s" % (ex.code, detail))
    except urllib.error.URLError as ex:
        die(E_NET, "network error reaching Google (%s): %s" % (url.split("?")[0], ex.reason))
    raw = resp.read()
    if accept_text:
        return raw.decode(errors="replace")
    try:
        return json.loads(raw.decode())
    except Exception:
        die(E_API, "Google returned a non-JSON body")


def emit(obj):
    sys.stdout.write(json.dumps(obj, indent=2, ensure_ascii=False) + "\n")


# --- argument helpers (mirrors fm-linear.sh) ---------------------------------

def opts(argv):
    """Parse a flat [--flag value | --bool | positional] list."""
    BOOL = {"--raw", "--name-only"}
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


def _q(params):
    return urllib.parse.urlencode(params)


def _limit(f, default=10):
    """Parse --limit as a positive int, or die(E_USAGE) on a bad value so a
    non-numeric flag surfaces the documented usage error, not a traceback."""
    raw = f.get("limit", default)
    try:
        n = int(raw)
    except (TypeError, ValueError):
        die(E_USAGE, "--limit must be a positive integer, got %r" % (raw,))
    if n <= 0:
        die(E_USAGE, "--limit must be a positive integer, got %r" % (raw,))
    return n


# --- subcommands -------------------------------------------------------------

def cmd_status(argv):
    tok, src, exp = resolve_token()
    if not tok:
        print("credential: NONE reachable  (reason: %s)" % _REASON)
        print("  checked: %s" % ", ".join(_CHECKED))
        print("  this is expected until open question 10 is settled; fetch")
        print("  subcommands will emit the 'notes-not-fetchable' degrade and")
        print("  exit 3 (meeting-sync-design.md Decision 4b Option C).")
        print("  remedy: export FM_GOOGLE_ACCESS_TOKEN, write %s, or configure gcloud."
              % CRED_FILE)
        sys.exit(E_AUTH)
    print("credential: present (source: %s)" % src)
    if exp is not None:
        import datetime
        left = exp - time.time()
        when = datetime.datetime.fromtimestamp(exp).isoformat()
        state = "EXPIRED" if left <= 0 else "valid (%.1f h left)" % (left / 3600.0)
        print("  expires: %s  [%s]" % (when, state))
    else:
        print("  expires: n/a (no expiry recorded for this source)")
    # live connectivity probe (read-only): a cheap Gmail profile GET.
    prof = _get(tok, GMAIL + "/users/me/profile", "status")
    print("  connectivity: OK, mailbox=%s" % prof.get("emailAddress", "?"))


def _thread_headers(tok, tid):
    url = (GMAIL + "/users/me/threads/" + urllib.parse.quote(tid) + "?"
           + _q([("format", "metadata"),
                 ("metadataHeaders", "Subject"),
                 ("metadataHeaders", "From"),
                 ("metadataHeaders", "Date")]))
    data = _get(tok, url, "thread")
    msgs = data.get("messages", [])
    out = {"id": tid, "messageCount": len(msgs)}
    if msgs:
        hdrs = {h["name"]: h["value"]
                for h in msgs[0].get("payload", {}).get("headers", [])}
        out["subject"] = hdrs.get("Subject")
        out["from"] = hdrs.get("From")
        out["date"] = hdrs.get("Date")
        out["snippet"] = msgs[0].get("snippet")
    return out


def cmd_threads(argv):
    pos, f = opts(argv)
    query = f.get("query", "Kronos Tech Sync")
    limit = _limit(f)
    tok, _, _ = token_or_degrade("threads")
    url = GMAIL + "/users/me/threads?" + _q([("q", query), ("maxResults", limit)])
    data = _get(tok, url, "threads")
    if f.get("raw"):
        emit(data)
        return
    threads = data.get("threads", [])[:limit]
    emit({"query": query,
          "resultSizeEstimate": data.get("resultSizeEstimate"),
          "threads": [_thread_headers(tok, t["id"]) for t in threads]})


def cmd_thread(argv):
    pos, f = opts(argv)
    if not pos:
        die(E_USAGE, "thread needs a <threadId> argument")
    tok, _, _ = token_or_degrade("thread")
    if f.get("raw"):
        url = (GMAIL + "/users/me/threads/" + urllib.parse.quote(pos[0])
               + "?format=full")
        emit(_get(tok, url, "thread"))
        return
    emit(_thread_headers(tok, pos[0]))


def cmd_files(argv):
    pos, f = opts(argv)
    query = f.get("query", "Kronos Tech Sync")
    limit = _limit(f)
    # Match on name OR full text so a Gemini "Notes: ..." doc is found either way.
    if f.get("name-only"):
        drive_q = "name contains '%s'" % query.replace("'", "\\'")
    else:
        drive_q = ("name contains '%s' or fullText contains '%s'"
                   % (query.replace("'", "\\'"), query.replace("'", "\\'")))
    tok, _, _ = token_or_degrade("files")
    url = DRIVE + "/files?" + _q([
        ("q", drive_q),
        ("orderBy", "modifiedTime desc"),
        ("pageSize", limit),
        ("fields",
         "files(id,name,mimeType,modifiedTime,createdTime,owners(emailAddress,displayName))"),
    ])
    data = _get(tok, url, "files")
    if f.get("raw"):
        emit(data)
        return
    emit({"query": query, "files": data.get("files", [])[:limit]})


def cmd_doc(argv):
    pos, f = opts(argv)
    if not pos:
        die(E_USAGE, "doc needs a <fileId> argument")
    fid = urllib.parse.quote(pos[0])
    tok, _, _ = token_or_degrade("doc")
    meta = _get(tok, DRIVE + "/files/" + fid
                + "?fields=id,name,mimeType,modifiedTime,createdTime,owners(emailAddress,displayName)",
                "doc")
    mime = meta.get("mimeType", "")
    if mime == "application/vnd.google-apps.document":
        text = _get(tok, DRIVE + "/files/" + fid + "/export?mimeType=text/plain",
                    "doc", accept_text=True)
    else:
        # A non-Google-Doc file (uploaded .txt/.md/pdf): stream the bytes.
        text = _get(tok, DRIVE + "/files/" + fid + "?alt=media", "doc",
                    accept_text=True)
    if f.get("format") == "json" or f.get("raw"):
        emit({"id": meta.get("id"), "name": meta.get("name"),
              "mimeType": mime, "modifiedTime": meta.get("modifiedTime"),
              "createdTime": meta.get("createdTime"),
              "owners": meta.get("owners", []), "text": text})
        return
    # Default: the raw structured-notes + transcript text (what Stage B extracts).
    sys.stdout.write(text if text.endswith("\n") else text + "\n")


def _classify_event(ev):
    """Attach a morning|eod slot_hint per data/meetings-cadence.md.

    The CST->PT trap and the Eric/Yujie attendee discriminator both live in
    that file: the Gemini docs are China-CST timestamped, so classification
    MUST use the calendar event's real UTC start converted to PT, not a doc
    title. Before ~13:00 PT = morning; after = eod. Eric present + morning is
    the Mon/Fri morning sync; Yujie present with Eric absent in the evening is
    an eod. This is a hint for the extractor, not an override of David's call.
    """
    import datetime
    start = ev.get("start", {}) or {}
    raw = start.get("dateTime") or start.get("date")
    attendees = ev.get("attendees", []) or []
    names = " ".join(
        ((a.get("displayName") or "") + " " + (a.get("email") or "")).lower()
        for a in attendees)
    eric = "eric" in names
    yujie = "yujie" in names
    out = {"start_raw": raw, "attendees": [
        {"email": a.get("email"), "displayName": a.get("displayName"),
         "responseStatus": a.get("responseStatus")} for a in attendees],
        "eric_present": eric, "yujie_present": yujie}
    if not raw:
        out["note"] = "no start time on event; cannot classify"
        return out
    try:
        dt = datetime.datetime.fromisoformat(raw.replace("Z", "+00:00"))
        if dt.tzinfo is None:
            dt = dt.replace(tzinfo=datetime.timezone.utc)
        out["start_utc"] = dt.astimezone(datetime.timezone.utc).isoformat()
        try:
            from zoneinfo import ZoneInfo
            pt = dt.astimezone(ZoneInfo("America/Los_Angeles"))
            out["start_pt"] = pt.isoformat()
            out["weekday_pt"] = pt.strftime("%A")
            morning = pt.hour < 13
            out["slot_hint"] = "morning" if morning else "eod"
            if pt.strftime("%A") not in ("Monday", "Friday") and morning:
                out["note"] = ("morning by time but not Mon/Fri; cadence says "
                               "only Mon/Fri have a morning sync - verify")
            elif morning and eric:
                out["note"] = "morning + Eric present: Mon/Fri morning sync"
            elif (not morning) and yujie and not eric:
                out["note"] = "evening + Yujie present, Eric absent: eod"
        except Exception:
            out["slot_hint"] = None
            out["note"] = ("zoneinfo unavailable; only UTC computed - convert "
                           "CST->PT before classifying (meetings-cadence.md)")
    except Exception:
        out["note"] = "unparseable start time; classify by hand"
    return out


def cmd_events(argv):
    pos, f = opts(argv)
    cal = urllib.parse.quote(f.get("calendar", "primary"))
    limit = _limit(f)
    params = [("singleEvents", "true"), ("orderBy", "startTime"),
              ("maxResults", limit)]
    if "query" in f:
        params.append(("q", f["query"]))
    if "from" in f:
        params.append(("timeMin", f["from"]))
    if "to" in f:
        params.append(("timeMax", f["to"]))
    tok, _, _ = token_or_degrade("events")
    url = CALENDAR + "/calendars/" + cal + "/events?" + _q(params)
    data = _get(tok, url, "events")
    if f.get("raw"):
        emit(data)
        return
    items = data.get("items", [])[:limit]
    emit({"calendar": f.get("calendar", "primary"),
          "events": [{"id": e.get("id"), "summary": e.get("summary"),
                      "classification": _classify_event(e)} for e in items]})


def cmd_event(argv):
    pos, f = opts(argv)
    if not pos:
        die(E_USAGE, "event needs an <eventId> argument")
    cal = urllib.parse.quote(f.get("calendar", "primary"))
    tok, _, _ = token_or_degrade("event")
    url = CALENDAR + "/calendars/" + cal + "/events/" + urllib.parse.quote(pos[0])
    ev = _get(tok, url, "event")
    if f.get("raw"):
        emit(ev)
        return
    emit({"id": ev.get("id"), "summary": ev.get("summary"),
          "classification": _classify_event(ev)})


USAGE = ("usage: fm-gfetch.sh {status|threads|thread|files|doc|events|event} [args]\n"
         "  see the header of bin/fm-gfetch.sh for full flag documentation")

COMMANDS = {
    "status": cmd_status,
    "threads": cmd_threads,
    "thread": cmd_thread,
    "files": cmd_files,
    "doc": cmd_doc,
    "events": cmd_events,
    "event": cmd_event,
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

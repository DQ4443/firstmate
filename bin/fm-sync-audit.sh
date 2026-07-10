#!/usr/bin/env bash
# fm-sync-audit.sh - append-only per-write audit log for the meeting-sync loop.
#
# THE PROBLEM THIS SOLVES (meeting-sync-design.md section 9a, Phase 0): a
# scheduled sync makes autonomous Linear + tracker + narrative + digest writes
# with no durable record of what changed, why, or on whose authority. Without
# that record there is no dispute-resolution trail ("why did ENG-260 move to
# Done") and, worse, no substrate for the reverse-run rollback (section 9b),
# which reads a slot's writes newest-first and applies the inverse of each. This
# script IS that substrate: every write in every later phase appends one line
# here BEFORE or as it lands, so the log is the source of truth for both audit
# and undo.
#
# THE RECORD (one JSON object per line, data/meeting-sync-audit/<slot-id>.jsonl):
#   ts        - ISO-8601 UTC timestamp of the append
#   slot      - the (date, morning|eod) slot id this write belongs to
#   run       - the run that made the write (defaults to slot; distinct when a
#               backfill run reprocesses an older slot, section 3)
#   target    - what was written: an ENG id (ENG-260) or a tracker node/item ref
#   op        - the operation (set_state, add_comment, move_master_item, ...)
#   before    - the value BEFORE the write (null for a create / comment)
#   after     - the value AFTER the write (null for a delete / retract)
#   evidence  - the transcript-timecode string that justified the write
#   note      - optional free-text detail
#
# ORDERING IS FILE ORDER, NOT TIMESTAMP (robustness): entries are read back in
# the exact order they were appended, and `read --newest-first` reverses that
# order. Two ops that land in the same clock second still reverse correctly,
# which the rollback (9b, "inverse of each recorded op, newest-first") depends
# on; sorting by a coarse timestamp would corrupt the undo order.
#
# CRASH-CORRECT PARTIAL RECORDS (section 3 partial-run recovery): each op is
# appended the moment it lands, never batched to run end, and each append is a
# single O_APPEND write of one line + fsync. A crash mid-run therefore leaves a
# correct record of exactly the ops that DID land, so the resumed run skips them
# and completes the rest rather than re-applying unguarded writes. `read`
# tolerates a truncated trailing line (the one theoretical torn write) by
# skipping it with a stderr note instead of failing the whole read.
#
# NO SECRETS EVER LOGGED (section 5 safety): the audit trail must never capture
# EDIT_PASSWORD, DOCS_PASSWORD, the ht-ml update keys, the Linear OAuth token, or
# the Google fetch credential. append REFUSES (exit 3) any value that exactly
# matches a sensitive env var's value (a name matching PASSWORD/TOKEN/SECRET/KEY/
# CREDENTIAL) or that contains a "Bearer " authorization header, naming the
# offending field but never echoing the value. This is defense-in-depth: the
# caller should not pass secrets, and the substrate refuses them if it does.
#
# USAGE:
#   fm-sync-audit.sh append <slot-id> <target> <op> \
#       [--before V] [--after V] [--evidence TIMECODE] [--run R] [--note N]
#   fm-sync-audit.sh read  <slot-id> [--newest-first] [--target T] [--op O]
#   fm-sync-audit.sh slots
#   fm-sync-audit.sh path  <slot-id>
#
# read prints a JSON array (empty [] when the slot has no log yet), so it pipes
# straight into jq. append prints a one-line confirmation to stderr only, so
# `append ... && read ... | jq` stays clean.
#
# The log root is $FM_SYNC_AUDIT_DIR if set (tests point it at a temp dir), else
# <repo>/data/meeting-sync-audit. data/ is untracked runtime state, never
# committed (repo invariant), so these logs are local operational memory.
#
# Exit codes: 0 ok; 2 usage error; 3 refused (a value looked like a secret);
#             4 read/parse error on an existing log.
set -euo pipefail

FM_SYNC_AUDIT_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export FM_SYNC_AUDIT_SCRIPT_DIR

exec python3 - "$@" <<'PYEOF'
import json
import os
import sys
import time

E_USAGE, E_SECRET, E_READ = 2, 3, 4

SCRIPT_DIR = os.environ["FM_SYNC_AUDIT_SCRIPT_DIR"]
REPO_ROOT = os.path.dirname(SCRIPT_DIR)
AUDIT_DIR = os.environ.get(
    "FM_SYNC_AUDIT_DIR", os.path.join(REPO_ROOT, "data", "meeting-sync-audit"))


def die(code, msg):
    sys.stderr.write("fm-sync-audit: " + msg + "\n")
    sys.exit(code)


# --- slot id -> path (validated, no traversal) ------------------------------

def slot_path(slot):
    """Resolve <slot-id>.jsonl under the audit dir, rejecting any traversal.

    A slot id is a shape like '2026-07-06/eod' (one nested level is expected and
    allowed), so a bare component check is not enough; each path component must
    be a plain name and none may be '.'/'..'.
    """
    if not slot:
        die(E_USAGE, "slot id must not be empty")
    if slot.startswith("/") or "\\" in slot or "\x00" in slot:
        die(E_USAGE, "invalid slot id %r (no absolute paths or backslashes)" % slot)
    parts = slot.split("/")
    for p in parts:
        if p in ("", ".", ".."):
            die(E_USAGE, "invalid slot id %r (empty or . / .. component)" % slot)
        for ch in p:
            if not (ch.isalnum() or ch in "._-"):
                die(E_USAGE,
                    "invalid slot id %r (component %r has illegal char %r)"
                    % (slot, p, ch))
    return os.path.join(AUDIT_DIR, *parts) + ".jsonl"


# --- secret guard (never echoes the offending value) ------------------------

_SENSITIVE = ("PASSWORD", "TOKEN", "SECRET", "CREDENTIAL", "APIKEY")


def _sensitive_env_values():
    """Non-trivial values of env vars whose NAME marks them sensitive."""
    vals = set()
    for name, val in os.environ.items():
        up = name.upper()
        hit = up.endswith("_KEY") or any(s in up for s in _SENSITIVE)
        if hit and val and len(val) >= 6:
            vals.add(val)
    return vals


def secret_check(fields):
    """Refuse if any recorded field carries something that looks like a secret."""
    env_secrets = _sensitive_env_values()
    for key, val in fields.items():
        if not isinstance(val, str) or not val:
            continue
        if val in env_secrets:
            die(E_SECRET,
                "refusing to log field --%s: its value matches a sensitive "
                "environment variable. The audit log must never capture a "
                "password, token, or credential (design section 5)." % key)
        if "bearer " in val.lower():
            die(E_SECRET,
                "refusing to log field --%s: it contains a 'Bearer ' "
                "authorization header. The audit log must never capture a "
                "token (design section 5)." % key)


# --- argument helpers -------------------------------------------------------

def opts(argv, bool_flags=()):
    """Parse a flat [--flag value | --bool | positional] list."""
    bools = set(bool_flags)
    pos, flags, i = [], {}, 0
    while i < len(argv):
        a = argv[i]
        if a.startswith("--"):
            key = a[2:]
            if a in bools:
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


# --- subcommands ------------------------------------------------------------

def cmd_append(argv):
    pos, f = opts(argv)
    if len(pos) < 3:
        die(E_USAGE,
            "append needs <slot-id> <target> <op> "
            "[--before V] [--after V] [--evidence TIMECODE] [--run R] [--note N]")
    slot, target, op = pos[0], pos[1], pos[2]
    for extra in pos[3:]:
        die(E_USAGE, "append got an unexpected positional argument %r "
                     "(did you forget to quote a value?)" % extra)

    recordable = {
        "before": f.get("before"),
        "after": f.get("after"),
        "evidence": f.get("evidence"),
        "note": f.get("note"),
        "target": target,
        "op": op,
        "slot": slot,
        "run": f.get("run", slot),
    }
    secret_check(recordable)

    entry = {
        "ts": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "slot": slot,
        "run": f.get("run", slot),
        "target": target,
        "op": op,
        "before": f.get("before"),
        "after": f.get("after"),
        "evidence": f.get("evidence"),
    }
    if "note" in f:
        entry["note"] = f["note"]

    path = slot_path(slot)
    os.makedirs(os.path.dirname(path), exist_ok=True)
    # One atomic O_APPEND write of a single line + fsync: an incremental,
    # crash-correct record (design section 3). json.dumps never emits a raw
    # newline, so one line == one entry, which read relies on.
    line = json.dumps(entry, ensure_ascii=False, separators=(",", ":")) + "\n"
    is_new = not os.path.exists(path)
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_APPEND, 0o644)
    try:
        buf = line.encode("utf-8")
        written = 0
        # POSIX permits a short write; loop until the whole line lands so a
        # partial write can never leave a torn (non-crash) record.
        while written < len(buf):
            written += os.write(fd, buf[written:])
        os.fsync(fd)
    finally:
        os.close(fd)
    if is_new:
        # A new slot file also needs its directory entry fsync'd, or a crash
        # after fsync(fd) can still lose the freshly created file.
        dir_fd = os.open(os.path.dirname(path), os.O_RDONLY)
        try:
            os.fsync(dir_fd)
        finally:
            os.close(dir_fd)
    sys.stderr.write("fm-sync-audit: appended %s/%s to %s\n" % (op, target, path))


def _load(path):
    """Return the list of entries in append order, tolerating a torn last line."""
    if not os.path.exists(path):
        return []
    try:
        with open(path, encoding="utf-8") as fh:
            raw = fh.readlines()
    except OSError as ex:
        die(E_READ, "cannot read %s: %s" % (path, ex))
    entries = []
    for idx, ln in enumerate(raw):
        s = ln.strip()
        if not s:
            continue
        try:
            entries.append(json.loads(s))
        except json.JSONDecodeError:
            # Only the final line may be a torn write from a crash; a broken
            # line anywhere else means real corruption and must fail loudly.
            if idx == len(raw) - 1:
                sys.stderr.write(
                    "fm-sync-audit: skipping a truncated trailing line in %s "
                    "(likely a crash mid-append)\n" % path)
                continue
            die(E_READ, "corrupt (non-final) line %d in %s" % (idx + 1, path))
    return entries


def cmd_read(argv):
    pos, f = opts(argv, bool_flags=("--newest-first",))
    if not pos:
        die(E_USAGE, "read needs a <slot-id> argument")
    entries = _load(slot_path(pos[0]))
    if "target" in f:
        entries = [e for e in entries if e.get("target") == f["target"]]
    if "op" in f:
        entries = [e for e in entries if e.get("op") == f["op"]]
    if f.get("newest-first"):
        entries = list(reversed(entries))
    sys.stdout.write(json.dumps(entries, indent=2) + "\n")


def cmd_slots(argv):
    """List every slot id that has an audit log, one per line."""
    found = []
    for dirpath, _dirs, files in os.walk(AUDIT_DIR):
        for name in files:
            if name.endswith(".jsonl"):
                full = os.path.join(dirpath, name)
                rel = os.path.relpath(full, AUDIT_DIR)
                found.append(rel[:-len(".jsonl")])
    for slot in sorted(found):
        sys.stdout.write(slot + "\n")


def cmd_path(argv):
    pos, _f = opts(argv)
    if not pos:
        die(E_USAGE, "path needs a <slot-id> argument")
    sys.stdout.write(slot_path(pos[0]) + "\n")


USAGE = ("usage: fm-sync-audit.sh {append|read|slots|path} [args]\n"
         "  see the header of bin/fm-sync-audit.sh for full flag documentation")

COMMANDS = {
    "append": cmd_append,
    "read": cmd_read,
    "slots": cmd_slots,
    "path": cmd_path,
}


def main():
    argv = sys.argv[1:]
    if not argv or argv[0] in ("-h", "--help", "help"):
        sys.stdout.write(USAGE + "\n")
        sys.exit(0 if argv else E_USAGE)
    cmd = argv[0]
    if cmd not in COMMANDS:
        die(E_USAGE, "unknown subcommand %r\n%s" % (cmd, USAGE))
    COMMANDS[cmd](argv[1:])


if __name__ == "__main__":
    main()
PYEOF

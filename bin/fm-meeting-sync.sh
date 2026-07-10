#!/usr/bin/env bash
# fm-meeting-sync.sh - the meeting-sync ORCHESTRATOR (meeting-sync-design.md
# Phase 2 + the autonomous slice of Phase 3 + the Phase 5 trigger surface).
#
# WHAT THIS IS (the integrating capstone, leaf L6). One run = one processed
# meeting SLOT (design section 2). It wires the four sibling leaves into one
# deterministic pipeline and then enforces the tiered human gate, with ONE
# load-bearing invariant that this script exists to guarantee:
#
#     THE NARRATIVE NEVER SELF-MERGES.
#
# The MVP-tracker NARRATIVE lives in code (src/components/narrative/content.ts,
# design section 1). This orchestrator NEVER edits content.ts and NEVER merges
# or deploys the tracker. Every narrative change is surfaced as a change-list
# and posted to David on the tracker-sync board thread (bin/fm-board-reply.sh
# --your-court) for his gate. That is David's END gate on tracker narrative,
# preserved exactly as designed (Decision 5a, prime rule 1).
#
# THE STAGES (design section 2):
#   A. INGEST     - locate the slot's Gemini notes via bin/fm-gfetch.sh, with the
#                   honest "paste the notes" degrade (Decision 4b Option C),
#                   slot-scoped selection (not "newest doc"), multi-doc meeting
#                   identity, and the backfill gap-scan over a bounded lookback
#                   (Stage A), all on the per-slot state schema (section 3).
#   B. EXTRACT    - the timecode-anchored, classify-to-destination change proposal
#                   with the full attribute set and roster-resolved owners
#                   (Decisions 2a/2b/2c) via data/roster-linear.md. LLM-judged: it
#                   proposes, it does not act. Two producers: an explicit proposal
#                   file (FM_MSYNC_EXTRACT_FILE, the hand-run path), or in
#                   --propose mode the wired extractor bin/fm-msync-extract.sh
#                   (FM_MSYNC_EXTRACT_BIN), a headless claude -p turn over the
#                   Stage A notes that writes the same proposal JSON. The
#                   produced proposal is PERSISTED under
#                   <state-dir>/proposals/<slot>.extract.json so David's later
#                   okay can be applied from exactly what he saw
#                   (FM_MSYNC_EXTRACT_FILE=<that file> ... --apply).
#   E. REFLECT    - reconcile the tracker to Linear (Linear = SSOT) via L5's
#                   bin/fm-reconcile.sh, whose autonomous tracker-side ops are the
#                   AUTONOMOUS tier here.
#   GATE          - split the full change-list by reversibility/blast-radius into
#                   AUTONOMOUS / GATED (NEEDS-DAVID) / HARD-STOP (Decision 5a
#                   Option B). --apply lands ONLY the autonomous tier; every gated
#                   or hard-stop item and the WHOLE narrative change-list is posted
#                   to the board, never applied here.
#
# TIERS (Decision 5a Option B, verbatim intent):
#   AUTONOMOUS (no gate, one FYI after): tracker chat edits (status/group/node via
#     the reconcile), the digest publish+attach, a meeting-context [sync:<slot>]
#     COMMENT on a ticket, and a NEW deliverable ticket SELF-ASSIGNED to David.
#   GATED (posted to the board, David okays before apply): assigning/reassigning
#     ANOTHER person's ticket, a state transition on ANOTHER person's ticket even
#     when the meeting signal is confident, close/cancel/dedupe, a descope write,
#     priority/parent/project change on an existing ticket, an owner that resolves
#     to a non-eng-assignee or is UNRESOLVED, and any "ambiguous" reconcile item.
#   HARD STOP (never autonomous, reported only): model reseed, node/item deletion,
#     schema change, DOCS_PASSWORD choice, gating the whole tracker, and an
#     MVP_DEADLINE / MVP-core narrative change (the ACTIVE-gate carve-out,
#     section 5). NARRATIVE of any kind is never self-applied regardless of tier.
#
# DEPENDENCIES (this branch is cut from origin/main; the sibling leaves are not
# merged yet, so this orchestrator resolves each by PATH and DEGRADES cleanly if
# absent rather than assuming):
#   bin/fm-gfetch.sh      (leaf L2) - Gmail/Drive/Calendar fetch. ABSENT on main
#                          today; when absent, Stage A takes the honest degrade.
#   bin/fm-reconcile.sh   (leaf L5) - Linear->tracker reconcile. ABSENT on main
#                          today; when absent, Stage E is reported not-run.
#   bin/fm-sync-audit.sh  (leaf L1) - append-only audit log. ABSENT on main today;
#                          when absent, autonomous writes note "audit unavailable".
#   data/roster-linear.md (leaf L3) - owner resolution. ABSENT on main today; when
#                          absent, every owned item is flagged for David (safe).
#   bin/fm-linear.sh, bin/fm-board-reply.sh - already on main.
# A live run lights up fully once the siblings merge; nothing here silently
# fabricates a result when a dependency is missing.
#
# HERMETIC TEST HOOKS (dependency injection, so the orchestrator is testable with
# NO network and NO siblings): FM_MSYNC_STATE_DIR, FM_MSYNC_ROSTER_FILE,
# FM_MSYNC_EXTRACT_FILE, FM_MSYNC_GFETCH_BIN, FM_MSYNC_RECONCILE_BIN,
# FM_MSYNC_AUDIT_BIN, FM_MSYNC_LINEAR_BIN, FM_MSYNC_BOARD_REPLY_BIN,
# FM_MSYNC_BOARD_ITEM, FM_MSYNC_NOW (ISO-8601 UTC, deterministic clock).
#
# MODES (three, mutually exclusive; dry-run is the default):
#   --dry-run  : touches NOTHING (no state write, no board post, no Linear write).
#   --propose  : THE SCHEDULED MODE. Runs Stage A + B for REAL (fetch the notes,
#                run the extraction), builds the change-list, persists the
#                proposal artifacts under <state-dir>/proposals/, and posts the
#                proposal to the board thread (--your-court) for David's one
#                okay. It applies NOTHING: no Linear write, no tracker write, no
#                content.ts edit. The cadence NEVER auto-applies (prime rule 1);
#                FM_MSYNC_SCHEDULED=1 (set by the launchd plists) structurally
#                REJECTS --apply so a mis-edited plist cannot flip autonomy on.
#                On a degrade (notes not fetchable, extraction unavailable) it
#                posts ONE loud board line per slot ("paste the notes / fix the
#                credential"), deduped in state so a repeated failing fire never
#                spams the thread. A re-fire of an already-proposed slot with an
#                unchanged change-list posts nothing (content-hash dedupe).
#   --apply    : lands ONLY the autonomous tier, after David's okay of a
#                proposal (FM_MSYNC_EXTRACT_FILE=<persisted proposal>). Never
#                from the schedule.
#
# SAFETY: dry-run is the default and touches NOTHING. --apply lands only the
# autonomous tier; it NEVER edits content.ts, NEVER merges/deploys the tracker,
# NEVER prints EDIT_PASSWORD / DOCS_PASSWORD / the Linear or Google credential.
# The scheduler is NOT flipped on by this script: cron cadence + launchd examples
# ship uninstalled (docs/launchd/, docs/meeting-sync-schedule.md); they are registered
# only after a hand-run proves one real meeting cycle (design Phase 5), and the
# scheduled entries run --propose, never --apply.
#
# USAGE:
#   fm-meeting-sync.sh --slot YYYY-MM-DD/<morning|eod|reconcile> [--dry-run|--propose|--apply]
#                      [--lookback N] [--no-backfill] [--live-url URL]
#   fm-meeting-sync.sh install-schedule    # prints the cadence + install steps; installs NOTHING
#
# Exit codes: 0 ok (dry run always 0 unless a usage error); 2 usage error (also
#             --apply under FM_MSYNC_SCHEDULED=1);
#             3 the honest degrade: Stage A could not fetch the notes (and no
#               proposal was supplied) or the --propose extraction was
#               unavailable; the change-list still prints, and on the propose/
#               apply paths the degrade is posted loudly to the board once per
#               slot.
set -euo pipefail

FM_MSYNC_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export FM_MSYNC_SCRIPT_DIR

exec python3 - "$@" <<'PYEOF'
import argparse
import datetime as dt
import hashlib
import json
import os
import re
import subprocess
import sys
import time

SCRIPT_DIR = os.environ["FM_MSYNC_SCRIPT_DIR"]
REPO = os.path.dirname(SCRIPT_DIR)

E_USAGE, E_DEGRADE = 2, 3

# --- environment / dependency resolution ------------------------------------

def _envpath(var, default):
    v = os.environ.get(var)
    return v if v else default

STATE_DIR = _envpath("FM_MSYNC_STATE_DIR", os.path.join(REPO, "data", "meeting-sync-state"))
ROSTER_FILE = _envpath("FM_MSYNC_ROSTER_FILE", os.path.join(REPO, "data", "roster-linear.md"))
EXTRACT_FILE = os.environ.get("FM_MSYNC_EXTRACT_FILE")  # may be None
GFETCH_BIN = _envpath("FM_MSYNC_GFETCH_BIN", os.path.join(SCRIPT_DIR, "fm-gfetch.sh"))
RECONCILE_BIN = _envpath("FM_MSYNC_RECONCILE_BIN", os.path.join(SCRIPT_DIR, "fm-reconcile.sh"))
AUDIT_BIN = _envpath("FM_MSYNC_AUDIT_BIN", os.path.join(SCRIPT_DIR, "fm-sync-audit.sh"))
LINEAR_BIN = _envpath("FM_MSYNC_LINEAR_BIN", os.path.join(SCRIPT_DIR, "fm-linear.sh"))
BOARD_REPLY_BIN = _envpath("FM_MSYNC_BOARD_REPLY_BIN", os.path.join(SCRIPT_DIR, "fm-board-reply.sh"))
BOARD_ITEM = os.environ.get("FM_MSYNC_BOARD_ITEM", "tracker-sync")
EXTRACT_BIN = _envpath("FM_MSYNC_EXTRACT_BIN", os.path.join(SCRIPT_DIR, "fm-msync-extract.sh"))
PROPOSAL_DIR = os.path.join(STATE_DIR, "proposals")


def now_utc():
    v = os.environ.get("FM_MSYNC_NOW")
    if v:
        s = v.strip().replace("Z", "+00:00")
        try:
            d = dt.datetime.fromisoformat(s)
            if d.tzinfo is None:
                d = d.replace(tzinfo=dt.timezone.utc)
            return d.astimezone(dt.timezone.utc)
        except ValueError:
            pass
    return dt.datetime.now(dt.timezone.utc)


def have(path):
    return bool(path) and os.path.exists(path) and os.access(path, os.X_OK)


# --- slot model -------------------------------------------------------------

SLOT_RE = re.compile(r"^(\d{4})-(\d{2})-(\d{2})/(morning|eod|reconcile)$")
KINDS_ORDER = {"morning": 0, "eod": 1, "reconcile": 2}


class Slot:
    __slots__ = ("date", "kind")

    def __init__(self, date, kind):
        self.date = date          # datetime.date
        self.kind = kind          # morning | eod | reconcile

    @property
    def sid(self):
        return "%s/%s" % (self.date.isoformat(), self.kind)

    def sort_key(self):
        return (self.date, KINDS_ORDER[self.kind])


def parse_slot(s):
    m = SLOT_RE.match(s or "")
    if not m:
        raise SystemExit(
            "fm-meeting-sync: --slot must be YYYY-MM-DD/<morning|eod|reconcile>, got %r" % s)
    y, mo, d, kind = int(m.group(1)), int(m.group(2)), int(m.group(3)), m.group(4)
    return Slot(dt.date(y, mo, d), kind)


def cadence_slots(start_date, end_slot):
    """Every MEETING slot in [start_date .. end_slot], oldest-first, per the
    cadence (design section Stage A / meetings-cadence.md): an EOD every day,
    plus a MORNING on Monday and Friday. The 'reconcile' kind is not a meeting
    slot and is never enumerated here."""
    out = []
    d = start_date
    while d <= end_slot.date:
        # Monday=0 .. Sunday=6; morning meetings are Mon(0)/Fri(4) only.
        if d.weekday() in (0, 4):
            out.append(Slot(d, "morning"))
        out.append(Slot(d, "eod"))
        d = d + dt.timedelta(days=1)
    # trim to <= the target slot within the last day
    return [s for s in out if s.sort_key() <= end_slot.sort_key()]


# --- per-slot state schema (design section 3) -------------------------------
# state.json: { "slots": { "<sid>": {emailIds, docIds, itemKeyToEng, writeSet,
# outcome} }, "lastProcessedSlot": "<sid>", "lookbackMarker": "<iso>" }.
# A single latest id is GONE; "seen" is per-slot completeness so an older skipped
# slot is still detected as incomplete and backfilled.

def state_path():
    return os.path.join(STATE_DIR, "state.json")


def load_state():
    try:
        with open(state_path()) as fh:
            st = json.load(fh)
    except (OSError, ValueError):
        st = {}
    st.setdefault("slots", {})
    return st


def slot_complete(st, sid):
    e = st["slots"].get(sid)
    return bool(e) and e.get("outcome") in ("verified", "complete")


def save_state(st):
    """Persist the per-slot state schema atomically (design Stage G: slot state
    is written incrementally, not held in memory). Called ONLY on the apply
    path; a dry-run never touches disk."""
    os.makedirs(STATE_DIR, exist_ok=True)
    tmp = state_path() + ".tmp"
    with open(tmp, "w") as fh:
        json.dump(st, fh, indent=2, sort_keys=True)
    os.replace(tmp, state_path())


def slot_record(st, sid):
    """The mutable per-slot record (design section 3): docIds, the writeSet
    idempotency ledger, itemKeyToEng for match-before-create, and the outcome."""
    rec = st.setdefault("slots", {}).setdefault(sid, {})
    rec.setdefault("docIds", [])
    rec.setdefault("writeSet", {})
    rec.setdefault("itemKeyToEng", {})
    rec.setdefault("outcome", "planned")
    return rec


def op_key(change, sid):
    """Stable idempotency key for one autonomous write, so a re-run of the same
    slot never re-applies a recorded op (design section 3: comment markers +
    match-before-create). One meeting comment per (ticket, slot); one
    self-assigned ticket per (slot, normalized title)."""
    if change.op == "add_comment":
        return "comment:%s:%s" % (change.target, sid)
    if change.op == "create_issue":
        norm = re.sub(r"\s+", " ", (change.detail or "").strip().lower())
        return "create:%s:%s" % (sid, norm)
    return "%s:%s:%s" % (change.op, change.target, sid)


def slot_sid_ge(a, b):
    """True if slot id a is at or after slot id b in cadence order. Used to
    advance lastProcessedSlot only forward, never backward on a backfill run."""
    ma, mb = SLOT_RE.match(a or ""), SLOT_RE.match(b or "")
    if not ma or not mb:
        return True
    ka = (dt.date(int(ma.group(1)), int(ma.group(2)), int(ma.group(3))), KINDS_ORDER[ma.group(4)])
    kb = (dt.date(int(mb.group(1)), int(mb.group(2)), int(mb.group(3))), KINDS_ORDER[mb.group(4)])
    return ka >= kb


# --- owner resolution (Decision 2b, via data/roster-linear.md) --------------

UUID_RE = re.compile(r"[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}")


def load_roster(path):
    """Parse data/roster-linear.md tolerantly into:
      canon[name] = {"id": <uuid|None>, "assignable": bool}
      alias[lower_alias] = canonical
    Returns (canon, alias, present:bool). If the file is absent, present=False
    and every owned item is later flagged for David (safe, never a silent
    default)."""
    canon, alias = {}, {}
    try:
        with open(path) as fh:
            text = fh.read()
    except OSError:
        return canon, alias, False

    section = None
    for line in text.splitlines():
        h = line.strip().lower()
        if h.startswith("## "):
            if "roster table" in h:
                section = "roster"
            elif "non-eng-assignee" in h:
                section = "noneng"
            elif "garble" in h or "alias" in h:
                section = "alias"
            else:
                section = None
            continue
        if not line.strip().startswith("|"):
            continue
        cells = [c.strip() for c in line.strip().strip("|").split("|")]
        if len(cells) < 2:
            continue
        c0 = cells[0]
        if c0.lower() in ("canonical", "person", "alias / mis-hearing (any case)",
                          "handle") or set(c0) <= set("-: "):
            continue
        if section == "roster":
            name = c0
            uid = None
            for cell in cells:
                m = UUID_RE.search(cell)
                if m:
                    uid = m.group(0)
                    break
            assignable = uid is not None and "unresolved" not in " ".join(cells).lower()
            canon[name] = {"id": uid, "assignable": assignable}
            alias.setdefault(name.lower(), name)
        elif section == "noneng":
            # a person listed here is explicitly NOT an eng assignee -> gate.
            name = c0
            canon.setdefault(name, {"id": None, "assignable": False})
            canon[name]["assignable"] = False
            alias.setdefault(name.lower(), name)
        elif section == "alias":
            aliases = [a.strip() for a in re.split(r",", cells[0]) if a.strip()]
            target = re.sub(r"\(.*?\)", "", cells[1]).strip()
            for a in aliases:
                alias[a.lower()] = target
    return canon, alias, True


def resolve_owner(spoken, canon, alias, present):
    """Return (canonical, linear_id, status) where status is one of
    resolved | default-david | gate | unavailable. Never invents an id, never
    silently defaults a stated-but-external owner to David (Decision 2b)."""
    if not present:
        return (spoken or None, None, "unavailable")
    if not spoken or not spoken.strip():
        # truly unstated owner -> the only default (Decision 2b step 5, open Q7)
        return ("David", (canon.get("David") or {}).get("id"), "default-david")
    key = spoken.strip().lower()
    name = alias.get(key)
    if name is None:
        # a stated name we do not recognize: do NOT invent, do NOT default. Gate.
        return (spoken.strip(), None, "gate")
    info = canon.get(name, {})
    if info.get("assignable") and info.get("id"):
        return (name, info["id"], "resolved")
    # stated but non-assignable (a PM) or unresolved (no Linear account) -> gate.
    return (name, info.get("id"), "gate")


# --- change-list model + tiered gate (Decision 5a Option B) ------------------

AUTONOMOUS, GATED, HARDSTOP = "AUTONOMOUS", "GATED", "HARD-STOP"

# destinations produced by Stage B extraction (Decision 2a) + the reconcile.
# Each maps to a tier by reversibility/blast-radius. NARRATIVE is special-cased
# out of every autonomous path (see classify()).


class Change:
    __slots__ = ("tier", "stage", "op", "target", "detail", "owner", "timecode", "reason")

    def __init__(self, tier, stage, op, target, detail, owner=None, timecode=None, reason=""):
        self.tier = tier
        self.stage = stage
        self.op = op
        self.target = target
        self.detail = detail
        self.owner = owner
        self.timecode = timecode
        self.reason = reason


def classify_item(item, canon, alias, roster_present):
    """Map one extracted item (Decision 2a categories) to a Change with a tier.
    Returns (change, is_narrative:bool). Narrative is NEVER applied here."""
    cat = (item.get("category") or "").upper()
    dest = (item.get("destination") or "").lower()
    title = item.get("title") or item.get("eng") or "(untitled)"
    eng = item.get("eng")
    tc = item.get("timecode")
    spoken = item.get("owner")
    is_existing = bool(eng)

    # NARRATIVE: a standing DECISION export or an MVP-core field. Never applied.
    if dest in ("narrative", "narrative-standing", "narrative-daycope", "narrative-dayscoped"):
        mvp_core = bool(item.get("mvp_core")) or (item.get("field") or "").upper() == "MVP_DEADLINE"
        tier = HARDSTOP if mvp_core else GATED
        reason = ("MVP-core/MVP_DEADLINE change is an ACTIVE decision (section 5 "
                  "carve-out); routed to David, never auto-overwritten") if mvp_core else \
                 "narrative change: surfaced to David, content.ts is never self-edited"
        c = Change(tier, "narrative", "narrative_change", eng or title,
                   item.get("description") or title, timecode=tc, reason=reason)
        return c, True

    canon_owner, oid, ostatus = resolve_owner(spoken, canon, alias, roster_present)

    if cat == "FYI" or dest in ("digest-only", "digest"):
        c = Change(AUTONOMOUS, "extract", "digest_only", title,
                   "pure FYI -> digest only, suppressed from Linear",
                   owner=canon_owner, timecode=tc)
        return c, False

    if cat == "DECISION" or dest == "comment":
        # a meeting-context comment on the affected ticket. The [sync:<slot>]
        # marker is prepended at apply time (op_key + comment body), so the
        # detail here is the human-readable meeting context itself, never the
        # literal placeholder token.
        c = Change(AUTONOMOUS, "extract", "add_comment", eng or "(net-new)",
                   "meeting-context: %s" % (item.get("description") or title),
                   owner=canon_owner, timecode=tc)
        return c, False

    if cat == "STATUS CLAIM" or dest == "state-transition":
        # a state flip. By design (Decision 5a) an OWN-ticket move is autonomous,
        # but the autonomous set_state WRITE is not wired into apply_autonomous
        # yet, so classifying it AUTONOMOUS would advertise an action the apply
        # path silently drops. Until the write lands, an own-ticket state move is
        # GATED too (honest change-list > a lie about what applies). Another
        # person's ticket is GATED regardless of confidence.
        own = (canon_owner == "David")
        reason = ("own-ticket state move; GATED until the autonomous set_state write is "
                  "wired (not applied autonomously today)") if own else \
                 "state transition on another person's ticket is high blast radius (gated even when confident)"
        c = Change(GATED, "extract", "set_state", eng or title,
                   item.get("state") or "(target state)", owner=canon_owner,
                   timecode=tc, reason=reason)
        return c, False

    if dest in ("close", "cancel", "dedupe") or cat in ("CLOSE", "DEDUPE"):
        c = Change(GATED, "extract", "close_issue", eng or title,
                   "close/cancel/dedupe is destructive to real work", owner=canon_owner,
                   timecode=tc, reason="destructive; gated")
        return c, False

    if dest == "descope" or cat == "DESCOPE":
        c = Change(GATED, "extract", "descope", eng or title,
                   "coordinated descope write (edit desc + close sub-issue + drift marker)",
                   owner=canon_owner, timecode=tc, reason="edits/closes real work; gated (Decision 5c)")
        return c, False

    # DELIVERABLE / ACTION ITEM -> create or update a ticket.
    if is_existing:
        # updating an EXISTING ticket's attributes: reassign / priority / parent /
        # project on someone else's ticket is gated.
        gated = ostatus in ("gate", "unavailable") or (canon_owner and canon_owner != "David")
        tier = GATED if gated else AUTONOMOUS
        reason = "attribute/reassign change on an existing ticket" if gated else "own-ticket update"
        c = Change(tier, "reconcile", "update_issue", eng,
                   "update attributes" + (" + reassign %s" % canon_owner if spoken else ""),
                   owner=canon_owner, timecode=tc, reason=reason)
        return c, False

    # NET-NEW ticket. Self-assigned to David is AUTONOMOUS; anyone else is GATED.
    if ostatus == "resolved" and canon_owner != "David":
        c = Change(GATED, "extract", "create_issue", "(net-new)",
                   "%s: %s" % (title, "assigns another person"), owner=canon_owner,
                   timecode=tc, reason="creating a ticket assigned to another person")
        return c, False
    if ostatus in ("gate", "unavailable"):
        c = Change(GATED, "extract", "create_issue", "(net-new)",
                   "%s: owner %s unresolved/non-assignee" % (title, spoken or "?"),
                   owner=canon_owner, timecode=tc,
                   reason="owner unresolved or non-eng-assignee (roster) -> David decides")
        return c, False
    # default-david or resolved-David: self-assignment, low blast radius.
    c = Change(AUTONOMOUS, "extract", "create_issue", "(net-new, David)",
               title, owner="David", timecode=tc,
               reason="new deliverable self-assigned to David (low blast radius)")
    return c, False


# --- Stage A: ingest --------------------------------------------------------

def slot_window_pt(slot):
    """Human-readable PT window a slot-scoped Gmail/Drive query targets (design
    Stage A). Time-of-day is authoritative: morning < 13:00 PT, eod >= 13:00 PT."""
    if slot.kind == "morning":
        return "%s 06:00-13:00 PT (Mon/Fri morning sync)" % slot.date.isoformat()
    if slot.kind == "eod":
        return "%s 13:00-23:59 PT (daily EOD)" % slot.date.isoformat()
    return "%s (meeting-less daily reconcile)" % slot.date.isoformat()


def _to_pt(iso):
    """RFC3339 timestamp -> America/Los_Angeles datetime. Classification hinges
    on the 13:00 PT boundary (Decision 7a), so the conversion uses the real tz
    database; the fixed UTC-8 fallback only fires if zoneinfo is unavailable."""
    s = (iso or "").strip().replace("Z", "+00:00")
    d = dt.datetime.fromisoformat(s)
    if d.tzinfo is None:
        d = d.replace(tzinfo=dt.timezone.utc)
    try:
        from zoneinfo import ZoneInfo
        return d.astimezone(ZoneInfo("America/Los_Angeles"))
    except Exception:  # noqa: BLE001 - a degraded tz is better than a crash
        return d.astimezone(dt.timezone(dt.timedelta(hours=-8)))


def _in_slot_window(slot, f):
    """True iff a Drive file record plausibly belongs to this slot's PT window
    (design Stage A: slot-scoped selection, never 'the newest doc'). A record
    with no usable timestamp is kept (cannot be ruled out; extracting from one
    extra doc beats a false degrade)."""
    seen_time = False
    for key in ("createdTime", "modifiedTime"):
        v = f.get(key)
        if not v:
            continue
        try:
            p = _to_pt(v)
        except ValueError:
            continue
        seen_time = True
        if p.date() != slot.date:
            continue
        if slot.kind == "morning" and p.hour < 13:
            return True
        if slot.kind == "eod" and p.hour >= 13:
            return True
    return not seen_time


def stage_a_ingest(slot, out, want_text=False):
    """Locate the slot's notes via bin/fm-gfetch.sh, slot-scoped, multi-doc.
    Returns (docs:list, degraded:bool, reason:str, notes_text:str). With
    want_text (the --propose path) it also reads each in-window doc's notes +
    transcript text for Stage B. On absence/failure of the fetch wrapper, take
    the honest degrade (Decision 4b Option C): emit the machine-parseable
    'notes-not-fetchable' token AND return the reason so the caller posts the
    loud 'paste the notes' board line, rather than staying silently empty."""
    out.append("stage A INGEST: slot-scoped window = %s" % slot_window_pt(slot))
    if slot.kind == "reconcile":
        out.append("  reconcile slot: no meeting fetch (degenerate case, skips B-D)")
        return [], False, "", ""

    # an explicit extraction proposal implies the notes were already fetched.
    if EXTRACT_FILE and os.path.exists(EXTRACT_FILE):
        out.append("  notes: supplied via extraction proposal (%s)" % EXTRACT_FILE)
        return ["(from-proposal)"], False, "", ""

    def degrade(reason):
        out.append("  notes-not-fetchable: %s. HONEST DEGRADE (Decision 4b "
                   "Option C): paste the notes or supply FM_MSYNC_EXTRACT_FILE." % reason)
        return [], True, reason, ""

    if not have(GFETCH_BIN):
        return degrade("bin/fm-gfetch.sh (leaf L2) is not on this branch/PATH")

    try:
        r = subprocess.run(
            [GFETCH_BIN, "files", "--query", "Kronos Tech Sync", "--limit", "10"],
            capture_output=True, text=True, timeout=90)
    except Exception as exc:  # noqa: BLE001 - degrade never crashes the run
        return degrade("fm-gfetch.sh error (%s)" % exc)
    if r.returncode == 3 or "notes-not-fetchable" in (r.stdout + r.stderr):
        return degrade("the Google credential is absent/expired (open question 10)")
    if r.returncode != 0:
        return degrade("fm-gfetch.sh exit %d" % r.returncode)

    # fm-gfetch.sh files emits {"query":..., "files":[{id,name,createdTime,
    # modifiedTime,...}]}; tolerate a plain-line emitter (older mocks) too.
    try:
        data = json.loads(r.stdout)
        files = data.get("files", []) if isinstance(data, dict) else []
    except ValueError:
        files = [{"id": None, "name": ln.strip()}
                 for ln in r.stdout.splitlines() if ln.strip()]
    in_window = [f for f in files if isinstance(f, dict) and _in_slot_window(slot, f)]
    out.append("  slot docs (multi-doc identity, the SET not the newest): "
               "%d of %d candidate(s) in the %s window" % (len(in_window), len(files), slot.kind))
    if not in_window:
        return degrade("no notes doc found in the %s window (%d candidate doc(s), none match)"
                       % (slot.sid, len(files)))
    if not want_text:
        return in_window, False, "", ""

    # --propose: read each in-window doc's notes + transcript for Stage B.
    texts = []
    for f in in_window:
        fid = f.get("id")
        if not fid:
            continue
        try:
            rd = subprocess.run([GFETCH_BIN, "doc", str(fid)],
                                capture_output=True, text=True, timeout=120)
        except Exception as exc:  # noqa: BLE001
            return degrade("doc %s fetch error (%s)" % (fid, exc))
        if rd.returncode != 0 or "notes-not-fetchable" in (rd.stdout + rd.stderr):
            return degrade("doc %s not readable (fm-gfetch.sh exit %d)" % (fid, rd.returncode))
        texts.append("===== DOC %s (%s) =====\n%s" % (f.get("name") or fid, fid, rd.stdout))
    if not texts:
        return degrade("slot docs found but none carried a readable Drive id")
    out.append("  notes text fetched for %d doc(s) (Stage B input)" % len(texts))
    return in_window, False, "", "\n".join(texts)


# --- Stage B: extract (LLM-judged; consumed from the proposal file) ---------

def stage_b_extract(out):
    """Consume the extraction proposal (Decision 2a/2b). Stage B is LLM-judged
    (it proposes, it does not act); this orchestrator consumes the proposal the
    LLM step wrote to FM_MSYNC_EXTRACT_FILE. Returns a list of item dicts."""
    if not EXTRACT_FILE:
        out.append("stage B EXTRACT: no extraction proposal supplied "
                   "(FM_MSYNC_EXTRACT_FILE unset). In a live run this is where the "
                   "timecode-anchored LLM extraction (Decision 2a/2b) writes its "
                   "classify-to-destination proposal; nothing to classify this pass.")
        return []
    try:
        with open(EXTRACT_FILE) as fh:
            data = json.load(fh)
    except (OSError, ValueError) as exc:
        out.append("stage B EXTRACT: proposal unreadable (%s); nothing classified." % exc)
        return []
    items = data.get("items") if isinstance(data, dict) else data
    if not isinstance(items, list):
        out.append("stage B EXTRACT: proposal has no 'items' list; nothing classified.")
        return []
    out.append("stage B EXTRACT: %d extracted item(s), each classify-to-destination "
               "with a transcript timecode anchor (Decision 2a)." % len(items))
    return items


def _slot_base(slot):
    return slot.sid.replace("/", "-")


def stage_b_produce(slot, notes_text, out):
    """The --propose Stage B PRODUCER: run bin/fm-msync-extract.sh (the
    LLM-judged extraction; it proposes, it does not act) over the Stage A notes
    and consume its proposal JSON. The notes input and the produced proposal
    are PERSISTED under <state-dir>/proposals/ so David's later okay applies
    exactly what he saw (FM_MSYNC_EXTRACT_FILE=<proposal> ... --apply).
    Returns (items:list, degraded:bool, reason:str)."""
    os.makedirs(PROPOSAL_DIR, exist_ok=True)
    base = _slot_base(slot)
    notes_path = os.path.join(PROPOSAL_DIR, base + ".notes.txt")
    prop_path = os.path.join(PROPOSAL_DIR, base + ".extract.json")
    # idempotent re-fire: a persisted, still-valid proposal for this slot is
    # REUSED rather than re-running the LLM (delete the file to force a fresh
    # extraction). Keeps a re-fire cheap and its change-list stable.
    if os.path.exists(prop_path):
        try:
            with open(prop_path) as fh:
                data = json.load(fh)
            items = data.get("items") if isinstance(data, dict) else None
            if isinstance(items, list):
                out.append("stage B EXTRACT: reusing the persisted proposal for %s "
                           "(%d item(s), %s); delete it to force a re-extraction."
                           % (slot.sid, len(items), prop_path))
                return items, False, ""
        except (OSError, ValueError):
            pass  # unreadable leftover: fall through and re-produce it.
    if not have(EXTRACT_BIN):
        return [], True, "the Stage B extractor (bin/fm-msync-extract.sh) is missing/not executable"
    try:
        with open(notes_path, "w") as fh:
            fh.write(notes_text)
    except OSError as exc:
        return [], True, "could not persist the notes for extraction (%s)" % exc
    cmd = [EXTRACT_BIN, "--slot", slot.sid, "--notes", notes_path,
           "--out", prop_path, "--roster", ROSTER_FILE]
    try:
        timeout_s = int(os.environ.get("FM_MSYNC_EXTRACT_TIMEOUT") or "600")
    except ValueError:
        timeout_s = 600
    try:
        r = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout_s)
    except Exception as exc:  # noqa: BLE001 - degrade never crashes the run
        return [], True, "extraction error (%s)" % exc
    if r.returncode != 0 or not os.path.exists(prop_path):
        detail = ""
        for ln in (r.stdout + "\n" + r.stderr).splitlines():
            if "extract-not-available" in ln:
                detail = ln.strip()
                break
        return [], True, (detail or "extraction failed (fm-msync-extract.sh exit %d)" % r.returncode)
    try:
        with open(prop_path) as fh:
            data = json.load(fh)
        items = data.get("items") if isinstance(data, dict) else data
        if not isinstance(items, list):
            raise ValueError("no 'items' list")
    except (OSError, ValueError) as exc:
        return [], True, "extraction proposal unreadable (%s)" % exc
    out.append("stage B EXTRACT (produced): %d item(s) via %s; proposal persisted at %s"
               % (len(items), os.path.basename(EXTRACT_BIN), prop_path))
    return items, False, ""


# --- Stage E: reflect (Linear -> tracker via L5 reconcile) ------------------

def stage_e_reflect(slot, out):
    """Run the L5 reconcile in DRY-RUN to get the tracker-side change-list
    (Linear = SSOT). Its AUTONOMOUS ops are the autonomous tracker tier here.
    Returns the reconcile's stdout text (or a not-run note)."""
    if not have(RECONCILE_BIN):
        out.append("stage E REFLECT: bin/fm-reconcile.sh (leaf L5) is NOT on this "
                   "branch/PATH; the Linear->tracker reconcile did not run. Its "
                   "autonomous tracker ops (status/group/node) will apply here once "
                   "L5 merges to main.")
        return ""
    try:
        r = subprocess.run([RECONCILE_BIN, "--dry-run", "--slot", slot.sid],
                           capture_output=True, text=True, timeout=180)
        out.append("stage E REFLECT: reconcile dry-run exit %d (Linear->tracker "
                   "change-list; its AUTONOMOUS ops are the autonomous tracker tier)." % r.returncode)
        return r.stdout
    except Exception as exc:  # noqa: BLE001
        out.append("stage E REFLECT: reconcile error (%s); tracker not reflected." % exc)
        return ""


# --- board post (narrative + gated items; NEVER content.ts, NEVER merge) ----

def post_to_board(text, apply_mode, out):
    if not apply_mode:
        out.append("  (dry-run: would post the narrative + gated change-list to the "
                   "'%s' board thread via fm-board-reply.sh --your-court; nothing posted)" % BOARD_ITEM)
        return
    if not have(BOARD_REPLY_BIN):
        out.append("  board post SKIPPED: bin/fm-board-reply.sh unavailable.")
        return
    try:
        subprocess.run([BOARD_REPLY_BIN, BOARD_ITEM, text, "--your-court", "--effort", "3"],
                       capture_output=True, text=True, timeout=60, check=False)
        out.append("  posted the narrative + gated change-list to the '%s' board thread "
                   "(--your-court). content.ts was NOT edited; the tracker was NOT merged." % BOARD_ITEM)
    except Exception as exc:  # noqa: BLE001
        out.append("  board post error (%s); the change-list is still printed above." % exc)


def _post_board_line(text, effort, out, label):
    """One firstmate-authored --your-court board post. True iff it landed."""
    if not have(BOARD_REPLY_BIN):
        out.append("%s board post SKIPPED: bin/fm-board-reply.sh unavailable "
                   "(not recorded, so the next fire retries)." % label)
        return False
    try:
        subprocess.run([BOARD_REPLY_BIN, BOARD_ITEM, text, "--your-court",
                        "--effort", str(effort)],
                       capture_output=True, text=True, timeout=60, check=False)
        return True
    except Exception as exc:  # noqa: BLE001
        out.append("%s board post error (%s); not recorded, next fire retries." % (label, exc))
        return False


def post_degrade(slot, reason, st, out):
    """THE LOUD DEGRADE (never silent): one board line per slot telling David
    exactly what to do, deduped in state so a nightly re-fire of the same
    failing slot never spams the thread (one post per slot)."""
    posts = st.setdefault("degradePosts", {})
    if slot.sid in posts:
        out.append("degrade already posted for %s at %s; NOT re-posting (one post per slot)."
                   % (slot.sid, posts[slot.sid]))
        return
    line = ("meeting sync could not fetch the %s notes: %s; paste them or fix the "
            "credential, then re-run bin/fm-meeting-sync.sh --slot %s --propose"
            % (slot.sid, reason, slot.sid))
    if _post_board_line(line, 2, out, "degrade"):
        posts[slot.sid] = now_utc().isoformat(timespec="seconds")
        save_state(st)
        out.append("degrade posted to the '%s' board thread: %s" % (BOARD_ITEM, line))


def post_proposal(slot, report, changes, narratives, st, out):
    """The --propose hand-back: persist the full change-list, then post a
    scannable your-court ask (first line = the exact ask, then dot points) to
    the board thread for David's ONE okay. Content-hash deduped per slot, so a
    re-fire with an unchanged change-list posts nothing and a genuinely new
    change-list posts again. An EMPTY change-list posts nothing (a meeting with
    zero actionable items, or a reconcile slot, is not a decision for David),
    and an already-complete slot never re-proposes."""
    if slot_complete(st, slot.sid):
        out.append("proposal: slot %s is already recorded complete (applied); "
                   "NOT re-proposing." % slot.sid)
        return
    if not (changes or narratives):
        out.append("proposal: nothing to propose for %s (no actionable change "
                   "extracted); no board post." % slot.sid)
        return
    os.makedirs(PROPOSAL_DIR, exist_ok=True)
    report_path = os.path.join(PROPOSAL_DIR, _slot_base(slot) + ".changelist.txt")
    try:
        with open(report_path, "w") as fh:
            fh.write(report + "\n")
    except OSError as exc:
        out.append("proposal: could not persist the change-list (%s); posting anyway." % exc)
    autos = [c for c in changes if c.tier == AUTONOMOUS]
    gated = [c for c in changes if c.tier == GATED]
    hard = [c for c in changes if c.tier == HARDSTOP] + [n for n in narratives if n.tier == HARDSTOP]
    narr = [n for n in narratives if n.tier != HARDSTOP]
    lines = ["Meeting sync proposal for %s: okay to apply? Nothing has been applied "
             "(the cadence never auto-applies); your one okay lands the list below." % slot.sid]

    def emit(tag, items):
        shown = items[:12]
        for c in shown:
            tc = (" @%s" % c.timecode) if c.timecode else ""
            ow = (" owner=%s" % c.owner) if c.owner else ""
            lines.append("- [%s] %s %s: %s%s%s" % (tag, c.op, c.target, c.detail or "", ow, tc))
        if len(items) > len(shown):
            lines.append("- [%s] +%d more (full change-list below)" % (tag, len(items) - len(shown)))

    emit("AUTONOMOUS on your okay", autos)
    emit("GATED, rule per item", gated)
    emit("NARRATIVE, your gate", narr)
    emit("HARD STOP, reported only", hard)
    if not (autos or gated or narr or hard):
        lines.append("- no actionable change extracted this slot (FYI-only or empty meeting)")
    prop_json = os.path.join(PROPOSAL_DIR, _slot_base(slot) + ".extract.json")
    lines.append("- full change-list: %s" % report_path)
    if os.path.exists(prop_json):
        lines.append("- to apply after your okay: FM_MSYNC_EXTRACT_FILE=%s "
                     "bin/fm-meeting-sync.sh --slot %s --apply" % (prop_json, slot.sid))
    lines.append("- recommendation: okay the autonomous tier now; rule on gated/narrative items individually")
    text = "\n".join(lines)
    digest = hashlib.sha256(text.encode()).hexdigest()
    rec = slot_record(st, slot.sid)
    if rec.get("proposalHash") == digest:
        out.append("proposal for %s unchanged since the last post; NOT re-posting (dedupe)." % slot.sid)
        return
    if _post_board_line(text, 3, out, "proposal"):
        rec["proposalHash"] = digest
        if rec.get("outcome") == "planned":
            rec["outcome"] = "proposed"
        save_state(st)
        out.append("proposal posted to the '%s' board thread (--your-court) for David's okay; "
                   "NOTHING was applied." % BOARD_ITEM)


# --- apply the AUTONOMOUS tier (Decision 5a; never narrative, never a merge) -

def audit(slot, target, op, before, after, evidence, out):
    """Best-effort append to the L1 audit log. Degrades to a note if absent."""
    if not have(AUDIT_BIN):
        out.append("      (audit unavailable: bin/fm-sync-audit.sh not on branch)")
        return
    cmd = [AUDIT_BIN, "append", slot.sid, target, op]
    if before is not None:
        cmd += ["--before", str(before)]
    if after is not None:
        cmd += ["--after", str(after)]
    if evidence:
        cmd += ["--evidence", str(evidence)]
    try:
        subprocess.run(cmd, capture_output=True, text=True, timeout=30, check=False)
    except Exception:  # noqa: BLE001 - audit never crashes the run
        out.append("      (audit append failed; write still recorded in state)")


# --- remote idempotency guard (design section 3: comment markers +
#     match-before-create). The persisted writeSet is the fast LOCAL path; this
#     is the DURABLE cross-process/crash guard. A crash between a landed Linear
#     write and the state flush leaves the remote changed but the ledger empty;
#     without a remote read the re-run duplicates the comment/ticket. So before
#     every autonomous Linear write we read the remote and skip if the
#     [sync:<slot>] marker is already there, then backfill the ledger. ROBUST
#     OVER DUCT TAPE: the local ledger is not durable across a mid-slot crash;
#     the remote is the source of truth. On any read error the guard returns
#     False (never a false "exists" that would DROP a real write); the local
#     ledger still de-dups the in-process re-run. -----------------------------

def remote_comment_exists(target, marker):
    """True iff ticket `target` already carries a comment bearing `marker`.
    Reads via fm-linear.sh get_issue --relations and greps the emitted issue
    (whatever its JSON shape) for the marker substring."""
    if not have(LINEAR_BIN):
        return False
    try:
        r = subprocess.run([LINEAR_BIN, "get_issue", target, "--relations"],
                           capture_output=True, text=True, timeout=60, check=False)
    except Exception:  # noqa: BLE001 - a read failure must never drop a write
        return False
    return r.returncode == 0 and marker in (r.stdout or "")


def remote_issue_exists(title, marker):
    """Match-before-create: True iff a ticket for this (slot, title) already
    exists. Searches fm-linear.sh list_issues by title and greps for the
    [sync:<slot>] marker that apply stamps into every self-created ticket's
    description."""
    if not have(LINEAR_BIN):
        return False
    try:
        r = subprocess.run([LINEAR_BIN, "list_issues", "--query", title, "--limit", "20"],
                           capture_output=True, text=True, timeout=60, check=False)
    except Exception:  # noqa: BLE001
        return False
    return r.returncode == 0 and marker in (r.stdout or "")


# --- concurrency lock (mkdir-style, atomic). Two --apply runs against the same
#     state dir (e.g. an overlapping cron fire) must not BOTH land writes. mkdir
#     is the portable atomic primitive; a lock older than FM_MSYNC_LOCK_STALE_SEC
#     (default 30 min) is stolen so a crashed run never deadlocks the cadence. --

def _rm_lock(lock):
    try:
        for name in os.listdir(lock):
            try:
                os.remove(os.path.join(lock, name))
            except OSError:
                pass
        os.rmdir(lock)
    except OSError:
        pass


def acquire_apply_lock(slot_sid, out):
    """Acquire the per-state-dir apply lock. Returns the lock path, or None if a
    live run holds it (caller must then apply NOTHING)."""
    os.makedirs(STATE_DIR, exist_ok=True)
    lock = os.path.join(STATE_DIR, "apply.lock")
    try:
        stale = int(os.environ.get("FM_MSYNC_LOCK_STALE_SEC") or "1800")
    except ValueError:
        stale = 1800
    try:
        os.mkdir(lock)
    except FileExistsError:
        try:
            age = time.time() - os.path.getmtime(lock)
        except OSError:
            age = 0.0
        if age > stale:
            out.append("apply: STALE apply lock (age %ds > %ds); prior run presumed "
                       "dead, stealing it." % (int(age), stale))
            _rm_lock(lock)
            try:
                os.mkdir(lock)
            except OSError:
                out.append("apply: could not steal the stale lock; refusing to apply.")
                return None
        else:
            out.append("apply: another --apply run holds the lock for this state dir "
                       "(age %ds < %ds stale); refusing to double-apply. Nothing "
                       "applied this pass." % (int(age), stale))
            return None
    try:
        with open(os.path.join(lock, "owner"), "w") as fh:
            fh.write("pid=%d slot=%s at=%s\n" %
                     (os.getpid(), slot_sid, now_utc().isoformat(timespec="seconds")))
    except OSError:
        pass
    return lock


def release_apply_lock(lock):
    if lock:
        _rm_lock(lock)


def apply_autonomous(slot, changes, canon, st, out):
    """Land ONLY the autonomous tier: tracker chat edits (via L5 reconcile
    --apply), [sync:<slot>] meeting comments, and David-self-assigned new
    tickets (via bin/fm-linear.sh). NEVER content.ts, NEVER a merge/deploy.

    IDEMPOTENT (design section 3, ROBUST OVER DUCT TAPE): every autonomous write
    is guarded read-before-write against the persisted per-slot writeSet, so a
    second --apply of the same slot (or a nightly cron re-fire) re-applies
    NOTHING. Each op is keyed (op_key), recorded the instant it lands, and the
    state is flushed incrementally so a crash mid-slot resumes without redoing a
    completed write. Each write is also guarded by tool presence and appended to
    the audit log."""
    autos = [c for c in changes if c.tier == AUTONOMOUS]
    rec = slot_record(st, slot.sid)
    ws = rec["writeSet"]
    if not autos:
        out.append("apply: no autonomous ops this slot.")
        return
    # tracker chat edits: one reconcile --apply pass, guarded so a re-run skips it.
    rkey = "reconcile:%s" % slot.sid
    if have(RECONCILE_BIN):
        if rkey in ws:
            out.append("apply: tracker reconcile --apply already ran for %s "
                       "(idempotent skip)." % slot.sid)
        else:
            try:
                r = subprocess.run([RECONCILE_BIN, "--apply", "--slot", slot.sid],
                                   capture_output=True, text=True, timeout=180, check=False)
                out.append("apply: tracker chat edits via reconcile --apply (exit %d)." % r.returncode)
                ws[rkey] = {"op": "reconcile_apply", "target": slot.sid,
                            "at": now_utc().isoformat(timespec="seconds"),
                            "result": "exit=%d" % r.returncode}
                save_state(st)
            except Exception as exc:  # noqa: BLE001
                out.append("apply: reconcile --apply error (%s)." % exc)
    else:
        out.append("apply: tracker chat edits SKIPPED (bin/fm-reconcile.sh not on branch).")
    # Linear autonomous writes.
    marker = "[sync:%s]" % slot.sid
    for c in autos:
        key = op_key(c, slot.sid)
        # fast LOCAL path: this op is already recorded in the persisted ledger.
        if key in ws:
            out.append("apply: %s on %s already applied for %s (idempotent skip, "
                       "local ledger)." % (c.op, c.target, slot.sid))
            continue
        if c.op == "add_comment" and c.target and c.target.startswith("ENG-"):
            if not have(LINEAR_BIN):
                out.append("apply: comment on %s SKIPPED (bin/fm-linear.sh unavailable)." % c.target)
                continue
            # DURABLE guard: a crash after a prior run's comment landed but before
            # its ledger flush leaves the marker on the remote and nothing local.
            # Read the remote first; if the marker is already there, record it and
            # skip so the re-run never double-comments.
            if remote_comment_exists(c.target, marker):
                out.append("apply: %s already on %s in Linear (remote-detected); "
                           "recording in the ledger, NOT re-commenting." % (marker, c.target))
                ws[key] = {"op": "add_comment", "target": c.target, "marker": marker,
                           "source": "remote-detected",
                           "at": now_utc().isoformat(timespec="seconds")}
                save_state(st)
                continue
            tc = (" @%s" % c.timecode) if c.timecode else ""
            body = "%s %s%s" % (marker, c.detail, tc)
            try:
                subprocess.run([LINEAR_BIN, "add_comment", c.target, "--body", body],
                               capture_output=True, text=True, timeout=60, check=False)
                out.append("apply: comment %s on %s." % (marker, c.target))
                audit(slot, c.target, "add_comment", None, marker, c.timecode, out)
                ws[key] = {"op": "add_comment", "target": c.target, "marker": marker,
                           "at": now_utc().isoformat(timespec="seconds")}
                save_state(st)
            except Exception as exc:  # noqa: BLE001
                out.append("apply: add_comment %s error (%s)." % (c.target, exc))
        elif c.op == "create_issue" and c.owner == "David":
            if not have(LINEAR_BIN):
                out.append("apply: self-assigned create SKIPPED (bin/fm-linear.sh unavailable).")
                continue
            # match-before-create DURABLE guard (same crash window as comments).
            if remote_issue_exists(c.detail, marker):
                out.append("apply: a ticket for %r this slot already exists in Linear "
                           "(remote-detected); recording in the ledger, NOT re-creating." % c.detail)
                rec["itemKeyToEng"][key] = "(exists-remote)"
                ws[key] = {"op": "create_issue", "target": c.detail,
                           "source": "remote-detected",
                           "at": now_utc().isoformat(timespec="seconds")}
                save_state(st)
                continue
            did = (canon.get("David") or {}).get("id")
            # stamp the [sync:<slot>] marker into the description so a later run's
            # match-before-create finds this ticket (the durable idempotency key).
            cmd = [LINEAR_BIN, "create_issue", "--title", c.detail,
                   "--description", "%s meeting-sync auto-created deliverable" % marker]
            if did:
                cmd += ["--assignee", did]
            try:
                subprocess.run(cmd, capture_output=True, text=True, timeout=60, check=False)
                out.append("apply: create self-assigned ticket %r." % c.detail)
                audit(slot, "(net-new)", "create_issue", None, c.detail, c.timecode, out)
                rec["itemKeyToEng"][key] = "(created)"
                ws[key] = {"op": "create_issue", "target": c.detail,
                           "at": now_utc().isoformat(timespec="seconds")}
                save_state(st)
            except Exception as exc:  # noqa: BLE001
                out.append("apply: create_issue error (%s)." % exc)
        elif c.op == "digest_only":
            # the FYI digest publish/attach is Phase 4 (docs-hosting); the
            # trailing note covers it. No Linear write, nothing to de-dup.
            continue
        else:
            # ROBUST OVER DUCT TAPE: an op classified AUTONOMOUS that this apply
            # path does not implement is SURFACED, never silently dropped, and is
            # NOT recorded as applied, so the change-list can never advertise an
            # autonomous action that did not happen (e.g. a future own-ticket
            # set_state / update_issue before its write is wired).
            out.append("apply: %s on %s is classified AUTONOMOUS but its autonomous "
                       "write is not wired yet; NOT applied (surfaced, not silently "
                       "dropped). It stays pending until the write lands or it is gated."
                       % (c.op, c.target))
    out.append("apply: digest publish/attach is Phase 4 (blocked on docs-hosting); deferred.")


# --- rendering --------------------------------------------------------------

def render(slot, backfill, ingest_lines, extract_lines, reflect_text,
           changes, narratives, roster_present, apply_mode, degraded,
           propose_mode=False):
    L = []
    L.append("=== MEETING SYNC CHANGE-LIST (slot %s) ===" % slot.sid)
    if apply_mode:
        mode = "APPLY (autonomous tier only)"
    elif propose_mode:
        mode = "PROPOSE (real fetch + extract; NOTHING applied; proposal -> board for David's okay)"
    else:
        mode = "dry-run (nothing applied)"
    L.append("mode: %s" % mode)
    L.append("clock: %s UTC" % now_utc().isoformat(timespec="seconds"))
    L.append("")
    L.append("--- backfill gap-scan (design Stage A) ---")
    if backfill:
        L.append("  unrecorded slots to process oldest-first (lookback):")
        for s in backfill:
            L.append("    - %s" % s.sid)
    else:
        L.append("  no unrecorded slot in the lookback window; this slot is the unit of work.")
    L.append("")
    L.append("--- stage A/B/E ---")
    L.extend("  " + x for x in ingest_lines)
    L.extend("  " + x for x in extract_lines)
    L.append("  roster (data/roster-linear.md): %s" %
             ("present" if roster_present else "ABSENT -> every owned item flagged for David"))
    for line in (reflect_text.splitlines() if reflect_text else []):
        L.append("  | " + line)
    L.append("")

    by_tier = {AUTONOMOUS: [], GATED: [], HARDSTOP: []}
    for c in changes:
        by_tier[c.tier].append(c)

    L.append("--- TIERED GATE (Decision 5a Option B) ---")
    L.append("AUTONOMOUS (applied without a gate; one FYI after):")
    _emit_tier(L, by_tier[AUTONOMOUS])
    L.append("GATED / NEEDS-DAVID (held; posted to the board, NEVER applied here):")
    _emit_tier(L, by_tier[GATED])
    L.append("HARD STOP (never autonomous; reported only):")
    _emit_tier(L, by_tier[HARDSTOP])
    L.append("")

    L.append("--- NARRATIVE (src/components/narrative/content.ts) ---")
    L.append("INVARIANT: firstmate NEVER edits content.ts and NEVER merges/deploys")
    L.append("the tracker. Every narrative change below is surfaced for David and")
    L.append("posted to the board via --your-court; nothing here is self-applied.")
    if narratives:
        for c in narratives:
            tag = "[HARD STOP / ACTIVE gate]" if c.tier == HARDSTOP else "[GATED]"
            tc = (" @%s" % c.timecode) if c.timecode else ""
            L.append("  %s %s -> %s%s" % (tag, c.target, c.detail, tc))
            if c.reason:
                L.append("      reason: %s" % c.reason)
    else:
        L.append("  no narrative change extracted this slot.")
    L.append("")

    # same-run overlap note: a ticket the reconcile autonomously reflects that a
    # GATED meeting item also proposes to change. No corruption (Linear is SSOT
    # and the meeting change is gated), but surfaced so David sees the tracker
    # node may move now under the reconcile and change again once he rules.
    gated_engs = {c.target for c in by_tier[GATED]
                  if c.target and c.target.startswith("ENG-")}
    overlap = sorted(e for e in gated_engs if reflect_text and e in reflect_text)
    if overlap:
        L.append("--- SAME-RUN OVERLAP NOTE ---")
        L.append("  BOTH autonomously reflected by the reconcile AND awaiting your "
                 "gate on a meeting change: %s" % ", ".join(overlap))
        L.append("  no corruption (Linear is SSOT; the meeting change is gated), but "
                 "the tracker node may move now and change again once you rule.")
        L.append("")

    na = len(by_tier[AUTONOMOUS])
    ng = len(by_tier[GATED])
    nh = len(by_tier[HARDSTOP])
    L.append("--- SUMMARY ---")
    L.append("  autonomous=%d  gated/needs-david=%d  hard-stop=%d  narrative=%d" %
             (na, ng, nh, len(narratives)))
    if degraded:
        L.append("  DEGRADED: notes not fetchable / extraction unavailable -> one loud "
                 "'paste the notes' line goes to the board (propose/apply paths, deduped "
                 "per slot); no meeting writes proposed this pass.")
    if apply_mode:
        L.append("  APPLY: autonomous tier lands (tracker chat edits, [sync:%s] comments, "
                 "David-self-assigned tickets, digest); gated + narrative go to the board." % slot.sid)
    elif propose_mode:
        L.append("  PROPOSE: nothing applied. The change-list goes to the board for David's "
                 "one okay; apply afterwards with FM_MSYNC_EXTRACT_FILE=<persisted proposal> --apply.")
    else:
        L.append("  dry-run: nothing applied. Re-run with --apply to land the autonomous tier.")
    return "\n".join(L)


def _emit_tier(L, items):
    if not items:
        L.append("  (none)")
        return
    for c in items:
        tc = (" @%s" % c.timecode) if c.timecode else ""
        ow = (" owner=%s" % c.owner) if c.owner else ""
        L.append("  [%s] %s: %s%s%s" % (c.stage, c.op, c.target, ow, tc))
        if c.detail:
            L.append("      %s" % c.detail)
        if c.reason:
            L.append("      reason: %s" % c.reason)


# --- schedule (Phase 5 trigger surface; installs NOTHING) -------------------

SCHEDULE_TEXT = """\
=== MEETING SYNC SCHEDULE (design Phase 5, Decision 7a) ===

NOT INSTALLED BY THIS SCRIPT. The cadence is registered ONLY after a hand-run
proves one real meeting cycle (design Phase 5). Until then this prints the plan.

THE CADENCE NEVER AUTO-APPLIES (prime rule 1). Every scheduled fire runs
--propose: fetch the notes, run the extraction, build the change-list, post the
proposal to the tracker-sync board thread for David's ONE okay. Applying is a
separate, human-okayed step. The plists export FM_MSYNC_SCHEDULED=1, which makes
this script REJECT --apply structurally (exit 2), so a mis-edited schedule
cannot flip autonomy on.

Trigger owner: CronCreate (harness routines), one entry per cadence SLOT, each
PINNED to America/Los_Angeles and passing its OWN slot identity so Stage A
selects slot-scoped docs, never "newest" (prevents the cron-slot-vs-newest-doc
mismatch). Each fire runs as TaskCreate background work so the session keeps
draining board wakes. One mechanism per surface: cron owns the trigger.

  1. EOD nightly (every day, evening PT):
       schedule: 0 21 * * *  America/Los_Angeles
       run: FM_MSYNC_SCHEDULED=1 fm-meeting-sync.sh --slot $(date +%F)/eod --propose
  2. MORNING Mon/Fri (morning PT):
       schedule: 0 10 * * 1,5  America/Los_Angeles
       run: FM_MSYNC_SCHEDULED=1 fm-meeting-sync.sh --slot $(date +%F)/morning --propose
  3. DAILY RECONCILE (meeting-less housekeeping):
       schedule: 30 7 * * *  America/Los_Angeles
       run: FM_MSYNC_SCHEDULED=1 fm-meeting-sync.sh --slot $(date +%F)/reconcile --propose

TIMEZONE/DST self-defense (Decision 7a): if the scheduler can only fire in UTC,
the run converts fire-time to PT and re-derives its slot rather than trusting the
schedule label, so a fixed UTC fire cannot drift across the 13:00 PT boundary at
a DST transition.

launchd alternative (long-lived, ship-uninstalled): see
  docs/launchd/com.firstmate.meeting-sync-eod.plist.example
  docs/launchd/com.firstmate.meeting-sync-morning.plist.example
and the install steps in docs/meeting-sync-schedule.md. Do NOT install until the
Phase 5 gate. The meeting-LESS daily reconcile can run from launchd (it calls no
Google MCP); the meeting ingest fires depend on bin/fm-gfetch.sh being credentialed.
"""


# --- main -------------------------------------------------------------------

def main(argv):
    if argv and argv[0] == "install-schedule":
        sys.stdout.write(SCHEDULE_TEXT)
        return 0

    ap = argparse.ArgumentParser(prog="fm-meeting-sync.sh", add_help=True)
    ap.add_argument("--slot", required=True)
    g = ap.add_mutually_exclusive_group()
    g.add_argument("--dry-run", action="store_true")
    g.add_argument("--propose", action="store_true")
    g.add_argument("--apply", action="store_true")
    ap.add_argument("--lookback", type=int, default=14)
    ap.add_argument("--no-backfill", action="store_true")
    ap.add_argument("--live-url", default=None)
    try:
        args = ap.parse_args(argv)
    except SystemExit as e:
        return E_USAGE if e.code else 0

    apply_mode = bool(args.apply)      # dry-run is the default
    propose_mode = bool(args.propose)  # the scheduled mode: real up to the proposal
    if os.environ.get("FM_MSYNC_SCHEDULED") == "1" and apply_mode:
        sys.stderr.write(
            "fm-meeting-sync: --apply is FORBIDDEN on the scheduled path "
            "(FM_MSYNC_SCHEDULED=1): the cadence never auto-applies (prime rule 1). "
            "Scheduled fires run --propose; applying needs David's okay.\n")
        return E_USAGE
    slot = parse_slot(args.slot)
    st = load_state()

    # backfill gap-scan (design Stage A): unrecorded meeting slots oldest-first.
    backfill = []
    if not args.no_backfill and slot.kind != "reconcile":
        start = slot.date - dt.timedelta(days=max(0, args.lookback))
        lp = st.get("lastProcessedSlot")
        if lp:
            m = SLOT_RE.match(lp)
            if m:
                cand = dt.date(int(m.group(1)), int(m.group(2)), int(m.group(3)))
                start = max(start, cand)
        for s in cadence_slots(start, slot):
            if s.sid == slot.sid:
                continue
            if not slot_complete(st, s.sid):
                backfill.append(s)

    ingest_lines, extract_lines, reflect_lines = [], [], []
    docs, degraded, degrade_reason, notes_text = stage_a_ingest(
        slot, ingest_lines, want_text=propose_mode)
    if propose_mode and not degraded and slot.kind != "reconcile" and not (
            EXTRACT_FILE and os.path.exists(EXTRACT_FILE)):
        # Stage B has a PRODUCER on the scheduled path: the wired extractor.
        items, b_degraded, b_reason = stage_b_produce(slot, notes_text, extract_lines)
        if b_degraded:
            degraded, degrade_reason = True, b_reason
            extract_lines.append("stage B EXTRACT: %s. HONEST DEGRADE: paste the "
                                 "notes or supply FM_MSYNC_EXTRACT_FILE." % b_reason)
    else:
        items = stage_b_extract(extract_lines)
    reflect_text = stage_e_reflect(slot, reflect_lines)
    extract_lines.extend(reflect_lines)

    canon, alias, roster_present = load_roster(ROSTER_FILE)
    changes, narratives = [], []
    for it in items:
        c, is_narr = classify_item(it, canon, alias, roster_present)
        if is_narr:
            narratives.append(c)
        else:
            changes.append(c)

    report = render(slot, backfill, ingest_lines, extract_lines, reflect_text,
                    changes, narratives, roster_present, apply_mode, degraded,
                    propose_mode=propose_mode)
    print(report)

    # A slot already recorded complete is fully idempotent: neither the writes
    # NOR the board handback re-fire. Capture completeness BEFORE finalizing so
    # the FIRST apply still posts and only RE-runs are suppressed.
    was_complete = slot_complete(st, slot.sid)
    apply_locked_out = False

    # land the autonomous tier (apply only) - NEVER narrative, NEVER a merge.
    if apply_mode and not degraded:
        print("")
        print("--- APPLY (autonomous tier) ---")
        if was_complete:
            print("apply: slot %s already recorded complete; re-applying NOTHING "
                  "(idempotent). Delete its state entry to force a re-run." % slot.sid)
        else:
            apply_out = []
            lock = acquire_apply_lock(slot.sid, apply_out)
            if lock is None:
                apply_locked_out = True
                for line in apply_out:
                    print(line)
            else:
                try:
                    apply_autonomous(slot, changes, canon, st, apply_out)
                    # finalize the slot (design Stage G): record completion and
                    # advance lastProcessedSlot so the gap-scan never re-lists it.
                    rec = slot_record(st, slot.sid)
                    rec["outcome"] = "complete"
                    if slot_sid_ge(slot.sid, st.get("lastProcessedSlot") or ""):
                        st["lastProcessedSlot"] = slot.sid
                    st["lookbackMarker"] = now_utc().isoformat(timespec="seconds")
                    save_state(st)
                finally:
                    release_apply_lock(lock)
                for line in apply_out:
                    print(line)

    # --propose: the scheduled path's terminal step. NOTHING is applied; the
    # proposal (or the loud degrade line) goes to the board for David's okay.
    if propose_mode:
        print("")
        print("--- PROPOSE (nothing applied) ---")
        prop_out = []
        if degraded:
            post_degrade(slot, degrade_reason, st, prop_out)
        else:
            post_proposal(slot, report, changes, narratives, st, prop_out)
        for line in prop_out:
            print(line)

    # a degraded --apply run is loud too: same one-line-per-slot board post.
    if apply_mode and degraded:
        print("")
        prop_out = []
        post_degrade(slot, degrade_reason, st, prop_out)
        for line in prop_out:
            print(line)

    # the board post (narrative + gated items) - NEVER content.ts, NEVER merge.
    # Guarded by the SAME slot-complete check as the writes (the LOW finding): a
    # re-run of a completed slot must not re-post the gated/narrative change-list
    # to David's court, and a run that lost the apply lock posts nothing (the
    # lock holder will). --propose has its own hand-back above.
    gated = [c for c in changes if c.tier == GATED]
    if (narratives or gated) and not was_complete and not apply_locked_out \
            and not propose_mode:
        print("")
        print("--- BOARD HANDBACK (--your-court) ---")
        board_out = []
        board_text = ("Meeting sync %s: %d narrative + %d gated item(s) need your gate. "
                      "content.ts was not edited and the tracker was not merged. "
                      "See the change-list." % (slot.sid, len(narratives), len(gated)))
        post_to_board(board_text, apply_mode, board_out)
        for line in board_out:
            print(line)

    if degraded:
        # honest degrade exit, but the change-list already printed above and the
        # propose/apply paths posted the loud board line (deduped per slot).
        return E_DEGRADE
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main(sys.argv[1:]))
    except SystemExit:
        raise
    except KeyboardInterrupt:
        sys.exit(130)
PYEOF

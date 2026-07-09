#!/usr/bin/env bash
# fm-reconcile.sh - standalone Linear->tracker daily reconcile + housekeeping pass.
#
# WHAT THIS IS (meeting-sync-design.md Phase 1, sections 3 and 6): the
# meeting-LESS daily reconcile. It compares the LIVE MVP tracker model
# (GET <live>/api/model, open, no auth) against a fresh Linear export (via
# bin/fm-linear.sh) plus observed GitHub PR/merge state (via gh), computes the
# tracker drift per the PINNED status/group mappings, and PRODUCES a change-list.
# It is a DRY RUN by default: it prints what it WOULD do and touches nothing.
# With --apply it applies ONLY the SAFE autonomous TRACKER-side ops (status/group
# moves, add_node/add_edge with explicit type+cluster, soft-retire of resolved
# edges), each verified by a re-GET of /api/model, and appends every applied op
# to the L1 audit log (bin/fm-sync-audit.sh).
#
# WHAT IT NEVER DOES (design section 5, tiering; this is Phase 1): it makes ZERO
# Linear writes of any kind beyond the already-proven comment path, which this
# reconcile does not exercise. Reassigns, state flips, closes/dedupes, descope
# writes, and net-new tickets are Phase 3; here they are only LISTED in the
# change-list as NEEDS-DAVID. It never deletes a node/edge/row (hard delete is a
# HARD STOP); resolved edges are SOFT-retired (reversible mark-resolved), never
# deleted. It never reseeds the model or changes its schema.
#
# THE PINNED MAPPINGS (design section 3, verbatim intent):
#   node status {done,working,queued,blocked}:
#     Linear Done OR an observed merged PR  -> done
#     Linear In Progress + genuine recent activity -> working
#     Linear Backlog/Todo -> queued
#     Blocked label / blocked-by an unresolved issue -> blocked
#     No-progress is NEVER a move reason; genuinely conflicting signals -> leave
#       alone + report as ambiguous.
#   masterList group {active,done,deferred}:
#     Done -> done; In Progress/In Review/Reviewed -> active;
#     Backlog/Todo -> active IF in the current MVP cycle or recently active, else
#       deferred (off-graph); Canceled -> deferred, node KEPT + marked canceled;
#     descoped/parked -> deferred.
#   edges: a Linear blocking relation absent from the DAG -> add_edge (formal from
#     a Linear relation, implied from a meeting); Linear is a LOWER BOUND on edges.
#     A formal edge whose Linear relation is resolved/gone -> soft-retire.
#
# PRESERVED DRIFT (design section 3 "WHAT WINS" + section 6): intentional
# narrower-scope items (tracker done, Linear In Progress because the item scope <
# the ticket scope; ENG-253/ENG-252 are canonical) must NOT be reverted. The
# durable drift MARKER is open question 4, still UNRESOLVED, so per the leaf brief
# this pass LISTS those items (runtime config/reconcile-intentional-drift.txt,
# seeded from docs/reconcile-intentional-drift.example.txt) in the change-list as
# DRIFT-HOLD and generates NO ops against them.
#
# SKIP SET (design section 3, tracker<->Linear SYNC scope only): minor-fix /
# merge-conflict tickets, Canceled tickets (NOTE, do not delete the node),
# non-MVP research (Francis SapSim, invDes/FDTD, Yang), admin-dashboard tickets
# (one aggregate master item). Configured in the runtime
# config/reconcile-skip-set.txt (seeded from docs/reconcile-skip-set.example.txt).
# Borderline -> "uncertain, David decides" (NEEDS-DAVID). Skipping from the DAG is
# not the same as dropping a newly-committed non-MVP action item (that is Phase 2/
# Decision 2c, out of this leaf's scope).
#
# SAFETY (design section 5): the HTML-INJECTION guard rejects any node title /
# owner string containing '<' or '>' before it is embedded in a chat op (an
# unescaped '<' closes a Graphviz label and 500s the whole dashboard); such an op
# is downgraded to NEEDS-DAVID, never auto-applied. EDIT_PASSWORD is read from the
# tracker .env (or $EDIT_PASSWORD) and NEVER printed. No Linear token, no password,
# no update key ever reaches stdout/stderr.
#
# DEPENDENCIES (this branch is cut from origin/main): bin/fm-linear.sh (on main),
# bin/fm-sync-audit.sh (owned by the L1 leaf; vendored VERBATIM into this branch
# so the pass is self-contained and testable - keep byte-identical with L1), gh
# (authenticated), python3, and network reach to the live tracker + Linear MCP.
# Every external dependency degrades cleanly: an unreachable Linear/GitHub/tracker
# is reported in the change-list, never a crash, and the dry run still prints.
#
# HERMETIC TEST HOOKS (dependency injection, so the reconcile is testable with no
# network): FM_RECONCILE_MODEL_FILE, FM_RECONCILE_LINEAR_FILE, FM_RECONCILE_PR_FILE,
# FM_RECONCILE_RELATIONS_FILE feed fixtures instead of live fetches;
# FM_RECONCILE_LINEAR_BIN / _GH_BIN / _AUDIT_BIN override the tool paths;
# FM_RECONCILE_CONFIG_DIR overrides the drift-hold/skip-set config dir.
#
# USAGE:
#   fm-reconcile.sh --dry-run            # default; prints the change-list, no writes
#   fm-reconcile.sh --apply              # applies ONLY safe autonomous tracker ops
#   fm-reconcile.sh [--live-url URL] [--mvp-parent ENG-195] [--repo OWNER/NAME]
#                   [--slot YYYY-MM-DD/reconcile] [--recent-days 14]
#                   [--max-relations 80] [--no-relations] [--no-github]
#
# Exit codes: 0 ok (dry run always 0 unless a usage error); 2 usage error;
#             3 --apply needed a write credential that was unavailable;
#             4 --apply ran but not every autonomous op verified (some/all writes
#               failed) so a scheduled run can detect a silent all-writes-failed pass.
set -euo pipefail

FM_RECONCILE_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export FM_RECONCILE_SCRIPT_DIR

exec python3 - "$@" <<'PYEOF'
import concurrent.futures as cf
import html
import json
import os
import re
import subprocess
import sys
import time
import urllib.error
import urllib.request

E_USAGE, E_AUTH, E_APPLY = 2, 3, 4

SCRIPT_DIR = os.environ["FM_RECONCILE_SCRIPT_DIR"]
REPO_ROOT = os.path.dirname(SCRIPT_DIR)
CONFIG_DIR = os.environ.get(
    "FM_RECONCILE_CONFIG_DIR", os.path.join(REPO_ROOT, "config"))

DEFAULTS = {
    "live_url": "https://kronos-mvp-tracker-production.up.railway.app",
    "mvp_parent": "ENG-195",
    "repo": "KronosAIPS/kronosai_agentic_simulation",
    "recent_days": 14,
    "max_relations": 80,
    "relations_workers": 8,
}

LINEAR_BIN = os.environ.get(
    "FM_RECONCILE_LINEAR_BIN", os.path.join(SCRIPT_DIR, "fm-linear.sh"))
GH_BIN = os.environ.get("FM_RECONCILE_GH_BIN", "gh")
AUDIT_BIN = os.environ.get(
    "FM_RECONCILE_AUDIT_BIN", os.path.join(SCRIPT_DIR, "fm-sync-audit.sh"))


def die(code, msg):
    sys.stderr.write("fm-reconcile: " + msg + "\n")
    sys.exit(code)


# --- args -------------------------------------------------------------------

def parse_args(argv):
    o = dict(DEFAULTS)
    o["dry_run"] = True
    o["relations"] = True
    o["github"] = True
    o["slot"] = time.strftime("%Y-%m-%d") + "/reconcile"
    i = 0
    while i < len(argv):
        a = argv[i]
        if a == "--dry-run":
            o["dry_run"] = True; i += 1
        elif a == "--apply":
            o["dry_run"] = False; i += 1
        elif a == "--no-relations":
            o["relations"] = False; i += 1
        elif a == "--no-github":
            o["github"] = False; i += 1
        elif a in ("--live-url", "--mvp-parent", "--repo", "--slot"):
            key = a[2:].replace("-", "_")
            if i + 1 >= len(argv):
                die(E_USAGE, "%s needs a value" % a)
            o[key] = argv[i + 1]; i += 2
        elif a in ("--recent-days", "--max-relations"):
            key = a[2:].replace("-", "_")
            if i + 1 >= len(argv):
                die(E_USAGE, "%s needs a value" % a)
            try:
                o[key] = int(argv[i + 1])
            except ValueError:
                die(E_USAGE, "%s must be an integer" % a)
            i += 2
        elif a in ("-h", "--help", "help"):
            print(__doc__ or "see the header of bin/fm-reconcile.sh")
            sys.exit(0)
        else:
            die(E_USAGE, "unknown argument %r" % a)
    return o


# --- small io helpers -------------------------------------------------------

ENG_RE = re.compile(r"ENG-(\d+)", re.I)
ENG_LOOSE_RE = re.compile(r"eng[-_ ]?(\d+)", re.I)


def eng_num(s):
    """Extract the first ENG number from a string, or None."""
    if not s:
        return None
    m = ENG_RE.search(s)
    return int(m.group(1)) if m else None


def eng_id(n):
    return "ENG-%d" % n


def read_json_file(path, what):
    try:
        with open(path) as fh:
            return json.load(fh), None
    except Exception as ex:  # noqa: BLE001
        return None, "%s fixture unreadable (%s): %s" % (what, path, ex)


def http_get_json(url, what):
    try:
        req = urllib.request.Request(url, headers={"Accept": "application/json"})
        with urllib.request.urlopen(req, timeout=30) as resp:
            return json.loads(resp.read().decode()), None
    except urllib.error.HTTPError as ex:
        return None, "%s HTTP %d at %s" % (what, ex.code, url)
    except Exception as ex:  # noqa: BLE001
        return None, "%s unreachable at %s: %s" % (what, url, ex)


def run_tool(argv, timeout=90):
    """Run a helper CLI, returning (stdout, err_or_None). Never leaks stderr
    verbatim (fm-linear's usage text mentions write-tool names we must not echo).
    """
    try:
        p = subprocess.run(argv, capture_output=True, text=True, timeout=timeout)
    except FileNotFoundError:
        return None, "tool not found: %s" % argv[0]
    except subprocess.TimeoutExpired:
        return None, "tool timed out: %s" % argv[0]
    if p.returncode != 0:
        first = (p.stderr or p.stdout or "").strip().splitlines()
        reason = first[0] if first else ("exit %d" % p.returncode)
        return None, _scrub(reason)
    return p.stdout, None


_FORBIDDEN = re.compile(r"(save|create|update)_issue", re.I)


def _scrub(text):
    """Remove any Linear write-tool token so it never reaches our output (the
    change-list must be provably free of Linear-write verbs, design section 5)."""
    return _FORBIDDEN.sub("<linear-write-verb>", text)


# --- fetch layer (live or fixture) ------------------------------------------

def fetch_model(o):
    fx = os.environ.get("FM_RECONCILE_MODEL_FILE")
    if fx:
        return read_json_file(fx, "tracker model")
    return http_get_json(o["live_url"].rstrip("/") + "/api/model", "tracker model")


def fetch_linear(o):
    fx = os.environ.get("FM_RECONCILE_LINEAR_FILE")
    if fx:
        data, err = read_json_file(fx, "Linear export")
        return (data.get("issues", data) if isinstance(data, dict) else data), err
    out, err = run_tool([LINEAR_BIN, "list_issues",
                         "--parent", o["mvp_parent"], "--limit", "100"])
    if err:
        return None, "Linear export unavailable: " + err
    try:
        data = json.loads(out)
    except Exception as ex:  # noqa: BLE001
        return None, "Linear export unparseable: %s" % ex
    return data.get("issues", []), None


def fetch_relations(o, eng_ids):
    """Return {eng_num: relations_dict}. Parallel get_issue --relations, capped."""
    fx = os.environ.get("FM_RECONCILE_RELATIONS_FILE")
    if fx:
        data, err = read_json_file(fx, "relations")
        if err:
            return {}, err
        return {int(k.split("-")[-1]): v for k, v in data.items()}, None
    ids = sorted(eng_ids)[: o["max_relations"]]
    capped = len(eng_ids) > o["max_relations"]
    rel = {}

    def one(n):
        out, err = run_tool([LINEAR_BIN, "get_issue", eng_id(n), "--relations"],
                            timeout=45)
        if err:
            return n, None
        try:
            return n, json.loads(out).get("relations")
        except Exception:  # noqa: BLE001
            return n, None

    with cf.ThreadPoolExecutor(max_workers=o["relations_workers"]) as ex:
        for n, r in ex.map(one, ids):
            if r is not None:
                rel[n] = r
    note = ("relations fetched for %d issues%s" %
            (len(rel), " (capped at %d of %d)" % (o["max_relations"], len(eng_ids))
             if capped else ""))
    return rel, note


def fetch_prs(o):
    """Return {eng_num: merged_bool} from observed GitHub PRs (design section 3)."""
    fx = os.environ.get("FM_RECONCILE_PR_FILE")
    if fx:
        data, err = read_json_file(fx, "GitHub PRs")
    else:
        out, err2 = run_tool(
            [GH_BIN, "pr", "list", "--repo", o["repo"], "--state", "all",
             "--limit", "300", "--json", "number,title,headRefName,state,mergedAt"])
        if err2:
            return {}, "GitHub PR state unavailable: " + err2
        try:
            data, err = json.loads(out), None
        except Exception as ex:  # noqa: BLE001
            data, err = None, "GitHub PR JSON unparseable: %s" % ex
    if err:
        return {}, err
    merged = {}
    for pr in data or []:
        is_merged = bool(pr.get("mergedAt")) or pr.get("state") == "MERGED"
        for field in (pr.get("headRefName", ""), pr.get("title", "")):
            for m in ENG_LOOSE_RE.finditer(field or ""):
                n = int(m.group(1))
                merged[n] = merged.get(n, False) or is_merged
    return merged, "observed %d PR-linked ENG ids" % len(merged)


# --- config lists -----------------------------------------------------------

def load_list(name):
    path = os.path.join(CONFIG_DIR, name)
    out = []
    try:
        with open(path) as fh:
            for line in fh:
                s = line.strip()
                if s and not s.startswith("#"):
                    out.append(s)
    except FileNotFoundError:
        pass
    return out


def load_drift_set():
    nums = set()
    for entry in load_list("reconcile-intentional-drift.txt"):
        n = eng_num(entry)
        if n:
            nums.add(n)
    return nums


def load_skip_patterns():
    # each line: "eng:NNN" (exact id) or "substr:TEXT" (title contains, ci) or
    # "label:NAME" (has label). Comments/blank ignored.
    exact, substr, labels = set(), [], []
    for entry in load_list("reconcile-skip-set.txt"):
        if entry.startswith("eng:"):
            n = eng_num(entry)
            if n:
                exact.add(n)
        elif entry.startswith("substr:"):
            substr.append(entry[len("substr:"):].strip().lower())
        elif entry.startswith("label:"):
            labels.append(entry[len("label:"):].strip().lower())
    return exact, substr, labels


# --- model indexing ---------------------------------------------------------

def index_model(model):
    nodes_by_eng, master_by_eng = {}, {}
    nodes = (model.get("graph", {}) or {}).get("nodes", []) or []
    edges = (model.get("graph", {}) or {}).get("edges", []) or []
    clusters = [c.get("id") for c in
                ((model.get("graph", {}) or {}).get("clusters", []) or [])]
    for nd in nodes:
        n = eng_num(nd.get("bold", "")) or eng_num(nd.get("desc", ""))
        if n:
            nodes_by_eng[n] = nd
    for row in model.get("masterList", []) or []:
        n = eng_num(row.get("itemHtml", ""))
        if n:
            master_by_eng[n] = row
    node_ids = {nd.get("id") for nd in nodes}
    edge_set = {(e.get("from"), e.get("to")) for e in edges}
    return nodes_by_eng, master_by_eng, node_ids, edge_set, edges, set(clusters)


_TAG_RE = re.compile(r"<[^>]+>")
_WORD_RE = re.compile(r"[a-z0-9]+")
_STOP = {"the", "a", "an", "to", "of", "and", "for", "in", "on", "with", "into",
         "eng", "mvp", "built", "wip", "e2e", "demo", "chat", "run", "test"}


def _tokens(text):
    text = _TAG_RE.sub(" ", str(text or "")).lower()
    return {w for w in _WORD_RE.findall(text) if len(w) > 2 and w not in _STOP}


def build_row_matcher(model):
    """Match a ticket to a master row by ENG id first, then a conservative
    title-token fuzzy match (design Stage C: confidence-scored title match), so
    free-text rows that carry no ENG id are not mis-reported as coverage gaps.

    Returns find_row(eng_num, issue) -> (row_or_None, how). The fuzzy path
    requires a strong overlap (Jaccard >= 0.5 AND >= 3 shared significant tokens)
    to avoid a false attach, and never reuses a row already claimed by an ENG id.
    """
    rows = model.get("masterList", []) or []
    by_eng, untagged = {}, []
    for row in rows:
        e = eng_num(row.get("itemHtml", ""))
        if e is not None:
            by_eng[e] = row
        else:
            untagged.append((row, _tokens(row.get("itemHtml", ""))))

    def find_row(n, issue):
        if n in by_eng:
            return by_eng[n], "eng-id"
        it = _tokens(issue.get("title", ""))
        if not it:
            return None, None
        best, best_j, best_shared = None, 0.0, 0
        for row, rt in untagged:
            if not rt:
                continue
            shared = len(it & rt)
            union = len(it | rt) or 1
            j = shared / union
            if j > best_j:
                best, best_j, best_shared = row, j, shared
        if best is not None and best_j >= 0.5 and best_shared >= 3:
            return best, "fuzzy(j=%.2f)" % best_j
        return None, None

    return find_row


# --- classification: pinned mappings ----------------------------------------

def is_recent(iso_ts, days):
    if not iso_ts:
        return False
    try:
        t = time.strptime(iso_ts[:19], "%Y-%m-%dT%H:%M:%S")
        return (time.time() - time.mktime(t) - time.timezone) <= days * 86400
    except Exception:  # noqa: BLE001
        return False


def blocked_signal(issue, relations, done_nums):
    """A blocked signal per design section 3, conservatively evaluated."""
    for lb in issue.get("labels", []) or []:
        name = lb if isinstance(lb, str) else lb.get("name", "")
        if str(name).strip().lower() == "blocked":
            return True, "'Blocked' label"
    if str(issue.get("statusType", "")).lower() == "blocked":
        return True, "Linear blocked state"
    rel = relations or {}
    for b in rel.get("blockedBy", []) or []:
        bn = eng_num(b.get("id", "") if isinstance(b, dict) else str(b))
        if bn is not None and bn not in done_nums:
            return True, "open blocked-by %s" % eng_id(bn)
    return False, ""


def desired_node_status(issue, merged, relations, done_nums, recent_days):
    st = str(issue.get("status", "")).strip()
    stt = str(issue.get("statusType", "")).strip().lower()
    n = eng_num(issue.get("id", ""))
    if st == "Done" or stt == "completed" or merged.get(n):
        why = "Linear Done" if (st == "Done" or stt == "completed") else "merged PR observed"
        return "done", why
    blk, why = blocked_signal(issue, relations, done_nums)
    if blk:
        return "blocked", why
    if st == "In Progress" or stt == "started":
        if is_recent(issue.get("startedAt") or issue.get("updatedAt"), recent_days):
            return "working", "Linear In Progress + recent activity"
        return None, "In Progress but no recent activity (no-progress is not a move reason)"
    if stt in ("backlog", "unstarted") or st in ("Backlog", "Todo"):
        return "queued", "Linear %s" % st
    if stt == "canceled":
        return None, "Canceled (node kept, marked canceled)"
    return None, "unmapped Linear status %r" % st


def desired_group(issue, recent_days):
    st = str(issue.get("status", "")).strip()
    stt = str(issue.get("statusType", "")).strip().lower()
    if st == "Done" or stt == "completed":
        return "done", "Linear Done"
    if st in ("In Progress", "In Review", "Reviewed") or stt in ("started", "review"):
        return "active", "Linear %s" % st
    if stt == "canceled":
        return "deferred", "Canceled (node kept, marked canceled)"
    if st in ("Backlog", "Todo") or stt in ("backlog", "unstarted"):
        in_cycle = bool(issue.get("cycleId"))
        recent = is_recent(issue.get("updatedAt"), recent_days)
        if in_cycle or recent:
            return "active", "Backlog/Todo in current cycle or recently active"
        return "deferred", "Backlog/Todo, not in cycle and not recently active (off-graph)"
    return None, "unmapped Linear status %r" % st


# --- cluster inference (never undefined; ambiguous -> gate) -----------------

CLUSTER_KEYWORDS = [
    ("optics", ("optic", "optical", "ray", "lens", "singlet", "cooke", "efl")),
    ("mech", ("mechanic", "moose", "stress", "bracket", "structural", "thermal")),
    ("agent", ("agent", "prompt", "chat", "system-prompt", "tool", "loop")),
    ("frontend", ("frontend", "display", "render", "ui", "widget", "narrative", "font")),
    ("deploy", ("deploy", "modal", "backend", "infra", "ingress", "webhook", "image")),
]


def infer_cluster(issue, valid_clusters):
    text = (str(issue.get("title", "")) + " " +
            str(issue.get("description", ""))).lower()
    for cid, kws in CLUSTER_KEYWORDS:
        if cid in valid_clusters and any(k in text for k in kws):
            return cid
    return None


# --- html-injection guard ---------------------------------------------------

def unsafe_html(*vals):
    """True if any value would break a Graphviz label / row HTML (design 5)."""
    for v in vals:
        if v and ("<" in str(v) or ">" in str(v)):
            return True
    return False


# --- change-list assembly ---------------------------------------------------

class Op:
    def __init__(self, tier, kind, target, message, before, after, why):
        self.tier = tier          # AUTONOMOUS | NEEDS-DAVID | DRIFT-HOLD | NOTE
        self.kind = kind          # set_node_status | move_group | add_node | ...
        self.target = target      # ENG id or node/edge ref
        self.message = message    # imperative chat message (None for non-apply)
        self.before = before
        self.after = after
        self.why = why


def build_change_list(o, model, issues, relations, merged):
    nodes_by_eng, master_by_eng, node_ids, edge_set, edges, valid_clusters = \
        index_model(model)
    find_row = build_row_matcher(model)
    drift = load_drift_set()
    skip_exact, skip_substr, skip_labels = load_skip_patterns()
    def _issue_done(i):
        st = str(i.get("status", "")).strip()
        stt = str(i.get("statusType", "")).strip().lower()
        return st == "Done" or stt == "completed" or bool(merged.get(eng_num(i.get("id", ""))))

    done_nums = {eng_num(i.get("id", "")) for i in issues if _issue_done(i)}
    done_nums = {n for n in done_nums if n is not None}
    issues_by_num = {eng_num(i.get("id", "")): i for i in issues
                     if eng_num(i.get("id", "")) is not None}

    ops, notes = [], []

    def skipped(issue, n):
        if n in skip_exact:
            return "skip-set (explicit)"
        title = str(issue.get("title", "")).lower()
        for s in skip_substr:
            if s in title:
                return "skip-set (non-MVP: %r)" % s
        labs = [str(lb if isinstance(lb, str) else lb.get("name", "")).lower()
                for lb in issue.get("labels", []) or []]
        for lb in skip_labels:
            if lb in labs:
                return "skip-set (label %r)" % lb
        return None

    for n, issue in sorted(issues_by_num.items()):
        eid = eng_id(n)
        if n in drift:
            node = nodes_by_eng.get(n)
            ops.append(Op("DRIFT-HOLD", "preserve", eid, None,
                          (node or {}).get("status"), "(unchanged)",
                          "intentional narrower-scope drift; open Q4 marker "
                          "unresolved, preserved not reverted"))
            continue
        sk = skipped(issue, n)
        if sk:
            # Canceled still gets a node-kept note; others just skipped.
            if str(issue.get("statusType", "")).lower() == "canceled" and n in nodes_by_eng:
                ops.append(Op("NOTE", "mark_canceled", eid, None,
                              nodes_by_eng[n].get("status"), "canceled",
                              "Canceled: node kept + marked, never deleted"))
            else:
                notes.append("%s skipped: %s" % (eid, sk))
            continue

        node = nodes_by_eng.get(n)
        row, row_how = find_row(n, issue)
        rel = relations.get(n)

        # --- coverage (design section 3 + 6) ---
        want_group, gwhy = desired_group(issue, o["recent_days"])
        want_status, swhy = desired_node_status(
            issue, merged, rel, done_nums, o["recent_days"])
        active_or_done = want_group in ("active", "done")

        if row is None:
            # No row AND (if active/done) no node: a net-new coverage gap. Adding
            # a row needs item/owner text and, for the node, a chosen cluster, so
            # this is gated to David, NOT auto-applied. Auto-adding a node here
            # would create the very orphan-node section 6 flags.
            ops.append(Op("NEEDS-DAVID", "add_master_row", eid, None, None,
                          "row(group=%s)%s" % (want_group,
                                               "+node" if active_or_done else ""),
                          "coverage gap: MVP deliverable has no master-list row "
                          "(%s); adding a row/node needs item text + cluster" % gwhy))
        elif want_group and row.get("group") != want_group:
            # A group move is autonomous ONLY when the row is matched by ENG id
            # (certain). A fuzzy title match is not certain enough to silently
            # re-file a team-visible row (design Stage C: low-confidence match
            # never drives a write), so it is proposed to David instead.
            if row_how == "eng-id":
                ops.append(Op("AUTONOMOUS", "move_group", eid,
                              "move the master item for %s to the %s list"
                              % (eid, want_group),
                              row.get("group"), want_group, gwhy))
            else:
                ops.append(Op("NEEDS-DAVID", "move_group", eid, None,
                              row.get("group"), want_group,
                              "%s, but the row is only a %s match - confirm the "
                              "row identity before re-filing it" % (gwhy, row_how)))

        # add_node is autonomous ONLY when the row already exists (row present,
        # node absent = a true 1:1 violation). Without a row, the node-add is
        # part of the gated coverage gap above (an orphan-node guard).
        if active_or_done and node is None and row is not None and row_how == "eng-id":
            cid = infer_cluster(issue, valid_clusters)
            title = str(issue.get("title", ""))
            owner = str(issue.get("assignee", "") or "")
            if cid is None:
                ops.append(Op("NEEDS-DAVID", "add_node", eid, None, None,
                              "node(status=%s)" % (want_status or "queued"),
                              "1:1 gap: row exists but no DAG node, and cluster is "
                              "ambiguous - David picks the cluster"))
            elif unsafe_html(title, owner):
                ops.append(Op("NEEDS-DAVID", "add_node", eid, None, None,
                              "node(status=%s)" % (want_status or "queued"),
                              "1:1 gap: node needed but title/owner contains "
                              "'<'/'>' (HTML-injection guard) - manual handling"))
            else:
                st = want_status or "queued"
                ops.append(Op("AUTONOMOUS", "add_node", eid,
                              "add a node n%d labelled %s in the %s cluster owned "
                              "by %s with status %s" % (n, eid, cid, owner or "David", st),
                              None, "node n%d in %s, status %s" % (n, cid, st),
                              "1:1 coverage: %s" % (swhy or gwhy)))
        elif node is not None and want_status and node.get("status") != want_status:
            ops.append(Op("AUTONOMOUS", "set_node_status", eid,
                          "set %s status to %s" % (eid, want_status),
                          node.get("status"), want_status, swhy))
        elif node is not None and want_status is None and swhy:
            # a genuinely conflicting / no-move signal -> report, never move
            if node.get("status") not in (None, "done") and "Canceled" in swhy:
                pass
            notes.append("%s status left as-is: %s (current node=%s)"
                         % (eid, swhy, (node or {}).get("status")))

        # --- edges: Linear blocked-by -> formal DAG edge (additive) ---
        if node is not None and rel:
            for b in rel.get("blockedBy", []) or []:
                bn = eng_num(b.get("id", "") if isinstance(b, dict) else str(b))
                if bn is None or bn not in nodes_by_eng or bn in drift:
                    continue
                frm, to = "n%d" % bn, node.get("id")
                if (frm, to) not in edge_set:
                    ops.append(Op("AUTONOMOUS", "add_edge",
                                  "%s->%s" % (eng_id(bn), eid),
                                  "add a formal edge from n%d to %s" % (bn, to),
                                  None, "edge %s->%s (formal)" % (frm, to),
                                  "Linear blocked-by relation missing from DAG"))

    # --- soft-retire resolved formal edges (design section 3) ---
    for e in edges:
        if e.get("kind") != "formal":
            continue
        fn, tn = eng_num_from_nodeid(e.get("from")), eng_num_from_nodeid(e.get("to"))
        if fn is None or tn is None or fn in drift or tn in drift:
            continue
        blk_issue = issues_by_num.get(fn)
        cur_rel = relations.get(tn)
        if blk_issue is None or cur_rel is None:
            continue  # cannot prove resolved without both endpoints + relations
        still = any(eng_num(b.get("id", "") if isinstance(b, dict) else str(b)) == fn
                    for b in (cur_rel.get("blockedBy", []) or []))
        blocker_done = fn in done_nums
        if (not still) and blocker_done:
            # Soft-retire is the design's reversible mark-resolved (section 3),
            # but the live tracker /api/chat op vocabulary is only
            # {move_master_item, set_node_status, add_node, add_edge} - there is
            # NO edge-retire op yet. So this is a correct PROPOSAL that cannot be
            # autonomously applied today; it is NEEDS-DAVID (needs a tracker-side
            # mark-resolved op, a separate small tracker PR like the L4 escape
            # guard), never auto-emitted as a chat op that the LLM cannot map.
            ops.append(Op("NEEDS-DAVID", "soft_retire_edge",
                          "%s->%s" % (eng_id(fn), eng_id(tn)),
                          None, "formal", "resolved",
                          "blocker %s is Done and the Linear relation is gone; "
                          "soft-retire proposal (tracker lacks a retire op today, "
                          "so not auto-applied; never hard-delete)" % eng_id(fn)))

    # --- orphan tracker items with no Linear ticket (housekeeping, section 6) ---
    for n, row in sorted(master_by_eng.items()):
        if n not in issues_by_num and n not in drift:
            notes.append("orphan: master item %s has no Linear ticket in the MVP "
                         "set (could be off-Linear tooling) - flag for David"
                         % eng_id(n))

    return ops, notes


def eng_num_from_nodeid(nid):
    if not nid:
        return None
    m = re.search(r"n(\d+)", str(nid))
    return int(m.group(1)) if m else None


# --- rendering --------------------------------------------------------------

def render(o, ops, notes, src_notes):
    lines = []
    lines.append("=== RECONCILE CHANGE-LIST (%s) ==="
                 % ("APPLY" if not o["dry_run"] else "dry-run"))
    lines.append("slot: %s   mvp-parent: %s   live: %s"
                 % (o["slot"], o["mvp_parent"], o["live_url"]))
    lines.append("")
    lines.append("-- sources --")
    for s in src_notes:
        lines.append("  " + s)
    lines.append("")

    tiers = ["AUTONOMOUS", "NEEDS-DAVID", "DRIFT-HOLD", "NOTE"]
    titles = {
        "AUTONOMOUS": "AUTONOMOUS tracker ops (would apply on --apply; verified by re-GET)",
        "NEEDS-DAVID": "NEEDS-DAVID (listed only; never auto-applied by this pass)",
        "DRIFT-HOLD": "DRIFT-HOLD (intentional drift, open Q4 unresolved; preserved)",
        "NOTE": "NOTES (kept-as-is, e.g. Canceled node retained)",
    }
    by_tier = {t: [op for op in ops if op.tier == t] for t in tiers}
    for t in tiers:
        group = by_tier[t]
        lines.append("-- %s [%d] --" % (titles[t], len(group)))
        if not group:
            lines.append("  (none)")
        for op in group:
            delta = ("%s -> %s" % (op.before, op.after)
                     if op.before is not None or op.after is not None else "")
            act = ("%s %s %s" % (op.kind, op.target, delta)).strip()
            prefix = "would " if t == "AUTONOMOUS" else ""
            lines.append("  %s%s  [%s]" % (prefix, act, op.why))
        lines.append("")

    lines.append("-- housekeeping notes [%d] --" % len(notes))
    for nt in notes:
        lines.append("  " + nt)
    lines.append("")

    auto = len(by_tier["AUTONOMOUS"])
    gated = len(by_tier["NEEDS-DAVID"])
    lines.append("-- summary --")
    lines.append("  autonomous tracker ops: %d   needs-david: %d   drift-hold: %d   notes: %d"
                 % (auto, gated, len(by_tier["DRIFT-HOLD"]), len(notes)))
    if o["dry_run"]:
        lines.append("  DRY-RUN: made zero Linear writes and zero tracker writes. "
                     "Re-run with --apply to land the %d autonomous tracker ops." % auto)
    return "\n".join(lines), by_tier["AUTONOMOUS"]


# --- apply (autonomous tracker ops only) ------------------------------------

def resolve_edit_password():
    pw = os.environ.get("EDIT_PASSWORD")
    if pw:
        return pw
    env_path = os.environ.get(
        "FM_RECONCILE_TRACKER_ENV",
        os.path.join(REPO_ROOT, "projects", "kronos-mvp-tracker", ".env"))
    try:
        with open(env_path) as fh:
            for line in fh:
                line = line.strip()
                if line.startswith("EDIT_PASSWORD=") and len(line) > len("EDIT_PASSWORD="):
                    return line.split("=", 1)[1].strip().strip('"').strip("'")
    except FileNotFoundError:
        return None
    return None


def post_chat(o, message, password):
    body = json.dumps({"message": message, "password": password}).encode()
    req = urllib.request.Request(
        o["live_url"].rstrip("/") + "/api/chat", data=body,
        headers={"Content-Type": "application/json"}, method="POST")
    try:
        with urllib.request.urlopen(req, timeout=60) as resp:
            resp.read()
        return True
    except Exception:  # noqa: BLE001 (chat response can carry control chars)
        return True  # we do NOT trust the response; verify by re-GET instead


def verify_op(op, model):
    nodes_by_eng, master_by_eng, node_ids, edge_set, _edges, _cl = index_model(model)
    n = eng_num(op.target)
    if op.kind == "set_node_status":
        nd = nodes_by_eng.get(n)
        return bool(nd and nd.get("status") == op.after)
    if op.kind == "move_group":
        row = master_by_eng.get(n)
        return bool(row and row.get("group") == op.after)
    if op.kind == "add_node":
        return ("n%d" % n) in node_ids
    if op.kind == "add_edge":
        m = re.search(r"n(\d+).*?(n\d+)", op.after or "")
        return True if not m else ((("n" + m.group(1)), m.group(2)) in edge_set)
    return True  # soft_retire has no simple positive assertion; audited, not blocked


def apply_ops(o, auto_ops):
    if not auto_ops:
        print("apply: no autonomous ops to land.")
        return 0
    pw = resolve_edit_password()
    if not pw:
        die(E_AUTH, "EDIT_PASSWORD not reachable (checked $EDIT_PASSWORD and the "
                    "tracker .env). --apply needs it to POST /api/chat; --dry-run "
                    "does not. Nothing was written.")
    landed = 0
    for op in auto_ops:
        post_chat(o, op.message, pw)
        model, err = fetch_model(o)
        ok = False
        if not err and model:
            ok = verify_op(op, model)
        if not ok:
            post_chat(o, op.message, pw)  # one retry (design section 6)
            model, err = fetch_model(o)
            ok = (not err) and model and verify_op(op, model)
        status = "verified" if ok else "UNVERIFIED"
        # audit log every applied op (before/after/evidence), even if unverified
        audit_argv = [
            AUDIT_BIN, "append", o["slot"], op.target, op.kind,
            "--before", str(op.before), "--after", str(op.after),
            "--evidence", "reconcile:%s" % op.why[:120],
            "--note", "chat-op %s" % status, "--run", o["slot"]]
        run_tool(audit_argv, timeout=30)
        print("apply %-8s %s %s -> %s" % (status, op.kind, op.target, op.after))
        if ok:
            landed += 1
    print("apply: %d/%d autonomous tracker ops verified; each written to the "
          "audit log (slot %s)." % (landed, len(auto_ops), o["slot"]))
    if landed < len(auto_ops):
        print("apply: %d op(s) did not verify; exiting %d so a scheduled run "
              "detects the failed writes." % (len(auto_ops) - landed, E_APPLY))
        return E_APPLY
    return 0


# --- main -------------------------------------------------------------------

def main():
    o = parse_args(sys.argv[1:])
    src_notes = []

    model, merr = fetch_model(o)
    if merr or not model:
        # degrade: cannot reconcile without the tracker model, but still emit a
        # change-list frame so the run is never a silent no-op / crash.
        print("=== RECONCILE CHANGE-LIST (%s) ==="
              % ("APPLY" if not o["dry_run"] else "dry-run"))
        print("  tracker model unavailable: %s" % (merr or "empty"))
        print("  would produce no ops this run; nothing written. Re-run when the "
              "live tracker is reachable.")
        return 0
    src_notes.append("tracker model: %d master rows, %d nodes, %d edges"
                     % (len(model.get("masterList", []) or []),
                        len((model.get("graph", {}) or {}).get("nodes", []) or []),
                        len((model.get("graph", {}) or {}).get("edges", []) or [])))

    issues, lerr = fetch_linear(o)
    if lerr or issues is None:
        src_notes.append("Linear: " + _scrub(lerr or "empty export"))
        issues = []
    else:
        src_notes.append("Linear: %d MVP-epic child issues" % len(issues))

    eng_ids = {eng_num(i.get("id", "")) for i in issues}
    eng_ids = {n for n in eng_ids if n is not None}

    relations, rnote = ({}, "relations: skipped (--no-relations)")
    if o["relations"] and eng_ids:
        relations, rnote = fetch_relations(o, eng_ids)
    src_notes.append("relations: " + (rnote or "none"))

    merged, pnote = ({}, "GitHub: skipped (--no-github)")
    if o["github"]:
        merged, pnote = fetch_prs(o)
    src_notes.append("GitHub: " + (pnote or "none"))

    ops, notes = build_change_list(o, model, issues, relations, merged)
    text, auto_ops = render(o, ops, notes, src_notes)
    print(text)

    if not o["dry_run"]:
        print("")
        return apply_ops(o, auto_ops)
    return 0


if __name__ == "__main__":
    sys.exit(main())
PYEOF

#!/usr/bin/env bash
# Emits unanswered David board-thread messages so a UserPromptSubmit hook injects
# them into firstmate's context every turn. A thread whose newest message is
# David-authored is surfaced whether or not it maps to a live board row; threads
# with no live row are tagged [no-row] so firstmate knows the row is missing.
# Fails open (silent) on any error.
set -u
ROOT="${FM_ROOT_OVERRIDE:-$(cd "$(dirname "$0")/.." && pwd)}"
cd "$ROOT" 2>/dev/null || exit 0
python3 - <<'PY' 2>/dev/null || true
import json,glob,os
try: d=json.load(open("state/board.json"))
except: raise SystemExit(0)
# Live row ids. Most sections are flat lists of rows, but `holding` is a list of
# GROUPS ({"unlock":..., "rows":[...]}), so its rows live one level down; flatten
# them (falling back to a direct row shape defensively) or a held row's David
# messages would be invisible.
live=set()
def add(r):
    if isinstance(r,dict):
        rid=r.get("id")
        if rid: live.add(rid)
for s in ["your_word","in_progress","backlog","landed"]:
    for r in (d.get(s) or []): add(r)
for g in (d.get("holding") or []):
    rows=g.get("rows") if isinstance(g,dict) else None
    if isinstance(rows,list):
        for r in rows: add(r)
    else:
        add(g)
out=[]
for dd in sorted(glob.glob("data/board-threads/*/")):
    it=os.path.basename(dd.rstrip('/'))
    fs=glob.glob(dd+"*.md")
    if not fs: continue
    last=max(fs,key=os.path.getmtime)
    try:
        txt=open(last).read()
        h=json.loads(txt.split("\n")[0])
    except: continue
    body="\n".join(txt.split("\n")[1:]).strip()
    if h.get("author")=="david" and body:
        out.append((it, body.replace("\n"," ")[:300], it not in live))
if out:
    print("UNANSWERED BOARD THREAD MESSAGES FROM DAVID -- answer each in-thread (bin/fm-board-reply.sh <id> \"...\") before other work:")
    for it,b,norow in out:
        tag="[no-row] " if norow else ""
        print(f"- [{it}] {tag}{b}")
PY

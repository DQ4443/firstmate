#!/usr/bin/env python3
"""Validate Lavish and Oat contract invariants targeted by hostile mutations."""

from __future__ import annotations

import argparse
import sys
from pathlib import Path


def require(text: str, value: str, label: str) -> None:
    if value not in text:
        raise ValueError(f"missing {label}")


def main() -> int:
    parser = argparse.ArgumentParser()
    for name in ("lavish", "evals", "oat", "decision", "sidebar"):
        parser.add_argument(f"--{name}", required=True, type=Path)
    args = parser.parse_args()
    texts = {name: getattr(args, name).read_text(encoding="utf-8") for name in ("lavish", "evals", "oat", "decision", "sidebar")}
    lavish, evals, oat = texts["lavish"], texts["evals"], texts["oat"]
    try:
        order = [lavish.index("Read `.agents/skills/oat/SKILL.md`"), lavish.index("Read `.agents/skills/lavish/references/decision-zone.md`"), lavish.index("Read `.agents/skills/lavish/references/nav-sidebar.md`"), lavish.index("Build the self-contained page"), lavish.index("Render the HTML in a real browser")]
        if order != sorted(order):
            raise ValueError("module order changed")
        require(evals, "$lavish discuss the dashboard design here", "$lavish trigger")
        require(lavish, "The Recommended option is first and preselected.", "Recommended-first rule")
        require(lavish, "Every short-answer question gets a real textarea wired into the reply bar.", "textarea rule")
        require(lavish, "Keep one stable file path per workstream.", "stable path rule")
        require(lavish, "Each round appends a section and preserves all prior round content.", "append-only update rule")
        require(lavish, "Claim session resume only after a real open, update, and reopen returns evidence for the same session identity.", "real resume evidence gate")
        require(oat, "only source of visual tokens and components", "sole style owner")
        require(texts["decision"], "arbitrary page-scoped `Dn`, `On`, and `Qn`", "arbitrary identifier support")
        require(texts["decision"], "DAVID_WARM_COMPONENT_FILE", "configured decision source")
        require(texts["sidebar"], "DAVID_WARM_COMPONENT_FILE", "configured sidebar source")
        require(texts["sidebar"], "Build round links at load time", "dynamic sidebar reference")
        if "COPY VERBATIM: EXECUTABLE MERMAID" in oat:
            raise ValueError("unverified executable Mermaid claim")
    except (OSError, ValueError) as error:
        print(f"ERROR: {error}", file=sys.stderr)
        return 2
    print("contract=PASS")
    return 0


if __name__ == "__main__":
    sys.exit(main())

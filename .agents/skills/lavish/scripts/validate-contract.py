#!/usr/bin/env python3
"""Validate the Lavish and Oat invariants targeted by hostile mutations."""

from __future__ import annotations

import argparse
import sys
from pathlib import Path


def require(text: str, value: str, label: str) -> None:
    if value not in text:
        raise ValueError(f"missing {label}")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--lavish", required=True, type=Path)
    parser.add_argument("--evals", required=True, type=Path)
    parser.add_argument("--oat", required=True, type=Path)
    args = parser.parse_args()
    lavish = args.lavish.read_text(encoding="utf-8")
    evals = args.evals.read_text(encoding="utf-8")
    oat = args.oat.read_text(encoding="utf-8")
    try:
        order = [
            lavish.index("Read `.agents/skills/oat/SKILL.md`"),
            lavish.index("Read `.agents/skills/lavish/references/decision-zone.md`"),
            lavish.index("Read `.agents/skills/lavish/references/nav-sidebar.md`"),
            lavish.index("Build the self-contained page"),
            lavish.index("Render the HTML in a real browser"),
        ]
        if order != sorted(order):
            raise ValueError("module order changed")
        require(evals, "$lavish discuss the dashboard design here", "$lavish trigger")
        require(lavish, "Use stable page-scoped IDs `D1`, `D2`, and later.", "D1 identifier rule")
        require(lavish, "Every block ends with a free-text note input wired into the reply bar.", "decision notes")
        require(lavish, "The first content section after the short summary is a rendered diagram", "report-first diagram")
        require(lavish, "Each round appends a section and preserves all prior round content.", "append-only history")
        require(lavish, "Do not run `lavish-axi share`", "outbound share gate")
        require(lavish, "do not send the file externally without David's explicit word", "outbound send gate")
        require(oat, "Pages with directed graphs copy `COPY VERBATIM: EXECUTABLE MERMAID` verbatim.", "canonical executable Mermaid component")
    except (ValueError, OSError) as error:
        print(f"ERROR: {error}", file=sys.stderr)
        return 2
    print("contract=PASS")
    return 0


if __name__ == "__main__":
    sys.exit(main())

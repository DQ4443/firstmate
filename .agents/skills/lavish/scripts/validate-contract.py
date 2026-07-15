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
    for name in ("lavish", "evals", "oat", "decision", "sidebar", "installer"):
        parser.add_argument(f"--{name}", required=True, type=Path)
    args = parser.parse_args()
    texts = {name: getattr(args, name).read_text(encoding="utf-8") for name in ("lavish", "evals", "oat", "decision", "sidebar", "installer")}
    lavish, evals, oat = texts["lavish"], texts["evals"], texts["oat"]
    installer = texts["installer"]
    try:
        order = [lavish.index("Read `.agents/skills/oat/SKILL.md`"), lavish.index("Read `.agents/skills/lavish/references/decision-zone.md`"), lavish.index("Read `.agents/skills/lavish/references/nav-sidebar.md`"), lavish.index("Build the self-contained page"), lavish.index("Render the HTML in a real browser")]
        if order != sorted(order):
            raise ValueError("module order changed")
        require(evals, "$lavish discuss the dashboard design here", "$lavish trigger")
        require(lavish, "The Recommended option is first and preselected.", "Recommended-first rule")
        require(lavish, "Every short-answer question gets a real textarea wired into the reply bar.", "textarea rule")
        require(lavish, "Keep one stable file path per workstream.", "stable path rule")
        require(
            lavish,
            "Keep one mutable current-round section directly after the page header and an append-only chronological history of completed rounds below it.",
            "append-only update rule",
        )
        require(
            lavish,
            "At a round transition, append the completed section to history before creating the next current section; move it rather than duplicating it.",
            "move completed round without duplication",
        )
        require(lavish, "Claim session resume only after a real open, update, and reopen returns evidence for the same session identity.", "real resume evidence gate")
        require(
            lavish,
            "Every checkpoint begins immediately after the page header with one mutable current-round section.",
            "mandatory checkpoint orientation placement",
        )
        require(
            lavish,
            "Its round heading is followed immediately by that round's visible `Where you are` table before the short summary, evidence, or decisions.",
            "current-round table placement",
        )
        require(lavish, "Each round appears exactly once on the page.", "one section per round")
        require(lavish, "The tables are never hidden in a fold or tab.", "orientation tables stay unfolded")
        require(
            evals,
            "The single current-round section and every preserved earlier round began with that round's visible, unfolded `Where you are` table containing Project, Ticket, Bigger picture, System position, Whole-ticket success, Current round, and Scope boundaries before its summary, evidence, or decisions.",
            "checkpoint orientation eval",
        )
        require(
            lavish,
            "Every preserved earlier-round section also begins with its own visible `Where you are` table immediately after the round heading and before that round's summary, evidence, or decisions.",
            "per-round orientation placement",
        )
        require(
            lavish,
            "When the next round begins, freeze the completed round's table with that round's final state, move the complete section into chronological history, and create a fresh current-round section at the top.",
            "frozen prior-round orientation",
        )
        require(
            lavish,
            "Refresh all seven rows when a new round begins so the table is a truthful snapshot of that round.",
            "refreshed round orientation",
        )
        require(
            lavish,
            "- `Current round`: the present phase, what is proven or unproven, and why David is being asked to decide now.",
            "current-round orientation field",
        )
        require(
            lavish,
            "While a round is active, update its `Current round` row and any changed boundary in place.",
            "active-round orientation refresh",
        )
        require(
            lavish,
            "The preserved content includes that round's seven-row orientation table, evidence, decisions, findings, and outcome.",
            "complete append-only round log",
        )
        require(
            lavish,
            "Never rewrite an earlier round to match the current state, remove it after supersession, or replace the page with only the latest round.",
            "no prior-round rewrite",
        )
        require(
            lavish,
            "Keep discarded work in its original round and mark its verdict `DISCARDED` with the reason.",
            "discarded-work preservation",
        )
        require(
            lavish,
            "Older round bodies may use `details` folds but may not disappear, and their round heading plus seven-row orientation table stay unfolded.",
            "orientation outside history folds",
        )
        require(
            evals,
            "The round-N page contains exactly one mutable current-round section plus N-1 complete chronological history sections, including each round's frozen seven-row orientation snapshot, evidence, decisions, findings, and outcome; earlier round bodies may fold without deletion or current-state rewriting.",
            "complete round-log eval",
        )
        orientation = lavish.index("### Checkpoint orientation")
        summary = lavish.index("### Short summary")
        if orientation >= summary:
            raise ValueError("checkpoint orientation must precede the short summary")
        for field in (
            "`Project`",
            "`Ticket`",
            "`Bigger picture`",
            "`System position`",
            "`Whole-ticket success`",
            "`Current round`",
            "`Scope boundaries`",
        ):
            require(lavish, field, f"checkpoint orientation field {field}")
        require(oat, "only source of visual tokens and components", "sole style owner")
        require(texts["decision"], "arbitrary page-scoped `Dn`, `On`, and `Qn`", "arbitrary identifier support")
        require(texts["decision"], "DAVID_WARM_COMPONENT_FILE", "configured decision source")
        require(texts["sidebar"], "DAVID_WARM_COMPONENT_FILE", "configured sidebar source")
        require(texts["sidebar"], 'data-nav="<group>|<status-glyph>|<label>"', "three-field sidebar contract")
        require(installer, "const [group,status,label] = section.dataset.nav.split('|');", "three-field sidebar parser")
        require(installer, "spec.options.length < 2 || spec.options.length > 4", "two-to-four option gate")
        require(installer, "spec.options.forEach((option, index) =>", "generic option repetition")
        require(installer, "spec.options[0].recommended !== true", "Recommended-first validation")
        require(installer, '"JIM EVIDENCE BADGES"', "canonical Jim evidence component")
        require(installer, "E0:'Assumed',E1:'Ran',E2:'Works-unit',E3:'Works-live',E4:'Causes',E5:'Refute-survived'", "Jim evidence semantics")
        require(installer, "laptopCap:'E1'", "laptop evidence cap")
        require(installer, "input.checked = index === 0;", "Recommended-first checked state")
        require(installer, '<textarea class="qtext" data-question="{{Q_ID}}"', "real question textarea template")
        if installer.count("bindInputs(fragment);") < 2:
            raise ValueError("missing generated decision or question input binding")
        require(installer, "fallback.hidden = false;", "visible selectable fallback")
        require(installer, "fallback.select();", "selected fallback text")
        require(installer, "instruction.hidden = false;", "visible Command-C instruction")
        require(installer, "if open_count > 1 or close_count > 1:", "duplicate component marker rejection")
        if "COPY VERBATIM: EXECUTABLE MERMAID" in oat:
            raise ValueError("unverified executable Mermaid claim")
    except (OSError, ValueError) as error:
        print(f"ERROR: {error}", file=sys.stderr)
        return 2
    print("contract=PASS")
    return 0


if __name__ == "__main__":
    sys.exit(main())

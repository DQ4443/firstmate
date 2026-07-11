#!/usr/bin/env python3
"""Audit Jim's pinned source and extract only sanctioned portable memories."""

from __future__ import annotations

import argparse
import ast
import hashlib
import json
import re
import sys
from pathlib import Path

PINNED_SHA256 = "134eb182731726ae9305d6a7a74d8a767bfb7f042201e953536ceec507f19f7c"
SPINE = ["pdw", "build", "scout", "explore", "websearch", "lavish", "oat", "submit", "rig-atlas"]
ROLES = ["planner", "implementer", "refute-reviewer"]
EXCLUDED_COUNT = 41
REDACTION = "# [portable-twin sanitize pass redacted in this edition: its swap/drop lists"


def assignment(text: str, name: str, following: str) -> list[str]:
    match = re.search(rf"^{name}\s*=\s*(\[.*?\])\n{following}", text, re.MULTILINE | re.DOTALL)
    if not match:
        raise ValueError(f"missing assignment: {name}")
    value = ast.literal_eval(match.group(1))
    if not isinstance(value, list) or not all(isinstance(item, str) for item in value):
        raise ValueError(f"invalid assignment: {name}")
    return value


def memory_bodies(text: str) -> dict[str, str]:
    pattern = re.compile(
        r"^### `memory/([^`]+)`\n\n````````markdown\n(.*?)\n````````$",
        re.MULTILINE | re.DOTALL,
    )
    return {name: body for name, body in pattern.findall(text)}


def inspect(source: Path) -> tuple[dict[str, object], dict[str, str]]:
    raw = source.read_bytes()
    text = raw.decode("utf-8")
    errors: list[str] = []
    digest = hashlib.sha256(raw).hexdigest()
    if digest != PINNED_SHA256:
        errors.append(f"source digest mismatch: {digest}")
    try:
        both = assignment(text, "MEMORIES_BOTH", "MEMORIES_FULL_ONLY")
        full_only = assignment(text, "MEMORIES_FULL_ONLY", "MEMORY_DIR")
        skills = assignment(text, "SKILLS", "AGENTS")
        roles = assignment(text, "AGENTS", r"\n# Curated memory inclusion")
    except ValueError as error:
        raise SystemExit(str(error)) from error
    bodies = memory_bodies(text)
    if len(both) != 47:
        errors.append(f"include-both count is {len(both)}, expected 47")
    if len(full_only) != 47:
        errors.append(f"full-only count is {len(full_only)}, expected 47")
    if skills != SPINE:
        errors.append("spine generator inventory differs from the nine-item source roster")
    if roles != ROLES:
        errors.append("role generator inventory differs from the three-item source roster")
    if set(bodies) != set(both):
        missing = sorted(set(both) - set(bodies))
        extra = sorted(set(bodies) - set(both))
        errors.append(f"Appendix D coverage mismatch: missing={missing}, extra={extra}")
    if set(bodies) & set(full_only):
        errors.append("Appendix D contains a full-only body")
    excluded_phrase = f"+ {EXCLUDED_COUNT} excluded via opus-classified three-bucket rubric"
    if excluded_phrase not in text:
        errors.append("exclude-both count assertion is missing or changed")
    if REDACTION not in text or "portable twin needs the unredacted generator" not in text:
        errors.append("portable sanitizer redaction marker is missing or changed")
    inventory: dict[str, object] = {
        "source_sha256": digest,
        "source_line_ranges": ["1222-1352", "1678-3055", "3057-3505"],
        "include_both": both,
        "full_only": full_only,
        "exclude_both_count": EXCLUDED_COUNT,
        "spine_skills": skills,
        "roles": roles,
        "portable_sanitizer": "redacted",
        "errors": errors,
    }
    return inventory, bodies


def write_runtime(state_dir: Path, inventory: dict[str, object], bodies: dict[str, str]) -> None:
    if inventory["errors"]:
        raise SystemExit("source audit failed; runtime was not written")
    memory_dir = state_dir / "portable-memory"
    memory_dir.mkdir(parents=True, exist_ok=True)
    for stale in memory_dir.glob("*.md"):
        stale.unlink()
    for name, body in sorted(bodies.items()):
        (memory_dir / name).write_text(body + "\n", encoding="utf-8")
    (state_dir / "source-inventory.json").write_text(
        json.dumps(inventory, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )
    status = {
        "portable_twin": "BLOCKED",
        "reason": "Jim's portable sanitizer is redacted in the supplied source.",
        "required_action": "Supply the unredacted sanitizer contract before implementation.",
    }
    (state_dir / "portable-status.json").write_text(
        json.dumps(status, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("source", type=Path)
    parser.add_argument("--setup", type=Path)
    args = parser.parse_args()
    inventory, bodies = inspect(args.source)
    if args.setup:
        write_runtime(args.setup, inventory, bodies)
    print(json.dumps(inventory, indent=2, sort_keys=True))
    return 1 if inventory["errors"] else 0


if __name__ == "__main__":
    sys.exit(main())

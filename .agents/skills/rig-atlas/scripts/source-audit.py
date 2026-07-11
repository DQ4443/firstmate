#!/usr/bin/env python3
"""Audit Jim's pinned source and materialize only adapted portable memories."""

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
REDACTION = "# [portable-twin sanitize pass redacted in this edition: its swap/drop lists"
EXCLUDED_BOTH = [
    "source-withheld-exclude-01", "source-withheld-exclude-02", "source-withheld-exclude-03",
    "source-withheld-exclude-04", "source-withheld-exclude-05", "source-withheld-exclude-06",
    "source-withheld-exclude-07", "source-withheld-exclude-08", "source-withheld-exclude-09",
    "source-withheld-exclude-10", "source-withheld-exclude-11", "source-withheld-exclude-12",
    "source-withheld-exclude-13", "source-withheld-exclude-14", "source-withheld-exclude-15",
    "source-withheld-exclude-16", "source-withheld-exclude-17", "source-withheld-exclude-18",
    "source-withheld-exclude-19", "source-withheld-exclude-20", "source-withheld-exclude-21",
    "source-withheld-exclude-22", "source-withheld-exclude-23", "source-withheld-exclude-24",
    "source-withheld-exclude-25", "source-withheld-exclude-26", "source-withheld-exclude-27",
    "source-withheld-exclude-28", "source-withheld-exclude-29", "source-withheld-exclude-30",
    "source-withheld-exclude-31", "source-withheld-exclude-32", "source-withheld-exclude-33",
    "source-withheld-exclude-34", "source-withheld-exclude-35", "source-withheld-exclude-36",
    "source-withheld-exclude-37", "source-withheld-exclude-38", "source-withheld-exclude-39",
    "source-withheld-exclude-40", "source-withheld-exclude-41",
]
SUBSTITUTIONS = [
    ("# The Captain Workflow Rig \u2014 PORTABLE edition (project-specific content stripped)", "# Rig Atlas"),
    ("Claude Code", "Codex"),
    ("Claude", "Codex"),
    ("Jim", "the captain"),
    ("RunPlatform", "external run system"),
    ("ReviewBot", "external review bot"),
    ("Workflow-tool", "native-task-team"),
    ("Workflow tool", "native task-team workflow"),
    ("Workflow", "PDW"),
    ("PushNotification", "injected Command Center notification"),
    ("ScheduleWakeup", "scheduled task wake"),
    ("~/.claude/agents", ".codex/agents"),
    ("~/.claude/skills", ".agents/skills"),
    ("~/.claude", "<harness-home>"),
    ("Fable-5", "high-effort command-center model"),
    ("Fable", "high-effort model"),
    ("opus-pinned", "high-effort-routed"),
    ("opus", "high effort"),
]
LEAK_PATTERNS = {
    "human-name": re.compile(r"\bJim(?:'s)?\b", re.IGNORECASE),
    "claude-harness": re.compile(r"\bClaude(?: Code)?\b|~/\.claude"),
    "source-run-system": re.compile(r"\bRunPlatform\b", re.IGNORECASE),
    "source-review-bot": re.compile(r"\bReviewBot\b", re.IGNORECASE),
    "slash-skill": re.compile(r"(?<![\w$])/(pdw|build|scout|explore|websearch|lavish|oat|submit|rig-atlas)\b"),
}


def sha_bytes(value: bytes) -> str:
    return hashlib.sha256(value).hexdigest()


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


def adapt_text(text: str) -> tuple[str, dict[str, int]]:
    adapted = text
    counts: dict[str, int] = {}
    for old, new in SUBSTITUTIONS:
        count = adapted.count(old)
        if count:
            adapted = adapted.replace(old, new)
            counts[f"{old} -> {new}"] = count
    for skill in SPINE:
        pattern = re.compile(rf"(?<![\w$])/{re.escape(skill)}\b")
        adapted, count = pattern.subn(f"${skill}", adapted)
        if count:
            counts[f"/{skill} -> ${skill}"] = count
    for label, pattern, replacement in (
        ("user-jim -> captain-profile", re.compile(r"user-jim", re.IGNORECASE), "captain-profile"),
        ("case-insensitive human name -> the captain", re.compile(r"\bJim\b", re.IGNORECASE), "the captain"),
        ("case-insensitive Claude -> Codex", re.compile(r"\bClaude\b", re.IGNORECASE), "Codex"),
        ("case-insensitive RunPlatform -> external run system", re.compile(r"\bRunPlatform\b", re.IGNORECASE), "external run system"),
        ("case-insensitive ReviewBot -> external review bot", re.compile(r"\bReviewBot\b", re.IGNORECASE), "external review bot"),
    ):
        adapted, count = pattern.subn(replacement, adapted)
        if count:
            counts[label] = count
    return adapted, counts


def adapt_name(name: str) -> str:
    adapted = re.sub("claude", "codex", name, flags=re.IGNORECASE)
    adapted = re.sub("jim", "captain", adapted, flags=re.IGNORECASE)
    adapted = re.sub("runplatform", "external-run", adapted, flags=re.IGNORECASE)
    adapted = re.sub("reviewbot", "external-review", adapted, flags=re.IGNORECASE)
    return adapted


def leak_scan(text: str) -> list[str]:
    return [name for name, pattern in LEAK_PATTERNS.items() if pattern.search(text)]


def inspect(source: Path) -> tuple[dict[str, object], dict[str, str], str]:
    raw = source.read_bytes()
    text = raw.decode("utf-8")
    errors: list[str] = []
    digest = sha_bytes(raw)
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
    if len(EXCLUDED_BOTH) != 41 or len(set(EXCLUDED_BOTH)) != 41:
        errors.append("exclude-both classification enumeration is not exactly 41 unique entries")
    if skills != SPINE:
        errors.append("spine generator inventory differs from the nine-item source roster")
    if roles != ROLES:
        errors.append("role generator inventory differs from the three-item source roster")
    if set(bodies) != set(both):
        errors.append(f"Appendix D coverage mismatch: missing={sorted(set(both) - set(bodies))}, extra={sorted(set(bodies) - set(both))}")
    if set(bodies) & set(full_only):
        errors.append("Appendix D contains a full-only body")
    if "+ 41 excluded via opus-classified three-bucket rubric" not in text:
        errors.append("exclude-both count assertion is missing or changed")
    if REDACTION not in text or "portable twin needs the unredacted generator" not in text:
        errors.append("portable sanitizer redaction marker is missing or changed")
    appendix = text.find("## Appendix A")
    if appendix < 0:
        errors.append("source atlas main sections are missing")
        main_prose = ""
    else:
        main_prose = text[:appendix].rstrip()
    for heading in ("## 0. Current-state atlas", "## 1. System model", "## 2. Replication steps", "## 3. Adaptation pass", "## 4. Verification", "## 5. Operating rules"):
        if heading not in main_prose:
            errors.append(f"source atlas module missing: {heading}")
    inventory: dict[str, object] = {
        "source_sha256": digest,
        "source_line_ranges": ["1-244", "1222-1352", "1678-3055", "3057-3505"],
        "include_both": both,
        "full_only": full_only,
        "exclude_both": EXCLUDED_BOTH,
        "exclude_both_names_withheld_by_source": True,
        "spine_skills": skills,
        "roles": roles,
        "portable_sanitizer": "redacted",
        "substitution_rules": [f"{old} -> {new}" for old, new in SUBSTITUTIONS] + ["/skill -> $skill"],
        "errors": errors,
    }
    canonical = json.dumps(inventory, sort_keys=True, separators=(",", ":")).encode()
    inventory["integrity_sha256"] = sha_bytes(canonical)
    return inventory, bodies, main_prose


def write_runtime(state_dir: Path, inventory: dict[str, object], bodies: dict[str, str]) -> None:
    if inventory["errors"]:
        raise SystemExit("source audit failed; runtime was not written")
    memory_dir = state_dir / "portable-memory"
    memory_dir.mkdir(parents=True, exist_ok=True)
    for stale in memory_dir.glob("*.md"):
        stale.unlink()
    body_manifest: dict[str, object] = {}
    for name, body in sorted(bodies.items()):
        adapted, substitutions = adapt_text(body)
        leaks = leak_scan(adapted)
        if leaks:
            raise SystemExit(f"adapted memory leaked forbidden tokens: {name}: {leaks}")
        adapted_name = adapt_name(name)
        target = memory_dir / adapted_name
        target.write_text(adapted + "\n", encoding="utf-8")
        body_manifest[name] = {
            "adapted_name": adapted_name,
            "source_sha256": sha_bytes(body.encode()),
            "adapted_sha256": sha_bytes((adapted + "\n").encode()),
            "substitutions": substitutions,
        }
    runtime_inventory = dict(inventory)
    runtime_inventory["adapted_bodies"] = body_manifest
    canonical = json.dumps(runtime_inventory, sort_keys=True, separators=(",", ":")).encode()
    runtime_inventory["runtime_integrity_sha256"] = sha_bytes(canonical)
    (state_dir / "source-inventory.json").write_text(json.dumps(runtime_inventory, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    status = {
        "portable_twin": "BLOCKED",
        "reason": "The portable sanitizer contract is redacted in the supplied source.",
        "required_action": "Supply the unredacted sanitizer contract before implementation.",
    }
    (state_dir / "portable-status.json").write_text(json.dumps(status, indent=2, sort_keys=True) + "\n", encoding="utf-8")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("source", type=Path)
    parser.add_argument("--setup", type=Path)
    args = parser.parse_args()
    inventory, bodies, _ = inspect(args.source)
    if args.setup:
        write_runtime(args.setup, inventory, bodies)
    print(json.dumps(inventory, indent=2, sort_keys=True))
    return 1 if inventory["errors"] else 0


if __name__ == "__main__":
    sys.exit(main())

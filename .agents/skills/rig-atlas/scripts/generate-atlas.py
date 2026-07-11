#!/usr/bin/env python3
"""Generate the single full rig atlas from live repository files."""

from __future__ import annotations

import argparse
import hashlib
import json
import sys
from datetime import date
from pathlib import Path

SPINE = ["pdw", "build", "scout", "explore", "websearch", "lavish", "oat", "submit", "rig-atlas"]
ROLES = ["planner", "implementer", "refute-reviewer"]


def sha(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def live_files(root: Path) -> list[Path]:
    files: list[Path] = []
    for skill in SPINE:
        skill_dir = root / ".agents" / "skills" / skill
        for name in ("SKILL.md", "evals.md"):
            candidate = skill_dir / name
            if candidate.is_file():
                files.append(candidate)
        references = skill_dir / "references"
        if references.is_dir():
            files.extend(sorted(references.glob("*.md")))
    role_dir = root / ".codex" / "agents"
    for role in ROLES:
        candidate = role_dir / f"{role}.md"
        if candidate.is_file():
            files.append(candidate)
    for candidate in (
        root / ".codex" / "config.toml",
        root / ".codex" / "keybindings.json",
    ):
        if candidate.is_file():
            files.append(candidate)
    hooks = root / ".codex" / "hooks"
    if hooks.is_dir():
        files.extend(sorted(path for path in hooks.rglob("*") if path.is_file()))
    return sorted(set(files))


def generate(root: Path, state: Path) -> Path:
    inventory_path = state / "source-inventory.json"
    if not inventory_path.is_file():
        raise SystemExit("source inventory is missing; run setup-runtime.sh first")
    inventory = json.loads(inventory_path.read_text(encoding="utf-8"))
    if inventory.get("errors"):
        raise SystemExit("source inventory contains audit errors")
    files = live_files(root)
    lines = [
        "# Rig Atlas",
        "",
        f"Generated {date.today().isoformat()} from live repository files.",
        "This file is a build artifact and must not be hand-edited.",
        "",
        "## 0. Live inventory",
        "",
        "| Path | SHA-256 |",
        "| --- | --- |",
    ]
    for path in files:
        lines.append(f"| `{path.relative_to(root)}` | `{sha(path)}` |")
    lines.extend(
        [
            "",
            "## 1. Rig surfaces",
            "",
            "1. Skill suite and evals.",
            "2. Harness configuration and hooks.",
            "3. Role definitions.",
            "4. State and notes conventions.",
            "5. Curated memory classifications.",
            "",
            "## 2. Generator inventory",
            "",
            f"Spine skills: {', '.join(SPINE)}.",
            f"Roles: {', '.join(ROLES)}.",
            "References, harness files, hooks, curated memory metadata, and this generator are inventoried.",
            "",
            "## 3. Memory classification",
            "",
            f"Include-both: {len(inventory['include_both'])}.",
            f"Full-only: {len(inventory['full_only'])}.",
            f"Exclude-both: {inventory['exclude_both_count']}.",
            "Only include-both bodies supplied by the portable source exist in this installation.",
            "Full-only and excluded bodies are not copied.",
            "",
            "## 4. Live-document discipline",
            "",
            "Run five independent surface PDWs in parallel and one convergence PDW.",
            "Edit live sources or generator inputs, then regenerate this file.",
            "Do not hand-edit this file or create an unsanctioned sibling.",
            "",
            "## 5. Portable twin",
            "",
            "BLOCKED.",
            "The supplied company-repo-agnostic source redacts the sanitizer contract.",
            "No portable twin may be emitted until the unredacted sanitizer is supplied and a zero-leak scan passes.",
            "",
            "## Appendix A. Live files",
        ]
    )
    for path in files:
        rel = path.relative_to(root)
        lines.extend(["", f"### `{rel}`", "", "````text", path.read_text(encoding="utf-8").rstrip(), "````"])
    generator = Path(__file__)
    lines.extend(
        [
            "",
            "## Appendix B. Generator",
            "",
            f"Tracked generator: `{generator.relative_to(root)}`.",
            f"SHA-256: `{sha(generator)}`.",
            "",
        ]
    )
    state.mkdir(parents=True, exist_ok=True)
    output = state / "rig-atlas.md"
    output.write_text("\n".join(lines), encoding="utf-8")
    return output


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--repo-root", required=True, type=Path)
    parser.add_argument("--state-dir", type=Path)
    parser.add_argument("--portable", action="store_true")
    args = parser.parse_args()
    root = args.repo_root.resolve()
    state = args.state_dir.resolve() if args.state_dir else root / "state" / "rig"
    if args.portable:
        portable = state / "rig-atlas-portable.md"
        portable.unlink(missing_ok=True)
        print("BLOCKED: portable sanitizer is redacted; no twin was written", file=sys.stderr)
        return 2
    output = generate(root, state)
    print(f"written={output} bytes={output.stat().st_size}")
    return 0


if __name__ == "__main__":
    sys.exit(main())

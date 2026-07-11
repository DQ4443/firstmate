#!/usr/bin/env python3
"""Generate and verify the single complete rig atlas from live repository files."""

from __future__ import annotations

import argparse
import hashlib
import importlib.util
import json
import sys
from pathlib import Path

SCRIPT_DIR = Path(__file__).resolve().parent
SPEC = importlib.util.spec_from_file_location("rig_source_audit", SCRIPT_DIR / "source-audit.py")
if SPEC is None or SPEC.loader is None:
    raise SystemExit("cannot load source audit module")
AUDIT = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(AUDIT)
SPINE = AUDIT.SPINE
ROLES = AUDIT.ROLES


def sha_bytes(value: bytes) -> str:
    return hashlib.sha256(value).hexdigest()


def required_live_files(root: Path) -> tuple[list[Path], list[Path], list[Path]]:
    skills: list[Path] = []
    missing: list[str] = []
    for skill in SPINE:
        skill_dir = root / ".agents" / "skills" / skill
        primary = skill_dir / "SKILL.md"
        if not primary.is_file():
            missing.append(str(primary.relative_to(root)))
            continue
        skills.append(primary)
        evals = skill_dir / "evals.md"
        if evals.is_file():
            skills.append(evals)
        references = skill_dir / "references"
        if references.is_dir():
            skills.extend(sorted(references.glob("*.md")))
        scripts = skill_dir / "scripts"
        if scripts.is_dir():
            skills.extend(sorted(path for path in scripts.rglob("*") if path.is_file()))
    roles: list[Path] = []
    for role in ROLES:
        candidate = root / ".codex" / "agents" / f"{role}.toml"
        if not candidate.is_file():
            missing.append(str(candidate.relative_to(root)))
        else:
            roles.append(candidate)
    if missing:
        raise ValueError(f"incomplete live rig: missing required files: {', '.join(missing)}")
    harness: list[Path] = []
    config = root / ".codex" / "config.toml"
    if config.is_file():
        harness.append(config)
    hook_declaration = root / ".codex" / "hooks.json"
    if hook_declaration.is_file():
        harness.append(hook_declaration)
    hooks = root / ".codex" / "hooks"
    if hooks.is_dir():
        harness.extend(sorted(path for path in hooks.rglob("*") if path.is_file()))
    return sorted(skills), sorted(roles), sorted(harness)


def append_files(lines: list[str], heading: str, root: Path, files: list[Path]) -> None:
    lines.extend(["", heading])
    for path in files:
        relative = path.relative_to(root)
        lines.extend(["", f"### `{relative}`", "", "````text", path.read_text(encoding="utf-8").rstrip(), "````"])


def expected_atlas(root: Path, state: Path, source: Path) -> tuple[bytes, dict[str, str]]:
    inventory, source_bodies, main_prose = AUDIT.inspect(source)
    if inventory["errors"]:
        raise ValueError(f"source audit failed: {inventory['errors']}")
    skills, roles, harness = required_live_files(root)
    memory_dir = state / "portable-memory"
    memory_inputs: list[Path] = []
    for name in inventory["include_both"]:
        candidate = memory_dir / AUDIT.adapt_name(name)
        if not candidate.is_file():
            raise ValueError(f"adapted portable memory is missing: {name}")
        expected, _ = AUDIT.adapt_text(source_bodies[name])
        expected_bytes = (expected + "\n").encode()
        if candidate.read_bytes() != expected_bytes:
            raise ValueError(f"adapted portable memory failed re-derivation: {name}")
        leaks = AUDIT.leak_scan(candidate.read_text(encoding="utf-8"))
        if leaks:
            raise ValueError(f"adapted portable memory leaked forbidden tokens: {name}: {leaks}")
        memory_inputs.append(candidate)
    adapted_prose, substitutions = AUDIT.adapt_text(main_prose)
    prose_leaks = AUDIT.leak_scan(adapted_prose)
    if prose_leaks:
        raise ValueError(f"adapted atlas prose leaked forbidden tokens: {prose_leaks}")
    lines = [adapted_prose, "", "## Adaptation manifest", "", "The source prose and all include-both memories use explicit human and harness substitutions.", ""]
    for rule, count in sorted(substitutions.items()):
        lines.append(f"- `{rule}`: {count}")
    append_files(lines, "## Appendix A: nine spine skills and their live references", root, skills)
    append_files(lines, "## Appendix B: three Codex role definitions", root, roles)
    append_files(lines, "## Appendix C: live Codex harness configuration and hooks", root, harness)
    lines.extend(["", "## Appendix D: curated adapted memories", "", "### Include-both classifications"])
    for path in memory_inputs:
        lines.extend(["", f"#### `memory/{path.name}`", "", "````markdown", path.read_text(encoding="utf-8").rstrip(), "````"])
    lines.extend(["", "### Full-only classifications", ""])
    for name in inventory["full_only"]:
        opaque = sha_bytes(name.encode())[:12]
        lines.append(f"- `source-full-only-{opaque}`: body and source identity intentionally absent")
    lines.extend(["", "### Exclude-both classifications", "", "The portable source withholds excluded filenames and bodies, so these opaque source slots remain excluded without guessed identities.", ""])
    for name in inventory["exclude_both"]:
        lines.append(f"- `{name}`: excluded unconditionally, source identity withheld")
    generator = Path(__file__).resolve()
    try:
        generator_label = generator.relative_to(root)
    except ValueError:
        generator_label = generator
    lines.extend(["", "## Appendix E: this document's generator", "", f"Tracked generator: `{generator_label}`.", "", "````python", generator.read_text(encoding="utf-8").rstrip(), "````", ""])
    output = "\n".join(lines).encode()
    inputs = {str(path.relative_to(root)): sha_bytes(path.read_bytes()) for path in skills + roles + harness}
    inputs.update({f"state/rig/portable-memory/{path.name}": sha_bytes(path.read_bytes()) for path in memory_inputs})
    inputs["source"] = inventory["source_sha256"]
    return output, inputs


def write_full(root: Path, state: Path, source: Path) -> Path:
    output_bytes, inputs = expected_atlas(root, state, source)
    state.mkdir(parents=True, exist_ok=True)
    output = state / "rig-atlas.md"
    output.write_bytes(output_bytes)
    integrity = {
        "output": "rig-atlas.md",
        "output_sha256": sha_bytes(output_bytes),
        "inputs": inputs,
        "generator_sha256": sha_bytes(Path(__file__).read_bytes()),
    }
    (state / "rig-atlas.integrity.json").write_text(json.dumps(integrity, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    return output


def verify(root: Path, state: Path, source: Path) -> None:
    output = state / "rig-atlas.md"
    integrity_path = state / "rig-atlas.integrity.json"
    if not output.is_file() or not integrity_path.is_file():
        raise ValueError("generated atlas or integrity record is missing")
    expected, inputs = expected_atlas(root, state, source)
    integrity = json.loads(integrity_path.read_text(encoding="utf-8"))
    if output.read_bytes() != expected:
        raise ValueError("generated atlas differs from deterministic regeneration")
    if integrity.get("output_sha256") != sha_bytes(expected):
        raise ValueError("generated atlas integrity hash is invalid")
    if integrity.get("inputs") != inputs:
        raise ValueError("generated atlas input manifest is invalid")
    if integrity.get("generator_sha256") != sha_bytes(Path(__file__).read_bytes()):
        raise ValueError("generated atlas generator hash is invalid")
    if integrity.get("output") != "rig-atlas.md":
        raise ValueError("generated atlas ownership record is invalid")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--repo-root", required=True, type=Path)
    parser.add_argument("--state-dir", type=Path)
    parser.add_argument("--source", required=True, type=Path)
    parser.add_argument("--portable", action="store_true")
    parser.add_argument("--verify", action="store_true")
    args = parser.parse_args()
    root = args.repo_root.resolve()
    state = args.state_dir.resolve() if args.state_dir else root / "state" / "rig"
    if args.portable:
        (state / "rig-atlas-portable.md").unlink(missing_ok=True)
        print("BLOCKED: portable sanitizer is redacted; no twin was written", file=sys.stderr)
        return 2
    try:
        if args.verify:
            verify(root, state, args.source)
            print("verified=rig-atlas.md")
        else:
            output = write_full(root, state, args.source)
            print(f"written={output} bytes={output.stat().st_size}")
    except (OSError, ValueError, json.JSONDecodeError) as error:
        print(f"ERROR: {error}", file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main())

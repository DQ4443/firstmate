#!/usr/bin/env python3
"""Generate and verify a deterministic Jim-source to Codex-target adaptation diff."""

from __future__ import annotations

import argparse
import difflib
import hashlib
import importlib.util
import json
import re
import sys
from pathlib import Path

SCRIPT_DIR = Path(__file__).resolve().parent
SPEC = importlib.util.spec_from_file_location("rig_source_audit", SCRIPT_DIR / "source-audit.py")
if SPEC is None or SPEC.loader is None:
    raise SystemExit("cannot load source audit module")
AUDIT = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(AUDIT)


def sha(value: bytes) -> str:
    return hashlib.sha256(value).hexdigest()


def source_block(text: str, label: str) -> str:
    heading = re.search(rf"^### `{re.escape(label)}`[^\n]*\n", text, re.MULTILINE)
    if not heading:
        raise ValueError(f"source section is missing: {label}")
    fence = re.search(r"(`{4,})(?:markdown|python|json|bash)?\n(.*?)\n\1", text[heading.end():], re.DOTALL)
    if not fence:
        raise ValueError(f"source fenced body is missing: {label}")
    return fence.group(2).rstrip() + "\n"


def targets(root: Path) -> list[tuple[str, str, Path]]:
    records: list[tuple[str, str, Path]] = []
    for skill in AUDIT.SPINE:
        for filename in ("SKILL.md", "evals.md"):
            target = root / ".agents" / "skills" / skill / filename
            if target.is_file():
                records.append((f"~/.claude/skills/{skill}/{filename}", str(target.relative_to(root)), target))
    for role in AUDIT.ROLES:
        records.append((f"~/.claude/agents/{role}.md", f".codex/agents/{role}.toml", root / ".codex" / "agents" / f"{role}.toml"))
    records.append(("~/.claude/hooks/git-guard.py", ".codex/hooks/git-guard.py", root / ".codex" / "hooks" / "git-guard.py"))
    return records


def expected(root: Path, source: Path) -> tuple[bytes, dict[str, object]]:
    source_bytes = source.read_bytes()
    if sha(source_bytes) != AUDIT.PINNED_SHA256:
        raise ValueError("source digest differs from the pin")
    text = source_bytes.decode("utf-8")
    lines = [
        "# Jim source to Codex adaptation diff",
        "",
        f"source_sha256={sha(source_bytes)}",
        "carrier=unified-diff-over-explicit-source-sections-and-live-targets",
        "",
        "## Declared substitutions",
        "",
    ]
    for old, new in AUDIT.SUBSTITUTIONS:
        lines.append(f"{old} -> {new}")
    lines.append("/skill -> $skill")
    manifest: dict[str, object] = {"source_sha256": sha(source_bytes), "substitutions": [list(item) for item in AUDIT.SUBSTITUTIONS] + [["/skill", "$skill"]], "targets": {}}
    for source_label, target_label, target in targets(root):
        if not target.is_file():
            raise ValueError(f"adaptation target is missing: {target_label}")
        raw_source = source_block(text, source_label)
        adapted_source, applied = AUDIT.adapt_text(raw_source)
        target_text = target.read_text(encoding="utf-8")
        diff = list(difflib.unified_diff(adapted_source.splitlines(), target_text.splitlines(), fromfile=f"jim:{source_label}", tofile=f"codex:{target_label}", lineterm=""))
        lines.extend(["", f"## {target_label}", "", *diff])
        manifest["targets"][target_label] = {
            "source_label": source_label,
            "source_sha256": sha(raw_source.encode()),
            "adapted_source_sha256": sha(adapted_source.encode()),
            "target_sha256": sha(target_text.encode()),
            "applied_substitutions": applied,
        }
    hook_start = text.index("## Appendix C")
    hook_end = text.index("### `~/.claude/hooks/git-guard.py`", hook_start)
    hook_source = text[hook_start:hook_end].rstrip() + "\n"
    hook_target = root / ".codex" / "hooks.json"
    if not hook_target.is_file():
        raise ValueError("adaptation target is missing: .codex/hooks.json")
    adapted_hook, applied_hook = AUDIT.adapt_text(hook_source)
    hook_target_text = hook_target.read_text(encoding="utf-8")
    hook_diff = list(difflib.unified_diff(adapted_hook.splitlines(), hook_target_text.splitlines(), fromfile="jim:Appendix-C-hook-declaration", tofile="codex:.codex/hooks.json", lineterm=""))
    lines.extend(["", "## .codex/hooks.json", "", *hook_diff, ""])
    manifest["targets"][".codex/hooks.json"] = {
        "source_label": "Appendix C hook declaration",
        "source_sha256": sha(hook_source.encode()),
        "adapted_source_sha256": sha(adapted_hook.encode()),
        "target_sha256": sha(hook_target_text.encode()),
        "applied_substitutions": applied_hook,
    }
    output = "\n".join(lines).encode()
    manifest["output_sha256"] = sha(output)
    manifest["generator_sha256"] = sha(Path(__file__).read_bytes())
    return output, manifest


def write(root: Path, state: Path, source: Path) -> None:
    output, manifest = expected(root, source)
    state.mkdir(parents=True, exist_ok=True)
    (state / "source-adaptation.diff").write_bytes(output)
    (state / "source-adaptation.integrity.json").write_text(json.dumps(manifest, indent=2, sort_keys=True) + "\n", encoding="utf-8")


def verify(root: Path, state: Path, source: Path) -> None:
    output, manifest = expected(root, source)
    output_path = state / "source-adaptation.diff"
    integrity_path = state / "source-adaptation.integrity.json"
    if not output_path.is_file() or not integrity_path.is_file():
        raise ValueError("source adaptation output or integrity metadata is missing")
    if output_path.read_bytes() != output:
        raise ValueError("source adaptation diff is stale")
    if json.loads(integrity_path.read_text(encoding="utf-8")) != manifest:
        raise ValueError("source adaptation integrity metadata is stale")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--repo-root", required=True, type=Path)
    parser.add_argument("--state-dir", required=True, type=Path)
    parser.add_argument("--source", required=True, type=Path)
    parser.add_argument("--verify", action="store_true")
    args = parser.parse_args()
    try:
        if args.verify:
            verify(args.repo_root.resolve(), args.state_dir.resolve(), args.source.resolve())
            print("verified=source-adaptation.diff")
        else:
            write(args.repo_root.resolve(), args.state_dir.resolve(), args.source.resolve())
            print("written=source-adaptation.diff")
    except (OSError, ValueError, json.JSONDecodeError) as error:
        print(f"ERROR: {error}", file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main())

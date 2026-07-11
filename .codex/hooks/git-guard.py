#!/usr/bin/env python3
"""Guard Codex shell calls against the repository's gated git operations.

Codex PreToolUse sends the unified shell command in ``tool_input.cmd``.
The legacy ``tool_input.command`` field is accepted as a compatibility input.
Malformed input and local inspection failures are fail-open, matching Jim's guard.
An intentional policy rejection exits 2 and writes its reason to stderr.

The pull request sentinel defaults to ``codex-submit-pr-go`` inside this
worktree's git metadata.
Set ``CODEX_SUBMIT_SENTINEL`` to an absolute path or a repository-relative path
when an operator needs a different portable location.
"""

from __future__ import annotations

import json
import os
from pathlib import Path
import re
import shlex
import subprocess
import sys
from typing import Iterable


BLOCKED_BRANCHES = {"main", "master"}
GENERATED_ATTRIBUTION = re.compile(
    r"co-authored-by\s*:|generated(?:\s+|-)(?:by|with)\b",
    re.IGNORECASE,
)
SHELL_SEPARATORS = {";", "&", "&&", "|", "||"}


def git(cwd: Path, *args: str) -> tuple[int, str]:
    try:
        result = subprocess.run(
            ["git", *args],
            cwd=cwd,
            capture_output=True,
            text=True,
            timeout=5,
            check=False,
        )
        return result.returncode, result.stdout.strip()
    except Exception:
        return 1, ""


def block(message: str) -> int:
    print(f"BLOCKED: {message}", file=sys.stderr)
    return 2


def shell_segments(command: str, depth: int = 0) -> list[list[str]]:
    lexer = shlex.shlex(command, posix=True, punctuation_chars=";&|")
    lexer.whitespace_split = True
    lexer.commenters = ""
    segments: list[list[str]] = []
    current: list[str] = []
    for token in lexer:
        if token in SHELL_SEPARATORS:
            if current:
                segments.append(current)
                current = []
            continue
        current.append(token)
    if current:
        segments.append(current)
    if depth >= 3:
        return segments

    expanded: list[list[str]] = []
    for segment in segments:
        expanded.append(segment)
        for index, token in enumerate(segment):
            if Path(token).name in {"bash", "sh", "zsh"}:
                if index + 2 < len(segment) and segment[index + 1] == "-c":
                    expanded.extend(shell_segments(segment[index + 2], depth + 1))
            if token == "eval" and index + 1 < len(segment):
                expanded.extend(shell_segments(segment[index + 1], depth + 1))
    return expanded


def resolved_path(base: Path, value: str) -> Path:
    path = Path(os.path.expandvars(os.path.expanduser(value)))
    if not path.is_absolute():
        path = base / path
    return path.resolve(strict=False)


def segment_cwd(tokens: list[str], current: Path) -> Path:
    if len(tokens) >= 2 and tokens[0] == "cd":
        return resolved_path(current, tokens[1])
    return current


def git_actions(tokens: list[str], current: Path) -> Iterable[tuple[str, list[str], Path]]:
    for index, token in enumerate(tokens):
        if Path(token).name != "git":
            continue
        cursor = index + 1
        repo = current
        while cursor < len(tokens):
            option = tokens[cursor]
            if option == "-C" and cursor + 1 < len(tokens):
                repo = resolved_path(current, tokens[cursor + 1])
                cursor += 2
                continue
            if option.startswith("-C") and len(option) > 2:
                repo = resolved_path(current, option[2:])
                cursor += 1
                continue
            if option in {"--git-dir", "--work-tree", "-c"} and cursor + 1 < len(tokens):
                cursor += 2
                continue
            if option.startswith("--git-dir=") or option.startswith("--work-tree="):
                cursor += 1
                continue
            if option.startswith("-"):
                cursor += 1
                continue
            break
        if cursor < len(tokens):
            yield tokens[cursor], tokens[cursor + 1 :], repo


def current_branch(repo: Path) -> str:
    status, branch = git(repo, "rev-parse", "--abbrev-ref", "HEAD")
    return branch if status == 0 else ""


def push_positionals(arguments: list[str]) -> tuple[list[str], bool]:
    positionals: list[str] = []
    broad_push = False
    options_with_values = {
        "-o",
        "--push-option",
        "--receive-pack",
        "--exec",
    }
    cursor = 0
    while cursor < len(arguments):
        token = arguments[cursor]
        if token == "--":
            positionals.extend(arguments[cursor + 1 :])
            break
        if token in {"--all", "--mirror"}:
            broad_push = True
            cursor += 1
            continue
        if token in options_with_values and cursor + 1 < len(arguments):
            cursor += 2
            continue
        if any(token.startswith(f"{option}=") for option in options_with_values):
            cursor += 1
            continue
        if token.startswith("-"):
            cursor += 1
            continue
        positionals.append(token)
        cursor += 1
    return positionals, broad_push


def ref_targets_protected(refspec: str, on_protected_branch: bool) -> bool:
    refspec = refspec.lstrip("+")
    target = refspec.rsplit(":", 1)[-1]
    if target.startswith("refs/heads/"):
        target = target.removeprefix("refs/heads/")
    return target in BLOCKED_BRANCHES or (target == "HEAD" and on_protected_branch)


def push_updates_protected(arguments: list[str], repo: Path) -> bool:
    branch = current_branch(repo)
    on_protected = branch in BLOCKED_BRANCHES
    positionals, broad_push = push_positionals(arguments)
    if broad_push:
        return True
    refspecs = positionals[1:] if positionals else []
    if not refspecs:
        return on_protected
    return any(ref_targets_protected(refspec, on_protected) for refspec in refspecs)


def message_file(arguments: list[str], repo: Path) -> str:
    for index, token in enumerate(arguments):
        value = ""
        if token in {"-F", "--file"} and index + 1 < len(arguments):
            value = arguments[index + 1]
        elif token.startswith("--file="):
            value = token.split("=", 1)[1]
        if not value:
            continue
        try:
            return resolved_path(repo, value).read_text(encoding="utf-8")
        except (OSError, UnicodeError):
            return ""
    return ""


def is_pushed_head(repo: Path) -> bool:
    status, upstream = git(repo, "rev-parse", "@{u}")
    if status != 0 or not upstream:
        return False
    ancestor, _ = git(repo, "merge-base", "--is-ancestor", "HEAD", upstream)
    return ancestor == 0


def pr_create_count(tokens: list[str]) -> int:
    count = 0
    for index, token in enumerate(tokens):
        if Path(token).name not in {"gh", "gh-axi"}:
            continue
        for cursor in range(index + 1, len(tokens) - 1):
            if tokens[cursor] == "pr" and tokens[cursor + 1] == "create":
                count += 1
                break
    return count


def default_sentinel(repo: Path) -> Path:
    configured = os.environ.get("CODEX_SUBMIT_SENTINEL", "")
    root_status, root = git(repo, "rev-parse", "--show-toplevel")
    project_root = Path(root) if root_status == 0 and root else repo
    if configured:
        return resolved_path(project_root, configured)
    status, git_path = git(repo, "rev-parse", "--git-path", "codex-submit-pr-go")
    if status == 0 and git_path:
        return resolved_path(repo, git_path)
    return project_root / ".codex-submit-pr-go"


def check(command: str, cwd: Path) -> int:
    segments = shell_segments(command)
    active_cwd = cwd
    pr_creates: list[Path] = []

    for tokens in segments:
        if len(tokens) >= 2 and tokens[0] == "cd":
            active_cwd = segment_cwd(tokens, active_cwd)
            if len(tokens) == 2:
                continue

        pr_creates.extend([active_cwd] * pr_create_count(tokens))

        for verb, arguments, repo in git_actions(tokens, active_cwd):
            if verb == "push" and push_updates_protected(arguments, repo):
                return block("this push can update main or master; push a work branch instead")

            if verb != "commit":
                continue

            command_text = " ".join(arguments)
            file_text = message_file(arguments, repo)
            if GENERATED_ATTRIBUTION.search(command_text) or GENERATED_ATTRIBUTION.search(file_text):
                return block("commit messages may not contain co-author or generated-by attribution")

            if any(argument == "--amend" or argument.startswith("--amend=") for argument in arguments):
                if is_pushed_head(repo):
                    return block("HEAD is already on its upstream; make a follow-up commit")

    if len(pr_creates) > 1:
        return block("one submit sentinel authorizes exactly one pull-request creation command")
    if pr_creates:
        sentinel = default_sentinel(pr_creates[0])
        if not sentinel.exists():
            return block(
                "pull-request creation requires explicit approval and the one-shot submit sentinel"
            )
        try:
            sentinel.unlink()
        except OSError:
            return block("the submit sentinel could not be consumed safely")

    return 0


def main() -> int:
    try:
        payload = json.load(sys.stdin)
    except Exception:
        return 0

    try:
        tool_input = payload.get("tool_input") or {}
        command = tool_input.get("cmd") or tool_input.get("command") or ""
        cwd = Path(payload.get("cwd") or os.getcwd())
        if not isinstance(command, str) or not command:
            return 0
        return check(command, cwd)
    except Exception:
        return 0


if __name__ == "__main__":
    raise SystemExit(main())

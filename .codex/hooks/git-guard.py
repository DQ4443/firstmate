#!/usr/bin/env python3
"""Guard Codex shell calls against the repository's gated git operations.

Codex PreToolUse sends Bash commands in ``tool_input.command``.
The desktop unified-exec ``tool_input.cmd`` field is accepted secondarily.
Malformed input and local inspection failures are fail-open, matching Jim's guard.
An intentional policy rejection exits 2 and writes its reason to stderr.

The pull request sentinel defaults to ``codex-submit-pr-go`` inside this
worktree's git metadata.
Set ``CODEX_SUBMIT_SENTINEL`` to an absolute path or a repository-relative path
when an operator needs a different portable location.
"""

from __future__ import annotations

from collections import deque
import fnmatch
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
SHELL_NAMES = {"bash", "sh", "zsh"}
SHELL_OPTIONS_WITH_VALUES = {"-O", "+O", "-o", "+o", "--init-file", "--rcfile"}
MAX_SHELL_DEPTH = 32
MAX_INSPECTION_BYTES = 1_000_000
INSPECTION_BUDGET_FACTOR = 40


class ShellInspectionLimit(Exception):
    """Raised when nested shell inspection reaches its fail-closed limit."""


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


def split_shell_segments(command: str) -> list[list[str]]:
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
    return segments


def nested_shell_command(segment: list[str]) -> str | None:
    wrapper_index: int | None = None
    wrapper_name = ""
    for index, token in enumerate(segment):
        name = Path(token).name
        if name in SHELL_NAMES or token == "eval":
            wrapper_index = index
            wrapper_name = name if name in SHELL_NAMES else token
            break
    if wrapper_index is None:
        return None

    cursor = wrapper_index + 1
    if wrapper_name == "eval":
        if cursor < len(segment) and segment[cursor] == "--":
            cursor += 1
        return " ".join(segment[cursor:]) if cursor < len(segment) else None

    while cursor < len(segment):
        option = segment[cursor]
        if option in SHELL_OPTIONS_WITH_VALUES:
            cursor += 2
            continue
        if option == "--":
            return None
        if option.startswith("--"):
            cursor += 1
            continue
        if option.startswith(("-", "+")):
            flags = option[1:]
            if "c" in flags:
                return segment[cursor + 1] if cursor + 1 < len(segment) else None
            cursor += 1
            continue
        return None
    return None


def shell_segments(command: str) -> list[list[str]]:
    queue: deque[tuple[str, int]] = deque([(command, 0)])
    seen: set[str] = set()
    expanded: list[list[str]] = []
    inspected = 0
    budget = min(
        MAX_INSPECTION_BYTES,
        max(4096, len(command) * INSPECTION_BUDGET_FACTOR),
    )
    while queue:
        current, depth = queue.popleft()
        if current in seen:
            continue
        if depth > MAX_SHELL_DEPTH:
            raise ShellInspectionLimit
        seen.add(current)
        segments = split_shell_segments(current)
        inspected += len(current) + sum(len(segment) for segment in segments)
        if inspected > budget:
            raise ShellInspectionLimit
        expanded.extend(segments)
        for segment in segments:
            nested = nested_shell_command(segment)
            if nested:
                queue.append((nested, depth + 1))
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
    protected_targets = {
        "main",
        "master",
        "refs/heads/main",
        "refs/heads/master",
    }
    if any(fnmatch.fnmatchcase(protected, target) for protected in protected_targets):
        return True
    if target.startswith("refs/heads/"):
        target = target.removeprefix("refs/heads/")
    return target in BLOCKED_BRANCHES or (target == "HEAD" and on_protected_branch)


def configured_push_refspecs(repo: Path, remote: str | None) -> list[str]:
    selected = remote
    if not selected:
        branch = current_branch(repo)
        keys = []
        if branch:
            keys.append(f"branch.{branch}.pushRemote")
        keys.append("remote.pushDefault")
        if branch:
            keys.append(f"branch.{branch}.remote")
        for key in keys:
            status, value = git(repo, "config", "--get", key)
            if status == 0 and value and value != ".":
                selected = value
                break
    if not selected:
        status, remotes = git(repo, "remote")
        names = remotes.splitlines() if status == 0 else []
        if len(names) == 1:
            selected = names[0]
    if selected:
        status, values = git(repo, "config", "--get-all", f"remote.{selected}.push")
        return values.splitlines() if status == 0 and values else []

    status, values = git(repo, "config", "--get-regexp", r"^remote\..*\.push$")
    if status != 0:
        return []
    return [line.split(None, 1)[1] for line in values.splitlines() if len(line.split(None, 1)) == 2]


def push_updates_protected(arguments: list[str], repo: Path) -> bool:
    branch = current_branch(repo)
    on_protected = branch in BLOCKED_BRANCHES
    positionals, broad_push = push_positionals(arguments)
    if broad_push:
        return True
    remote = positionals[0] if positionals else None
    refspecs = positionals[1:] if positionals else []
    if not refspecs:
        refspecs = configured_push_refspecs(repo, remote)
        return on_protected or any(
            ref_targets_protected(refspec, on_protected) for refspec in refspecs
        )
    return any(ref_targets_protected(refspec, on_protected) for refspec in refspecs)


def message_file(arguments: list[str], repo: Path) -> tuple[str, bool]:
    for index, token in enumerate(arguments):
        value = ""
        if token in {"-F", "--file"} and index + 1 < len(arguments):
            value = arguments[index + 1]
        elif token.startswith("-F") and len(token) > 2:
            value = token[2:]
        elif token.startswith("--file="):
            value = token.split("=", 1)[1]
        if not value:
            continue
        if value in {"-", "/dev/stdin", "/dev/fd/0"}:
            return "", True
        try:
            return resolved_path(repo, value).read_text(encoding="utf-8"), False
        except (OSError, UnicodeError):
            return "", False
    return "", False


def is_pushed_head(repo: Path) -> bool:
    status, upstream = git(repo, "rev-parse", "@{u}")
    if status != 0 or not upstream:
        return False
    ancestor, _ = git(repo, "merge-base", "--is-ancestor", "HEAD", upstream)
    return ancestor == 0


def normalized_executable(token: str) -> str:
    name = Path(token).name
    if name.startswith("gh-axi@"):
        return "gh-axi"
    return name


def pr_action_count(tokens: list[str]) -> int:
    count = 0
    for index, token in enumerate(tokens):
        if normalized_executable(token) not in {"gh", "gh-axi"}:
            continue
        for cursor in range(index + 1, len(tokens) - 1):
            if tokens[cursor] == "pr" and tokens[cursor + 1] in {"create", "ready"}:
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
    pr_actions: list[Path] = []

    for tokens in segments:
        if len(tokens) >= 2 and tokens[0] == "cd":
            active_cwd = segment_cwd(tokens, active_cwd)
            if len(tokens) == 2:
                continue

        pr_actions.extend([active_cwd] * pr_action_count(tokens))

        for verb, arguments, repo in git_actions(tokens, active_cwd):
            if verb == "push" and push_updates_protected(arguments, repo):
                return block("this push can update main or master; push a work branch instead")

            if verb != "commit":
                continue

            command_text = " ".join(arguments)
            file_text, stdin_message = message_file(arguments, repo)
            if stdin_message:
                return block("stdin-sourced commit messages cannot be inspected safely")
            if GENERATED_ATTRIBUTION.search(command_text) or GENERATED_ATTRIBUTION.search(file_text):
                return block("commit messages may not contain co-author or generated-by attribution")

            if any(argument == "--amend" or argument.startswith("--amend=") for argument in arguments):
                if is_pushed_head(repo):
                    return block("HEAD is already on its upstream; make a follow-up commit")

    if len(pr_actions) > 1:
        return block("one submit sentinel authorizes exactly one pull-request action")
    if pr_actions:
        sentinel = default_sentinel(pr_actions[0])
        if not sentinel.exists():
            return block(
                "pull-request creation or readiness requires explicit approval and the one-shot submit sentinel"
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
        command = tool_input.get("command") or tool_input.get("cmd") or ""
        cwd = Path(payload.get("cwd") or os.getcwd())
        if not isinstance(command, str) or not command:
            return 0
        return check(command, cwd)
    except ShellInspectionLimit:
        return block("nested shell command exceeded the safe inspection depth")
    except Exception:
        return 0


if __name__ == "__main__":
    raise SystemExit(main())

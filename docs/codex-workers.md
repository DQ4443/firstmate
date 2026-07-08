# Codex Workers

Firstmate stays the Claude orchestrator.
Codex workers run heavy build and review work on GPT-5.5 through `codex-cli`.
The split is orchestrate on Claude, build on GPT, and review on GPT.

## Build Worker

Use `bin/fm-codex-build.sh <task-id> <repo-dir> <brief-file> [--base <branch>]` for caller-orchestrated writing work.
The script creates `<repo-dir>/.claude/worktrees/<task-id>` on `feat/<task-id>` from the requested base, defaulting to the repository default branch.
It then runs `codex exec --model gpt-5.5 -c model_reasoning_effort=xhigh --sandbox workspace-write --skip-git-repo-check -C <worktree> <brief>`.
After Codex returns, the script requires at least one commit beyond the base and a clean worktree.
It emits one JSON object with the task id, status, repo, worktree, branch, base, commit sha, and reason.
It never pushes and never merges.

## Review Worker

Use `bin/fm-codex-review.sh <repo-dir> <review-brief-file> [--diff-base <ref>]` for read-only review or research fan-out.
The default diff base is `main`.
The script runs Codex with `--sandbox read-only` in the target repository.
Its prompt tells the GPT-5.5 parent to spawn parallel correctness, security, and regression subagents, then consolidate the review.
It emits one JSON object with `repo`, `diff_base`, `findings`, and `verdict`.
The verdict is `pass` only when the consolidated finding list is empty.

## Lifecycle

Build worktrees are real git worktrees under the repository's `.claude/worktrees/` directory.
They are not temporary directories or scratchpads.
Unlanded build worktrees remain subject to `bin/fm-teardown.sh --worktree <path>`, which refuses disposal unless the work has landed or the caller has explicit discard authority.

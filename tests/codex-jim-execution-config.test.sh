#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)

grep -Fq 'Only an explicit execute instruction for the agreed plan authorizes writes.' "$ROOT/.codex/agents/implementer.toml"
grep -Fq 'A question about whether there is a better design requires analysis and a recommendation without edits.' "$ROOT/.codex/agents/implementer.toml"
printf 'ok - implementer role carries the authorization fence\n'

if ! command -v codex >/dev/null 2>&1; then
  printf 'ok - installed Codex loader probe skipped because codex CLI is absent\n'
  exit 0
fi

python3 - "$ROOT" <<'PY'
import json
import os
import pathlib
import shutil
import subprocess
import sys
import tempfile

root = pathlib.Path(sys.argv[1]).resolve()

def read_config(home, cwd, probe_discovery=False):
    env = os.environ.copy()
    env["CODEX_HOME"] = str(home)
    process = subprocess.Popen(
        ["codex", "app-server", "--stdio"],
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        env=env,
    )

    def call(identifier, method, params):
        process.stdin.write(json.dumps({"id": identifier, "method": method, "params": params}) + "\n")
        process.stdin.flush()
        while True:
            line = process.stdout.readline()
            if not line:
                raise AssertionError(process.stderr.read())
            response = json.loads(line)
            if response.get("id") == identifier:
                return response["result"]

    call(1, "initialize", {"clientInfo": {"name": "config-test", "version": "1"}, "capabilities": {}})
    result = call(2, "config/read", {"cwd": str(cwd), "includeLayers": True})
    discovery = None
    if probe_discovery:
        skills = call(3, "skills/list", {"cwds": [str(cwd)], "forceReload": True})
        thread = call(4, "thread/start", {"cwd": str(cwd), "ephemeral": True})
        discovery = {"skills": skills, "thread": thread}
    process.terminate()
    process.wait(timeout=5)
    return result["config"], discovery

common_dir = pathlib.Path(subprocess.run(
    ["git", "rev-parse", "--git-common-dir"],
    cwd=root,
    check=True,
    text=True,
    capture_output=True,
).stdout.strip())
if not common_dir.is_absolute():
    common_dir = root / common_dir
canonical_repo_root = common_dir.resolve().parent

home = pathlib.Path(tempfile.mkdtemp(prefix="codex-loader-"))
try:
    home.joinpath("config.toml").write_text(f'[projects."{canonical_repo_root}"]\ntrust_level = "trusted"\n')
    config, discovery = read_config(home, root, probe_discovery=True)
    assert config["model"] == "gpt-5.6-sol"
    assert config["model_reasoning_effort"] == "high"
    assert set(config["agents"].keys()) >= {"planner", "implementer", "refute-reviewer"}
    for role in ("planner", "implementer", "refute-reviewer"):
        target = pathlib.Path(config["agents"][role]["config_file"])
        assert target.is_file(), target
    expected_skills = {"build", "pdw", "scout", "explore", "websearch", "lavish", "oat", "submit", "rig-atlas"}
    assert discovery is not None
    entries = discovery["skills"]["data"]
    assert len(entries) == 1
    assert entries[0]["errors"] == []
    repo_skills = {skill["name"]: skill for skill in entries[0]["skills"] if skill["scope"] == "repo"}
    assert expected_skills <= repo_skills.keys()
    for name in expected_skills:
        skill = repo_skills[name]
        assert skill["enabled"] is True
        assert pathlib.Path(skill["path"]).resolve() == root / ".agents" / "skills" / name / "SKILL.md"
    instruction_sources = {pathlib.Path(path).resolve() for path in discovery["thread"]["instructionSources"]}
    assert root / "AGENTS.md" in instruction_sources
    assert root.joinpath("AGENTS.md").read_text(encoding="utf-8").splitlines()[0] == "# Firstmate for Codex"
finally:
    shutil.rmtree(home, ignore_errors=True)

for role in ("planner", "implementer", "refute-reviewer"):
    home = pathlib.Path(tempfile.mkdtemp(prefix=f"codex-role-{role}-"))
    try:
        shutil.copy2(root / ".codex" / "agents" / f"{role}.toml", home / "config.toml")
        config, _ = read_config(home, home)
        assert config["approval_policy"] == "never"
        assert config["sandbox_mode"] in ("read-only", "workspace-write")
        assert config["developer_instructions"]
        assert config["model"] is None
        assert config["model_reasoning_effort"] is None
    finally:
        shutil.rmtree(home, ignore_errors=True)
PY
printf 'ok - installed Codex config loader resolves root config and every role target\n'
printf 'ok - installed Codex discovers the root AGENTS contract and all nine pipeline skills\n'

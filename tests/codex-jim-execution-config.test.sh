#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)

python3 - "$ROOT" <<'PY'
import json
import os
import pathlib
import shutil
import subprocess
import sys
import tempfile

root = pathlib.Path(sys.argv[1]).resolve()

def read_config(home, cwd):
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
    process.terminate()
    process.wait(timeout=5)
    return result["config"]

home = pathlib.Path(tempfile.mkdtemp(prefix="codex-loader-"))
try:
    home.joinpath("config.toml").write_text(f'[projects."{root.parent}"]\ntrust_level = "trusted"\n')
    config = read_config(home, root)
    assert config["model"] == "gpt-5.6-sol"
    assert config["model_reasoning_effort"] == "high"
    assert set(config["agents"].keys()) >= {"planner", "implementer", "refute-reviewer"}
    for role in ("planner", "implementer", "refute-reviewer"):
        target = pathlib.Path(config["agents"][role]["config_file"])
        assert target.is_file(), target
finally:
    shutil.rmtree(home, ignore_errors=True)

for role in ("planner", "implementer", "refute-reviewer"):
    home = pathlib.Path(tempfile.mkdtemp(prefix=f"codex-role-{role}-"))
    try:
        shutil.copy2(root / ".codex" / "agents" / f"{role}.toml", home / "config.toml")
        config = read_config(home, home)
        assert config["approval_policy"] == "never"
        assert config["sandbox_mode"] in ("read-only", "workspace-write")
        assert config["developer_instructions"]
        assert config["model"] is None
        assert config["model_reasoning_effort"] is None
    finally:
        shutil.rmtree(home, ignore_errors=True)
PY
printf 'ok - installed Codex config loader resolves root config and every role target\n'

grep -Fq 'Only an explicit execute instruction for the agreed plan authorizes writes.' "$ROOT/.codex/agents/implementer.toml"
grep -Fq 'A question about whether there is a better design requires analysis and a recommendation without edits.' "$ROOT/.codex/agents/implementer.toml"
printf 'ok - implementer role carries the authorization fence\n'

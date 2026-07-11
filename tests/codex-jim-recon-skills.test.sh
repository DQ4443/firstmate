#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)

python3 - "$ROOT" <<'PY'
import pathlib
import sys

root = pathlib.Path(sys.argv[1])


def ordered(text: str, markers: list[str]) -> bool:
    cursor = -1
    for marker in markers:
        found = text.find(marker, cursor + 1)
        if found <= cursor:
            return False
        cursor = found
    return True


def validate_markers(name: str, text: str) -> bool:
    markers = {
        "scout": ["## Calibration", "## The pipeline", "## The threshold"],
        "explore": ["## Shape", "## Angles", "## The pipeline", "## Anti-patterns"],
        "websearch": ["## Shape", "## Angles", "## The pipeline", "## Source discipline", "## Anti-patterns"],
    }
    return ordered(text, markers[name])


REQUIRED_TRIGGERS = {
    "scout": [
            "$scout research ways to improve our agentic workflow",
            "What already exists for deterministic agent-run replay, and is it worth building?",
            "How should we solve the connection-pool leak? Map the options first.",
            "Is X still useful now that Y exists?",
            "A `$build` entry question that genuinely asks what should be built.",
            "Where is the auth gate implemented?",
            "Implement the fix we already agreed on.",
            "Summarize this paper I pasted.",
    ],
    "explore": [
            "$explore how does the auth gate decide allow versus deny across the viewer?",
            "Dig into how the connection-pool lease code is structured and why it is shaped that way.",
            "What do we already have on other branches or worktrees for request sharding?",
            "A `$build` move recon asking whether the repository already contains something to adopt.",
            "The local half of a `$scout` research question.",
            "Where is compute_layout defined?",
            "What is the current state of the art for agent-run replay?",
            "Research whether X is worth building.",
    ],
    "websearch": [
            "$websearch what is the current state of the art for deterministic agent-run replay?",
            "Is there a standard tool to adopt for workspace snapshotting instead of hand-rolling one?",
            "What failures do people hit when pinning transitive dependencies in a monorepo?",
            "What changed in Playwright MCP in the last three months?",
            "A `$build` move recon asking for the standard pattern and known pitfalls.",
            "What version of ruff does our CI use?",
            "What is the capital of France?",
            "Research whether X is worth building.",
    ],
}


def validate_triggers(name: str, text: str) -> bool:
    return all(trigger in text for trigger in REQUIRED_TRIGGERS[name])


def validate_scout_angle_ownership(text: str) -> bool:
    ownership = "Each `$explore` and `$websearch` half owns its angle-design step and chooses two to five"
    nonownership = "The scout parent must not choose or prescribe an angle template for either half."
    return ownership in text and nonownership in text and "The scout parent must choose" not in text


def validate_invocation_tokens(text: str) -> bool:
    forbidden = ("/pdw", "/build", "/scout", "/explore", "/websearch", "/lavish")
    return not any(token in text for token in forbidden)


def validate_enforcement_rule(text: str) -> bool:
    correct = "without claiming enforcement when unavailable"
    reversed_rule = "without claiming unavailable enforcement"
    return correct in text and reversed_rule not in text


skills = {}
evals = {}
for skill in ("scout", "explore", "websearch"):
    skill_path = root / ".agents" / "skills" / skill / "SKILL.md"
    eval_path = root / ".agents" / "skills" / skill / "evals.md"
    skills[skill] = skill_path.read_text()
    evals[skill] = eval_path.read_text()
    assert validate_markers(skill, skills[skill]), f"{skill} source module order"
    assert validate_triggers(skill, evals[skill]), f"{skill} trigger boundaries"
    assert validate_invocation_tokens(skills[skill]), f"{skill} skill invocation carrier"
    assert validate_invocation_tokens(evals[skill]), f"{skill} eval invocation carrier"
    assert validate_enforcement_rule(evals[skill]), f"{skill} enforcement rule"
    assert "every native subagent is a leaf that returns only to its immediate parent" in skills[skill]
    assert "requested effort, effective effort" in skills[skill]
    assert "reject degenerate upstream outputs" in skills[skill]
    assert "`UNVERIFIED`" in skills[skill]
    for forbidden in ("Workflow", "Skill(", "ToolSearch", "agentType"):
        assert forbidden not in skills[skill], f"{skill} contains {forbidden}"

for skill, text in skills.items():
    marker_sets = {
        "scout": ["## Calibration", "## The pipeline", "## The threshold"],
        "explore": ["## Shape", "## Angles", "## The pipeline", "## Anti-patterns"],
        "websearch": ["## Shape", "## Angles", "## The pipeline", "## Source discipline", "## Anti-patterns"],
    }
    first, second = marker_sets[skill][0:2]
    reordered = text.replace(first, "MUTATION_FIRST", 1).replace(second, first, 1).replace("MUTATION_FIRST", second, 1)
    assert not validate_markers(skill, reordered), f"{skill} marker-order mutation escaped"

for skill, text in evals.items():
    for trigger in REQUIRED_TRIGGERS[skill]:
        deleted = text.replace(trigger, "", 1)
        assert not validate_triggers(skill, deleted), f"{skill} trigger deletion escaped: {trigger}"

for skill, text in skills.items():
    slash_mutation = text.replace("$pdw", "/pdw", 1)
    assert not validate_invocation_tokens(slash_mutation), f"{skill} slash invocation mutation escaped"

for skill, text in evals.items():
    trigger_mutation = text.replace(f"${skill}", f"/{skill}", 1)
    assert not validate_invocation_tokens(trigger_mutation), f"{skill} slash trigger mutation escaped"
    enforcement_mutation = text.replace(
        "without claiming enforcement when unavailable",
        "without claiming unavailable enforcement",
        1,
    )
    assert not validate_enforcement_rule(enforcement_mutation), f"{skill} enforcement reversal escaped"

scout = skills["scout"]
ownership = "Each `$explore` and `$websearch` half owns its angle-design step and chooses two to five"
assert validate_scout_angle_ownership(scout)
assert not validate_scout_angle_ownership(scout.replace(ownership, "", 1)), "angle ownership deletion escaped"
reversed_ownership = scout.replace("must not choose", "must choose", 1)
assert not validate_scout_angle_ownership(reversed_ownership), "angle ownership reversal escaped"

assert "label its result `MEASURED`" in scout
assert "Flag and justify expensive external experiments without launching them" in scout
assert "NEXT_STEP: invoke $lavish decision page before reporting" in scout
assert "`file:line` anchor" in skills["explore"]
assert "direct URL, a publication or last-updated date, and a `reported` or `verified` label" in skills["websearch"]

print("PASS: adversarial recon structure, triggers, and angle ownership checks")
PY

if find "$ROOT/.agents" -type f -path '*/skills-spine/*' -print -quit | grep -q .; then
  printf 'FAIL: found forbidden .agents/skills-spine target\n' >&2
  exit 1
fi

printf 'PASS: no forbidden skills-spine target\n'

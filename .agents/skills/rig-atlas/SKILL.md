---
name: rig-atlas
description: Inventory the live Codex workflow rig and regenerate its single full atlas after skills, harness configuration, role definitions, state conventions, or memory classifications change.
argument-hint: <optional changed surface or full>
user-invocable: true
---

# Rig Atlas

Use this skill for the workflow rig, not product code or a single skill edit.

The deliverable is one generated full document at `state/rig/rig-atlas.md`.
It is never hand-edited.
The only sanctioned twin is `state/rig/rig-atlas-portable.md`.
Portable generation is blocked until Jim supplies the unredacted sanitizer omitted from the company-repo-agnostic source.
Never infer, approximate, or replace that sanitizer.

Runtime material under `state/rig/` is ignored and never committed.
Tracked ownership is limited to this skill, its evals, and its narrow scripts.

## Rig surfaces

Scour exactly five subjects.

1. The skill suite under `.agents/skills/`, including every selected `SKILL.md`, `evals.md`, and referenced instruction file.
2. Codex harness configuration, hooks, plugins, MCP configuration, and optional keybindings that actually exist.
3. Role definitions under `.codex/agents/`, recording model or effort policy, tool fence, and operational role rather than persona.
4. State and notes conventions, recording layout, schema, and purpose without copying live task contents.
5. The memory layer, classifying every candidate into include-both, full-only, or exclude-both before any body is read into an edition.

The source classification baseline is 47 include-both, 47 full-only, and 41 exclude-both.
The portable source includes bodies only for the 47 include-both files.
Never copy full-only or excluded bodies from another installation.

The generator inventory is nine spine skills named `pdw`, `build`, `scout`, `explore`, `websearch`, `lavish`, `oat`, `submit`, and `rig-atlas`.
It also inventories three role definitions named `planner`, `implementer`, and `refute-reviewer`, harness hooks and configuration, references, curated memory metadata, and the generator itself.
Domain skills stay in the live inventory and out of the spine appendix.

## Pipeline

1. Read `$pdw` and `$scout` before dispatch.
2. Read the current full atlas, source inventory, and generator first so the run starts from a baseline.
3. Create five independent, scout-shaped PDWs, one per rig surface, and launch them in parallel.
4. Size each surface's read cells dynamically from its live complexity.
5. Skip research razors and experiments because this is an inventory task.
6. Require every surface funnel to reject placeholder or degenerate returns, verify referenced paths, label dead lanes `UNVERIFIED`, and deduplicate against all observed material.
7. Run one convergence PDW over the five funneled briefs.
8. Produce a concrete drift list before changing the generator or live source files.
9. Update live owned files or generator inputs, then regenerate the full atlas.
10. Never type into the generated atlas and never create an unsanctioned sibling.
11. Run `$lavish` in report mode only after the atlas is current, then use `$oat` to update the existing system-study surface in place when that surface is part of the host installation.

The portable twin is not a current deliverable.
`scripts/generate-atlas.py --portable` must fail closed and leave no output until the unredacted sanitizer contract is supplied and implemented with a zero-leak scan.

## Setup and regeneration

Run the source audit and portable include-both extraction with:

```sh
.agents/skills/rig-atlas/scripts/setup-runtime.sh "/absolute/path/to/message (4).txt"
```

Generate the full live atlas with:

```sh
python3 .agents/skills/rig-atlas/scripts/generate-atlas.py --repo-root "$PWD"
```

The setup script verifies the pinned source digest, exact classifications, generator roster, Appendix D coverage, and sanitizer redaction before writing runtime files.
It extracts only the sanctioned include-both bodies.

## Live-document discipline

The full atlas is a context drop for an agent reader.
Use dense tables and lists, present-tense mechanisms, literal paths, and no motivational narrative.
Record optional surfaces as absent unless verified.
Record conventions rather than task contents.
Re-run the generator after any live source change, even when the prose inventory did not change.
The convergence return carries `NEXT_STEP: regenerate the full rig atlas, then update the existing system-study surface last`.

## Forbidden outcomes

- A hand-edited generated atlas.
- More than one full atlas.
- A portable twin produced from a guessed sanitizer.
- Full-only or excluded memory bodies copied into this repository.
- One mega-workflow covering all five surfaces.
- Bare subagents dumping raw surface reports into the root context.
- A fixed angle count applied to every surface.
- An invented hook, role, keybinding, or memory mechanism.
- Runtime output committed from `state/rig/`.

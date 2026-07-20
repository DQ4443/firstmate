---
name: lavish
description: Render a plan, decision review, closing report, or build checkpoint as one interactive living HTML page. Use it for design-heavy or multi-option work, candidate sets from scout, significant closing reports, and every build-round checkpoint. Read the oat skill first, then use the required decision-zone and nav-sidebar references before building those structures.
---

# lavish, visual plan review

## Invariant triggers

- Read `.agents/skills/oat/SKILL.md` before writing the page.
- Read `.agents/skills/lavish/references/decision-zone.md` before building any decision zone.
- Read `.agents/skills/lavish/references/nav-sidebar.md` before building a checkpoint sidebar.
- Render the page and inspect the screenshot before presenting it.
- Keep one stable file path per workstream.
- Retire decided tabs into the Decided log.
- Badge every landed or evidence claim with the level rendered by the canonical `JIM EVIDENCE BADGES` component.

## Step 0

Read `.agents/skills/oat/SKILL.md` completely.

Oat owns the style boundary and resolves the canonical component file from `DAVID_WARM_COMPONENT_FILE`, defaulting to `data/operating-model/components/david-warm.html` relative to the repository root.

If that file is absent, page creation is blocked.

If it lacks the decision-zone or dynamic-sidebar component, install them into that canonical file only after the separately reviewed source change is authorized.

Use `.agents/skills/lavish/scripts/install-components.py "${DAVID_WARM_COMPONENT_FILE:-data/operating-model/components/david-warm.html}"`.
The installer preserves the legacy David-warm evidence row and adds the separately named canonical `JIM EVIDENCE BADGES` block.

A page that copies the source rig's palette, invents a second component system, or restyles a David-warm component is a defect.

## Delivery

Every Lavish page is a self-contained HTML file under a stable workstream path, normally `.lavish/<workstream>.html`.

Run `lavish-axi <html-file>` to open the local review surface.

Claim session resume only after a real open, update, and reopen returns evidence for the same session identity.

Run `lavish-axi poll <html-file>` when David is actively reviewing it so annotations and layout warnings return to the owning task.

Do not run `lavish-axi share`, do not publish to `ht-ml.app`, and do not send the file externally without David's explicit word.

The reply bar and its Copy button are the page's response channel.

The Copy button must try `navigator.clipboard.writeText`, fall back to `document.execCommand('copy')` on a temporary textarea, then keep a selectable textarea visible with the manual Command-C instruction if both methods fail.

Keep one living page per workstream.

When a round lands or a tracked follow-up resolves, update the same file, keep its title stable, append the result, and refresh the short summary.

Create a new page only for a genuinely new direction.

## Procedure

1. Read Oat and the configured canonical David-warm component source.
2. Gather enough evidence to render facts rather than a speculative plan.
3. For a decision page, read `references/decision-zone.md` before writing the zone.
4. For a checkpoint page, also read `references/nav-sidebar.md` before writing the rail.
5. Build the self-contained page at its stable `.lavish/` path with only verbatim David-warm components.
6. Render the HTML in a real browser and inspect the screenshot for overflow, overlap, clipped controls, unreadable diagrams, and reply composition.
7. Exercise option selection, typed answers, tab changes, and the full Copy fallback.
8. Fix every error-severity layout or interaction defect and render again.
9. Open the page with `lavish-axi <html-file>` and record real session identity before claiming resume.
10. Ask only the open questions already rendered on the page.
11. Update the same page as decisions land and move decided blocks into the Decided log.

## Page anatomy

Every plan, report, and checkpoint ends with the decision zone and Questions.

All informational content reads linearly.

Only decisions use tabs, and those tabs come after the evidence they depend on.

A single open decision may render linearly without a tab row, but it still uses the decision-zone structure and reply channel.

### Short summary

Use at most four short standalone lines or a two-column mini-table.

Each line carries one clause and puts the decision-relevant fact first.

### Definitions

Any page reporting something tried includes a `What was tried` section immediately after the short summary.

Define the mechanism, its source, its parts, and the exact difference between experimental arms before reporting results.

Define every invented term used later on the page.

Use a small diagram when the subject is a pipeline or mechanism.

### Situation brief

Use three to six concise points from reconnaissance that name what exists, what changed, and the constraint shaping the decision.

### Decision blocks

Use stable page-scoped IDs `D1`, `D2`, and later.

Each block starts with a four-row context table named `What`, `Why now`, `Why / why not`, and `Cost / risk`.

Each block has two to four option cards.

Instantiate and repeat those cards through the canonical generic decision carrier rather than hand-writing a fixed option count.

The Recommended option is first and preselected.

Each option includes one plain description, its strongest benefit, and its honest cost.

Every block ends with a free-text note input wired into the reply bar.

Single-select is the default.

Use multi-select only when the options form one coherent combined move, show a `select any` hint, and compose the reply as `D1: O1+O2`.

Every short-answer question gets a real textarea wired into the reply bar.

Decided decisions leave the live tab bar and become rows in the Decided log with their old content preserved in a `details` fold.

The live tab bar contains open decisions, the Decided log, and Standing or Questions.

### Mockups and diagrams

Render a product mockup in that product's own design system inside a framed David-warm page section.

Use a real SVG or rendered Mermaid figure for architecture, pipelines, and flows.

Do not use ASCII diagrams.

### Questions and reply template

Tag each open question to its decision block.

The reply bar composes one string such as `D1: O2 (note) | D2: O1+O3 | Q1: typed answer`.

When two live pages both contain `D1`, restate the page title and interpreted decision before acting on a bare response.

### Risk and rollback

Use a table with risk, likelihood, blast radius, and undo path.

## Style boundary

All visual tokens, components, Mermaid theme variables, evidence badges, and footer treatment come from the configured canonical David-warm component file verbatim.

Do not fork those rules inside this skill.

Mockups of an existing product may use that product's design system only inside their framed mockup area.

## Evidence badges

Use only the installed `JIM EVIDENCE BADGES` block for workflow claims.
The badge levels are the canonical E0-E5 ladder in `data/operating-model/evidence-ladder.md`, where E5 is David-verified live; `CAUSAL` and `PANEL-SURVIVED` are separate named requirements, not E4 or E5.
Evidence that never touched the deployed product cannot exceed E2.
Every side claim earns the same bar as the headline claim or carries its lower level visibly.

## Report mode

Report mode closes a run while preserving any decision still held for David.

Its short summary states the exact outcome, the PR or artifact state when relevant, and the one next decision.

The first content section after the short summary is a rendered diagram of the final end-to-end pipeline, with changed nodes identified through a David-warm status treatment.

Definitions follow the diagram.

Then show what changed, the findings ledger and each resolution, evidence artifacts, the review pointer, and next steps.

CodeRabbit is the external review name in this rig.

Every UI-facing claim embeds the decisive browser capture or is marked `UNVERIFIED`.

Fold the closing report into the workstream's existing page when one exists.

## Checkpoint mode

Checkpoint mode gates every build round.

The live decision zone carries the next round's open decisions, not completed decisions from earlier rounds.

Zero open decisions is valid only on a terminal page or a stuck page whose blocker is named.

The content order is what landed and its evidence, suggested next moves, stop check, Questions, and the standing mode choice.

Suggested moves are concrete forks produced by the round's validation and reconnaissance.

Use plural moves when real alternatives exist.

State one real move plainly instead of inventing filler alternatives.

The standing mode choice is `stay current`, `active`, or `passive`, with `stay current` preselected.

Active mode waits at the checkpoint.

Passive mode takes the Recommended move and keeps looping until a termination proposal, a genuine blocker, unapproved spend, or an outward action requires David.

### Append-only history

Each round appends a section and preserves all prior round content.

Older rounds may use `details` folds but may not disappear.

A substantive round gets a one-line purpose, a small flow diagram when flow changed, per-lane mechanism sections, panel findings, evidence, and spillover.

A small round compresses to a short paragraph and evidence line.

Every landed and evidence row uses the canonical David-warm evidence badge at the level actually reached.

Gloss the evidence ladder once per page by reference to `data/operating-model/evidence-ladder.md` rather than redefining it.

Every round heading carries a round tag and a CSS status glyph.

The sidebar has exactly `Main`, `Rounds`, and `Decisions` groups.

Each round link uses `<status glyph> R# &middot; terse summary`.

When later work replaces an earlier result, keep the earlier section and add an `updated cycle N` link to the replacement.

Remove work that was discarded without a replacement because the ledger remains its record.

Each decision state is `open`, `decided: <pick>`, or `SUPERSEDED: <replacement>` with an evidence link.

The reply bar composes only open decisions.

The compact round history records round number, chosen move, who chose it, what landed, evidence level, and verdict for every round.

The closing update keeps that full history intact.

## When not to use

Do not create a page for a trivial fix, a single known answer, or pure prose that fits in a short response.

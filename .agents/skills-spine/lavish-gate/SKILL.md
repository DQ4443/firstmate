---
name: lavish-gate
description: The reporting-and-gating layer. Renders every plan, checkpoint, and closing report as an interactive David-warm HTML page with inline decision blocks, then gates the run on it. Three modes — DECISION (design gate before code), CHECKPOINT (a round gate mapped onto David's active/passive lanes), REPORT (closing / merge-review). Auto-applies whenever firstmate would otherwise hand David a wall of prose, a multi-option plan, a round result, or a completion doc. Defers all visual style to data/operating-model/components/david-warm.html.
argument-hint: <plan / round result / closing report to render>
user-invocable: true
allowed-tools: Bash, Read, Grep, Glob, Write, Edit, Artifact, Skill
---

# lavish-gate, render the decision, then gate on it

> SUBSTRATE PRESENT (as of 2026-07-10): this module reads `data/operating-model/components/david-warm.html` (the canonical component library) as mandatory step 0. That file is now on disk, installed untracked-local under David's Option C (the AGENTS.md component mandate merged in DQ4443/firstmate#26). The house-style rules below are a runnable contract; symlink activation remains David-gated.

David cannot point at the part of a prose wall he disagrees with. Render the plan, the round result, or the closing report as an interactive page he clicks through in a minute, with the decisions as inline clickable blocks he answers in place, then gate the run on his pick. This is the firstmate adaptation of Jim's /lavish: same craft (decision zone, option cards, reply loop, diagram-first), our palette, our ladder, our gate model.

## Harness portability (why this is a file, not a habit)

Every rule that shapes a David-facing page lives in this file and in the two files it points at (the david-warm component library and the E0-E5 ladder), not in a model's memory. A doc-generating agent, whatever its harness, produces a conformant page by reading these instructions and copying the components verbatim; it does not need to have absorbed firstmate style. The no-em-dash / no-emoji / no-border-left-accent guardrails ride the brief explicitly because they fire at authoring time, long after any skill text is compacted (decisions.md 2026-07-08: the doc-gen no-dash rule was leaking precisely because it was not passed down into each brief). Paste the guardrails into every doc brief; do not trust them to survive.

## Step 0 — load the house style (mandatory, before writing anything)

Read data/operating-model/components/david-warm.html and COPY its components verbatim: tokens (cream background, clay accent, sage green, brown neutrals), cards, your-call decision blocks, chips, the E0-E5 evidence badge row, footer. Restyle nothing. The file carries the warm-light palette and the banned-pattern guardrails. A lavish-gate page that improvises its own tokens or forks a component is a defect (AGENTS.md section 9 mandate: all David-facing HTML copies its components from that file verbatim).

## Delivery — the lavish-axi editor lifecycle (David 2026-07-08)

The link on a board row follows a fixed lifecycle, NOT a one-shot publish:

1. Author the page HTML to disk (scratchpad or the item's data dir).
2. Open it in the lavish editor: `lavish-axi <file>` (local editor session). The board item's link points to that EDITOR SESSION, where David reviews and annotates inline. This is the review state.
3. On David's approval: deploy with `lavish-axi share --password kronos`, then REPLACE the editor link on the row with the deployed ht-ml.app link. That is the permanent state.

Link lifecycle: lavish editor (review) then, on approval, deployed html (kronos password, permanent). Every board item carrying a review doc uses this; a doc not yet approved keeps its editor link, never a deployed link. Board link labels never carry "(lavish editor)" — review links are lavish by default, the suffix is noise (decisions.md 2026-07-08).

## Banned patterns (auto-fail — reviewers and self-check both enforce)

Before handing David any link, VISUALLY CHECK the rendered page against this list (decisions.md 2026-07-09, the repeat-offense root cause: a doc shipped with a banned pattern because the link was posted without looking at the artifact):

- No border-left accent bars on any card, callout, quote, or list item. David calls this "the UI em dash"; it is banned everywhere, always. Alternatives: full soft-border cards, background-wash sections, small-caps eyebrow labels, spacing hierarchy.
- No em dashes and no en dashes in prose. Commas, periods, or parentheses.
- No emojis.
- No dark chrome and no `prefers-color-scheme` dependence. The page is always the warm light theme; it renders identically for David in any viewer. Code blocks and any Mermaid diagrams are explicitly themed light.

A delivered artifact carrying a banned pattern is a firstmate failure, not an agent one.

## Shared anatomy (every mode, in order)

- TL;DR strip: 3-4 standalone lines, one clause each, bold lead word. Never a paragraph.
- Definitions section (mandatory on any page reporting on something TRIED): restate what the thing under test IS, mechanism-level, because David arrives with zero context from this workstream. A small light-themed diagram when it is a pipeline.
- Situation brief: a few bullets of what exists, what moved, the binding constraint.
- Decision blocks: CLICKABLE, not prose. Stable page-scoped IDs D1, D2 (never invent another prefix). Each block: a context table (What changes, mechanism-level; Why now; Why / why not, the core argument for and the strongest against; Cost / risk), then 2-4 option cards each with a one-line description and a pros/cons line. The (Recommended) card is ALWAYS FIRST and pre-selected. Every block ends with a free-text note input. Short-answer questions get a real typeable textarea, not just chips. All wired into a sticky reply bar that composes `D1: O1 (note) - D2: ...` with a copy button. A page with a decision but no working reply loop is a memo, not a lavish page.
- The reading content is linear; ONLY the decision zone is tabbed and it comes LAST, so David never decides on a fraction of the evidence.
- Diagrams over textwalls: real inline SVG or a light-themed rendered diagram, never ASCII, never a screenshot of text.

Analysis depth is the bar, not the floor (decisions.md 2026-07-08 KEEP UP THE DETAILED ANALYSIS): concrete call paths with file references, explicit option sets with trade-offs and a recommendation, boxed unknowns, evidence. Do not thin it out.

For any UI/design judgment, SHOW do not tell (decisions.md 2026-07-09): name the precise tell rather than "looks AI generated," build a mini component demonstrating the better version, render current vs proposed side by side. Words-only UI reasoning is banned.

---

## Mode A — DECISION (the design gate, before any code)

Purpose: the ACTIVE-lane gate. When a task is an architecture call or MVP-core (the trade-off decisions David wants to make himself), this page is where he makes them BEFORE code is written.

### Node pipeline

1. GATE-CHECK — is this ACTIVE or PASSIVE?
   - Entry: the task and its classification.
   - Action: PASSIVE (internal tooling, non-architectural, non-MVP-core) does NOT get a design gate; firstmate runs it end to end and this mode is skipped, going straight to REPORT at the end. ACTIVE (architecture / MVP-core) gets this page and waits. The axis is whether David wants a seat in the DESIGN decision, never risk level (decisions.md AUTONOMY MODEL). The mechanical pin protects the classification: after compaction, never silently run an ACTIVE decision as passive.
   - Exit: either "PASSIVE, skip to build" (stated in one line) or "ACTIVE, build this page."
2. RECON-GROUND — do not render fiction.
   - Entry: an ACTIVE task.
   - Action: if the plan does not exist yet, a read-only recon wave (scouts) grounds it first. For UI work, build the current baseline FROM the real source (real tokens, real component markup), never reconstructed from notes (decisions.md GROUND-TRUTH RULE).
   - Exit: a grounded situation brief and a real option set.
3. RENDER — write the page (shared anatomy), option sets with a recommendation per Jim's recorded format (context first, options, a (Recommended) pick), never "this is what I did, good?".
   - Exit: the page passes QA (below) and the banned-pattern check.
4. OPEN IN EDITOR — deliver via the lavish-axi editor lifecycle; the board row link points at the editor session.
5. WAIT — the run holds at the design gate until David picks. His pick (via the reply bar or in-editor annotation) is the design decision; the build does not start before it. This is firstmate's adaptation of Jim's every-round human checkpoint: our human seat is the ACTIVE-lane design gate, not a per-round wait.

---

## Mode B — CHECKPOINT (the round gate, mapped onto active/passive)

Purpose: gate a /build-style round loop. This is Jim's checkpoint mode adapted: Jim waits every round; we wait only in the ACTIVE lane, and PASSIVE auto-takes the Recommended pick but never skips the publish.

### Node pipeline

1. ASSEMBLE — build the round section.
   - Entry: the round's validate output (what landed + recorded evidence, each row E-badged on our E0-E5 ladder).
   - Action: append this round's section to the ONE living checkpoint page (same file path, same URL). Append-only: prior rounds' sections stay intact; the page is the loop's history. Round sections scale with round complexity (a substantive round gets a flow diagram + per-lane subsections + findings + evidence; a trivial round compresses to a short paragraph + evidence line).
   - Exit: the page carries all rounds so far, current round detailed, prior rounds compressed to a history row each.
2. DECISION-ZONE — carry the NEXT round's OPEN decisions, never decided banners.
   - Action: the live tabs hold only decisions open NOW, each a concrete fork derived from this round's validation and issue recon; decided picks compress into a Decided-log. Zero open decisions is legitimate ONLY when terminal (submit-ready or scope-cut, and that go IS the one remaining decision) or stuck (blocker named). Manufactured filler questions are banned; a meta scheduling question is not a decision block.
   - Exit: real forks, or a stated end-state.
3. STOP-CHECK — CONTINUE / DONE / SCOPE-CREEP-cut, with the recommended verdict. Intent-anchored, never diff-line counts. Plus the standing mode-flip chip (stay / active / passive, default pre-selected).
4. GATE BY LANE.
   - ACTIVE: the loop waits on this page for David's pick.
   - PASSIVE: take the Recommended pick and continue, but NEVER skip the publish. Every passive round still redeploys the checkpoint page with its round section appended before the next round starts. A passive stretch whose page shows fewer sections than rounds ran is a defect. This is how David audits the rounds he did not watch.
   - BOTH lanes always pause for: spend, direction change, irreversible actions, and every scope-creep cut proposal. This maps Jim's "PASSIVE never auto-decides a scope cut" onto our consent rules (AGENTS.md prime rule 5).
   - Exit: the picked (or auto-Recommended) move feeds the next round; the page reflects the pick.
5. NOTIFY — a push notification at every checkpoint redeploy in BOTH lanes, plus blocking pauses and the stop. Silence between checkpoints. (David's analog of Jim's every-round ping: he still cares in passive.)

Note: this mode gates the /build round loop, which is an OPTIONAL control surface invoked EXPLICITLY for ambiguous or high-stakes builds only, NEVER the default for volume work (decisions.md deferred list; see the build module's "When this applies"). This mode exists so the gating machinery is ready when a run deliberately opts into that loop; it does NOT fire for the volume path, which is a plain /pdw run whose only lavish-gate surfaces are Mode A (an active-lane design gate) and Mode C (the closing merge-review). Do not read Mode B as a per-round default.

---

## Mode C — REPORT (closing / merge-review)

Purpose: the END gate. David reviews a completion document showing success was achieved and achieved correctly; his approval of it IS the merge authorization for a Kronos product batch (decisions.md HUMAN GATE MODEL). For non-project code the same page carries the independent critique that clears the standing grant.

### Node pipeline

1. FOLD, do not spawn.
   - Entry: a finished workstream that already has a lavish-gate page.
   - Action: the closing report FOLDS INTO the existing page (update in place, same URL), not a sibling. A fresh page only if the run was never tracked.
2. PIPELINE-RECAP DIAGRAM FIRST.
   - Action: right after the TL;DR, a light-themed diagram of the final built pipeline end-to-end, with the pieces this change added in soft-clay emphasis. A closing report whose first content section is text is a defect. David arrives with zero context; the diagram is the "where are we" recap.
3. EVIDENCE, e2e ahead of unit tests.
   - Action: the merge-review contract (AGENTS.md section 5, data/captain.md): what was done and why, expected behavior stated explicitly, e2e evidence with screenshots and logs AHEAD of unit tests. For a Kronos product PR, the e2e is on the DEPLOYED product as the expected user; problems it finds are folded into this ticket, not split off. Where no user-facing workflow exists, state "not relevant" explicitly. Embed the decisive captures as data URIs; a UI claim with no capture is listed UNVERIFIED. Every landed claim carries its E0-E5 badge; anything below E3 is justified in the case-against-merging section.
4. CASE-AGAINST-MERGING, directly above the decision.
   - Action: a consolidated, actionable case-against section. Low-impact-plus-low-effort items are FIXED silently before the merge ask, never listed as debt (decisions.md MERGE-GATE LOW-ITEMS RULE); low-impact-plus-high-effort or sensitive items are skipped with a one-line note. IMPACT >= EFFORT means fix it now, before the ask (AGENTS.md decision principle 1).
5. THE ASK, dot points, exact decision first.
   - Action: the your-court block LEADS with the exact decision firstmate wants plus its recommendation, then short points (options, evidence, recommendation). Never a bare report of what happened (AGENTS.md hand-back contract + FORMAT rule). Route by lane: non-project code merges autonomously under the standing grant once the independent critique on this page clears (log the merge); Kronos product code waits for David's approval of this completion document, then bin/fm-pr-merge.sh (squash default).
6. DELIVER — via the editor lifecycle; link from the board thread with the full PR URL. David judges from this page, not the diff. A bare link is not a merge ask.

---

## QA-then-publish (every mode, no exceptions)

1. Write the page to disk. Content only, concise `<title>`.
2. `npx -y playwright screenshot --viewport-size=940,1300 "file://<page>" qa.png`, plus a ~390px mobile-width shot for any UI page. READ the PNGs. Check text overflow, clipped tabs, the reply bar composing, and the banned-pattern list. Fix and re-shoot until clean. Never ship a page you have not looked at.
3. Deliver via the lavish-axi editor lifecycle above. Redeploy the same file path so the URL sticks; keep favicon and title stable across updates.
4. One page per workstream, kept current in place. A stale sibling trail is a defect.

## Where our rules override Jim

- Jim's per-round human checkpoint becomes our ACTIVE-lane design gate (Mode A) plus the optional checkpoint gate (Mode B); PASSIVE runs skip the design seat entirely, gated on the active/passive classification, not on round count.
- Jim's oat house style becomes our david-warm.html component library (step 0), warm light only, no dark twin.
- Jim's Artifact-tool delivery becomes the lavish-axi editor-then-deployed lifecycle.
- Jim's E-ladder becomes the firstmate E0-E5 ladder (E3 = deployed e2e as expected user, E5 = David-verified live).
- Jim's closing report becomes our completion document / merge-review contract, whose approval IS the merge gate for Kronos product code, with the standing-grant autonomous path for non-project code.
- The banned-pattern list (border-left accent, em dashes, emojis, dark chrome) is firstmate-specific and has no Jim analog; it is a hard auto-fail here.

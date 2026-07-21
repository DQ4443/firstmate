# Evals for lavish

Run isolated binary graders three times and target at least 90 percent.

## Should trigger

1. `$lavish discuss the dashboard design here`.
2. `Render the plan as a page I can click through`.
3. `Give me the closing report for this PR run`.
4. A build checkpoint with several open decisions.
5. A scout candidate set that needs picks.

## Should not trigger

1. `Give me a quick summary of what changed`.
2. `Confirm this one-option approach`.
3. `Update the PR body`.

## Binary output checks

- [ ] Oat and the configured canonical David-warm component source were read before page construction.
- [ ] The canonical source resolved from `DAVID_WARM_COMPONENT_FILE` or the repo-relative default, and absence blocked page creation.
- [ ] Decision-zone and dynamic-sidebar components were copied byte-for-byte from their canonical `COPY VERBATIM` blocks.
- [ ] Every used David-warm component was copied verbatim, with no second palette or restyled component.
- [ ] The required decision-zone reference was read before building a decision zone.
- [ ] The required nav-sidebar reference was read before building a checkpoint rail.
- [ ] Browser QA rendered the page and the worker inspected the screenshot before presentation.
- [ ] The review session used `lavish-axi <html-file> --no-open` and opened the returned URL in the owning task's Codex in-app browser without launching David's system browser.
- [ ] QA checked overflow, clipping, overlap, diagrams, selection, typing, tabs, reply composition, and the Copy fallback.
- [ ] Reading content is linear and only live decisions are tabbed at the end.
- [ ] The single current-round section and every preserved earlier round began with that round's visible, unfolded `Where you are` table containing Project, Ticket, Bigger picture, System position, Whole-ticket success, Current round, and Scope boundaries before its summary, evidence, or decisions.
- [ ] Every page ends with the decision zone and Questions.
- [ ] Short-answer questions have real textareas wired into the reply bar.
- [ ] A results page starts with a short summary, then a final-pipeline diagram, then definitions of what was tried.
- [ ] Decision blocks use page-scoped `D` IDs, the four-row context table, two to four options, Recommended first and preselected, benefits and costs, and a note input.
- [ ] Decided and superseded decisions retire from live tabs into the Decided log.
- [ ] Tab changes never move the reader above the sticky tab bar.
- [ ] Checkpoint mode shows landed evidence, concrete suggested moves, a stop check, Questions, and the standing mode choice with `stay current` preselected.
- [ ] The round-N page contains exactly one mutable current-round section plus N-1 complete chronological history sections, including each round's frozen seven-row orientation snapshot, evidence, decisions, findings, and outcome; earlier round bodies may fold without deletion or current-state rewriting.
- [ ] Every landed or evidence claim uses the canonical `JIM EVIDENCE BADGES` block at the level actually reached without rewriting the legacy David-warm row.
- [ ] The badges mean E0 Assumed, E1 Ran, E2 Works-unit with mutation, E3 Works-live, E4 Independently reproduced by a non-author agent, and E5 Refute-survived, with CAUSAL (preregistered control and sample count) kept as the orthogonal named requirement, not an E-level.
- [ ] Laptop-only evidence is capped at E1, and side claims display the same earned bar as the headline or their own lower level.
- [ ] The sidebar has exactly Main, Rounds, and Decisions and is built dynamically from page sections.
- [ ] The rail scrolls independently when long and switches to a toggle overlay below the paired breakpoint.
- [ ] UI claims embed the decisive capture or carry `UNVERIFIED`.
- [ ] The workstream keeps one stable HTML path and claims session resume only after a real open, update, and reopen prove the same session identity.
- [ ] No `lavish-axi share`, `ht-ml.app`, external send, or other outward action occurred.
- [ ] A new page was created only for a genuinely new direction.

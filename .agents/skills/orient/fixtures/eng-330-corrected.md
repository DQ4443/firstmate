## Bigger picture

A user should select an optical mode once and see how that same mode propagates, with fields and a compact physical summary they can trust.
ENG-330 carries that chosen mode from the uploaded waveguide into the forward electromagnetic simulation.

## Success

Starting with an uploaded waveguide, a user selects one optical mode and launches a signed, sanctioned Modal forward simulation with that mode's frozen full-vector result.
The ticket closes only when progress and terminal callbacks, fields, artifacts, and the physical summary return under one correlation while mode ordinal, requested and actual solver identity, carrier identity, and fallback state remain unchanged from selection through display.
A failing replay must preserve the first failing stage.
ENG-330 does not reselect the upstream mode or requalify CPU and GPU solvers; acceptance proves it carries the selected result without changing it.

## Current status

The Round 6 checkpoint and latest owner return show the upstream cancellation and solver work complete and ENG-331 owning the frozen full-vector result.
That result, the forward replay, and its user-visible output remain unproven, so the missing input blocks ENG-330.
The ticket remains incomplete at E1 because the available evidence records task state rather than the end-to-end behavior.

## Next steps

ENG-331 owns freezing the replayable result first.
Command Center then delivers that exact result to ENG-330.
ENG-330 owns syncing current main and running the forward dispatch, callback, field, artifact, physical-summary, and failure-provenance acceptance path.
David has no action until that replay exposes a product or authority decision.

NEXT_STEP: ENG-331 freezes and returns the replayable full-vector result; ENG-330 then resumes its forward-simulation build.

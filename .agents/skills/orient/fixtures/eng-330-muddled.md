ENG-330 is correctly waiting while ENG-331 builds the one input it needs: a frozen, replayable full-vector result with complete identity and provenance. The two Nate dependencies are cleared. Product PR #137 and waveEMFDFD PR #2 are merged. ENG-331 has reconciled current main into the ENG-329 stack and is actively implementing the strict full-vector selection, ordinal, identity, and same-result rendering boundary on clean head f3459ea…. I recommend leaving ENG-330 idle until that work returns. No action is needed from David now.
Success
ENG-330 closes only when the exact ENG-331 result reaches forward fdfdSim without changing the selected mode, requested or actual solver identity, carrier, fallback state, or artifact correlation.
The missing end-to-end proof must show:
Signed sanctioned Modal dispatch.
Progress and terminal callbacks tied to the same correlation.
Returned fields and artifacts with a compact physical summary.
First-failing-stage provenance preserved.
That behavior has not been observed yet. ENG-330 remains E1; unit tests alone cannot close it.
Current position
[Linear ENG-330](https://linear.app/kronosai/issue/ENG-330/eng-326-carry-the-full-vector-eigenmode-result-into-forward-fdfdsim) is In Progress and due July 17. Its branch is clean at d71e3f6a, one merged product commit behind origin/main. The [Round 6 checkpoint](https://7a9ce28d.ht-ml.app/) records ENG-331 as the only dependency.
ENG-330 does not own the upstream selection seam, TE/TM confirmation, or CPU/GPU qualification. Starting early would either guess at the frozen carrier or duplicate ENG-331’s work.
NEXT_STEP: ENG-331 finishes and freezes the replayable minimum result; Command Center delivers it; ENG-330 then syncs current main and resumes the ACTIVE build.

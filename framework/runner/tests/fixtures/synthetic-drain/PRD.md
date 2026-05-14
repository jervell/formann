# Synthetic drain (demo fixture)

## Problem Statement

The AFK runner needs a tiny, self-contained feature to drain end-to-end
when demonstrating loop semantics. The real `afk-runner` queue is too
expensive (each dispatch is real `/implement` work) and conflates the
runner's verification with the slices it dispatches.

## Solution

Two trivial AFK issues, each instructing `/implement` to drop a
marker file under `.scratch/synthetic-drain/markers/` and commit it.
Both issues are independently eligible — no blockers — so the runner
picks them in source order.

## User Stories

1. As the runner, I want a queue I can drain in a couple of minutes,
   so that loop semantics are demonstrable without long-running
   real `/implement` runs.
2. As the maintainer, I want each issue's success to be verifiable
   with `ls`, so that the demo doesn't depend on subjective UI
   judgement.

## Implementation Decisions

- Markers live at `.scratch/synthetic-drain/markers/MARKER-NN.txt`,
  committed alongside the tracker move. They're inside the feature
  dir so cleaning up means deleting the branch.
- Issues are independent (no `Blocked by`) so both are eligible from
  the first iteration. The loop drains them in numeric order.

## Out of scope

- Anything beyond marker files. This fixture exists to exercise the
  loop, not to be useful work.

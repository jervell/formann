# Multi-drain alpha (smoke fixture)

## Problem Statement

The branch-independent runner's bare invocation has to drain **multiple**
features in one pass. The existing `synthetic-drain` fixture covers a single
feature with multiple issues. To exercise the multi-feature outer loop end-to-
end against real Docker, real binding, and real propagation, the smoke setup
needs a *second* micro-feature whose branch exists alongside another. This
fixture (`multi-drain-alpha`) is one half of that pair; its sibling is
`multi-drain-beta`.

## Solution

One trivial AFK issue that drops a marker file inside the feature dir and
commits it. Independently eligible — no blockers — so the runner picks it on
its first pass.

## User Stories

1. As the runner, I want a one-issue feature I can drain in seconds, so that
   the multi-feature smoke exercises the outer loop without each dispatch
   taking minutes.
2. As the maintainer, I want the issue's success to be verifiable with `ls`,
   so that smoke validation doesn't depend on subjective judgement.

## Implementation Decisions

- Marker lives at `.scratch/multi-drain-alpha/markers/MARKER-01.txt`,
  committed alongside the tracker move. Inside the feature dir so cleanup
  means deleting the branch + the working-tree fixture.
- Single issue — keeps each per-feature drain section in SUMMARY.md compact
  so the operator can compare the two features side-by-side.

## Out of scope

- Anything beyond the marker file. This fixture exists to exercise the outer
  drain loop, not to be useful work.

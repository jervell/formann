# Runner smoke (fixture PRD)

## Problem Statement

The AFK runner needs a one-issue feature it can drain end-to-end against
real Docker, real claude inference, and real fast-forward. Pure-logic
bats tests don't see image drift, network-policy regressions,
token-passing breakage, or propagation hiccups; this fixture gives the
smoke test something deterministic to assert on.

## Solution

A single trivial AFK issue that tells `/implement` to drop a marker
file under `.scratch/smoke/markers/` and commit it alongside the
tracker move. One issue keeps the smoke run short while still
exercising every step of the dispatch path (snapshot, container,
classifier, fast-forward).

## User Stories

1. As the smoke test, I want a queue I can drain in roughly one
   minute so that running it before milestones is cheap enough to
   actually do.
2. As the maintainer, I want each issue's success to be verifiable
   with `ls`, so that the smoke assertion doesn't depend on subjective
   judgement.

## Out of scope

- Anything beyond writing a marker file. This fixture exists to
  exercise the runner's real-dispatch path, not to be useful work.
- Multi-issue queue draining — covered by `synthetic-drain` and
  slice 05's bats tests.

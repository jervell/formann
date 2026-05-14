# Multi-drain beta (smoke fixture)

## Problem Statement

Sibling of `multi-drain-alpha`. The branch-independent runner's bare
invocation has to walk every active feature and drain the ones it's allowed
to touch. A single feature is not enough to exercise that outer loop — two
side-by-side features are the minimum to demonstrate "feature A drained,
feature B skipped" and "both drained in one pass."

## Solution

One trivial AFK issue that drops a marker file inside the feature dir and
commits it. Independently eligible — no blockers.

## User Stories

1. As the runner, I want a second one-issue feature with the same shape as
   `multi-drain-alpha`, so that the outer loop has two features to walk and
   the per-feature gate evaluator has two cases to evaluate.
2. As the maintainer, I want the issue's success to be verifiable with `ls`,
   so that smoke validation doesn't depend on subjective judgement.

## Implementation Decisions

- Marker lives at `.scratch/multi-drain-beta/markers/MARKER-01.txt`,
  committed alongside the tracker move.
- Single issue — same shape as alpha. Per-feature SUMMARY sections stay
  compact.

## Out of scope

- Anything beyond the marker file.

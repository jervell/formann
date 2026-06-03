# Smoke-review-gate (fixture PRD)

## Problem Statement

The `[review, gate]` manifest composition needs a smoke fixture to verify
that a separate review step posts findings and a separate gate step then
applies the Critical-findings threshold — reproducing the same promote-on-clean
decision as the fused `review-and-gate` prompt, but with the two steps
explicitly separated.

## Solution

A single trivial AFK issue. The manifest installs both the `review` and
`gate` steps. After the run, if the review is clean, the gate promotes
the issue to `done`; if the review finds Critical issues, the issue
stays at `in-review`.

## User Stories

1. As the smoke walk, I want to verify that the `review` step posts a
   findings comment and the `gate` step reads it to make the
   promote/leave decision.
2. As the maintainer, I want confirmation that the review↔gate handoff
   (severity-convention contract) works end-to-end.

## Out of scope

- Anything beyond stamping the marker and verifying the review+gate outcome.

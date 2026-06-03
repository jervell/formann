# Smoke-iterate (fixture PRD)

## Problem Statement

The unrolled iterate manifest (`[review-and-gate, fix, review-and-gate]`)
needs a smoke fixture to verify that the runner early-exits the moment a
gate reaches `done`, spending no further Dispatches.

## Solution

A single trivial AFK issue. The manifest installs the unrolled iterate
sequence. For a clean issue (no Critical findings), the first
`review-and-gate` step should promote the issue to `done` and the runner
should record `stop-success` without dispatching the `fix` or second
`review-and-gate` steps.

## User Stories

1. As the smoke walk, I want to verify that the unrolled iterate manifest
   early-exits at the first clean gate.
2. As the maintainer, I want confirmation that the loop control (snapshot
   delta drives the `continue` vs `stop-success` decision) works correctly.

## Out of scope

- Anything beyond stamping the marker and verifying the early-exit outcome.

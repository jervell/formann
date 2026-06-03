# Smoke-review-only (fixture PRD)

## Problem Statement

The `[review]` manifest composition needs a smoke fixture to verify
that the review step posts findings and leaves the issue at `in-review`
without any state promotion.

## Solution

A single trivial AFK issue. The manifest installs only the `review`
step. After the run the issue must remain at `in-review` with a
severity-tagged findings comment posted; it must not reach `done`.

## User Stories

1. As the smoke walk, I want to verify that `review` posts findings
   without promoting the issue.
2. As the maintainer, I want a runbook that confirms the `[review]`
   manifest composition's behavior end-to-end.

## Out of scope

- Anything beyond stamping the marker and verifying the review-only outcome.

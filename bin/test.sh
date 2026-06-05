#!/usr/bin/env bash
# Run the full Formann test suite — every tracked bats file, one command.
#
# The verdict is the exit code: 0 iff every test in every suite passed.
# Suites are enumerated via `git ls-files` so the runner-checkout clone under
# .runner-state/ (which carries duplicate *.bats copies) is never double-run,
# and so the set tracks exactly what's committed.
#
# Prerequisites: bats 1.x, plus a reachable Docker daemon for
# framework/runner/tests/build-image.bats. That suite fails loudly without
# Docker — by design: this is the ship gate, and a silently skipped Docker
# test would mask a broken toolchain. (smoke.bats self-skips unless
# RUNNER_SMOKE=1; it needs a real end-to-end workspace, not just Docker.)
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"

exec bats -p --print-output-on-failure $(git ls-files '*.bats')

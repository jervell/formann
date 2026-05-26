# `format_end_of_run_table` UTF-8 alignment fails in non-UTF-8 locales

## Symptom

The bats test `format_end_of_run_table — header and data rows align visually under UTF-8 → indicator` (`framework/runner/tests/run-the-queue.bats:4209`) fails in environments without an `en_US.UTF-8` locale — notably the AFK dispatch container. The full suite then exits 1, which silently breaks the "bats exits 0" form of acceptance criteria on any issue that runs the runner tests in that environment (surfaced on #42).

On host (macOS with `en_US.UTF-8` installed) the same test passes at the same commit; the issue is purely environmental.

## Why

Both the production function (`format_end_of_run_table` in `framework/runner/run-the-queue.sh`) and the regression test count characters via `LC_ALL=en_US.UTF-8 wc -m`. When `en_US.UTF-8` is not installed, the locale falls back to `C`, where `wc -m` counts **bytes**, not code points. The `→` (U+2192) is 3 bytes in UTF-8, so the header's padding ends up 2 wider than the visible width of the data row, and the alignment assertion fails.

## Options

- Install `en_US.UTF-8` in the dispatch container image — cheapest fix, but tied to image build.
- Switch the explicit locale to `C.UTF-8` (POSIX-portable UTF-8 locale present on glibc-based systems) — keeps the locale dependency narrow but more portable.
- Replace the codepoint-counting mechanism in `format_end_of_run_table` and the test with something locale-independent (e.g. `python3 -c 'import sys; print(sum(1 for _ in sys.stdin.read()))'`, or `awk` with explicit multi-byte handling).

## Context

Surfaced during review of #42 (`runner-unborn-head`). Out of scope for that issue — the runner change is unrelated to the alignment logic. AC7 on #42 had to be downgraded to "partial" because of this.
#!/usr/bin/env bats
#
# reconcile_dead_runs / reconcile_one_dead_run — post-mortem of run dirs
# that died without a SUMMARY.md (#82). Pure-function tests; no container,
# no tracker, no lock.

setup() {
  load 'test_helper/bats-support/load'
  load 'test_helper/bats-assert/load'

  HERE="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)"
  RUNNER_SCRIPT="$HERE/../run-the-queue.sh"
  # Source the runner so its pure functions are callable in-process. The
  # source-guard inside the script prevents `main` from running.
  # shellcheck source=../run-the-queue.sh
  source "$RUNNER_SCRIPT"

  HOST_RUNS="$BATS_TEST_TMPDIR/runs"
  RUN_TS="20990101-000000"
  RUN_DIR="$HOST_RUNS/$RUN_TS"
  mkdir -p "$RUN_DIR"
}

# Lay down a dead run dir (no SUMMARY.md) and return its path. $1 = ts.
dead_run_dir() {
  local dir="$HOST_RUNS/$1"
  mkdir -p "$dir"
  printf '%s' "$dir"
}

# Write an implement artifact pair into $1 with exit code $2 for issue $3.
implement_artifact() {
  local dir="$1" exit_code="$2" nn="$3"
  printf '%s' "$exit_code" >"$dir/$nn.exit"
  printf 'implement summary\n' >"$dir/$nn.summary.md"
}

@test "stranded shape — implement exit 0, no walk-step artifacts" {
  dir="$(dead_run_dir 20260703-223257)"
  implement_artifact "$dir" 0 1011

  run reconcile_dead_runs
  assert_success
  assert_output --partial "stranded-in-review: #1011 (-) — implement finished but the review walk never ran (dead run 20260703-223257)"
  assert [ -f "$dir/SUMMARY.md" ]
  run cat "$dir/SUMMARY.md"
  assert_output --partial "Stop reason: died-without-summary"
  assert_output --partial "| #1011 | - | stranded-in-review | 0 |"
}

@test "nested layout — feature name reported from the subdirectory" {
  dir="$(dead_run_dir 20260703-223257)"
  mkdir -p "$dir/front-door-onboarding"
  implement_artifact "$dir/front-door-onboarding" 0 1011

  run reconcile_dead_runs
  assert_success
  assert_output --partial "stranded-in-review: #1011 (front-door-onboarding)"
  run cat "$dir/SUMMARY.md"
  assert_output --partial "| #1011 | front-door-onboarding | stranded-in-review | 0 |"
}

@test "walk started — softer dead-run line, tracker state authoritative" {
  dir="$(dead_run_dir 20260101-120000)"
  implement_artifact "$dir" 0 42
  printf 'review summary\n' >"$dir/42-01-review-and-gate-strict.summary.md"

  run reconcile_dead_runs
  assert_success
  refute_output --partial "stranded-in-review:"
  assert_output --partial "dead-run: #42 (-) — implement finished and the walk started"
  run cat "$dir/SUMMARY.md"
  assert_output --partial "| #42 | - | interrupted-during-walk | 0 |"
}

@test "implement died — nonzero exit reported, not stranded" {
  dir="$(dead_run_dir 20260101-120000)"
  implement_artifact "$dir" 137 7

  run reconcile_dead_runs
  assert_success
  refute_output --partial "stranded-in-review:"
  assert_output --partial "dead-run: #7 (-) — implement dispatch ended with exit 137"
  run cat "$dir/SUMMARY.md"
  assert_output --partial "| #7 | - | implement-died | 137 |"
}

@test "no dispatch artifacts — post-mortem still written" {
  dir="$(dead_run_dir 20260101-120000)"

  run reconcile_dead_runs
  assert_success
  assert_output --partial "dead run 20260101-120000 has no SUMMARY.md"
  run cat "$dir/SUMMARY.md"
  assert_output --partial "No dispatch artifacts found"
}

@test "run dir with a SUMMARY.md is left alone" {
  dir="$(dead_run_dir 20260101-120000)"
  printf 'original\n' >"$dir/SUMMARY.md"
  implement_artifact "$dir" 0 9

  run reconcile_dead_runs
  assert_success
  assert_output ""
  run cat "$dir/SUMMARY.md"
  assert_output "original"
}

@test "the current run dir is skipped" {
  implement_artifact "$RUN_DIR" 0 5

  run reconcile_dead_runs
  assert_success
  assert_output ""
  assert [ ! -f "$RUN_DIR/SUMMARY.md" ]
}

@test "idempotent — a second pass is silent" {
  dir="$(dead_run_dir 20260101-120000)"
  implement_artifact "$dir" 0 11

  run reconcile_dead_runs
  assert_success
  assert_output --partial "stranded-in-review: #11"

  run reconcile_dead_runs
  assert_success
  assert_output ""
}

@test "multiple dead runs and mixed shapes in one pass" {
  a="$(dead_run_dir 20260101-010000)"
  implement_artifact "$a" 0 1
  b="$(dead_run_dir 20260102-020000)"
  mkdir -p "$b/some-feature"
  implement_artifact "$b/some-feature" 1 2

  run reconcile_dead_runs
  assert_success
  assert_output --partial "stranded-in-review: #1 (-)"
  assert_output --partial "dead-run: #2 (some-feature) — implement dispatch ended with exit 1"
  assert [ -f "$a/SUMMARY.md" ]
  assert [ -f "$b/SUMMARY.md" ]
}

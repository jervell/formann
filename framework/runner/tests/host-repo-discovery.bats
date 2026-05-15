#!/usr/bin/env bats
#
# Exercises `resolve_host_repo` end-to-end against a synthetic-consumer
# fixture. The function walks up from $PWD looking for a directory that
# contains a `.formann` entry — that directory is the consumer root.
# Tests stage `<tmp>/synthetic-consumer/.formann -> <formann-root>`, cd
# into the synthetic consumer (or a subdirectory), and assert HOST_REPO
# resolves correctly.

setup() {
  load 'test_helper/bats-support/load'
  load 'test_helper/bats-assert/load'

  HERE="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)"
  FORMANN_ROOT="$(cd "$HERE/../../.." && pwd)"
  RUNNER_SCRIPT="$HERE/../run-the-queue.sh"

  SYNTHETIC_CONSUMER="$BATS_TEST_TMPDIR/synthetic-consumer"
  mkdir -p "$SYNTHETIC_CONSUMER"
  ln -s "$FORMANN_ROOT" "$SYNTHETIC_CONSUMER/.formann"

  # shellcheck source=../run-the-queue.sh
  source "$RUNNER_SCRIPT"
}

@test "resolve_host_repo — finds .formann ancestor from the consumer root" {
  cd "$SYNTHETIC_CONSUMER"

  HOST_REPO=""
  resolve_host_repo

  assert_equal "$HOST_REPO" "$SYNTHETIC_CONSUMER"
  assert_equal "$HOST_RUNNER_STATE" "$SYNTHETIC_CONSUMER/$RUNNER_STATE_DIR"
  assert_equal "$HOST_LOCK" "$SYNTHETIC_CONSUMER/$RUNNER_LOCK_PATH"
  assert_equal "$HOST_CHECKOUT" "$SYNTHETIC_CONSUMER/$RUNNER_CHECKOUT_PATH"
  assert_equal "$HOST_RUNS" "$SYNTHETIC_CONSUMER/$RUNNER_RUNS_PATH"
  assert_equal "$HOST_ABORT_DIR" "$SYNTHETIC_CONSUMER/$RUNNER_ABORT_PATH"
}

@test "resolve_host_repo — finds .formann ancestor from a subdirectory" {
  mkdir -p "$SYNTHETIC_CONSUMER/deep/nested/work"
  cd "$SYNTHETIC_CONSUMER/deep/nested/work"

  HOST_REPO=""
  resolve_host_repo

  assert_equal "$HOST_REPO" "$SYNTHETIC_CONSUMER"
}

@test "resolve_host_repo — refuses when cwd has no .formann ancestor" {
  local outside="$BATS_TEST_TMPDIR/outside"
  mkdir -p "$outside"

  run bash -c "cd '$outside' && source '$RUNNER_SCRIPT' && HOST_REPO='' && resolve_host_repo"

  [ "$status" -ne 0 ]
  assert_output --partial "not inside a consumer"
  assert_output --partial "no '.formann' ancestor"
}
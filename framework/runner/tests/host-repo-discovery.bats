#!/usr/bin/env bats
#
# Exercises `resolve_host_repo` end-to-end via the consumer's `.formann`
# indirection symlink. The test stages a synthetic consumer at
# $BATS_TEST_TMPDIR/synthetic-consumer/, plants `.formann -> <formann-root>`
# inside it, sources `run-the-queue.sh` through that symlink chain, and
# asserts that `HOST_REPO` resolves to the synthetic consumer path — not
# to the Formann checkout that the symlink ultimately points at.

setup() {
  load 'test_helper/bats-support/load'
  load 'test_helper/bats-assert/load'

  HERE="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)"
  FORMANN_ROOT="$(cd "$HERE/../../.." && pwd)"

  SYNTHETIC_CONSUMER="$BATS_TEST_TMPDIR/synthetic-consumer"
  mkdir -p "$SYNTHETIC_CONSUMER"
  ln -s "$FORMANN_ROOT" "$SYNTHETIC_CONSUMER/.formann"
}

@test "resolve_host_repo — walks via .formann to the consumer root" {
  # Source the runner through the consumer-side indirection. `BASH_SOURCE[0]`
  # inside the function will be the unresolved path containing `.formann`.
  # shellcheck source=/dev/null
  source "$SYNTHETIC_CONSUMER/.formann/framework/runner/run-the-queue.sh"

  HOST_REPO=""
  resolve_host_repo

  assert_equal "$HOST_REPO" "$SYNTHETIC_CONSUMER"
  assert_equal "$HOST_RUNNER_STATE" "$SYNTHETIC_CONSUMER/$RUNNER_STATE_DIR"
  assert_equal "$HOST_LOCK" "$SYNTHETIC_CONSUMER/$RUNNER_LOCK_PATH"
  assert_equal "$HOST_CHECKOUT" "$SYNTHETIC_CONSUMER/$RUNNER_CHECKOUT_PATH"
  assert_equal "$HOST_RUNS" "$SYNTHETIC_CONSUMER/$RUNNER_RUNS_PATH"
  assert_equal "$HOST_ABORT_DIR" "$SYNTHETIC_CONSUMER/$RUNNER_ABORT_PATH"
}

@test "resolve_host_repo — refuses when invoked outside a .formann indirection" {
  # Sourcing the script directly from the Formann checkout — no `.formann`
  # in the path — must surface a diagnostic and exit non-zero rather than
  # silently landing inside Formann.
  run bash -c "source '$FORMANN_ROOT/framework/runner/run-the-queue.sh'; HOST_REPO=''; resolve_host_repo"

  [ "$status" -ne 0 ]
  assert_output --partial "cannot locate consumer's '.formann' symlink"
}

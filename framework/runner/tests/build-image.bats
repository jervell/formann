#!/usr/bin/env bats

setup() {
  load 'test_helper/bats-support/load'
  load 'test_helper/bats-assert/load'

  SCRIPT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)/build-image.sh"

  CONSUMER="$BATS_TEST_TMPDIR/consumer"
  mkdir -p "$CONSUMER/runner"
  touch "$CONSUMER/runner/Dockerfile"
  # .formann is a real dir here (tests don't need it to be a symlink)
  mkdir -p "$CONSUMER/.formann"

  # Stub docker: exit 1 for `image inspect` (forces build); capture args for `build`
  mkdir -p "$BATS_TEST_TMPDIR/bin"
  STUB_OUTPUT="$BATS_TEST_TMPDIR/docker-build-args"
  export STUB_OUTPUT
  cat > "$BATS_TEST_TMPDIR/bin/docker" <<'STUB'
#!/usr/bin/env bash
if [ "$1" = "image" ] && [ "$2" = "inspect" ]; then
  exit 1
fi
if [ "$1" = "build" ]; then
  echo "$@" > "${STUB_OUTPUT}"
fi
STUB
  chmod +x "$BATS_TEST_TMPDIR/bin/docker"
  export PATH="$BATS_TEST_TMPDIR/bin:$PATH"
}

@test "build-image.sh builds from <consumer>/runner when invoked with --rebuild" {
  cd "$CONSUMER"
  run bash "$SCRIPT" --rebuild
  assert_success
  build_args="$(cat "$STUB_OUTPUT")"
  [[ "$build_args" == *"$CONSUMER/runner"* ]] || {
    echo "expected build context containing $CONSUMER/runner, got: $build_args" >&2
    return 1
  }
}

@test "build-image.sh discovers consumer root by walking PWD upward through subdir" {
  mkdir -p "$CONSUMER/sub/dir"
  cd "$CONSUMER/sub/dir"
  run bash "$SCRIPT" --rebuild
  assert_success
  build_args="$(cat "$STUB_OUTPUT")"
  [[ "$build_args" == *"$CONSUMER/runner"* ]] || {
    echo "expected build context containing $CONSUMER/runner, got: $build_args" >&2
    return 1
  }
}

@test "build-image.sh fails when no .formann ancestor exists" {
  cd "$BATS_TEST_TMPDIR"
  run bash "$SCRIPT" --rebuild
  assert_failure
  assert_output --partial ".formann"
}

@test "build-image.sh does not build from script's own directory" {
  script_dir="$(dirname "$SCRIPT")"
  cd "$CONSUMER"
  run bash "$SCRIPT" --rebuild
  assert_success
  build_args="$(cat "$STUB_OUTPUT")"
  [[ "$build_args" != *"$script_dir"* ]] || {
    echo "build context must not be script directory $script_dir" >&2
    return 1
  }
}

@test "build-image.sh prints the image name on stdout" {
  cd "$CONSUMER"
  run bash "$SCRIPT" --rebuild
  assert_success
  assert_output "afk-runner-sandbox"
}

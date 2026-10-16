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
  unset RUNNER_IMAGE_NAME

  # shellcheck source=../lib.sh
  source "$(dirname "$SCRIPT")/lib.sh"

  # Stub docker. `image inspect` fails (no image) unless $STUB_IMAGE_LABEL
  # exists, in which case the image is present and the file's content is its
  # formann.runner.context-hash label. `build` records its args.
  mkdir -p "$BATS_TEST_TMPDIR/bin"
  STUB_OUTPUT="$BATS_TEST_TMPDIR/docker-build-args"
  STUB_IMAGE_LABEL="$BATS_TEST_TMPDIR/docker-image-label"
  export STUB_OUTPUT STUB_IMAGE_LABEL
  cat > "$BATS_TEST_TMPDIR/bin/docker" <<'STUB'
#!/usr/bin/env bash
if [ "$1" = "image" ] && [ "$2" = "inspect" ]; then
  [ -f "$STUB_IMAGE_LABEL" ] || exit 1
  cat "$STUB_IMAGE_LABEL"
  exit 0
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

@test "build-image.sh prints the consumer's default image name on stdout and tags it" {
  cd "$CONSUMER"
  run bash "$SCRIPT" --rebuild
  assert_success
  assert_output "$(runner_image_name "$CONSUMER")"
  [[ "$(cat "$STUB_OUTPUT")" == *"--tag $output "* ]] || {
    echo "expected --tag $output in build args, got: $(cat "$STUB_OUTPUT")" >&2
    return 1
  }
}

@test "build-image.sh gives consumers with the same dir name different images" {
  for side in a b; do
    mkdir -p "$BATS_TEST_TMPDIR/$side/proj/runner" "$BATS_TEST_TMPDIR/$side/proj/.formann"
    touch "$BATS_TEST_TMPDIR/$side/proj/runner/Dockerfile"
  done
  cd "$BATS_TEST_TMPDIR/a/proj"
  run bash "$SCRIPT" --rebuild
  assert_success
  name_a="$output"
  cd "$BATS_TEST_TMPDIR/b/proj"
  run bash "$SCRIPT" --rebuild
  assert_success
  [ "$name_a" != "$output" ] || {
    echo "expected different image names, both were: $output" >&2
    return 1
  }
}

@test "build-image.sh uses RUNNER_IMAGE_NAME for the tag and stdout when set" {
  cd "$CONSUMER"
  RUNNER_IMAGE_NAME=custom-image run bash "$SCRIPT" --rebuild
  assert_success
  assert_output "custom-image"
  [[ "$(cat "$STUB_OUTPUT")" == *"--tag custom-image "* ]] || {
    echo "expected --tag custom-image in build args, got: $(cat "$STUB_OUTPUT")" >&2
    return 1
  }
}

@test "build-image.sh builds when no image exists, with the cache and the context-hash label" {
  cd "$CONSUMER"
  run bash "$SCRIPT"
  assert_success
  build_args="$(cat "$STUB_OUTPUT")"
  [[ "$build_args" == *"--label formann.runner.context-hash=$(runner_context_hash "$CONSUMER")"* ]] || {
    echo "expected context-hash label in build args, got: $build_args" >&2
    return 1
  }
  [[ "$build_args" != *"--no-cache"* ]] || {
    echo "expected a cached build, got --no-cache: $build_args" >&2
    return 1
  }
}

@test "build-image.sh skips the build when the image label matches the context hash" {
  runner_context_hash "$CONSUMER" > "$STUB_IMAGE_LABEL"
  cd "$CONSUMER"
  run bash "$SCRIPT"
  assert_success
  assert_output "$(runner_image_name "$CONSUMER")"
  [ ! -e "$STUB_OUTPUT" ] || {
    echo "expected no docker build, got: $(cat "$STUB_OUTPUT")" >&2
    return 1
  }
}

@test "build-image.sh rebuilds with the cache when the image label differs from the context hash" {
  runner_context_hash "$CONSUMER" > "$STUB_IMAGE_LABEL"
  printf 'FROM scratch\n' > "$CONSUMER/runner/Dockerfile"
  cd "$CONSUMER"
  run bash "$SCRIPT"
  assert_success
  assert_output "$(runner_image_name "$CONSUMER")"
  [ -e "$STUB_OUTPUT" ] || {
    echo "expected a docker build after the context changed" >&2
    return 1
  }
  build_args="$(cat "$STUB_OUTPUT")"
  [[ "$build_args" == *"--label formann.runner.context-hash=$(runner_context_hash "$CONSUMER")"* ]] || {
    echo "expected the current context-hash label in build args, got: $build_args" >&2
    return 1
  }
  [[ "$build_args" != *"--no-cache"* ]] || {
    echo "expected a cached build, got --no-cache: $build_args" >&2
    return 1
  }
}

@test "build-image.sh --rebuild builds despite a matching label and passes the label" {
  runner_context_hash "$CONSUMER" > "$STUB_IMAGE_LABEL"
  cd "$CONSUMER"
  run bash "$SCRIPT" --rebuild
  assert_success
  build_args="$(cat "$STUB_OUTPUT")"
  [[ "$build_args" == *"--label formann.runner.context-hash=$(runner_context_hash "$CONSUMER")"* ]] || {
    echo "expected context-hash label in build args, got: $build_args" >&2
    return 1
  }
}

@test "build-image.sh --fresh builds despite a matching label and passes the label" {
  runner_context_hash "$CONSUMER" > "$STUB_IMAGE_LABEL"
  cd "$CONSUMER"
  run bash "$SCRIPT" --fresh
  assert_success
  build_args="$(cat "$STUB_OUTPUT")"
  [[ "$build_args" == *"--label formann.runner.context-hash=$(runner_context_hash "$CONSUMER")"* ]] || {
    echo "expected context-hash label in build args, got: $build_args" >&2
    return 1
  }
}

@test "build-image.sh --fresh bypasses the layer cache and re-pulls the base" {
  cd "$CONSUMER"
  run bash "$SCRIPT" --fresh
  assert_success
  build_args="$(cat "$STUB_OUTPUT")"
  [[ "$build_args" == *"--no-cache"* ]] || {
    echo "expected --no-cache in build args, got: $build_args" >&2
    return 1
  }
  [[ "$build_args" == *"--pull"* ]] || {
    echo "expected --pull in build args, got: $build_args" >&2
    return 1
  }
}

@test "build-image.sh --rebuild reuses the layer cache (no --no-cache)" {
  cd "$CONSUMER"
  run bash "$SCRIPT" --rebuild
  assert_success
  build_args="$(cat "$STUB_OUTPUT")"
  [[ "$build_args" != *"--no-cache"* ]] || {
    echo "expected --rebuild to reuse the layer cache, got --no-cache: $build_args" >&2
    return 1
  }
}

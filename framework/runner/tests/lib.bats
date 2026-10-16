#!/usr/bin/env bats
#
# Exercises the lib.sh functions that name a consumer's runner image and
# fingerprint its `runner/` build context.

setup() {
  load 'test_helper/bats-support/load'
  load 'test_helper/bats-assert/load'

  HERE="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)"
  unset RUNNER_IMAGE_NAME
  # shellcheck source=../lib.sh
  source "$HERE/../lib.sh"

  ROOTS="$BATS_TEST_TMPDIR/roots"
  mkdir -p "$ROOTS"
}

sha256_hex() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum | cut -d' ' -f1
  else
    shasum -a 256 | cut -d' ' -f1
  fi
}

# === Default image name ======================================================

@test "runner_image_name — identical basenames at different paths get different names" {
  mkdir -p "$ROOTS/a/proj" "$ROOTS/b/proj"
  name_a="$(runner_image_name "$ROOTS/a/proj")"
  name_b="$(runner_image_name "$ROOTS/b/proj")"
  [ "$name_a" != "$name_b" ] || {
    echo "expected different names, both were: $name_a" >&2
    return 1
  }
}

@test "runner_image_name — pathhash is the first 8 hex of SHA-256 of the physical path" {
  mkdir -p "$ROOTS/real/proj"
  ln -s "$ROOTS/real" "$ROOTS/link"
  physical="$(cd "$ROOTS/real/proj" && pwd -P)"
  expected_hash="$(printf '%s' "$physical" | sha256_hex | cut -c1-8)"

  run runner_image_name "$ROOTS/link/proj"
  assert_success
  assert_output "formann-runner-proj-$expected_hash"
}

@test "runner_image_name — uppercase, spaces and non-ASCII sanitize to a valid tag" {
  root="$ROOTS/My Project ÆØÅ café"
  mkdir -p "$root"
  run runner_image_name "$root"
  assert_success
  [[ "$output" =~ ^formann-runner-[a-z0-9]+(-[a-z0-9]+)*-[0-9a-f]{8}$ ]] || {
    echo "name does not match the tag pattern: $output" >&2
    return 1
  }
  [[ "$output" == formann-runner-my-project-caf-* ]] || {
    echo "expected dir part my-project-caf, got: $output" >&2
    return 1
  }
}

@test "runner_image_name — separator runs collapse and edge separators are stripped" {
  root="$ROOTS/._a._-b__"
  mkdir -p "$root"
  run runner_image_name "$root"
  assert_success
  [[ "$output" =~ ^formann-runner-a-b-[0-9a-f]{8}$ ]] || {
    echo "expected formann-runner-a-b-<8 hex>, got: $output" >&2
    return 1
  }
}

@test "runner_image_name — basename that sanitizes to empty falls back to formann-runner-<pathhash>" {
  root="$ROOTS/ÆØÅ"
  mkdir -p "$root"
  run runner_image_name "$root"
  assert_success
  [[ "$output" =~ ^formann-runner-[0-9a-f]{8}$ ]] || {
    echo "expected formann-runner-<8 hex>, got: $output" >&2
    return 1
  }
}

@test "runner_image_name — dir part truncates to 40 characters without a trailing separator" {
  long="$(printf 'a%.0s' {1..39})"
  root="$ROOTS/${long}_bbbbbbbbbb"
  mkdir -p "$root"
  run runner_image_name "$root"
  assert_success
  [[ "$output" =~ ^formann-runner-${long}-[0-9a-f]{8}$ ]] || {
    echo "expected 39 a's then the pathhash, got: $output" >&2
    return 1
  }
}

@test "runner_image_name — RUNNER_IMAGE_NAME overrides the default" {
  mkdir -p "$ROOTS/proj"
  RUNNER_IMAGE_NAME=custom-image run runner_image_name "$ROOTS/proj"
  assert_success
  assert_output "custom-image"
}

# === Context hash ============================================================

# Stage a baseline runner/ tree under $1.
make_tree() {
  mkdir -p "$1/runner/sub"
  printf 'FROM scratch\n' > "$1/runner/Dockerfile"
  printf '#!/bin/sh\n' > "$1/runner/entrypoint.sh"
  chmod +x "$1/runner/entrypoint.sh"
  printf 'nested\n' > "$1/runner/sub/conf"
}

@test "runner_context_hash — is a 64-hex SHA-256 and stable for an unchanged tree" {
  make_tree "$ROOTS/c"
  first="$(runner_context_hash "$ROOTS/c")"
  second="$(runner_context_hash "$ROOTS/c")"
  [[ "$first" =~ ^[0-9a-f]{64}$ ]] || {
    echo "expected 64 hex, got: $first" >&2
    return 1
  }
  assert_equal "$second" "$first"
}

@test "runner_context_hash — changes when a file is edited" {
  make_tree "$ROOTS/c"
  before="$(runner_context_hash "$ROOTS/c")"
  printf 'nested, edited\n' > "$ROOTS/c/runner/sub/conf"
  after="$(runner_context_hash "$ROOTS/c")"
  [ "$before" != "$after" ]
}

@test "runner_context_hash — changes when a file is added" {
  make_tree "$ROOTS/c"
  before="$(runner_context_hash "$ROOTS/c")"
  touch "$ROOTS/c/runner/sub/new"
  after="$(runner_context_hash "$ROOTS/c")"
  [ "$before" != "$after" ]
}

@test "runner_context_hash — changes when a file is removed" {
  make_tree "$ROOTS/c"
  before="$(runner_context_hash "$ROOTS/c")"
  rm "$ROOTS/c/runner/sub/conf"
  after="$(runner_context_hash "$ROOTS/c")"
  [ "$before" != "$after" ]
}

@test "runner_context_hash — changes when a file is renamed" {
  make_tree "$ROOTS/c"
  before="$(runner_context_hash "$ROOTS/c")"
  mv "$ROOTS/c/runner/sub/conf" "$ROOTS/c/runner/sub/conf2"
  after="$(runner_context_hash "$ROOTS/c")"
  [ "$before" != "$after" ]
}

@test "runner_context_hash — changes when the executable bit flips" {
  make_tree "$ROOTS/c"
  before="$(runner_context_hash "$ROOTS/c")"
  chmod -x "$ROOTS/c/runner/entrypoint.sh"
  after="$(runner_context_hash "$ROOTS/c")"
  [ "$before" != "$after" ]
}

@test "runner_context_hash — changes when bytes move from one file to the next" {
  mkdir -p "$ROOTS/x/runner" "$ROOTS/y/runner"
  printf 'ab' > "$ROOTS/x/runner/a"; printf 'c' > "$ROOTS/x/runner/b"
  printf 'a' > "$ROOTS/y/runner/a"; printf 'bc' > "$ROOTS/y/runner/b"
  x="$(runner_context_hash "$ROOTS/x")"
  y="$(runner_context_hash "$ROOTS/y")"
  [ "$x" != "$y" ]
}

@test "runner_context_hash — fails when a file under runner/ cannot be read" {
  [ "$(id -u)" -eq 0 ] && skip "root reads files regardless of mode"
  make_tree "$ROOTS/c"
  chmod 000 "$ROOTS/c/runner/sub/conf"
  run runner_context_hash "$ROOTS/c"
  assert_failure
  assert_output --partial "sub/conf"
}

@test "runner_context_hash — same tree written in a different order hashes the same" {
  make_tree "$ROOTS/c"
  mkdir -p "$ROOTS/d/runner/sub"
  printf 'nested\n' > "$ROOTS/d/runner/sub/conf"
  printf '#!/bin/sh\n' > "$ROOTS/d/runner/entrypoint.sh"
  chmod +x "$ROOTS/d/runner/entrypoint.sh"
  printf 'FROM scratch\n' > "$ROOTS/d/runner/Dockerfile"
  c="$(runner_context_hash "$ROOTS/c")"
  d="$(runner_context_hash "$ROOTS/d")"
  assert_equal "$d" "$c"
}

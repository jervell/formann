#!/usr/bin/env bats

setup() {
  load 'test_helper/bats-support/load'
  load 'test_helper/bats-assert/load'

  HERE="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)"
  SANDBOX_ENV="$HERE/../sandbox-env"

  FAKE_BIN="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$FAKE_BIN"

  # Default: fake 'security' binary that returns a valid token.
  cat >"$FAKE_BIN/security" <<'EOF'
#!/usr/bin/env bash
# Shim: echo the fake token when called with find-generic-password -w.
if [[ "$1" == "find-generic-password" ]]; then
  for arg in "$@"; do
    [[ "$arg" == "-w" ]] && { echo "ghp_fake_test_token"; exit 0; }
  done
fi
exit 1
EOF
  chmod +x "$FAKE_BIN/security"
  export PATH="$FAKE_BIN:$PATH"

  # Force darwin OSTYPE so the macOS branch runs in CI (Linux host).
  export OSTYPE="darwin21"
}

@test "Keychain entry present — emits GH_TOKEN=<token> on stdout" {
  run "$SANDBOX_ENV"
  assert_success
  assert_output "GH_TOKEN=ghp_fake_test_token"
}

@test "Keychain entry absent — exits non-zero with clear stderr error" {
  # Override shim to fail find-generic-password.
  cat >"$FAKE_BIN/security" <<'EOF'
#!/usr/bin/env bash
if [[ "$1" == "find-generic-password" ]]; then
  echo "security: SecKeychainSearchCopyNext: The specified item could not be found in the keychain." >&2
  exit 44
fi
exit 1
EOF
  chmod +x "$FAKE_BIN/security"

  run "$SANDBOX_ENV"
  assert_failure
  assert_output --partial "GH token not found in Keychain"
  assert_output --partial "formann-gh-token"
}

@test "security binary absent — exits 2 with clear stderr error" {
  rm "$FAKE_BIN/security"

  run "$SANDBOX_ENV"
  [ "$status" -eq 2 ]
  assert_output --partial "security"
}

@test "output line is valid KEY=value format parseable by collect_binding_env" {
  run "$SANDBOX_ENV"
  assert_success
  # Must match ^[A-Z_][A-Z0-9_]*= (the runner's validation regex).
  [[ "$output" =~ ^[A-Z_][A-Z0-9_]*= ]]
}

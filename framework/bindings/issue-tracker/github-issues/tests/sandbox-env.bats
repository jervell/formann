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

  # Default: fake 'git' binary that returns a valid GitHub HTTPS origin URL.
  # GIT_FAKE_ORIGIN_URL: override the returned URL (default: https://github.com/owner/repo.git)
  # GIT_FAKE_NO_ORIGIN:  when non-empty, simulate a missing origin remote (exit non-zero)
  cat >"$FAKE_BIN/git" <<'EOF'
#!/usr/bin/env bash
if [[ "$1" == "-C" ]]; then shift 2; fi
if [[ "$1" == "rev-parse" && "$2" == "--show-toplevel" ]]; then
  echo "/fake/repo"; exit 0
fi
if [[ "$1" == "remote" && "$2" == "get-url" && "$3" == "origin" ]]; then
  if [[ -n "${GIT_FAKE_NO_ORIGIN:-}" ]]; then
    echo "error: No such remote 'origin'" >&2; exit 2
  fi
  printf '%s\n' "${GIT_FAKE_ORIGIN_URL:-https://github.com/owner/repo.git}"
  exit 0
fi
exit 1
EOF
  chmod +x "$FAKE_BIN/git"

  export PATH="$FAKE_BIN:$PATH"

  # Force darwin OSTYPE so the macOS branch runs in CI (Linux host).
  export OSTYPE="darwin21"
}

@test "Keychain entry present — emits GH_TOKEN and GH_REPO on stdout" {
  run "$SANDBOX_ENV"
  assert_success
  assert_line --index 0 "GH_TOKEN=ghp_fake_test_token"
  assert_line --index 1 "GH_REPO=owner/repo"
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
  # Remove the fake `security` and isolate PATH to a dir that has bash but no
  # `security` binary — otherwise macOS's `/usr/bin/security` leaks in, finds
  # the developer's real Keychain entry, and the script succeeds when this
  # test demands it fail. `/bin` ships bash on macOS but no security tool.
  rm "$FAKE_BIN/security"
  export PATH="$FAKE_BIN:/bin"

  run "$SANDBOX_ENV"
  [ "$status" -eq 2 ]
  assert_output --partial "security"
}

@test "output lines are valid KEY=value format parseable by collect_binding_env" {
  run "$SANDBOX_ENV"
  assert_success
  # Both output lines must match ^[A-Z_][A-Z0-9_]*= (the runner's validation regex).
  [[ "$output" =~ ^[A-Z_][A-Z0-9_]*= ]]
}

# ── GH_REPO URL parsing — success cases ──────────────────────────────────────

@test "SSH URL git@github.com — emits GH_REPO=owner/repo" {
  export GIT_FAKE_ORIGIN_URL="git@github.com:owner/repo.git"
  run "$SANDBOX_ENV"
  assert_success
  assert_line "GH_REPO=owner/repo"
}

@test "HTTPS URL with .git suffix — emits GH_REPO=owner/repo" {
  export GIT_FAKE_ORIGIN_URL="https://github.com/owner/repo.git"
  run "$SANDBOX_ENV"
  assert_success
  assert_line "GH_REPO=owner/repo"
}

@test "HTTPS URL without .git suffix — emits GH_REPO=owner/repo" {
  export GIT_FAKE_ORIGIN_URL="https://github.com/owner/repo"
  run "$SANDBOX_ENV"
  assert_success
  assert_line "GH_REPO=owner/repo"
}

@test "HTTPS URL with credentials — emits GH_REPO=owner/repo" {
  export GIT_FAKE_ORIGIN_URL="https://user:pass@github.com/owner/repo.git"
  run "$SANDBOX_ENV"
  assert_success
  assert_line "GH_REPO=owner/repo"
}

# ── GH_REPO URL parsing — lookalike hostname rejection ───────────────────────

@test "lookalike hostname self-hosted-github.com — exits 1 naming the host" {
  export GIT_FAKE_ORIGIN_URL="git@self-hosted-github.com:owner/repo.git"
  run "$SANDBOX_ENV"
  assert_failure
  assert_output --partial "self-hosted-github.com"
}

@test "lookalike hostname github.enterprise.com — exits 1 naming the host" {
  export GIT_FAKE_ORIGIN_URL="git@github.enterprise.com:owner/repo.git"
  run "$SANDBOX_ENV"
  assert_failure
  assert_output --partial "github.enterprise.com"
}

@test "lookalike hostname github.com.local — exits 1 naming the host" {
  export GIT_FAKE_ORIGIN_URL="git@github.com.local:owner/repo.git"
  run "$SANDBOX_ENV"
  assert_failure
  assert_output --partial "github.com.local"
}

@test "lookalike hostname my-github.com — exits 1 naming the host" {
  export GIT_FAKE_ORIGIN_URL="https://my-github.com/owner/repo.git"
  run "$SANDBOX_ENV"
  assert_failure
  assert_output --partial "my-github.com"
}

# ── Missing origin ────────────────────────────────────────────────────────────

@test "no origin remote — exits 1 with clear message" {
  export GIT_FAKE_NO_ORIGIN="1"
  run "$SANDBOX_ENV"
  assert_failure
  assert_output --partial "origin"
}

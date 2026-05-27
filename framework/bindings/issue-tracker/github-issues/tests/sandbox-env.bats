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
  # GIT_FAKE_ORIGIN_URL:  override the returned URL (default: https://github.com/owner/repo.git)
  # GIT_FAKE_NO_ORIGIN:   when non-empty, simulate a missing origin remote (exit non-zero)
  # GIT_FAKE_NO_TOPLEVEL: when non-empty, simulate running outside a git repo (rev-parse exits non-zero)
  cat >"$FAKE_BIN/git" <<'EOF'
#!/usr/bin/env bash
if [[ "$1" == "-C" ]]; then shift 2; fi
if [[ "$1" == "rev-parse" && "$2" == "--show-toplevel" ]]; then
  if [[ -n "${GIT_FAKE_NO_TOPLEVEL:-}" ]]; then
    echo "fatal: not a git repository (or any of the parent directories): .git" >&2; exit 128
  fi
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

# Mirror of the runner's collect_binding_env validation regex
# (framework/runner/run-the-queue.sh:1522 — applied per line). Returns 0 if
# every line matches, 1 otherwise. The runner-side validator is the contract;
# this helper re-states it locally until #49 extracts a shared validator.
_validate_output() {
  local _line
  while IFS= read -r _line; do
    [[ "$_line" =~ ^[A-Z_][A-Z0-9_]*= ]] || return 1
  done <<<"$1"
  return 0
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

@test "Keychain returns empty token — exits 1 with 'token is empty' message" {
  # Override shim to return an empty string for find-generic-password -w.
  cat >"$FAKE_BIN/security" <<'EOF'
#!/usr/bin/env bash
if [[ "$1" == "find-generic-password" ]]; then
  for arg in "$@"; do
    [[ "$arg" == "-w" ]] && { echo ""; exit 0; }
  done
fi
exit 1
EOF
  chmod +x "$FAKE_BIN/security"

  run "$SANDBOX_ENV"
  assert_failure
  assert_output --partial "token is empty"
}

@test "GH token never appears in stderr on any post-fetch failure path" {
  # The shim emits 'ghp_fake_test_token' on a successful Keychain lookup. Each
  # scenario below triggers a failure AFTER token retrieval, so the token has
  # been fetched (and printed to stdout) but the script aborts before emitting
  # GH_REPO. The script's documented invariant — header line 11, "The token is
  # NEVER written to stderr" — must hold across every post-fetch failure path.
  local tok="ghp_fake_test_token"
  local stderr

  stderr="$(GIT_FAKE_NO_TOPLEVEL=1 "$SANDBOX_ENV" 2>&1 >/dev/null)" || true
  [[ "$stderr" != *"$tok"* ]] || { echo "leaked in NO_TOPLEVEL: $stderr"; return 1; }

  stderr="$(GIT_FAKE_NO_ORIGIN=1 "$SANDBOX_ENV" 2>&1 >/dev/null)" || true
  [[ "$stderr" != *"$tok"* ]] || { echo "leaked in NO_ORIGIN: $stderr"; return 1; }

  stderr="$(GIT_FAKE_ORIGIN_URL='not-a-recognised-url' "$SANDBOX_ENV" 2>&1 >/dev/null)" || true
  [[ "$stderr" != *"$tok"* ]] || { echo "leaked in BAD_URL: $stderr"; return 1; }

  stderr="$(GIT_FAKE_ORIGIN_URL='git@github.evil.com:owner/repo.git' "$SANDBOX_ENV" 2>&1 >/dev/null)" || true
  [[ "$stderr" != *"$tok"* ]] || { echo "leaked in LOOKALIKE: $stderr"; return 1; }

  stderr="$(GIT_FAKE_ORIGIN_URL='git@github.com:owner/sub/repo.git' "$SANDBOX_ENV" 2>&1 >/dev/null)" || true
  [[ "$stderr" != *"$tok"* ]] || { echo "leaked in BAD_SHAPE: $stderr"; return 1; }
}

@test "output lines are valid KEY=value format parseable by collect_binding_env" {
  run "$SANDBOX_ENV"
  assert_success
  _validate_output "$output"
}

@test "validator rejects output with a malformed (lowercase-key) second line" {
  # Fixture: a valid first line followed by a lowercase-keyed second line —
  # the runner's per-line validator must reject this. If _validate_output
  # accepts it (e.g., because the assertion anchors at start of whole string
  # and only sees line 1), the bug at sandbox-env.bats:93 is back.
  local malformed="GH_TOKEN=ok
gh_repo=lowercase_bad"
  ! _validate_output "$malformed"
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

@test "ssh:// URL with user — emits GH_REPO=owner/repo" {
  export GIT_FAKE_ORIGIN_URL="ssh://git@github.com/owner/repo.git"
  run "$SANDBOX_ENV"
  assert_success
  assert_line "GH_REPO=owner/repo"
}

@test "ssh:// URL without user — emits GH_REPO=owner/repo" {
  export GIT_FAKE_ORIGIN_URL="ssh://github.com/owner/repo.git"
  run "$SANDBOX_ENV"
  assert_success
  assert_line "GH_REPO=owner/repo"
}

@test "ssh:// URL with explicit port — emits GH_REPO=owner/repo" {
  export GIT_FAKE_ORIGIN_URL="ssh://git@github.com:22/owner/repo.git"
  run "$SANDBOX_ENV"
  assert_success
  assert_line "GH_REPO=owner/repo"
}

@test "ssh:// URL without .git suffix — emits GH_REPO=owner/repo" {
  export GIT_FAKE_ORIGIN_URL="ssh://git@github.com/owner/repo"
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

@test "ssh:// URL with lookalike hostname — exits 1 naming the host" {
  export GIT_FAKE_ORIGIN_URL="ssh://git@github.evil.com/owner/repo.git"
  run "$SANDBOX_ENV"
  assert_failure
  assert_output --partial "github.evil.com"
}

# ── GH_REPO URL parsing — malformed path-shape rejection ────────────────────

@test "SCP-SSH URL with sub-path — exits 1 naming the bad URL" {
  export GIT_FAKE_ORIGIN_URL="git@github.com:owner/sub/repo.git"
  run "$SANDBOX_ENV"
  assert_failure
  assert_output --partial "owner/repo"
  assert_output --partial "owner/sub/repo"
}

@test "HTTPS URL with sub-path — exits 1 naming the bad URL" {
  export GIT_FAKE_ORIGIN_URL="https://github.com/foo/bar/baz"
  run "$SANDBOX_ENV"
  assert_failure
  assert_output --partial "owner/repo"
  assert_output --partial "foo/bar/baz"
}

@test "ssh:// URL with sub-path — exits 1 naming the bad URL" {
  export GIT_FAKE_ORIGIN_URL="ssh://git@github.com/foo/bar/baz"
  run "$SANDBOX_ENV"
  assert_failure
  assert_output --partial "owner/repo"
  assert_output --partial "foo/bar/baz"
}

@test "HTTPS URL with single segment — exits 1 naming the bad URL" {
  export GIT_FAKE_ORIGIN_URL="https://github.com/just-one.git"
  run "$SANDBOX_ENV"
  assert_failure
  assert_output --partial "owner/repo"
  assert_output --partial "just-one"
}

@test "ssh:// URL with single segment — exits 1 naming the bad URL" {
  export GIT_FAKE_ORIGIN_URL="ssh://git@github.com/just-one.git"
  run "$SANDBOX_ENV"
  assert_failure
  assert_output --partial "owner/repo"
  assert_output --partial "just-one"
}

# ── Missing origin / outside repo ─────────────────────────────────────────────

@test "no origin remote — exits 1 with clear message" {
  export GIT_FAKE_NO_ORIGIN="1"
  run "$SANDBOX_ENV"
  assert_failure
  assert_output --partial "origin"
}

@test "not inside a git repository — exits 1 with clear message" {
  export GIT_FAKE_NO_TOPLEVEL="1"
  run "$SANDBOX_ENV"
  assert_failure
  assert_output --partial "not inside a git repository"
}

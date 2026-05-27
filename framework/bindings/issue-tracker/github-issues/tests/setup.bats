#!/usr/bin/env bats

setup() {
  load 'test_helper/bats-support/load'
  load 'test_helper/bats-assert/load'

  HERE="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)"
  SETUP_SCRIPT="$HERE/../setup"

  FAKE_BIN="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$FAKE_BIN"
  CALL_LOG="$BATS_TEST_TMPDIR/calls.log"

  # gh shim: record calls, succeed (used by bootstrap-labels).
  cat >"$FAKE_BIN/gh" <<'EOF'
#!/usr/bin/env bash
echo "gh $*" >> "$CALL_LOG"
exit 0
EOF
  chmod +x "$FAKE_BIN/gh"

  # security shim: SECURITY_FAKE_PRESENT=1 simulates an existing Keychain entry.
  # Writes a marker line to CALL_LOG when add-generic-password is called.
  cat >"$FAKE_BIN/security" <<'EOF'
#!/usr/bin/env bash
case "$1" in
  find-generic-password)
    if [[ "${SECURITY_FAKE_PRESENT:-}" == "1" ]]; then
      exit 0
    fi
    echo "security: SecKeychainSearchCopyNext: The specified item could not be found in the keychain." >&2
    exit 44
    ;;
  add-generic-password)
    echo "add-generic-password" >> "$CALL_LOG"
    exit 0
    ;;
  *)
    exit 1
    ;;
esac
EOF
  chmod +x "$FAKE_BIN/security"

  export CALL_LOG
  export GH_TOKEN="fake-token-for-tests"
  export PATH="$FAKE_BIN:$PATH"
  # Force the macOS code path so the Keychain check runs on a Linux CI host.
  export OSTYPE="darwin21"
}

@test "Keychain entry absent — calls add-generic-password to prompt maintainer" {
  run "$SETUP_SCRIPT"
  assert_success
  run grep -q "^add-generic-password" "$CALL_LOG"
  assert_success
}

@test "Keychain entry present — silent no-op (add-generic-password not called)" {
  export SECURITY_FAKE_PRESENT="1"
  run "$SETUP_SCRIPT"
  assert_success
  run grep -q "^add-generic-password" "$CALL_LOG" 2>/dev/null
  assert_failure
}

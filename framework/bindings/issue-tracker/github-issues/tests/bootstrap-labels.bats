#!/usr/bin/env bats

setup() {
  load 'test_helper/bats-support/load'
  load 'test_helper/bats-assert/load'

  HERE="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)"
  BOOTSTRAP_LABELS="$HERE/../bootstrap-labels"

  # Scratch dir for this test: a fake gh shim + call log
  FAKE_BIN="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$FAKE_BIN"
  CALL_LOG="$BATS_TEST_TMPDIR/gh-calls.log"

  # Build a gh shim that records every invocation and succeeds.
  cat >"$FAKE_BIN/gh" <<'EOF'
#!/usr/bin/env bash
echo "$@" >> "$CALL_LOG"
exit 0
EOF
  chmod +x "$FAKE_BIN/gh"
  export CALL_LOG
  export PATH="$FAKE_BIN:$PATH"

  # Ensure GH_TOKEN is set so the auth guard passes without calling gh auth status.
  export GH_TOKEN="fake-token-for-tests"
}

# ---------------------------------------------------------------------------
# Helper: count label create calls recorded in the call log.
# ---------------------------------------------------------------------------
label_create_calls() {
  grep -c "^label create" "$CALL_LOG" 2>/dev/null || echo 0
}

# ---------------------------------------------------------------------------
# Static label inventory (must match bootstrap-labels exactly)
# ---------------------------------------------------------------------------
EXPECTED_LABELS=(
  "formann:feature"
  "formann:archived"
  "formann:status:needs-triage"
  "formann:status:needs-info"
  "formann:status:ready-for-agent"
  "formann:status:ready-for-human"
  "formann:status:in-review"
  "formann:status:wontfix"
  "formann:category:bug"
  "formann:category:enhancement"
  "formann:type:afk"
  "formann:type:hitl"
)

# ---------------------------------------------------------------------------

@test "creates every label in the static namespace" {
  run "$BOOTSTRAP_LABELS"
  assert_success

  # `gh label create` takes the label name as a *positional* argument, not
  # a --name flag. Assert on the positional form so this test fails when the
  # script drifts back to --name (which gh CLI rejects with "unknown flag").
  for label in "${EXPECTED_LABELS[@]}"; do
    assert grep -qE -- "^label create --force $label( |$)" "$CALL_LOG"
  done
}

@test "uses --force on every label create call" {
  run "$BOOTSTRAP_LABELS"
  assert_success

  # Every recorded gh call must be a 'label create --force ...' call.
  while IFS= read -r line; do
    [[ "$line" == label\ create\ --force* ]] || {
      echo "Found gh call without --force: $line" >&2
      return 1
    }
  done < "$CALL_LOG"
}

@test "idempotent — second run succeeds and issues the same calls" {
  run "$BOOTSTRAP_LABELS"
  assert_success
  first_count="$(label_create_calls)"

  # Reset call log and run again.
  : >"$CALL_LOG"
  run "$BOOTSTRAP_LABELS"
  assert_success
  second_count="$(label_create_calls)"

  [ "$first_count" = "$second_count" ]
}

@test "missing-token — exits non-zero with a clear stderr message" {
  # Override: gh shim that fails on 'auth status' to simulate no local auth.
  cat >"$FAKE_BIN/gh" <<'EOF'
#!/usr/bin/env bash
if [[ "$1" = "auth" && "$2" = "status" ]]; then
  echo "You are not logged into any GitHub hosts." >&2
  exit 1
fi
echo "$@" >> "$CALL_LOG"
exit 0
EOF
  chmod +x "$FAKE_BIN/gh"

  # Remove GH_TOKEN so the script must fall back to gh auth status.
  unset GH_TOKEN

  run "$BOOTSTRAP_LABELS"
  assert_failure
  assert_output --partial "not authenticated"
}

@test "missing gh binary — exits non-zero with a clear stderr message" {
  # Remove the fake gh and isolate PATH to system dirs only — otherwise the
  # host's real `gh` (Homebrew, etc.) leaks in and the test passes on machines
  # without gh installed but fails on developer machines with `gh auth login`
  # already set up.
  rm "$FAKE_BIN/gh"
  unset GH_TOKEN
  export PATH="/usr/bin:/bin"

  run "$BOOTSTRAP_LABELS"
  assert_failure
  assert_output --partial "gh"
}

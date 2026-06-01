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

@test "creates exactly the declared labels — both directions" {
  # Derive the expected set from the script's create_label invocations so
  # a label added to or removed from the script changes the test outcome
  # with no manual edit to a parallel list.
  DECLARED_LABELS=()
  while IFS= read -r name; do
    DECLARED_LABELS+=("$name")
  done < <(grep -E '^create_label ' "$BOOTSTRAP_LABELS" | sed -E 's/^create_label "([^"]+)".*/\1/')

  run "$BOOTSTRAP_LABELS"
  assert_success

  # Extract the label name from each recorded 'label create --force <name> ...' call.
  CREATED_LABELS=()
  while IFS= read -r line; do
    if [[ "$line" == label\ create\ --force\ * ]]; then
      rest="${line#label create --force }"
      CREATED_LABELS+=("${rest%% *}")
    fi
  done < "$CALL_LOG"

  # Direction 1: every declared label must be created at runtime.
  for name in "${DECLARED_LABELS[@]}"; do
    found=0
    for created in "${CREATED_LABELS[@]}"; do
      [[ "$created" == "$name" ]] && found=1 && break
    done
    [[ "$found" -eq 1 ]] || {
      echo "Declared label '$name' was not created at runtime" >&2
      return 1
    }
  done

  # Direction 2: every label created at runtime must be declared in the script.
  for created in "${CREATED_LABELS[@]}"; do
    found=0
    for name in "${DECLARED_LABELS[@]}"; do
      [[ "$name" == "$created" ]] && found=1 && break
    done
    [[ "$found" -eq 1 ]] || {
      echo "Label '$created' was created at runtime but is not declared in the script" >&2
      return 1
    }
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

#!/usr/bin/env bats
bats_require_minimum_version 1.5.0

setup() {
  load 'test_helper/bats-support/load'
  load 'test_helper/bats-assert/load'

  HERE="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)"
  SET_BLOCKERS="$HERE/../set-blockers"
  FIXTURES="$HERE/fixtures"

  # Scratch dir for gh shim + call log
  FAKE_BIN="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$FAKE_BIN"
  CALL_LOG="$BATS_TEST_TMPDIR/gh-calls.log"
  : >"$CALL_LOG"

  # gh shim: intercepts `gh api graphql`, records calls, serves numbered fixtures.
  # Writes exactly one marker line per call so wc -l gives the correct prior count.
  # (grep -c exits 1 on zero matches, which causes `|| echo 0` to double-output.)
  cat >"$FAKE_BIN/gh" <<'SHIM'
#!/usr/bin/env bash
if [ "$1" = "api" ] && [ "$2" = "graphql" ]; then
  prior_count=$(wc -l <"${CALL_LOG}" 2>/dev/null | tr -d ' ')
  : "${prior_count:=0}"
  call_num=$((prior_count + 1))
  echo "graphql call $call_num" >>"${CALL_LOG}"

  fail_n="${FAIL_FIRST_N:-0}"
  if [ "$call_num" -le "$fail_n" ]; then
    echo "gh: API rate limit exceeded" >&2
    exit 1
  fi

  if [ -f "${FIXTURE_RESPONSES_DIR}/graphql-response-${call_num}.json" ]; then
    cat "${FIXTURE_RESPONSES_DIR}/graphql-response-${call_num}.json"
    exit 0
  elif [ -f "${FIXTURE_RESPONSES_DIR}/graphql-response.json" ]; then
    cat "${FIXTURE_RESPONSES_DIR}/graphql-response.json"
    exit 0
  fi

  echo "shim: no fixture response for call $call_num in ${FIXTURE_RESPONSES_DIR}" >&2
  exit 1
fi
echo "shim: unexpected gh command: $*" >&2
exit 1
SHIM
  chmod +x "$FAKE_BIN/gh"

  export CALL_LOG
  export PATH="$FAKE_BIN:$PATH"
  export GH_TRACKER_REPO="test-owner/test-repo"
  export PATH="$HOME/bin:$PATH"
}

graphql_call_count() {
  grep -c "^graphql call" "$CALL_LOG" 2>/dev/null || echo 0
}

# ════════════════════════════════════════════════════════════════════════════════
# Core mutation cases
# ════════════════════════════════════════════════════════════════════════════════

@test "add-only: no current blockers, request one — fires one addBlockedBy" {
  # Calls: (1) read state, (2) resolve #5 node ID, (3) addBlockedBy mutation
  export FIXTURE_RESPONSES_DIR="$FIXTURES/set-blockers-add-only/recorded-responses"
  run "$SET_BLOCKERS" 10 '#5'
  assert_success
  count="$(graphql_call_count)"
  [ "$count" -eq 3 ]
}

@test "remove-only: one current blocker, request empty set — fires one removeBlockedBy" {
  # Calls: (1) read state (has #5), (2) removeBlockedBy mutation
  export FIXTURE_RESPONSES_DIR="$FIXTURES/set-blockers-remove-only/recorded-responses"
  run "$SET_BLOCKERS" 10
  assert_success
  count="$(graphql_call_count)"
  [ "$count" -eq 2 ]
}

@test "clear-all: two current blockers, request empty set — fires two removeBlockedBy" {
  # Calls: (1) read state (has #5 and #6), (2) removeBlockedBy #5, (3) removeBlockedBy #6
  export FIXTURE_RESPONSES_DIR="$FIXTURES/set-blockers-clear-all/recorded-responses"
  run "$SET_BLOCKERS" 10
  assert_success
  count="$(graphql_call_count)"
  [ "$count" -eq 3 ]
}

@test "mixed: one existing blocker replaced by a different one — fires remove then add" {
  # Calls: (1) read state (has #5), (2) removeBlockedBy #5, (3) resolve #7, (4) addBlockedBy #7
  export FIXTURE_RESPONSES_DIR="$FIXTURES/set-blockers-mixed/recorded-responses"
  run "$SET_BLOCKERS" 10 '#7'
  assert_success
  count="$(graphql_call_count)"
  [ "$count" -eq 4 ]
}

@test "idempotent no-op: requested set matches current — no mutations fired" {
  # Calls: (1) read state only — already has #5, no diff
  export FIXTURE_RESPONSES_DIR="$FIXTURES/set-blockers-idempotent-noop/recorded-responses"
  run "$SET_BLOCKERS" 10 '#5'
  assert_success
  count="$(graphql_call_count)"
  [ "$count" -eq 1 ]
}

# ════════════════════════════════════════════════════════════════════════════════
# Ref formats
# ════════════════════════════════════════════════════════════════════════════════

@test "ref without leading # accepted — treated as issue number" {
  # Same as add-only but passes '5' instead of '#5'
  export FIXTURE_RESPONSES_DIR="$FIXTURES/set-blockers-add-only/recorded-responses"
  run "$SET_BLOCKERS" 10 5
  assert_success
  count="$(graphql_call_count)"
  [ "$count" -eq 3 ]
}

@test "target without leading # accepted — treated as issue number" {
  export FIXTURE_RESPONSES_DIR="$FIXTURES/set-blockers-idempotent-noop/recorded-responses"
  run "$SET_BLOCKERS" '#10' '#5'
  assert_success
  count="$(graphql_call_count)"
  [ "$count" -eq 1 ]
}

# ════════════════════════════════════════════════════════════════════════════════
# Usage errors
# ════════════════════════════════════════════════════════════════════════════════

@test "missing argument exits non-zero with usage message" {
  run "$SET_BLOCKERS"
  assert_failure
  assert_output --partial "usage: set-blockers"
}

@test "duplicate ref in argv exits non-zero with usage message" {
  run "$SET_BLOCKERS" 10 '#5' '#5'
  assert_failure
  assert_output --partial "duplicate blocker ref"
}

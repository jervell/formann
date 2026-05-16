#!/usr/bin/env bats
bats_require_minimum_version 1.5.0

setup() {
  load 'test_helper/bats-support/load'
  load 'test_helper/bats-assert/load'

  HERE="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)"
  TRACKER_SNAPSHOT="$HERE/../tracker-snapshot"
  FIXTURES="$HERE/fixtures"

  # Scratch dir for gh shim + call log
  FAKE_BIN="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$FAKE_BIN"
  CALL_LOG="$BATS_TEST_TMPDIR/gh-calls.log"
  : >"$CALL_LOG"

  # Create the gh shim.
  # Handles: gh api graphql → records call, optionally fails (FAIL_FIRST_N),
  # then serves ${FIXTURE_RESPONSES_DIR}/graphql-response.json.
  cat >"$FAKE_BIN/gh" <<'SHIM'
#!/usr/bin/env bash
if [ "$1" = "api" ] && [ "$2" = "graphql" ]; then
  # Count calls (this call not yet recorded)
  prior_count=$(wc -l <"${CALL_LOG}" 2>/dev/null | tr -d ' ')
  call_num=$((prior_count + 1))
  echo "graphql call $call_num: $*" >>"${CALL_LOG}"

  # Optionally fail the first N calls to simulate transient errors
  fail_n="${FAIL_FIRST_N:-0}"
  if [ "$call_num" -le "$fail_n" ]; then
    echo "gh: API rate limit exceeded" >&2
    exit 1
  fi

  # Serve the fixture response
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

  # Prepend fake bin so our shim wins PATH lookup.
  export CALL_LOG
  export PATH="$FAKE_BIN:$PATH"

  # Suppress git-remote detection — all tests use the env var override.
  export GH_TRACKER_REPO="test-owner/test-repo"

  # Ensure jq is available (installed to ~/bin in this environment).
  export PATH="$HOME/bin:$PATH"
}

# ── Helper: compare snapshot output to an expected.json (jq-normalised) ───────
assert_snapshot_matches_golden() {
  local scenario="$1" slug="$2"
  export FIXTURE_RESPONSES_DIR="$FIXTURES/$scenario/recorded-responses"
  run "$TRACKER_SNAPSHOT" "$slug"
  assert_success
  diff \
    <(printf '%s\n' "$output" | jq -S .) \
    <(jq -S . "$FIXTURES/$scenario/expected.json")
}

# ── Helper: graphql call count ────────────────────────────────────────────────
graphql_call_count() {
  grep -c "^graphql call" "$CALL_LOG" 2>/dev/null || echo 0
}

# ════════════════════════════════════════════════════════════════════════════════
# Slug-mode fixtures
# ════════════════════════════════════════════════════════════════════════════════

@test "empty feature — 0 sub-issues yields empty issues array" {
  assert_snapshot_matches_golden "empty-feature" "empty-feature"
}

@test "single-issue feature — correct ref, status, category, type, eligible" {
  assert_snapshot_matches_golden "single-issue-feature" "single-issue-feature"
}

@test "multi-issue priority ordering — subIssues API order preserved, #N tiebreaker" {
  assert_snapshot_matches_golden "multi-issue-priority-tiebreaker" "multi-issue"
}

@test "unresolved #N blocker — conservative-false eligibility" {
  assert_snapshot_matches_golden "unresolved-blocker-conservative-false" "unresolved-blocker"
}

# ── Slug mode: 0-match case ───────────────────────────────────────────────────
@test "slug mode: 0 parent matches — emits empty snapshot and exits 0" {
  export FIXTURE_RESPONSES_DIR="$BATS_TEST_TMPDIR/zero-match"
  mkdir -p "$FIXTURE_RESPONSES_DIR"
  cat >"$FIXTURE_RESPONSES_DIR/graphql-response.json" <<'JSON'
{"data":{"repository":{"issues":{"nodes":[]}}}}
JSON
  run "$TRACKER_SNAPSHOT" "no-such-feature"
  assert_success
  feature="$(printf '%s\n' "$output" | jq -r '.feature')"
  count="$(printf '%s\n' "$output" | jq '.issues | length')"
  [ "$feature" = "no-such-feature" ]
  [ "$count" = "0" ]
}

# ── Slug mode: slug collision (≥2 matches) ────────────────────────────────────
@test "slug-collision — exits non-zero (code 4) and names both parents on stderr" {
  export FIXTURE_RESPONSES_DIR="$FIXTURES/slug-collision/recorded-responses"
  run "$TRACKER_SNAPSHOT" "my-feature"
  [ "$status" -eq 4 ]
  assert_output --partial "#8"
  assert_output --partial "#11"
}

# ── One GraphQL query per invocation ─────────────────────────────────────────
@test "one GraphQL query per slug invocation" {
  export FIXTURE_RESPONSES_DIR="$FIXTURES/single-issue-feature/recorded-responses"
  run "$TRACKER_SNAPSHOT" "single-issue-feature"
  assert_success
  count="$(graphql_call_count)"
  [ "$count" -eq 1 ]
}

@test "one GraphQL query per --list invocation" {
  export FIXTURE_RESPONSES_DIR="$FIXTURES/list-archived-excluded/recorded-responses"
  run "$TRACKER_SNAPSHOT" --list
  assert_success
  count="$(graphql_call_count)"
  [ "$count" -eq 1 ]
}

# ════════════════════════════════════════════════════════════════════════════════
# --list mode fixtures
# ════════════════════════════════════════════════════════════════════════════════

@test "--list: archived (closed) parent absent — only open parents returned" {
  export FIXTURE_RESPONSES_DIR="$FIXTURES/list-archived-excluded/recorded-responses"
  run "$TRACKER_SNAPSHOT" --list
  assert_success
  diff \
    <(printf '%s\n' "$output" | jq -S .) \
    <(jq -S . "$FIXTURES/list-archived-excluded/expected.json")
}

@test "--list: ordered by #N ascending (query uses orderBy NUMBER ASC)" {
  # Fixture returns issues in order #3, #7 — verify output preserves that order.
  export FIXTURE_RESPONSES_DIR="$FIXTURES/list-archived-excluded/recorded-responses"
  run "$TRACKER_SNAPSHOT" --list
  assert_success
  first="$(printf '%s\n' "$output" | jq -r '.[0]')"
  second="$(printf '%s\n' "$output" | jq -r '.[1]')"
  [ "$first" = "alpha-feature" ]
  [ "$second" = "beta-feature" ]
}

@test "--list: issues with no formann:slug:* label are silently skipped" {
  export FIXTURE_RESPONSES_DIR="$BATS_TEST_TMPDIR/no-slug"
  mkdir -p "$FIXTURE_RESPONSES_DIR"
  cat >"$FIXTURE_RESPONSES_DIR/graphql-response.json" <<'JSON'
{
  "data": {
    "repository": {
      "issues": {
        "nodes": [
          {"number": 1, "labels": {"nodes": [{"name": "formann:feature"}]}},
          {"number": 2, "labels": {"nodes": [{"name": "formann:feature"}, {"name": "formann:slug:has-slug"}]}}
        ]
      }
    }
  }
}
JSON
  run "$TRACKER_SNAPSHOT" --list
  assert_success
  count="$(printf '%s\n' "$output" | jq 'length')"
  slug="$(printf '%s\n' "$output" | jq -r '.[0]')"
  [ "$count" = "1" ]
  [ "$slug" = "has-slug" ]
}

@test "--list: duplicate slug warns on stderr, deduplicates in output" {
  export FIXTURE_RESPONSES_DIR="$BATS_TEST_TMPDIR/dupe-slug"
  mkdir -p "$FIXTURE_RESPONSES_DIR"
  cat >"$FIXTURE_RESPONSES_DIR/graphql-response.json" <<'JSON'
{
  "data": {
    "repository": {
      "issues": {
        "nodes": [
          {"number": 5, "labels": {"nodes": [{"name": "formann:feature"}, {"name": "formann:slug:shared"}]}},
          {"number": 9, "labels": {"nodes": [{"name": "formann:feature"}, {"name": "formann:slug:shared"}]}}
        ]
      }
    }
  }
}
JSON
  run --separate-stderr "$TRACKER_SNAPSHOT" --list
  assert_success
  # Slug appears only once in the JSON array (stdout only)
  count="$(printf '%s\n' "$output" | jq 'length')"
  [ "$count" = "1" ]
  # Warning mentions both parent numbers on stderr
  [[ "$stderr" == *"#5"* ]] || { echo "Expected #5 in stderr: $stderr" >&2; return 1; }
  [[ "$stderr" == *"#9"* ]] || { echo "Expected #9 in stderr: $stderr" >&2; return 1; }
  [[ "$stderr" == *"shared"* ]] || { echo "Expected 'shared' in stderr: $stderr" >&2; return 1; }
}

# ════════════════════════════════════════════════════════════════════════════════
# Transient failure / retry
# ════════════════════════════════════════════════════════════════════════════════

@test "transient-error retry success — first call fails, second succeeds, output correct" {
  export FIXTURE_RESPONSES_DIR="$FIXTURES/transient-error-retry-success/recorded-responses"
  export FAIL_FIRST_N=1
  run --separate-stderr "$TRACKER_SNAPSHOT" "retry-feature"
  assert_success
  count="$(graphql_call_count)"
  [ "$count" -ge 2 ]
  issue_count="$(printf '%s\n' "$output" | jq '.issues | length')"
  [ "$issue_count" = "1" ]
}

@test "transient-error retry exhaustion — all calls fail, exits with code 3" {
  export FIXTURE_RESPONSES_DIR="$BATS_TEST_TMPDIR/always-fail"
  mkdir -p "$FIXTURE_RESPONSES_DIR"
  export FAIL_FIRST_N=99
  run "$TRACKER_SNAPSHOT" "some-feature"
  [ "$status" -eq 3 ]
  assert_output --partial "failed after"
}

# ════════════════════════════════════════════════════════════════════════════════
# Usage and pre-condition errors
# ════════════════════════════════════════════════════════════════════════════════

@test "missing argument exits non-zero with usage message" {
  run "$TRACKER_SNAPSHOT"
  assert_failure
  assert_output --partial "usage: tracker-snapshot"
}

@test "done sub-issue is not eligible even with correct status label absent" {
  # done is derived from state=CLOSED+stateReason=COMPLETED, not from a label.
  export FIXTURE_RESPONSES_DIR="$BATS_TEST_TMPDIR/done-closed"
  mkdir -p "$FIXTURE_RESPONSES_DIR"
  cat >"$FIXTURE_RESPONSES_DIR/graphql-response.json" <<'JSON'
{
  "data": {
    "repository": {
      "issues": {
        "nodes": [
          {
            "number": 1,
            "subIssues": {
              "nodes": [
                {
                  "number": 2,
                  "state": "CLOSED",
                  "stateReason": "COMPLETED",
                  "body": "## Blocked by\n\nNone.",
                  "labels": {"nodes": [{"name": "formann:category:enhancement"}, {"name": "formann:type:afk"}]}
                }
              ]
            }
          }
        ]
      }
    }
  }
}
JSON
  run "$TRACKER_SNAPSHOT" "done-feature"
  assert_success
  status_val="$(printf '%s\n' "$output" | jq -r '.issues[0].status')"
  eligible_val="$(printf '%s\n' "$output" | jq -r '.issues[0].eligible')"
  [ "$status_val" = "done" ]
  [ "$eligible_val" = "false" ]
}

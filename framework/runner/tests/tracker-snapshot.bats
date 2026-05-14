#!/usr/bin/env bats

setup() {
  load 'test_helper/bats-support/load'
  load 'test_helper/bats-assert/load'

  HERE="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)"
  TRACKER_SNAPSHOT="$HERE/../../bindings/issue-tracker/local-markdown/tracker-snapshot"
  FIXTURES="$HERE/fixtures"
  export TRACKER_SCRATCH_ROOT="$FIXTURES"
}

# Compare the script's stdout to the fixture's expected.json after
# canonicalising both via `jq -S`. Diff output appears in the bats
# failure log so a golden mismatch is self-explaining.
assert_snapshot_matches_golden() {
  local feature="$1"
  run "$TRACKER_SNAPSHOT" "$feature"
  assert_success
  diff \
    <(printf '%s\n' "$output" | jq -S .) \
    <(jq -S . "$FIXTURES/$feature/expected.json")
}

@test "case 1 — eligible with no blockers" {
  assert_snapshot_matches_golden "eligible-no-blockers"
}

@test "case 2 — eligible with all-done blockers" {
  assert_snapshot_matches_golden "eligible-all-done-blockers"
}

@test "case 3 — ineligible due to unmet blockers" {
  assert_snapshot_matches_golden "ineligible-unmet-blockers"
}

@test "case 4 — ineligible HITL (status passes, type fails)" {
  assert_snapshot_matches_golden "ineligible-hitl"
}

@test "case 5 — every non-ready-for-agent status is ineligible" {
  assert_snapshot_matches_golden "non-ready-states"
}

@test "case 6 — malformed frontmatter surfaces parse_error" {
  assert_snapshot_matches_golden "malformed-frontmatter"
}

@test "case 7 — cross-feature blocker forces eligible:false" {
  assert_snapshot_matches_golden "cross-feature-blocker"
}

@test "missing argument exits non-zero with usage" {
  run "$TRACKER_SNAPSHOT"
  assert_failure
  assert_output --partial "usage: tracker-snapshot"
}

# === tracker-snapshot --list ================================================
#
# Additive flag: emits a JSON array of active feature slugs (subdirs of
# scratch_root excluding done/). Today's bare invocation (no --list, no slug)
# keeps exiting 2 with a usage line — the contract grows additively.

@test "--list — emits a JSON array of active slugs" {
  local scratch="$BATS_TEST_TMPDIR/scratch-list"
  mkdir -p "$scratch/alpha" "$scratch/beta"
  TRACKER_SCRATCH_ROOT="$scratch" run "$TRACKER_SNAPSHOT" --list
  assert_success
  local count
  count="$(printf '%s\n' "$output" | jq 'length')"
  [ "$count" = "2" ]
  local slugs
  slugs="$(printf '%s\n' "$output" | jq -r '.[]' | sort | tr '\n' ' ' | sed 's/ $//')"
  [ "$slugs" = "alpha beta" ]
}

@test "--list — excludes done/ directory and its contents" {
  local scratch="$BATS_TEST_TMPDIR/scratch-done"
  mkdir -p "$scratch/active" "$scratch/done" "$scratch/done/archived"
  TRACKER_SCRATCH_ROOT="$scratch" run "$TRACKER_SNAPSHOT" --list
  assert_success
  local count
  count="$(printf '%s\n' "$output" | jq 'length')"
  [ "$count" = "1" ]
  local slug
  slug="$(printf '%s\n' "$output" | jq -r '.[0]')"
  [ "$slug" = "active" ]
}

@test "--list — ordering is deterministic (sorted by name)" {
  local scratch="$BATS_TEST_TMPDIR/scratch-order"
  mkdir -p "$scratch/zebra" "$scratch/apple" "$scratch/mango"
  TRACKER_SCRATCH_ROOT="$scratch" run "$TRACKER_SNAPSHOT" --list
  assert_success
  local first second third
  first="$(printf '%s\n' "$output" | jq -r '.[0]')"
  second="$(printf '%s\n' "$output" | jq -r '.[1]')"
  third="$(printf '%s\n' "$output" | jq -r '.[2]')"
  [ "$first" = "apple" ]
  [ "$second" = "mango" ]
  [ "$third" = "zebra" ]
}

@test "--list — empty scratch root yields empty array" {
  local scratch="$BATS_TEST_TMPDIR/scratch-empty"
  mkdir -p "$scratch"
  TRACKER_SCRATCH_ROOT="$scratch" run "$TRACKER_SNAPSHOT" --list
  assert_success
  local count
  count="$(printf '%s\n' "$output" | jq 'length')"
  [ "$count" = "0" ]
}

@test "--list — nonexistent scratch root yields empty array" {
  TRACKER_SCRATCH_ROOT="$BATS_TEST_TMPDIR/no-such-dir" run "$TRACKER_SNAPSHOT" --list
  assert_success
  local count
  count="$(printf '%s\n' "$output" | jq 'length')"
  [ "$count" = "0" ]
}

@test "CRLF-encoded issue files are parsed, not silently dropped" {
  # Regression: parse_frontmatter compared each line to the bare string
  # `---`, but `read -r` does not strip a trailing `\r`. A CRLF-saved
  # issue file's `---\r` opener never matched, the parser fell through
  # to "no frontmatter" mode, and the issue surfaced with empty
  # status/type, eligible:false, and *no* parse_error — invisible to
  # the runner and the maintainer alike. The fix strips `\r` from each
  # line before comparison so the parser handles CRLF transparently.
  local feature_dir="$BATS_TEST_TMPDIR/scratch/crlf-feature/issues"
  mkdir -p "$feature_dir"
  # Write the issue with CRLF line endings throughout.
  printf -- '---\r\nstatus: ready-for-agent\r\ncategory: enhancement\r\ntype: AFK\r\n---\r\n\r\n# CRLF\r\n\r\n## Blocked by\r\n\r\nNone.\r\n' \
    >"$feature_dir/01-crlf.md"

  TRACKER_SCRATCH_ROOT="$BATS_TEST_TMPDIR/scratch" \
    run "$TRACKER_SNAPSHOT" "crlf-feature"
  assert_success

  # Issue parsed: status/type populated, eligible:true, no parse_error.
  local status_field type_field eligible_field has_parse_error
  status_field="$(printf '%s\n' "$output" | jq -r '.issues[0].status')"
  type_field="$(printf '%s\n' "$output" | jq -r '.issues[0].type')"
  eligible_field="$(printf '%s\n' "$output" | jq -r '.issues[0].eligible')"
  has_parse_error="$(printf '%s\n' "$output" | jq 'has("issues") and (.issues[0] | has("parse_error"))')"
  [ "$status_field" = "ready-for-agent" ]
  [ "$type_field" = "AFK" ]
  [ "$eligible_field" = "true" ]
  [ "$has_parse_error" = "false" ]
}

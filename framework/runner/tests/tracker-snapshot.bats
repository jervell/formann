#!/usr/bin/env bats

setup() {
  load 'test_helper/bats-support/load'
  load 'test_helper/bats-assert/load'

  HERE="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)"
  TRACKER_SNAPSHOT="$HERE/../../bindings/issue-tracker/local-markdown/tracker-snapshot"
  FIXTURES="$HERE/fixtures"
  export TRACKER_ROOT="$FIXTURES"
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
# tracker_root excluding done/). Today's bare invocation (no --list, no slug)
# keeps exiting 2 with a usage line — the contract grows additively.

@test "--list — emits a JSON array of active slugs" {
  local tracker_root="$BATS_TEST_TMPDIR/tracker-list"
  mkdir -p "$tracker_root/alpha" "$tracker_root/beta"
  TRACKER_ROOT="$tracker_root" run "$TRACKER_SNAPSHOT" --list
  assert_success
  local count
  count="$(printf '%s\n' "$output" | jq 'length')"
  [ "$count" = "2" ]
  local slugs
  slugs="$(printf '%s\n' "$output" | jq -r '.[]' | sort | tr '\n' ' ' | sed 's/ $//')"
  [ "$slugs" = "alpha beta" ]
}

@test "--list — excludes done/ directory and its contents" {
  local tracker_root="$BATS_TEST_TMPDIR/tracker-done"
  mkdir -p "$tracker_root/active" "$tracker_root/done" "$tracker_root/done/archived"
  TRACKER_ROOT="$tracker_root" run "$TRACKER_SNAPSHOT" --list
  assert_success
  local count
  count="$(printf '%s\n' "$output" | jq 'length')"
  [ "$count" = "1" ]
  local slug
  slug="$(printf '%s\n' "$output" | jq -r '.[0]')"
  [ "$slug" = "active" ]
}

@test "--list — ordering is deterministic (sorted by name)" {
  local tracker_root="$BATS_TEST_TMPDIR/tracker-order"
  mkdir -p "$tracker_root/zebra" "$tracker_root/apple" "$tracker_root/mango"
  TRACKER_ROOT="$tracker_root" run "$TRACKER_SNAPSHOT" --list
  assert_success
  local first second third
  first="$(printf '%s\n' "$output" | jq -r '.[0]')"
  second="$(printf '%s\n' "$output" | jq -r '.[1]')"
  third="$(printf '%s\n' "$output" | jq -r '.[2]')"
  [ "$first" = "apple" ]
  [ "$second" = "mango" ]
  [ "$third" = "zebra" ]
}

@test "--list — empty tracker root yields empty array" {
  local tracker_root="$BATS_TEST_TMPDIR/tracker-empty"
  mkdir -p "$tracker_root"
  TRACKER_ROOT="$tracker_root" run "$TRACKER_SNAPSHOT" --list
  assert_success
  local count
  count="$(printf '%s\n' "$output" | jq 'length')"
  [ "$count" = "0" ]
}

@test "--list — nonexistent tracker root yields empty array" {
  TRACKER_ROOT="$BATS_TEST_TMPDIR/no-such-dir" run "$TRACKER_SNAPSHOT" --list
  assert_success
  local count
  count="$(printf '%s\n' "$output" | jq 'length')"
  [ "$count" = "0" ]
}

# Discovery: when no TRACKER_ROOT is set, the script must find the
# consumer's .features/ by walking $PWD upward for a .formann ancestor — the
# same shape build-image.sh uses to find HOST_REPO. Without this walk, the
# fallback "compute relative to BASH_SOURCE" path breaks when the role-surface
# entry point (docs/formann/issue-tracker/) is itself a directory symlink:
# `..` resolution physically follows the symlink into the framework checkout
# and lands in the wrong namespace.
@test "auto-discovers tracker_root via .formann ancestor when no env override" {
  unset TRACKER_ROOT
  local consumer="$BATS_TEST_TMPDIR/consumer"
  mkdir -p "$consumer/.features/auto-discovered"
  # The .formann marker is what identifies the consumer root. The walk only
  # cares that the entry exists; pointing it at a real dir keeps `[ -e ]`
  # honest without requiring symlink resolution.
  ln -s "$BATS_TEST_TMPDIR" "$consumer/.formann"
  ( cd "$consumer" && "$TRACKER_SNAPSHOT" --list ) >"$BATS_TEST_TMPDIR/out" 2>&1
  run cat "$BATS_TEST_TMPDIR/out"
  assert_success
  local slugs
  slugs="$(printf '%s\n' "$output" | jq -r '.[]' 2>/dev/null | tr '\n' ' ' | sed 's/ $//')"
  [ "$slugs" = "auto-discovered" ]
}

@test "CRLF-encoded issue files are parsed, not silently dropped" {
  # Regression: parse_frontmatter compared each line to the bare string
  # `---`, but `read -r` does not strip a trailing `\r`. A CRLF-saved
  # issue file's `---\r` opener never matched, the parser fell through
  # to "no frontmatter" mode, and the issue surfaced with empty
  # status/type, eligible:false, and *no* parse_error — invisible to
  # the runner and the maintainer alike. The fix strips `\r` from each
  # line before comparison so the parser handles CRLF transparently.
  local feature_dir="$BATS_TEST_TMPDIR/tracker/crlf-feature/issues"
  mkdir -p "$feature_dir"
  # Write the issue with CRLF line endings throughout.
  printf -- '---\r\nstatus: ready-for-agent\r\ncategory: enhancement\r\ntype: AFK\r\n---\r\n\r\n# CRLF\r\n\r\n## Blocked by\r\n\r\nNone.\r\n' \
    >"$feature_dir/01-crlf.md"

  TRACKER_ROOT="$BATS_TEST_TMPDIR/tracker" \
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

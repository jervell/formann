#!/usr/bin/env bats
bats_require_minimum_version 1.5.0

setup() {
  load 'test_helper/bats-support/load'
  load 'test_helper/bats-assert/load'

  HERE="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)"
  ADD_ISSUE="$HERE/../add-issue-to-slug"

  FAKE_BIN="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$FAKE_BIN"
  CALL_LOG="$BATS_TEST_TMPDIR/gh-calls.log"
  : >"$CALL_LOG"

  # gh shim: records every invocation.
  # - 'issue list ...'   → serves LIST_FIXTURE (default: one matching parent).
  # - 'issue create ...' → prints a fake URL.
  # - 'issue view ...'   → returns JSON with a fake node ID (LIST_FIXTURE can override).
  # - 'api graphql ...'  → serves GRAPHQL_FIXTURE (default: addSubIssue success).
  cat >"$FAKE_BIN/gh" <<'SHIM'
#!/usr/bin/env bash
echo "$*" >> "${CALL_LOG}"
_default_one_parent='[{"number":10,"id":"I_parent_node","title":"My feature"}]'
if [ "$1" = "issue" ] && [ "$2" = "list" ]; then
  printf '%s\n' "${LIST_FIXTURE:-$_default_one_parent}"
  exit 0
fi
if [ "$1" = "issue" ] && [ "$2" = "create" ]; then
  echo "https://github.com/test-owner/test-repo/issues/42"
  exit 0
fi
if [ "$1" = "issue" ] && [ "$2" = "view" ]; then
  echo '{"id":"I_new_node"}'
  exit 0
fi
if [ "$1" = "api" ] && [ "$2" = "graphql" ]; then
  echo '{"data":{"addSubIssue":{"issue":{"number":10},"subIssue":{"number":42}}}}'
  exit 0
fi
printf 'shim: unexpected gh call: %s\n' "$*" >&2
exit 1
SHIM
  chmod +x "$FAKE_BIN/gh"

  export CALL_LOG
  export PATH="$FAKE_BIN:$PATH"
}

# ── Default list fixture helper ───────────────────────────────────────────────

_one_parent_list() {
  printf '[{"number":10,"id":"I_parent_node","title":"My feature"}]'
}

# ── Executable ────────────────────────────────────────────────────────────────

@test "add-issue-to-slug exists and is executable" {
  [ -x "$ADD_ISSUE" ]
}

# ── Usage / required-arg errors ───────────────────────────────────────────────

@test "missing --slug exits with usage error" {
  run "$ADD_ISSUE" --title "My issue" --category enhancement --type afk
  [ "$status" -eq 2 ]
}

@test "missing --title exits with usage error" {
  run "$ADD_ISSUE" --slug my-feature --category enhancement --type afk
  [ "$status" -eq 2 ]
}

@test "missing --category exits with usage error" {
  run "$ADD_ISSUE" --slug my-feature --title "My issue" --type afk
  [ "$status" -eq 2 ]
}

@test "missing --type exits with usage error" {
  run "$ADD_ISSUE" --slug my-feature --title "My issue" --category enhancement
  [ "$status" -eq 2 ]
}

@test "invalid --category exits with usage error" {
  run "$ADD_ISSUE" --slug my-feature --title "My issue" --category invalid --type afk
  [ "$status" -eq 2 ]
}

@test "invalid --type exits with usage error" {
  run "$ADD_ISSUE" --slug my-feature --title "My issue" --category enhancement --type invalid
  [ "$status" -eq 2 ]
}

@test "unknown argument exits with usage error" {
  run "$ADD_ISSUE" --slug my-feature --title "My issue" --category enhancement --type afk --unknown val
  [ "$status" -eq 2 ]
}

# ── Scenario (a): addSubIssue to a work-item parent with zero sub-issues ──────
# The resolve step returns one match; the script creates the sub-issue and links it.

@test "work-item-parent: issue list called with formann:feature and slug label" {
  export LIST_FIXTURE='[{"number":10,"id":"I_parent_node","title":"Standalone parent"}]'
  run "$ADD_ISSUE" --slug my-standalone --title "Follow-up" --category enhancement --type afk
  assert_success
  run grep "issue list" "$CALL_LOG"
  assert_output --partial "formann:feature"
  assert_output --partial "formann:slug:my-standalone"
}

@test "work-item-parent: issue create called with needs-triage, category, type" {
  export LIST_FIXTURE='[{"number":10,"id":"I_parent_node","title":"Standalone parent"}]'
  run "$ADD_ISSUE" --slug my-standalone --title "Follow-up" --category bug --type hitl
  assert_success
  run grep "issue create" "$CALL_LOG"
  assert_output --partial "formann:status:needs-triage"
  assert_output --partial "formann:category:bug"
  assert_output --partial "formann:type:hitl"
}

@test "work-item-parent: issue create does NOT receive formann:feature label" {
  export LIST_FIXTURE='[{"number":10,"id":"I_parent_node","title":"Standalone parent"}]'
  run "$ADD_ISSUE" --slug my-standalone --title "Follow-up" --category enhancement --type afk
  assert_success
  run grep "issue create" "$CALL_LOG"
  refute_output --partial "formann:feature"
}

@test "work-item-parent: issue create does NOT receive formann:slug label" {
  export LIST_FIXTURE='[{"number":10,"id":"I_parent_node","title":"Standalone parent"}]'
  run "$ADD_ISSUE" --slug my-standalone --title "Follow-up" --category enhancement --type afk
  assert_success
  run grep "issue create" "$CALL_LOG"
  refute_output --partial "formann:slug:"
}

@test "work-item-parent: addSubIssue graphql mutation is called" {
  export LIST_FIXTURE='[{"number":10,"id":"I_parent_node","title":"Standalone parent"}]'
  run "$ADD_ISSUE" --slug my-standalone --title "Follow-up" --category enhancement --type afk
  assert_success
  run grep "api graphql" "$CALL_LOG"
  assert_success
}

@test "work-item-parent: new issue URL printed to stdout" {
  export LIST_FIXTURE='[{"number":10,"id":"I_parent_node","title":"Standalone parent"}]'
  run "$ADD_ISSUE" --slug my-standalone --title "Follow-up" --category enhancement --type afk
  assert_success
  assert_output --partial "https://github.com/test-owner/test-repo/issues/42"
}

# ── Scenario (b): addSubIssue to a pure-container parent with existing sub-issues
# Same call sequence — verb is shape-insensitive.

@test "pure-container-parent: resolve, create, and addSubIssue sequence fires" {
  export LIST_FIXTURE='[{"number":5,"id":"I_container_node","title":"PRD-led feature"}]'
  run "$ADD_ISSUE" --slug prd-feature --title "Add endpoint" --category enhancement --type afk
  assert_success
  run grep "issue list" "$CALL_LOG"
  assert_output --partial "formann:slug:prd-feature"
  run grep "issue create" "$CALL_LOG"
  assert_success
  run grep "api graphql" "$CALL_LOG"
  assert_success
}

@test "pure-container-parent: issue create does NOT receive formann:feature or formann:slug" {
  export LIST_FIXTURE='[{"number":5,"id":"I_container_node","title":"PRD-led feature"}]'
  run "$ADD_ISSUE" --slug prd-feature --title "Add endpoint" --category enhancement --type afk
  assert_success
  run grep "issue create" "$CALL_LOG"
  refute_output --partial "formann:feature"
  refute_output --partial "formann:slug:"
}

@test "pure-container-parent: new issue URL printed to stdout" {
  export LIST_FIXTURE='[{"number":5,"id":"I_container_node","title":"PRD-led feature"}]'
  run "$ADD_ISSUE" --slug prd-feature --title "Add endpoint" --category enhancement --type afk
  assert_success
  assert_output --partial "https://github.com/test-owner/test-repo/issues/42"
}

# ── Scenario (c): refusal on zero-match resolve ───────────────────────────────

@test "zero-match: exits with resolve-failure code" {
  export LIST_FIXTURE='[]'
  run "$ADD_ISSUE" --slug missing-slug --title "New issue" --category enhancement --type afk
  [ "$status" -eq 1 ]
}

@test "zero-match: not-found diagnostic names the slug" {
  export LIST_FIXTURE='[]'
  run "$ADD_ISSUE" --slug missing-slug --title "New issue" --category enhancement --type afk
  [ "$status" -eq 1 ]
  assert_output --partial "missing-slug"
}

@test "zero-match: issue create NOT called when slug not found" {
  export LIST_FIXTURE='[]'
  run "$ADD_ISSUE" --slug missing-slug --title "New issue" --category enhancement --type afk
  [ "$status" -eq 1 ]
  run grep "issue create" "$CALL_LOG"
  assert_failure
}

@test "zero-match: graphql NOT called when slug not found" {
  export LIST_FIXTURE='[]'
  run "$ADD_ISSUE" --slug missing-slug --title "New issue" --category enhancement --type afk
  [ "$status" -eq 1 ]
  run grep "api graphql" "$CALL_LOG"
  assert_failure
}

# ── Scenario (d): refusal on slug-collision (≥2 parents) ─────────────────────

@test "collision: exits with resolve-failure code" {
  export LIST_FIXTURE='[{"number":5,"id":"I_a","title":"First parent"},{"number":7,"id":"I_b","title":"Second parent"}]'
  run "$ADD_ISSUE" --slug dup-slug --title "New issue" --category enhancement --type afk
  [ "$status" -eq 1 ]
}

@test "collision: diagnostic names the slug" {
  export LIST_FIXTURE='[{"number":5,"id":"I_a","title":"First parent"},{"number":7,"id":"I_b","title":"Second parent"}]'
  run "$ADD_ISSUE" --slug dup-slug --title "New issue" --category enhancement --type afk
  [ "$status" -eq 1 ]
  assert_output --partial "dup-slug"
}

@test "collision: issue create NOT called when collision" {
  export LIST_FIXTURE='[{"number":5,"id":"I_a","title":"First parent"},{"number":7,"id":"I_b","title":"Second parent"}]'
  run "$ADD_ISSUE" --slug dup-slug --title "New issue" --category enhancement --type afk
  [ "$status" -eq 1 ]
  run grep "issue create" "$CALL_LOG"
  assert_failure
}

@test "collision: graphql NOT called when collision" {
  export LIST_FIXTURE='[{"number":5,"id":"I_a","title":"First parent"},{"number":7,"id":"I_b","title":"Second parent"}]'
  run "$ADD_ISSUE" --slug dup-slug --title "New issue" --category enhancement --type afk
  [ "$status" -eq 1 ]
  run grep "api graphql" "$CALL_LOG"
  assert_failure
}

# ── Body content via --body-file ──────────────────────────────────────────────

@test "body-file content is passed to gh issue create" {
  export LIST_FIXTURE='[{"number":10,"id":"I_node","title":"My feature"}]'
  body_file="$BATS_TEST_TMPDIR/body.md"
  printf '%s' "## Gist\nSome content here." >"$body_file"
  run "$ADD_ISSUE" --slug my-feature --title "New issue" --category enhancement --type afk --body-file "$body_file"
  assert_success
}

@test "missing body-file exits with usage error" {
  run "$ADD_ISSUE" --slug my-feature --title "New issue" --category enhancement --type afk --body-file /nonexistent/path/body.md
  [ "$status" -eq 2 ]
}

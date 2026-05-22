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
  #                        If LIST_FAIL=<exit>, emits a fake stderr error and
  #                        exits non-zero (simulates auth/network/rate-limit).
  # - 'issue create ...' → prints a fake URL. If CREATE_FAIL=<exit>, emits a
  #                        fake stderr error and exits non-zero.
  # - 'issue view ...'   → returns JSON with a fake node ID. If VIEW_FAIL=<exit>,
  #                        emits a fake stderr error and exits non-zero.
  # - 'api graphql ...'  → serves GRAPHQL_FIXTURE (default: addSubIssue success).
  #                        If GRAPHQL_FAIL=<exit>, emits a fake stderr error and
  #                        exits non-zero.
  cat >"$FAKE_BIN/gh" <<'SHIM'
#!/usr/bin/env bash
echo "$*" >> "${CALL_LOG}"
_default_one_parent='[{"number":10,"id":"I_parent_node","title":"My feature"}]'
if [ "$1" = "issue" ] && [ "$2" = "list" ]; then
  if [ -n "${LIST_FAIL:-}" ]; then
    echo "gh: simulated upstream failure (HTTP 401: bad credentials)" >&2
    exit "${LIST_FAIL}"
  fi
  printf '%s\n' "${LIST_FIXTURE:-$_default_one_parent}"
  exit 0
fi
if [ "$1" = "issue" ] && [ "$2" = "create" ]; then
  if [ -n "${CREATE_FAIL:-}" ]; then
    echo "gh: simulated upstream failure during issue create (HTTP 503)" >&2
    exit "${CREATE_FAIL}"
  fi
  echo "https://github.com/test-owner/test-repo/issues/42"
  exit 0
fi
if [ "$1" = "issue" ] && [ "$2" = "view" ]; then
  if [ -n "${VIEW_FAIL:-}" ]; then
    echo "gh: simulated upstream failure during issue view (HTTP 502)" >&2
    exit "${VIEW_FAIL}"
  fi
  echo '{"id":"I_new_node"}'
  exit 0
fi
if [ "$1" = "api" ] && [ "$2" = "graphql" ]; then
  if [ -n "${GRAPHQL_FAIL:-}" ]; then
    echo "gh: simulated upstream failure during api graphql (HTTP 504)" >&2
    exit "${GRAPHQL_FAIL}"
  fi
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

@test "collision: diagnostic names both parents" {
  export LIST_FIXTURE='[{"number":5,"id":"I_a","title":"First parent"},{"number":7,"id":"I_b","title":"Second parent"}]'
  run "$ADD_ISSUE" --slug dup-slug --title "New issue" --category enhancement --type afk
  [ "$status" -eq 1 ]
  assert_output --partial "#5"
  assert_output --partial "#7"
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

# ── Scenario (e): transient gh failure (network / auth / rate limit) ─────────

@test "gh failure: exits with transient code (3), distinct from resolve-failure (1)" {
  export LIST_FAIL=1
  run "$ADD_ISSUE" --slug some-slug --title "New issue" --category enhancement --type afk
  [ "$status" -eq 3 ]
}

@test "gh failure: surfaces a script-specific diagnostic" {
  export LIST_FAIL=1
  run "$ADD_ISSUE" --slug some-slug --title "New issue" --category enhancement --type afk
  [ "$status" -eq 3 ]
  assert_output --partial "add-issue-to-slug"
  assert_output --partial "gh issue list"
}

@test "gh failure: issue create NOT called" {
  export LIST_FAIL=1
  run "$ADD_ISSUE" --slug some-slug --title "New issue" --category enhancement --type afk
  [ "$status" -eq 3 ]
  run grep "issue create" "$CALL_LOG"
  assert_failure
}

# ── Scenario (f): transient gh failure on issue create ───────────────────────
# The create call itself fails — no issue is born, no orphan risk, but the
# script must still classify this as transient (3), not resolve-failure (1).

@test "create failure: exits with transient code (3), distinct from resolve-failure (1)" {
  export CREATE_FAIL=1
  run "$ADD_ISSUE" --slug some-slug --title "New issue" --category enhancement --type afk
  [ "$status" -eq 3 ]
}

@test "create failure: surfaces a script-specific diagnostic naming gh issue create" {
  export CREATE_FAIL=1
  run "$ADD_ISSUE" --slug some-slug --title "New issue" --category enhancement --type afk
  [ "$status" -eq 3 ]
  assert_output --partial "add-issue-to-slug"
  assert_output --partial "gh issue create"
}

@test "create failure: graphql NOT called" {
  export CREATE_FAIL=1
  run "$ADD_ISSUE" --slug some-slug --title "New issue" --category enhancement --type afk
  [ "$status" -eq 3 ]
  run grep "api graphql" "$CALL_LOG"
  assert_failure
}

# ── Scenario (g): transient gh failure on post-create issue view ─────────────
# Issue is already created on GitHub; the script needs its node ID via
# 'gh issue view' before linking. A transient failure here leaves an orphan
# AND must classify as transient (3), not resolve-failure (1), so the caller
# distinguishes "orphan due to infra hiccup, retry the link" from "slug
# resolve failed, never created anything".

@test "post-create view failure: exits with transient code (3), distinct from resolve-failure (1)" {
  export VIEW_FAIL=1
  run "$ADD_ISSUE" --slug some-slug --title "New issue" --category enhancement --type afk
  [ "$status" -eq 3 ]
}

@test "post-create view failure: surfaces a script-specific diagnostic naming gh issue view" {
  export VIEW_FAIL=1
  run "$ADD_ISSUE" --slug some-slug --title "New issue" --category enhancement --type afk
  [ "$status" -eq 3 ]
  assert_output --partial "add-issue-to-slug"
  assert_output --partial "gh issue view"
}

@test "post-create view failure: diagnostic names the orphan issue number" {
  export VIEW_FAIL=1
  run "$ADD_ISSUE" --slug some-slug --title "New issue" --category enhancement --type afk
  [ "$status" -eq 3 ]
  assert_output --partial "#42"
  assert_output --partial "orphan"
}

@test "post-create view failure: graphql NOT called" {
  export VIEW_FAIL=1
  run "$ADD_ISSUE" --slug some-slug --title "New issue" --category enhancement --type afk
  [ "$status" -eq 3 ]
  run grep "api graphql" "$CALL_LOG"
  assert_failure
}

# ── Scenario (h): transient gh failure on addSubIssue mutation ───────────────
# Issue is already created on GitHub and its node ID has been fetched. The
# linking mutation fails. Exact same orphan-with-transient-classification
# contract as scenario (g).

@test "addSubIssue failure: exits with transient code (3), distinct from resolve-failure (1)" {
  export GRAPHQL_FAIL=1
  run "$ADD_ISSUE" --slug some-slug --title "New issue" --category enhancement --type afk
  [ "$status" -eq 3 ]
}

@test "addSubIssue failure: surfaces a script-specific diagnostic naming addSubIssue" {
  export GRAPHQL_FAIL=1
  run "$ADD_ISSUE" --slug some-slug --title "New issue" --category enhancement --type afk
  [ "$status" -eq 3 ]
  assert_output --partial "add-issue-to-slug"
  assert_output --partial "addSubIssue"
}

@test "addSubIssue failure: diagnostic names the orphan issue number" {
  export GRAPHQL_FAIL=1
  run "$ADD_ISSUE" --slug some-slug --title "New issue" --category enhancement --type afk
  [ "$status" -eq 3 ]
  assert_output --partial "#42"
  assert_output --partial "orphan"
}

# ── Body content via --body-file ──────────────────────────────────────────────

@test "body-file content is passed to gh issue create" {
  export LIST_FIXTURE='[{"number":10,"id":"I_node","title":"My feature"}]'
  body_file="$BATS_TEST_TMPDIR/body.md"
  printf '%s' "Sentinel body content for grepping" >"$body_file"
  run "$ADD_ISSUE" --slug my-feature --title "New issue" --category enhancement --type afk --body-file "$body_file"
  assert_success
  run grep "issue create" "$CALL_LOG"
  assert_output --partial "Sentinel body content for grepping"
}

@test "missing body-file exits with usage error" {
  run "$ADD_ISSUE" --slug my-feature --title "New issue" --category enhancement --type afk --body-file /nonexistent/path/body.md
  [ "$status" -eq 2 ]
}

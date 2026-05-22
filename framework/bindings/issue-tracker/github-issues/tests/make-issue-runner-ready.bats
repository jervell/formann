#!/usr/bin/env bats
bats_require_minimum_version 1.5.0

setup() {
  load 'test_helper/bats-support/load'
  load 'test_helper/bats-assert/load'

  HERE="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)"
  MAKE_READY="$HERE/../make-issue-runner-ready"

  FAKE_BIN="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$FAKE_BIN"
  CALL_LOG="$BATS_TEST_TMPDIR/gh-calls.log"
  : >"$CALL_LOG"

  # gh shim: records every invocation.
  # - 'issue view <N> --json id,labels' → serves ISSUE_VIEW_FIXTURE.
  # - 'issue list ...'                  → serves LIST_FIXTURE (default: empty = no collision).
  # - 'label create ...'                → succeeds silently.
  # - 'issue edit ...'                  → succeeds silently.
  # - 'api graphql ...'                 → serves GRAPHQL_FIXTURE (default: null parent).
  cat >"$FAKE_BIN/gh" <<'SHIM'
#!/usr/bin/env bash
echo "$*" >> "${CALL_LOG}"
_default_view='{"id":"I_node","labels":[]}'
_default_graphql='{"data":{"node":{"parent":null}}}'
if [ "$1" = "issue" ] && [ "$2" = "view" ]; then
  printf '%s\n' "${ISSUE_VIEW_FIXTURE:-$_default_view}"
  exit 0
fi
if [ "$1" = "issue" ] && [ "$2" = "list" ]; then
  printf '%s\n' "${LIST_FIXTURE:-[]}"
  exit 0
fi
if [ "$1" = "label" ] && [ "$2" = "create" ]; then
  exit 0
fi
if [ "$1" = "issue" ] && [ "$2" = "edit" ]; then
  exit 0
fi
if [ "$1" = "api" ] && [ "$2" = "graphql" ]; then
  printf '%s\n' "${GRAPHQL_FIXTURE:-$_default_graphql}"
  exit 0
fi
printf 'shim: unexpected gh call: %s\n' "$*" >&2
exit 1
SHIM
  chmod +x "$FAKE_BIN/gh"

  export CALL_LOG
  export PATH="$FAKE_BIN:$PATH"
}

# ── Executable ────────────────────────────────────────────────────────────────

@test "make-issue-runner-ready exists and is executable" {
  [ -x "$MAKE_READY" ]
}

# ── Usage / required-arg errors ───────────────────────────────────────────────

@test "missing issue number exits with usage error" {
  run "$MAKE_READY"
  [ "$status" -eq 2 ]
}

@test "unknown argument exits with usage error" {
  run "$MAKE_READY" 42 --unknown val
  [ "$status" -eq 2 ]
}

@test "extra positional argument exits with usage error" {
  run "$MAKE_READY" 42 99
  [ "$status" -eq 2 ]
}

# ── Scenario (a): slug-less standalone with slug supplied ─────────────────────
# Issue has no formann:slug:* and no formann:feature labels, no parent.
# Supplying --slug triggers both the slug-label write and the feature-label write.

@test "standalone-with-slug: exits successfully" {
  export ISSUE_VIEW_FIXTURE='{"id":"I_node","labels":[]}'
  export LIST_FIXTURE='[]'
  export GRAPHQL_FIXTURE='{"data":{"node":{"parent":null}}}'
  run "$MAKE_READY" 42 --slug my-slug
  assert_success
}

@test "standalone-with-slug: issue list called with slug label and --state all" {
  export ISSUE_VIEW_FIXTURE='{"id":"I_node","labels":[]}'
  export LIST_FIXTURE='[]'
  export GRAPHQL_FIXTURE='{"data":{"node":{"parent":null}}}'
  run "$MAKE_READY" 42 --slug my-slug
  assert_success
  run grep "issue list" "$CALL_LOG"
  assert_output --partial "formann:slug:my-slug"
  assert_output --partial "--state all"
}

@test "standalone-with-slug: label create called for slug label" {
  export ISSUE_VIEW_FIXTURE='{"id":"I_node","labels":[]}'
  export LIST_FIXTURE='[]'
  export GRAPHQL_FIXTURE='{"data":{"node":{"parent":null}}}'
  run "$MAKE_READY" 42 --slug my-slug
  assert_success
  run grep "label create" "$CALL_LOG"
  assert_output --partial "formann:slug:my-slug"
  assert_output --partial "--force"
}

@test "standalone-with-slug: issue edit called with slug label" {
  export ISSUE_VIEW_FIXTURE='{"id":"I_node","labels":[]}'
  export LIST_FIXTURE='[]'
  export GRAPHQL_FIXTURE='{"data":{"node":{"parent":null}}}'
  run "$MAKE_READY" 42 --slug my-slug
  assert_success
  run grep "issue edit" "$CALL_LOG"
  assert_output --partial "formann:slug:my-slug"
}

@test "standalone-with-slug: issue edit called with formann:feature label" {
  export ISSUE_VIEW_FIXTURE='{"id":"I_node","labels":[]}'
  export LIST_FIXTURE='[]'
  export GRAPHQL_FIXTURE='{"data":{"node":{"parent":null}}}'
  run "$MAKE_READY" 42 --slug my-slug
  assert_success
  run grep "issue edit" "$CALL_LOG"
  assert_output --partial "formann:feature"
}

@test "standalone-with-slug: graphql parent-detection called" {
  export ISSUE_VIEW_FIXTURE='{"id":"I_node","labels":[]}'
  export LIST_FIXTURE='[]'
  export GRAPHQL_FIXTURE='{"data":{"node":{"parent":null}}}'
  run "$MAKE_READY" 42 --slug my-slug
  assert_success
  run grep "api graphql" "$CALL_LOG"
  assert_success
}

# ── Scenario (b): slug-less standalone with no slug supplied ──────────────────
# Issue has no formann:slug:* label and no --slug is provided → refusal, no writes.

@test "no-slug: exits with refusal code 1" {
  export ISSUE_VIEW_FIXTURE='{"id":"I_node","labels":[]}'
  run "$MAKE_READY" 42
  [ "$status" -eq 1 ]
}

@test "no-slug: diagnostic mentions slug required" {
  export ISSUE_VIEW_FIXTURE='{"id":"I_node","labels":[]}'
  run "$MAKE_READY" 42
  [ "$status" -eq 1 ]
  assert_output --partial "slug"
}

@test "no-slug: issue list NOT called" {
  export ISSUE_VIEW_FIXTURE='{"id":"I_node","labels":[]}'
  run "$MAKE_READY" 42
  [ "$status" -eq 1 ]
  run grep "issue list" "$CALL_LOG"
  assert_failure
}

@test "no-slug: label create NOT called" {
  export ISSUE_VIEW_FIXTURE='{"id":"I_node","labels":[]}'
  run "$MAKE_READY" 42
  [ "$status" -eq 1 ]
  run grep "label create" "$CALL_LOG"
  assert_failure
}

@test "no-slug: issue edit NOT called" {
  export ISSUE_VIEW_FIXTURE='{"id":"I_node","labels":[]}'
  run "$MAKE_READY" 42
  [ "$status" -eq 1 ]
  run grep "issue edit" "$CALL_LOG"
  assert_failure
}

# ── Scenario (c): slug-uniqueness collision ───────────────────────────────────
# Issue has no slug; --slug is supplied but already in use → refusal, no writes.

@test "collision: exits with refusal code 1" {
  export ISSUE_VIEW_FIXTURE='{"id":"I_node","labels":[]}'
  export LIST_FIXTURE='[{"number":5,"title":"Existing issue"}]'
  run "$MAKE_READY" 42 --slug taken-slug
  [ "$status" -eq 1 ]
}

@test "collision: diagnostic names the slug and existing issue" {
  export ISSUE_VIEW_FIXTURE='{"id":"I_node","labels":[]}'
  export LIST_FIXTURE='[{"number":5,"title":"Existing issue"}]'
  run "$MAKE_READY" 42 --slug taken-slug
  [ "$status" -eq 1 ]
  assert_output --partial "taken-slug"
  assert_output --partial "#5"
  assert_output --partial "Choose a different slug"
}

@test "collision: label create NOT called" {
  export ISSUE_VIEW_FIXTURE='{"id":"I_node","labels":[]}'
  export LIST_FIXTURE='[{"number":5,"title":"Existing issue"}]'
  run "$MAKE_READY" 42 --slug taken-slug
  [ "$status" -eq 1 ]
  run grep "label create" "$CALL_LOG"
  assert_failure
}

@test "collision: issue edit NOT called" {
  export ISSUE_VIEW_FIXTURE='{"id":"I_node","labels":[]}'
  export LIST_FIXTURE='[{"number":5,"title":"Existing issue"}]'
  run "$MAKE_READY" 42 --slug taken-slug
  [ "$status" -eq 1 ]
  run grep "issue edit" "$CALL_LOG"
  assert_failure
}

# ── Scenario (d): sub-issue (has slug, no feature, has parent) ────────────────
# Issue has a formann:slug:* label (so slug step is no-op) but no formann:feature.
# Parent-detection returns a non-null parent → formann:feature NOT applied.

@test "sub-issue: exits successfully" {
  export ISSUE_VIEW_FIXTURE='{"id":"I_node","labels":[{"name":"formann:slug:my-feature"}]}'
  export GRAPHQL_FIXTURE='{"data":{"node":{"parent":{"id":"I_parent"}}}}'
  run "$MAKE_READY" 42
  assert_success
}

@test "sub-issue: formann:feature label NOT added" {
  export ISSUE_VIEW_FIXTURE='{"id":"I_node","labels":[{"name":"formann:slug:my-feature"}]}'
  export GRAPHQL_FIXTURE='{"data":{"node":{"parent":{"id":"I_parent"}}}}'
  run "$MAKE_READY" 42
  assert_success
  run grep "issue edit" "$CALL_LOG"
  assert_failure
}

@test "sub-issue: slug label NOT created (slug already present)" {
  export ISSUE_VIEW_FIXTURE='{"id":"I_node","labels":[{"name":"formann:slug:my-feature"}]}'
  export GRAPHQL_FIXTURE='{"data":{"node":{"parent":{"id":"I_parent"}}}}'
  run "$MAKE_READY" 42
  assert_success
  run grep "label create" "$CALL_LOG"
  assert_failure
}

@test "sub-issue: graphql parent-detection IS called" {
  export ISSUE_VIEW_FIXTURE='{"id":"I_node","labels":[{"name":"formann:slug:my-feature"}]}'
  export GRAPHQL_FIXTURE='{"data":{"node":{"parent":{"id":"I_parent"}}}}'
  run "$MAKE_READY" 42
  assert_success
  run grep "api graphql" "$CALL_LOG"
  assert_success
}

# ── Scenario (e): fully-ready issue (idempotent no-op) ───────────────────────
# Issue already has both formann:slug:* and formann:feature → no API writes.

@test "idempotent: exits successfully" {
  export ISSUE_VIEW_FIXTURE='{"id":"I_node","labels":[{"name":"formann:slug:my-feature"},{"name":"formann:feature"}]}'
  run "$MAKE_READY" 42
  assert_success
}

@test "idempotent: no label create called" {
  export ISSUE_VIEW_FIXTURE='{"id":"I_node","labels":[{"name":"formann:slug:my-feature"},{"name":"formann:feature"}]}'
  run "$MAKE_READY" 42
  assert_success
  run grep "label create" "$CALL_LOG"
  assert_failure
}

@test "idempotent: no issue edit called" {
  export ISSUE_VIEW_FIXTURE='{"id":"I_node","labels":[{"name":"formann:slug:my-feature"},{"name":"formann:feature"}]}'
  run "$MAKE_READY" 42
  assert_success
  run grep "issue edit" "$CALL_LOG"
  assert_failure
}

@test "idempotent: no graphql called" {
  export ISSUE_VIEW_FIXTURE='{"id":"I_node","labels":[{"name":"formann:slug:my-feature"},{"name":"formann:feature"}]}'
  run "$MAKE_READY" 42
  assert_success
  run grep "api graphql" "$CALL_LOG"
  assert_failure
}

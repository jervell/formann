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
  # - 'issue view <N> --json id,labels' → serves ISSUE_VIEW_FIXTURE. If
  #                                       VIEW_FAIL=<exit>, emits stderr and
  #                                       exits non-zero.
  # - 'issue list ...'                  → serves LIST_FIXTURE (default: empty = no collision).
  #                                       If LIST_FAIL=<exit>, emits stderr and
  #                                       exits non-zero (auth/network/rate-limit).
  # - 'label create ...'                → succeeds silently. If LABEL_FAIL=<exit>,
  #                                       emits stderr and exits non-zero.
  # - 'issue edit ...'                  → succeeds silently. If EDIT_FAIL=<exit>,
  #                                       emits stderr and exits non-zero.
  # - 'api graphql ...'                 → serves GRAPHQL_FIXTURE (default: null parent).
  #                                       If GRAPHQL_FAIL=<exit>, emits stderr and
  #                                       exits non-zero.
  cat >"$FAKE_BIN/gh" <<'SHIM'
#!/usr/bin/env bash
echo "$*" >> "${CALL_LOG}"
_default_view='{"id":"I_node","labels":[]}'
_default_graphql='{"data":{"node":{"parent":null}}}'
if [ "$1" = "issue" ] && [ "$2" = "view" ]; then
  if [ -n "${VIEW_FAIL:-}" ]; then
    echo "gh: simulated upstream failure during issue view (HTTP 502)" >&2
    exit "${VIEW_FAIL}"
  fi
  printf '%s\n' "${ISSUE_VIEW_FIXTURE:-$_default_view}"
  exit 0
fi
if [ "$1" = "issue" ] && [ "$2" = "list" ]; then
  if [ -n "${LIST_FAIL:-}" ]; then
    echo "gh: simulated upstream failure (HTTP 401: bad credentials)" >&2
    exit "${LIST_FAIL}"
  fi
  printf '%s\n' "${LIST_FIXTURE:-[]}"
  exit 0
fi
if [ "$1" = "label" ] && [ "$2" = "create" ]; then
  if [ -n "${LABEL_FAIL:-}" ]; then
    echo "gh: simulated upstream failure during label create (HTTP 503)" >&2
    exit "${LABEL_FAIL}"
  fi
  exit 0
fi
if [ "$1" = "issue" ] && [ "$2" = "edit" ]; then
  if [ -n "${EDIT_FAIL:-}" ]; then
    echo "gh: simulated upstream failure during issue edit (HTTP 503)" >&2
    exit "${EDIT_FAIL}"
  fi
  exit 0
fi
if [ "$1" = "api" ] && [ "$2" = "graphql" ]; then
  if [ -n "${GRAPHQL_FAIL:-}" ]; then
    echo "gh: simulated upstream failure during api graphql (HTTP 504)" >&2
    exit "${GRAPHQL_FAIL}"
  fi
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

@test "standalone-with-slug: happy path produces no stderr noise" {
  export ISSUE_VIEW_FIXTURE='{"id":"I_node","labels":[]}'
  export LIST_FIXTURE='[]'
  export GRAPHQL_FIXTURE='{"data":{"node":{"parent":null}}}'
  run --separate-stderr "$MAKE_READY" 42 --slug my-slug
  assert_success
  [ -z "$stderr" ]
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

@test "collision: title with JSON-escaped quotes is rendered correctly" {
  export ISSUE_VIEW_FIXTURE='{"id":"I_node","labels":[]}'
  export LIST_FIXTURE='[{"number":5,"title":"Fix: the \"main\" thing"}]'
  run "$MAKE_READY" 42 --slug taken-slug
  [ "$status" -eq 1 ]
  assert_output --partial 'Fix: the "main" thing'
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

# ── Scenario (f): transient gh failure on uniqueness lookup ──────────────────

@test "gh failure: exits with transient code (3), distinct from refusal (1)" {
  export ISSUE_VIEW_FIXTURE='{"id":"I_node","labels":[]}'
  export LIST_FAIL=1
  run "$MAKE_READY" 42 --slug some-slug
  [ "$status" -eq 3 ]
}

@test "gh failure: surfaces a script-specific diagnostic" {
  export ISSUE_VIEW_FIXTURE='{"id":"I_node","labels":[]}'
  export LIST_FAIL=1
  run "$MAKE_READY" 42 --slug some-slug
  [ "$status" -eq 3 ]
  assert_output --partial "make-issue-runner-ready"
  assert_output --partial "gh issue list"
}

@test "gh failure: label create NOT called" {
  export ISSUE_VIEW_FIXTURE='{"id":"I_node","labels":[]}'
  export LIST_FAIL=1
  run "$MAKE_READY" 42 --slug some-slug
  [ "$status" -eq 3 ]
  run grep "label create" "$CALL_LOG"
  assert_failure
}

@test "gh failure: issue edit NOT called" {
  export ISSUE_VIEW_FIXTURE='{"id":"I_node","labels":[]}'
  export LIST_FAIL=1
  run "$MAKE_READY" 42 --slug some-slug
  [ "$status" -eq 3 ]
  run grep "issue edit" "$CALL_LOG"
  assert_failure
}

# ── Scenario (g): transient gh failure on Step 0 issue view ──────────────────
# The label/parent lookup at the top of the script must classify as transient
# (3), not refusal (1). Without exit-code capture, set -e + pipefail would
# leak gh's exit code (typically 1) and a caller would misread the failure
# as a slug-uniqueness collision.

@test "step-0 view failure: exits with transient code (3), distinct from refusal (1)" {
  export VIEW_FAIL=1
  run "$MAKE_READY" 42 --slug some-slug
  [ "$status" -eq 3 ]
}

@test "step-0 view failure: surfaces a script-specific diagnostic naming gh issue view" {
  export VIEW_FAIL=1
  run "$MAKE_READY" 42 --slug some-slug
  [ "$status" -eq 3 ]
  assert_output --partial "make-issue-runner-ready"
  assert_output --partial "gh issue view"
}

@test "step-0 view failure: no downstream writes" {
  export VIEW_FAIL=1
  run "$MAKE_READY" 42 --slug some-slug
  [ "$status" -eq 3 ]
  run grep "issue list" "$CALL_LOG"
  assert_failure
  run grep "label create" "$CALL_LOG"
  assert_failure
  run grep "issue edit" "$CALL_LOG"
  assert_failure
}

# ── Scenario (h): transient gh failure on Step 2 parent-detection graphql ────
# The parent-detection call gates whether to apply formann:feature. A
# transient failure here must classify as transient (3), not refusal (1).

@test "parent-detection graphql failure: exits with transient code (3)" {
  export ISSUE_VIEW_FIXTURE='{"id":"I_node","labels":[{"name":"formann:slug:my-feature"}]}'
  export GRAPHQL_FAIL=1
  run "$MAKE_READY" 42
  [ "$status" -eq 3 ]
}

@test "parent-detection graphql failure: surfaces a script-specific diagnostic naming gh api graphql" {
  export ISSUE_VIEW_FIXTURE='{"id":"I_node","labels":[{"name":"formann:slug:my-feature"}]}'
  export GRAPHQL_FAIL=1
  run "$MAKE_READY" 42
  [ "$status" -eq 3 ]
  assert_output --partial "make-issue-runner-ready"
  assert_output --partial "gh api graphql"
}

@test "parent-detection graphql failure: formann:feature NOT added" {
  export ISSUE_VIEW_FIXTURE='{"id":"I_node","labels":[{"name":"formann:slug:my-feature"}]}'
  export GRAPHQL_FAIL=1
  run "$MAKE_READY" 42
  [ "$status" -eq 3 ]
  run grep "issue edit" "$CALL_LOG"
  assert_failure
}

# ── Scenario (i): transient gh failure on slug-label create ──────────────────
# The label create is a write; a transient failure here must classify as
# transient (3), not refusal (1).

@test "label create failure: exits with transient code (3)" {
  export ISSUE_VIEW_FIXTURE='{"id":"I_node","labels":[]}'
  export LIST_FIXTURE='[]'
  export LABEL_FAIL=1
  run "$MAKE_READY" 42 --slug some-slug
  [ "$status" -eq 3 ]
}

@test "label create failure: surfaces a script-specific diagnostic naming gh label create" {
  export ISSUE_VIEW_FIXTURE='{"id":"I_node","labels":[]}'
  export LIST_FIXTURE='[]'
  export LABEL_FAIL=1
  run "$MAKE_READY" 42 --slug some-slug
  [ "$status" -eq 3 ]
  assert_output --partial "make-issue-runner-ready"
  assert_output --partial "gh label create"
}

# ── Scenario (j): transient gh failure on slug-label issue edit ──────────────
# Same exit-code-classification contract for the issue-edit write.

@test "issue edit (slug) failure: exits with transient code (3)" {
  export ISSUE_VIEW_FIXTURE='{"id":"I_node","labels":[]}'
  export LIST_FIXTURE='[]'
  export EDIT_FAIL=1
  run "$MAKE_READY" 42 --slug some-slug
  [ "$status" -eq 3 ]
}

@test "issue edit (slug) failure: surfaces a script-specific diagnostic naming gh issue edit" {
  export ISSUE_VIEW_FIXTURE='{"id":"I_node","labels":[]}'
  export LIST_FIXTURE='[]'
  export EDIT_FAIL=1
  run "$MAKE_READY" 42 --slug some-slug
  [ "$status" -eq 3 ]
  assert_output --partial "make-issue-runner-ready"
  assert_output --partial "gh issue edit"
}

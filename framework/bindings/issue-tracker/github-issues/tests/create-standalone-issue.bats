#!/usr/bin/env bats
bats_require_minimum_version 1.5.0

setup() {
  load 'test_helper/bats-support/load'
  load 'test_helper/bats-assert/load'

  HERE="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)"
  CREATE_STANDALONE="$HERE/../create-standalone-issue"

  FAKE_BIN="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$FAKE_BIN"
  CALL_LOG="$BATS_TEST_TMPDIR/gh-calls.log"
  : >"$CALL_LOG"

  # gh shim: records every invocation.
  # - 'issue list ...' → serves LIST_FIXTURE (default: empty array = no collision).
  # - 'label create ...' → succeeds silently.
  # - 'issue create ...' → prints a fake URL.
  cat >"$FAKE_BIN/gh" <<'SHIM'
#!/usr/bin/env bash
echo "$*" >> "${CALL_LOG}"
if [ "$1" = "issue" ] && [ "$2" = "list" ]; then
  printf '%s\n' "${LIST_FIXTURE:-[]}"
  exit 0
fi
if [ "$1" = "label" ] && [ "$2" = "create" ]; then
  exit 0
fi
if [ "$1" = "issue" ] && [ "$2" = "create" ]; then
  echo "https://github.com/test-owner/test-repo/issues/42"
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

@test "create-standalone-issue exists and is executable" {
  [ -x "$CREATE_STANDALONE" ]
}

# ── Usage / required-arg errors ───────────────────────────────────────────────

@test "missing --title exits with usage error" {
  run "$CREATE_STANDALONE" --category enhancement --type afk
  [ "$status" -eq 2 ]
}

@test "missing --category exits with usage error" {
  run "$CREATE_STANDALONE" --title "My issue" --type afk
  [ "$status" -eq 2 ]
}

@test "missing --type exits with usage error" {
  run "$CREATE_STANDALONE" --title "My issue" --category enhancement
  [ "$status" -eq 2 ]
}

@test "invalid --category value exits with usage error" {
  run "$CREATE_STANDALONE" --title "My issue" --category invalid --type afk
  [ "$status" -eq 2 ]
}

@test "invalid --type value exits with usage error" {
  run "$CREATE_STANDALONE" --title "My issue" --category enhancement --type invalid
  [ "$status" -eq 2 ]
}

@test "unknown argument exits with usage error" {
  run "$CREATE_STANDALONE" --title "My issue" --category enhancement --type afk --unknown val
  [ "$status" -eq 2 ]
}

# ── Scenario (a): standalone creation with slug succeeds ─────────────────────

@test "with-slug: issue list called with correct slug label" {
  export LIST_FIXTURE='[]'
  run "$CREATE_STANDALONE" --title "Fix the thing" --category enhancement --type afk --slug my-fix
  assert_success
  run grep "issue list" "$CALL_LOG"
  assert_output --partial "formann:slug:my-fix"
}

@test "with-slug: label create called for slug label" {
  export LIST_FIXTURE='[]'
  run "$CREATE_STANDALONE" --title "Fix the thing" --category enhancement --type afk --slug my-fix
  assert_success
  run grep "label create" "$CALL_LOG"
  assert_output --partial "formann:slug:my-fix"
  assert_output --partial "--force"
}

@test "with-slug: issue create receives expected label set" {
  export LIST_FIXTURE='[]'
  run "$CREATE_STANDALONE" --title "Fix the thing" --category bug --type hitl --slug my-fix
  assert_success
  run grep "issue create" "$CALL_LOG"
  assert_output --partial "formann:status:needs-triage"
  assert_output --partial "formann:slug:my-fix"
  assert_output --partial "formann:category:bug"
  assert_output --partial "formann:type:hitl"
}

@test "with-slug: issue create does NOT receive formann:feature label" {
  export LIST_FIXTURE='[]'
  run "$CREATE_STANDALONE" --title "Fix the thing" --category enhancement --type afk --slug my-fix
  assert_success
  run grep "issue create" "$CALL_LOG"
  refute_output --partial "formann:feature"
}

@test "with-slug: issue URL printed to stdout" {
  export LIST_FIXTURE='[]'
  run "$CREATE_STANDALONE" --title "Fix the thing" --category enhancement --type afk --slug my-fix
  assert_success
  assert_output --partial "https://github.com/test-owner/test-repo/issues/42"
}

@test "with-slug: slug too long (38 chars) exits with usage error" {
  # 38-char slug exceeds the 37-char limit
  long_slug="$(printf 'x%.0s' {1..38})"
  run "$CREATE_STANDALONE" --title "Fix the thing" --category enhancement --type afk --slug "$long_slug"
  [ "$status" -eq 2 ]
  assert_output --partial "37 characters"
}

@test "with-slug: slug exactly 37 chars is accepted" {
  export LIST_FIXTURE='[]'
  slug37="$(printf 'x%.0s' {1..37})"
  run "$CREATE_STANDALONE" --title "Fix the thing" --category enhancement --type afk --slug "$slug37"
  assert_success
}

# ── Scenario (b): standalone creation without slug succeeds ──────────────────

@test "no-slug: issue list NOT called" {
  run "$CREATE_STANDALONE" --title "Fix the thing" --category enhancement --type afk
  assert_success
  run grep "issue list" "$CALL_LOG"
  assert_failure
}

@test "no-slug: label create NOT called" {
  run "$CREATE_STANDALONE" --title "Fix the thing" --category enhancement --type afk
  assert_success
  run grep "label create" "$CALL_LOG"
  assert_failure
}

@test "no-slug: issue create receives needs-triage, category, type but NO slug label" {
  run "$CREATE_STANDALONE" --title "Fix the thing" --category bug --type afk
  assert_success
  run grep "issue create" "$CALL_LOG"
  assert_output --partial "formann:status:needs-triage"
  assert_output --partial "formann:category:bug"
  assert_output --partial "formann:type:afk"
  refute_output --partial "formann:slug:"
}

@test "no-slug: issue URL printed to stdout" {
  run "$CREATE_STANDALONE" --title "Fix the thing" --category enhancement --type afk
  assert_success
  assert_output --partial "https://github.com/test-owner/test-repo/issues/42"
}

# ── Scenario (c): slug-uniqueness collision refuses ───────────────────────────

@test "collision: exits with code 1 and diagnostic when slug already in use" {
  export LIST_FIXTURE='[{"number":5,"title":"Existing issue"}]'
  run "$CREATE_STANDALONE" --title "New issue" --category enhancement --type afk --slug taken-slug
  [ "$status" -eq 1 ]
  assert_output --partial "taken-slug"
  assert_output --partial "#5"
  assert_output --partial "Choose a different slug"
}

@test "collision: issue create NOT called when slug already in use" {
  export LIST_FIXTURE='[{"number":5,"title":"Existing issue"}]'
  run "$CREATE_STANDALONE" --title "New issue" --category enhancement --type afk --slug taken-slug
  [ "$status" -eq 1 ]
  run grep "issue create" "$CALL_LOG"
  assert_failure
}

@test "collision: label create NOT called when slug already in use" {
  export LIST_FIXTURE='[{"number":5,"title":"Existing issue"}]'
  run "$CREATE_STANDALONE" --title "New issue" --category enhancement --type afk --slug taken-slug
  [ "$status" -eq 1 ]
  run grep "label create" "$CALL_LOG"
  assert_failure
}

# ── Body content via --body-file ──────────────────────────────────────────────

@test "body-file content is passed to gh issue create" {
  body_file="$BATS_TEST_TMPDIR/body.md"
  printf '%s' "## Gist\nSome content here." >"$body_file"
  run "$CREATE_STANDALONE" --title "Fix the thing" --category enhancement --type afk --body-file "$body_file"
  assert_success
}

@test "missing body-file exits with usage error" {
  run "$CREATE_STANDALONE" --title "Fix the thing" --category enhancement --type afk --body-file /nonexistent/path/body.md
  [ "$status" -eq 2 ]
}

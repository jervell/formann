#!/usr/bin/env bats
bats_require_minimum_version 1.5.0

setup() {
  load 'test_helper/bats-support/load'
  load 'test_helper/bats-assert/load'

  HERE="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)"
  BODY_EDIT="$HERE/../body-edit"

  FAKE_BIN="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$FAKE_BIN"
  CALL_LOG="$BATS_TEST_TMPDIR/gh-calls.log"
  : >"$CALL_LOG"
  WRITTEN_BODY_FILE="$BATS_TEST_TMPDIR/written-body"

  # gh shim: records every invocation; serves BODY_FIXTURE on `issue view`;
  # captures the body file on `issue edit`.
  cat >"$FAKE_BIN/gh" <<'SHIM'
#!/usr/bin/env bash
echo "$*" >> "${CALL_LOG}"
if [ "$1" = "issue" ] && [ "$2" = "view" ]; then
  printf '%s' "${BODY_FIXTURE:-}"
  exit 0
fi
if [ "$1" = "issue" ] && [ "$2" = "edit" ]; then
  shift 2
  while [ "$#" -gt 0 ]; do
    if [ "$1" = "--body-file" ]; then
      cat "$2" > "${WRITTEN_BODY_FILE}"
      break
    fi
    shift
  done
  exit 0
fi
printf 'shim: unexpected gh call: %s\n' "$*" >&2
exit 1
SHIM
  chmod +x "$FAKE_BIN/gh"

  export CALL_LOG
  export WRITTEN_BODY_FILE
  # Prepend the shim dir so our fake gh wins the PATH lookup.
  export PATH="$FAKE_BIN:$PATH"
}

# ── AC1: executable ──────────────────────────────────────────────────────────

@test "body-edit exists and is executable" {
  [ -x "$BODY_EDIT" ]
}

# ── AC2: section-exists — replaced; surrounding sections preserved ────────────

@test "section-exists: target section replaced; surrounding sections preserved" {
  export BODY_FIXTURE
  BODY_FIXTURE="$(cat <<'BODY'
## First
first content
## Target Section
old target content
## Last
last content
BODY
)"

  NEW_CONTENT="$BATS_TEST_TMPDIR/new-content"
  printf '%s' 'new target content' >"$NEW_CONTENT"

  run "$BODY_EDIT" 42 "Target Section" "$NEW_CONTENT"
  assert_success

  written="$(cat "$WRITTEN_BODY_FILE")"
  # Target section has new content
  [[ "$written" == *"new target content"* ]]
  # Old content removed
  [[ "$written" != *"old target content"* ]]
  # Surrounding sections preserved verbatim
  [[ "$written" == *"## First"* ]]
  [[ "$written" == *"first content"* ]]
  [[ "$written" == *"## Last"* ]]
  [[ "$written" == *"last content"* ]]
  # Heading present
  [[ "$written" == *"## Target Section"* ]]
}

# ── AC3: section-absent — appended at end ────────────────────────────────────

@test "section-absent: section appended at end with correct heading" {
  export BODY_FIXTURE
  BODY_FIXTURE="$(cat <<'BODY'
## Existing
existing content
BODY
)"

  NEW_CONTENT="$BATS_TEST_TMPDIR/new-content"
  printf '%s' 'brand new content' >"$NEW_CONTENT"

  run "$BODY_EDIT" 7 "New Section" "$NEW_CONTENT"
  assert_success

  written="$(cat "$WRITTEN_BODY_FILE")"
  # New section appended with correct heading
  [[ "$written" == *"## New Section"* ]]
  [[ "$written" == *"brand new content"* ]]
  # Existing section preserved
  [[ "$written" == *"## Existing"* ]]
  [[ "$written" == *"existing content"* ]]
  # New section appears after existing content
  existing_line="$(printf '%s\n' "$written" | grep -n "## Existing" | cut -d: -f1)"
  new_line="$(printf '%s\n' "$written" | grep -n "## New Section" | cut -d: -f1)"
  [ "$new_line" -gt "$existing_line" ]
}

# ── AC4: empty-new-content — section removed ─────────────────────────────────

@test "empty-new-content: section removed; surrounding sections preserved" {
  export BODY_FIXTURE
  BODY_FIXTURE="$(cat <<'BODY'
## First
first content
## To Delete
delete me
## Last
last content
BODY
)"

  run "$BODY_EDIT" 13 "To Delete" /dev/null
  assert_success

  written="$(cat "$WRITTEN_BODY_FILE")"
  # Deleted section is gone
  [[ "$written" != *"## To Delete"* ]]
  [[ "$written" != *"delete me"* ]]
  # Surrounding sections preserved
  [[ "$written" == *"## First"* ]]
  [[ "$written" == *"first content"* ]]
  [[ "$written" == *"## Last"* ]]
  [[ "$written" == *"last content"* ]]
}

# ── AC4 variant: empty file (not /dev/null) also deletes ────────────────────

@test "empty-new-content via empty file: section removed" {
  export BODY_FIXTURE
  BODY_FIXTURE="$(cat <<'BODY'
## Keep
keep content
## Remove Me
remove this content
BODY
)"

  EMPTY_FILE="$BATS_TEST_TMPDIR/empty"
  : >"$EMPTY_FILE"

  run "$BODY_EDIT" 3 "Remove Me" "$EMPTY_FILE"
  assert_success

  written="$(cat "$WRITTEN_BODY_FILE")"
  [[ "$written" != *"## Remove Me"* ]]
  [[ "$written" != *"remove this content"* ]]
  [[ "$written" == *"## Keep"* ]]
  [[ "$written" == *"keep content"* ]]
}

# ── AC5: multiple ## headings — only named section mutated ───────────────────

@test "multiple headings: only the named section is mutated" {
  export BODY_FIXTURE
  BODY_FIXTURE="$(cat <<'BODY'
## Alpha
content of alpha
## Beta
content of beta
## Gamma
content of gamma
BODY
)"

  NEW_CONTENT="$BATS_TEST_TMPDIR/new-content"
  printf '%s' 'replacement for beta' >"$NEW_CONTENT"

  run "$BODY_EDIT" 5 "Beta" "$NEW_CONTENT"
  assert_success

  written="$(cat "$WRITTEN_BODY_FILE")"
  # Beta replaced
  [[ "$written" == *"replacement for beta"* ]]
  [[ "$written" != *"content of beta"* ]]
  # Alpha and Gamma unchanged
  [[ "$written" == *"## Alpha"* ]]
  [[ "$written" == *"content of alpha"* ]]
  [[ "$written" == *"## Gamma"* ]]
  [[ "$written" == *"content of gamma"* ]]
}

# ── AC6: AI-disclaimer preserved verbatim ────────────────────────────────────

@test "AI-disclaimer: leading disclaimer line preserved verbatim inside section" {
  export BODY_FIXTURE
  BODY_FIXTURE="$(cat <<'BODY'
## Agent Brief
old brief content
BODY
)"

  NEW_CONTENT="$BATS_TEST_TMPDIR/disclaimer-content"
  printf '%s\n\n%s' \
    '> *This was generated by AI during triage.*' \
    'Actual brief content here.' >"$NEW_CONTENT"

  run "$BODY_EDIT" 99 "Agent Brief" "$NEW_CONTENT"
  assert_success

  # Disclaimer line preserved with literal asterisks
  grep -q '> \*This was generated by AI during triage\.\*' "$WRITTEN_BODY_FILE"
  grep -q 'Actual brief content here\.' "$WRITTEN_BODY_FILE"
  # Old content gone
  [[ "$(cat "$WRITTEN_BODY_FILE")" != *"old brief content"* ]]
}

# ── AC7: correct gh commands used ────────────────────────────────────────────

@test "uses gh issue view --json body to fetch and gh issue edit --body-file to write" {
  export BODY_FIXTURE=""

  NEW_CONTENT="$BATS_TEST_TMPDIR/content"
  printf '%s' 'some content' >"$NEW_CONTENT"

  run "$BODY_EDIT" 42 "Test Section" "$NEW_CONTENT"
  assert_success

  # Fetch call recorded with --json body
  grep -q "issue view" "$CALL_LOG"
  grep -q -- "--json body" "$CALL_LOG"
  # Write call recorded with --body-file
  grep -q "issue edit" "$CALL_LOG"
  grep -q -- "--body-file" "$CALL_LOG"
}

# ── Additional: section-absent on empty body ─────────────────────────────────

@test "section-absent on empty body: heading appended with no leading blank line" {
  export BODY_FIXTURE=""

  NEW_CONTENT="$BATS_TEST_TMPDIR/content"
  printf '%s' 'content for new section' >"$NEW_CONTENT"

  run "$BODY_EDIT" 1 "Brand New" "$NEW_CONTENT"
  assert_success

  written="$(cat "$WRITTEN_BODY_FILE")"
  [[ "$written" == *"## Brand New"* ]]
  [[ "$written" == *"content for new section"* ]]
  # No leading blank line when body was empty — first line is the heading
  first_line="$(printf '%s\n' "$written" | head -1)"
  [ "$first_line" = "## Brand New" ]
}

# ── Additional: multiline new content preserved ──────────────────────────────

@test "multiline new content is preserved verbatim" {
  export BODY_FIXTURE
  BODY_FIXTURE="$(cat <<'BODY'
## Section
old content
BODY
)"

  NEW_CONTENT="$BATS_TEST_TMPDIR/multiline"
  printf '%s\n%s\n%s' 'line one' 'line two' 'line three' >"$NEW_CONTENT"

  run "$BODY_EDIT" 8 "Section" "$NEW_CONTENT"
  assert_success

  grep -q 'line one' "$WRITTEN_BODY_FILE"
  grep -q 'line two' "$WRITTEN_BODY_FILE"
  grep -q 'line three' "$WRITTEN_BODY_FILE"
  [[ "$(cat "$WRITTEN_BODY_FILE")" != *"old content"* ]]
}

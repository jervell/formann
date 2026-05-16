#!/usr/bin/env bats

# Self-install test suite.
#
# Exercises the installer in self-install mode: the consumer path resolves to
# the Formann checkout itself. In this mode `update_gitignore` writes a managed
# block delimited by marker comments, listing every installer product.
#
# Invocation: bats installer/tests/self-install.bats (from the formann/ repo root)

setup() {
  load 'test_helper/bats-support/load'
  load 'test_helper/bats-assert/load'

  INSTALLER_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
  INSTALL_SH="$INSTALLER_DIR/install.sh"

  # In self-install mode the consumer IS the formann fixture.
  FORMANN_FIXTURE="$BATS_TEST_TMPDIR/formann-self"

  MARKER_START='# === Formann self-install (managed by installer — do not edit) ==='
  MARKER_END='# === /Formann self-install ==='

  _setup_self_install_fixture
}

# ---------------------------------------------------------------------------
# Fixture
# ---------------------------------------------------------------------------

# Builds a synthetic Formann checkout that doubles as the consumer dir.
_setup_self_install_fixture() {
  mkdir -p "$FORMANN_FIXTURE/framework/bindings/issue-tracker/local-markdown"
  mkdir -p "$FORMANN_FIXTURE/framework/skills/grill-me"
  mkdir -p "$FORMANN_FIXTURE/framework/skills/implement"
  mkdir -p "$FORMANN_FIXTURE/framework/agents"
  touch "$FORMANN_FIXTURE/framework/skills/grill-me/SKILL.md"
  touch "$FORMANN_FIXTURE/framework/skills/implement/SKILL.md"
  touch "$FORMANN_FIXTURE/framework/agents/review-feature.md"
  touch "$FORMANN_FIXTURE/framework/agents/review-issue.md"
  touch "$FORMANN_FIXTURE/framework/lifecycle.md"
  touch "$FORMANN_FIXTURE/framework/inbox.md"
  touch "$FORMANN_FIXTURE/framework/domain.md"
  touch "$FORMANN_FIXTURE/framework/triage-states.md"
  touch "$FORMANN_FIXTURE/framework/afk-runner.md"
  touch "$FORMANN_FIXTURE/framework/afk-runner-flow.md"

  mkdir -p "$FORMANN_FIXTURE/installer/templates"
  cp "$INSTALLER_DIR/templates/Dockerfile" "$FORMANN_FIXTURE/installer/templates/Dockerfile"
  cp "$INSTALLER_DIR/templates/claude-md-snippet.md" "$FORMANN_FIXTURE/installer/templates/claude-md-snippet.md"
}

_run_self_install() {
  FORMANN_PATH="$FORMANN_FIXTURE" \
  FORMANN_INSTALL_BINDING_issue_tracker=local-markdown \
    bash "$INSTALL_SH" "$FORMANN_FIXTURE"
}

# Returns the block bounded by MARKER_START..MARKER_END (inclusive),
# or empty if no block is present.
_extract_block() {
  local file="$1"
  awk -v start="$MARKER_START" -v end="$MARKER_END" '
    $0 == start { inside=1 }
    inside { print }
    $0 == end { inside=0 }
  ' "$file"
}

_block_body() {
  local file="$1"
  awk -v start="$MARKER_START" -v end="$MARKER_END" '
    $0 == start { inside=1; next }
    $0 == end { inside=0; next }
    inside { print }
  ' "$file"
}

_assert_block_contains() {
  local file="$1" entry="$2"
  if ! grep -qxF "$entry" <(_block_body "$file"); then
    echo "managed block missing expected entry: $entry" >&2
    echo "--- block body ---" >&2
    _block_body "$file" >&2
    echo "------------------" >&2
    return 1
  fi
}

_assert_block_lacks() {
  local file="$1" entry="$2"
  if grep -qxF "$entry" <(_block_body "$file"); then
    echo "managed block unexpectedly contains entry: $entry" >&2
    return 1
  fi
}

# ---------------------------------------------------------------------------
# Self-install detection
# ---------------------------------------------------------------------------

@test "self-install is detected when consumer path equals formann path" {
  run _run_self_install
  assert_success
  grep -qxF "$MARKER_START" "$FORMANN_FIXTURE/.gitignore"
  grep -qxF "$MARKER_END" "$FORMANN_FIXTURE/.gitignore"
}

@test "self-install detection survives a trailing slash on the consumer arg" {
  run env FORMANN_PATH="$FORMANN_FIXTURE" \
    FORMANN_INSTALL_BINDING_issue_tracker=local-markdown \
    bash "$INSTALL_SH" "$FORMANN_FIXTURE/"
  assert_success
  grep -qxF "$MARKER_START" "$FORMANN_FIXTURE/.gitignore"
}

@test "self-install detection survives a relative consumer path" {
  parent="$(dirname "$FORMANN_FIXTURE")"
  base="$(basename "$FORMANN_FIXTURE")"
  run env FORMANN_PATH="$FORMANN_FIXTURE" \
    FORMANN_INSTALL_BINDING_issue_tracker=local-markdown \
    bash -c "cd '$parent' && bash '$INSTALL_SH' './$base'"
  assert_success
  grep -qxF "$MARKER_START" "$FORMANN_FIXTURE/.gitignore"
}

@test "normal-consumer install (paths differ) writes NO managed block" {
  consumer="$BATS_TEST_TMPDIR/consumer-elsewhere"
  mkdir -p "$consumer"
  run env FORMANN_PATH="$FORMANN_FIXTURE" \
    FORMANN_INSTALL_BINDING_issue_tracker=local-markdown \
    bash "$INSTALL_SH" "$consumer"
  assert_success
  ! grep -qxF "$MARKER_START" "$consumer/.gitignore"
  ! grep -qxF "$MARKER_END" "$consumer/.gitignore"
  grep -qxF '/.formann' "$consumer/.gitignore"
}

# ---------------------------------------------------------------------------
# Managed-block content: includes every installer product
# ---------------------------------------------------------------------------

@test "managed block contains /.formann" {
  run _run_self_install
  assert_success
  _assert_block_contains "$FORMANN_FIXTURE/.gitignore" '/.formann'
}

@test "managed block contains every skill under /.claude/skills/<name>" {
  run _run_self_install
  assert_success
  _assert_block_contains "$FORMANN_FIXTURE/.gitignore" '/.claude/skills/grill-me'
  _assert_block_contains "$FORMANN_FIXTURE/.gitignore" '/.claude/skills/implement'
}

@test "managed block contains every agent under /.claude/agents/<name>.md" {
  run _run_self_install
  assert_success
  _assert_block_contains "$FORMANN_FIXTURE/.gitignore" '/.claude/agents/review-feature.md'
  _assert_block_contains "$FORMANN_FIXTURE/.gitignore" '/.claude/agents/review-issue.md'
}

@test "managed block lists rules under /.claude/rules/<name> when framework/rules exists" {
  mkdir -p "$FORMANN_FIXTURE/framework/rules"
  touch "$FORMANN_FIXTURE/framework/rules/runner-smoke-artifacts.md"
  run _run_self_install
  assert_success
  _assert_block_contains "$FORMANN_FIXTURE/.gitignore" '/.claude/rules/runner-smoke-artifacts.md'
}

@test "managed block omits rules entries when framework/rules is absent" {
  [ ! -d "$FORMANN_FIXTURE/framework/rules" ]
  run _run_self_install
  assert_success
  # No entry under /.claude/rules/ should appear in the block.
  if grep -qE '^/\.claude/rules/' <(_block_body "$FORMANN_FIXTURE/.gitignore"); then
    echo "block unexpectedly contains a rules entry" >&2
    return 1
  fi
}

@test "managed block lists chosen role-binding folder under /docs/formann/<role>" {
  run _run_self_install
  assert_success
  _assert_block_contains "$FORMANN_FIXTURE/.gitignore" '/docs/formann/issue-tracker'
}

@test "managed block lists every flat role doc under /docs/formann/" {
  run _run_self_install
  assert_success
  for doc in lifecycle.md inbox.md domain.md triage-states.md afk-runner.md afk-runner-flow.md; do
    _assert_block_contains "$FORMANN_FIXTURE/.gitignore" "/docs/formann/$doc"
  done
}

@test "managed block contains /runner/Dockerfile" {
  run _run_self_install
  assert_success
  _assert_block_contains "$FORMANN_FIXTURE/.gitignore" '/runner/Dockerfile'
}

@test "adding a new skill folder and re-running adds its entry to the block" {
  _run_self_install
  _assert_block_lacks "$FORMANN_FIXTURE/.gitignore" '/.claude/skills/freshly-added'

  mkdir -p "$FORMANN_FIXTURE/framework/skills/freshly-added"
  touch "$FORMANN_FIXTURE/framework/skills/freshly-added/SKILL.md"

  run _run_self_install
  assert_success
  _assert_block_contains "$FORMANN_FIXTURE/.gitignore" '/.claude/skills/freshly-added'
}

# ---------------------------------------------------------------------------
# Managed-block writer — fixture inputs
# ---------------------------------------------------------------------------

@test "writer: empty .gitignore yields a block with all expected entries" {
  : > "$FORMANN_FIXTURE/.gitignore"
  run _run_self_install
  assert_success
  _assert_block_contains "$FORMANN_FIXTURE/.gitignore" '/.formann'
  _assert_block_contains "$FORMANN_FIXTURE/.gitignore" '/runner/Dockerfile'
}

@test "writer: pre-existing unrelated entries are preserved above the block" {
  cat > "$FORMANN_FIXTURE/.gitignore" <<EOF
.DS_Store
/.idea/
*.iml
__pycache__/
EOF
  run _run_self_install
  assert_success
  # Original lines still present, in original order, above the marker.
  awk -v marker="$MARKER_START" 'BEGIN{seen=0} $0==marker{print NR" MARKER"; exit} {print NR" "$0}' \
    "$FORMANN_FIXTURE/.gitignore" > "$BATS_TEST_TMPDIR/before-block.txt"
  grep -qxF '1 .DS_Store' "$BATS_TEST_TMPDIR/before-block.txt"
  grep -qxF '2 /.idea/' "$BATS_TEST_TMPDIR/before-block.txt"
  grep -qxF '3 *.iml' "$BATS_TEST_TMPDIR/before-block.txt"
  grep -qxF '4 __pycache__/' "$BATS_TEST_TMPDIR/before-block.txt"
}

@test "writer: pre-existing unrelated entries below the block are preserved" {
  cat > "$FORMANN_FIXTURE/.gitignore" <<EOF
$MARKER_START
/.formann
$MARKER_END
trailing-line-1
trailing-line-2
EOF
  run _run_self_install
  assert_success
  # Lines after the end marker are still present.
  awk -v end="$MARKER_END" '
    $0 == end { after=1; next }
    after { print }
  ' "$FORMANN_FIXTURE/.gitignore" > "$BATS_TEST_TMPDIR/after-block.txt"
  grep -qxF 'trailing-line-1' "$BATS_TEST_TMPDIR/after-block.txt"
  grep -qxF 'trailing-line-2' "$BATS_TEST_TMPDIR/after-block.txt"
}

@test "writer: stale block with extra entries — extras are removed" {
  cat > "$FORMANN_FIXTURE/.gitignore" <<EOF
$MARKER_START
/.formann
/.claude/skills/grill-me
/.claude/skills/implement
/.claude/skills/this-skill-does-not-exist
/runner/Dockerfile
$MARKER_END
EOF
  run _run_self_install
  assert_success
  _assert_block_lacks "$FORMANN_FIXTURE/.gitignore" '/.claude/skills/this-skill-does-not-exist'
  _assert_block_contains "$FORMANN_FIXTURE/.gitignore" '/.claude/skills/grill-me'
}

@test "writer: stale block with missing entries — missing entries are added" {
  cat > "$FORMANN_FIXTURE/.gitignore" <<EOF
$MARKER_START
/.formann
$MARKER_END
EOF
  run _run_self_install
  assert_success
  _assert_block_contains "$FORMANN_FIXTURE/.gitignore" '/.claude/skills/grill-me'
  _assert_block_contains "$FORMANN_FIXTURE/.gitignore" '/.claude/agents/review-feature.md'
  _assert_block_contains "$FORMANN_FIXTURE/.gitignore" '/runner/Dockerfile'
}

@test "writer: hand-edited block is silently overwritten with no warning emitted" {
  cat > "$FORMANN_FIXTURE/.gitignore" <<EOF
$MARKER_START
# hand-edited comment that should be wiped
/totally-bogus-entry
$MARKER_END
EOF
  run _run_self_install
  assert_success
  # Hand-edits gone.
  _assert_block_lacks "$FORMANN_FIXTURE/.gitignore" '# hand-edited comment that should be wiped'
  _assert_block_lacks "$FORMANN_FIXTURE/.gitignore" '/totally-bogus-entry'
  # Real products back in.
  _assert_block_contains "$FORMANN_FIXTURE/.gitignore" '/.formann'
  # No warning about the overwrite.
  refute_output --partial 'overwrite'
  refute_output --partial 'manual edit'
}

@test "writer: produces exactly one marker pair (no duplicate blocks on re-run)" {
  _run_self_install
  _run_self_install
  start_count="$(grep -cxF "$MARKER_START" "$FORMANN_FIXTURE/.gitignore")"
  end_count="$(grep -cxF "$MARKER_END" "$FORMANN_FIXTURE/.gitignore")"
  [ "$start_count" -eq 1 ]
  [ "$end_count" -eq 1 ]
}

@test "writer: re-running with no changes is a no-op (idempotent .gitignore)" {
  _run_self_install
  before="$(cat "$FORMANN_FIXTURE/.gitignore")"
  _run_self_install
  after="$(cat "$FORMANN_FIXTURE/.gitignore")"
  [ "$before" = "$after" ]
}

# ---------------------------------------------------------------------------
# End-to-end: fresh fixture, run installer once, block is present and complete
# ---------------------------------------------------------------------------

@test "end-to-end: managed block is present and lists every expected product" {
  run _run_self_install
  assert_success

  for entry in \
    '/.formann' \
    '/.claude/skills/grill-me' \
    '/.claude/skills/implement' \
    '/.claude/agents/review-feature.md' \
    '/.claude/agents/review-issue.md' \
    '/docs/formann/issue-tracker' \
    '/docs/formann/lifecycle.md' \
    '/docs/formann/inbox.md' \
    '/docs/formann/domain.md' \
    '/docs/formann/triage-states.md' \
    '/docs/formann/afk-runner.md' \
    '/docs/formann/afk-runner-flow.md' \
    '/runner/Dockerfile'
  do
    _assert_block_contains "$FORMANN_FIXTURE/.gitignore" "$entry"
  done
}

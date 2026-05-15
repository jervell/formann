#!/usr/bin/env bats

# Non-interactive installer test suite.
#
# Invocation: bats installer/tests/install.bats (from the formann/ repo root)
#
# Tests bypass interactive prompts via FORMANN_INSTALL_BINDING_<role> env vars
# and override the Formann root via FORMANN_PATH so each test runs against a
# controlled fixture rather than the live framework directory.

setup() {
  load 'test_helper/bats-support/load'
  load 'test_helper/bats-assert/load'

  INSTALLER_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
  INSTALL_SH="$INSTALLER_DIR/install.sh"

  FORMANN_FIXTURE="$BATS_TEST_TMPDIR/formann-fixture"
  CONSUMER="$BATS_TEST_TMPDIR/consumer"

  _setup_formann_fixture
  _setup_synthetic_consumer
}

# ---------------------------------------------------------------------------
# Fixture helpers
# ---------------------------------------------------------------------------

_setup_formann_fixture() {
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
  # Installer templates — copy the real templates so tests exercise the actual
  # scaffolded content (the installer's `cp` is part of what we're verifying).
  mkdir -p "$FORMANN_FIXTURE/installer/templates"
  cp "$INSTALLER_DIR/templates/Dockerfile" "$FORMANN_FIXTURE/installer/templates/Dockerfile"
  cp "$INSTALLER_DIR/templates/claude-md-snippet.md" "$FORMANN_FIXTURE/installer/templates/claude-md-snippet.md"
}

_setup_synthetic_consumer() {
  mkdir -p "$CONSUMER"
  git -C "$CONSUMER" init -q
}

_run_installer() {
  FORMANN_PATH="$FORMANN_FIXTURE" \
  FORMANN_INSTALL_BINDING_issue_tracker=local-markdown \
    bash "$INSTALL_SH" "$CONSUMER"
}

# ---------------------------------------------------------------------------
# .formann symlink
# ---------------------------------------------------------------------------

@test ".formann symlink exists at consumer root and resolves to formann fixture" {
  run _run_installer
  assert_success
  [ -L "$CONSUMER/.formann" ]
  resolved="$(readlink "$CONSUMER/.formann")"
  [ "$resolved" = "$FORMANN_FIXTURE" ]
}

# ---------------------------------------------------------------------------
# docs/formann role surface
# ---------------------------------------------------------------------------

@test "docs/formann/issue-tracker is a symlink resolving through .formann/framework/bindings" {
  run _run_installer
  assert_success
  [ -L "$CONSUMER/docs/formann/issue-tracker" ]
  target="$(readlink "$CONSUMER/docs/formann/issue-tracker")"
  [ "$target" = "../../.formann/framework/bindings/issue-tracker/local-markdown" ]
}

@test "docs/formann/lifecycle.md symlink exists and resolves through .formann" {
  run _run_installer
  assert_success
  [ -L "$CONSUMER/docs/formann/lifecycle.md" ]
  target="$(readlink "$CONSUMER/docs/formann/lifecycle.md")"
  [ "$target" = "../../.formann/framework/lifecycle.md" ]
}

@test "all framework-level doc symlinks exist in docs/formann" {
  run _run_installer
  assert_success
  for doc in lifecycle.md inbox.md domain.md triage-states.md afk-runner.md afk-runner-flow.md; do
    [ -L "$CONSUMER/docs/formann/$doc" ] || {
      echo "missing symlink: docs/formann/$doc" >&2
      return 1
    }
  done
}

# ---------------------------------------------------------------------------
# .claude/{skills,agents,rules} symlinks
# ---------------------------------------------------------------------------

@test ".claude/skills/grill-me is a symlink resolving through .formann/framework/skills" {
  run _run_installer
  assert_success
  [ -L "$CONSUMER/.claude/skills/grill-me" ]
  target="$(readlink "$CONSUMER/.claude/skills/grill-me")"
  [ "$target" = "../../.formann/framework/skills/grill-me" ]
}

@test ".claude/skills/* symlinks exist for every skill in the fixture" {
  run _run_installer
  assert_success
  for skill in grill-me implement; do
    [ -L "$CONSUMER/.claude/skills/$skill" ] || {
      echo "missing skill symlink: .claude/skills/$skill" >&2
      return 1
    }
  done
}

@test ".claude/agents/review-feature.md is a symlink resolving through .formann" {
  run _run_installer
  assert_success
  [ -L "$CONSUMER/.claude/agents/review-feature.md" ]
  target="$(readlink "$CONSUMER/.claude/agents/review-feature.md")"
  [ "$target" = "../../.formann/framework/agents/review-feature.md" ]
}

# ---------------------------------------------------------------------------
# runner/Dockerfile
# ---------------------------------------------------------------------------

@test "runner/Dockerfile is created as a real file (not a symlink)" {
  run _run_installer
  assert_success
  [ ! -L "$CONSUMER/runner/Dockerfile" ]
  [ -f "$CONSUMER/runner/Dockerfile" ]
}

@test "runner/Dockerfile contains runner-capable content" {
  run _run_installer
  assert_success
  grep -q "temurin-21-jdk" "$CONSUMER/runner/Dockerfile"
  grep -q "@anthropic-ai/claude-code" "$CONSUMER/runner/Dockerfile"
  grep -q "RUNNER_UID" "$CONSUMER/runner/Dockerfile"
  grep -q "ulimit -c 0" "$CONSUMER/runner/Dockerfile"
}

# ---------------------------------------------------------------------------
# .gitignore
# ---------------------------------------------------------------------------

@test ".gitignore contains /.formann after install" {
  run _run_installer
  assert_success
  grep -qxF '/.formann' "$CONSUMER/.gitignore"
}

# ---------------------------------------------------------------------------
# CLAUDE.md snippet printed to stdout
# ---------------------------------------------------------------------------

@test "install prints the CLAUDE.md snippet to stdout" {
  run _run_installer
  assert_success
  assert_output --partial "## Formann"
}

@test "install prints a paste-into-CLAUDE.md preamble" {
  run _run_installer
  assert_success
  assert_output --partial "CLAUDE.md"
}

# ---------------------------------------------------------------------------
# CLAUDE.md not modified
# ---------------------------------------------------------------------------

@test "install does not create or modify consumer CLAUDE.md" {
  echo "sentinel-content" > "$CONSUMER/CLAUDE.md"
  run _run_installer
  assert_success
  content="$(cat "$CONSUMER/CLAUDE.md")"
  [ "$content" = "sentinel-content" ]
}

# ---------------------------------------------------------------------------
# Idempotency
# ---------------------------------------------------------------------------

@test "running installer twice produces no diff (idempotent)" {
  _run_installer
  snapshot_before="$(find "$CONSUMER" -mindepth 1 | sort)"
  gitignore_before="$(cat "$CONSUMER/.gitignore")"
  dockerfile_before="$(cat "$CONSUMER/runner/Dockerfile")"

  _run_installer

  snapshot_after="$(find "$CONSUMER" -mindepth 1 | sort)"
  gitignore_after="$(cat "$CONSUMER/.gitignore")"
  dockerfile_after="$(cat "$CONSUMER/runner/Dockerfile")"

  [ "$snapshot_before" = "$snapshot_after" ]
  [ "$gitignore_before" = "$gitignore_after" ]
  [ "$dockerfile_before" = "$dockerfile_after" ]
}

@test ".gitignore entry is not duplicated on second run" {
  _run_installer
  _run_installer
  count="$(grep -cxF '/.formann' "$CONSUMER/.gitignore")"
  [ "$count" -eq 1 ]
}

# ---------------------------------------------------------------------------
# Stale-target overwrite
# ---------------------------------------------------------------------------

@test "installer overwrites stale skill symlink pointing at OLD-PATH" {
  mkdir -p "$CONSUMER/.claude/skills"
  ln -s "../../OLD-PATH" "$CONSUMER/.claude/skills/grill-me"

  run _run_installer
  assert_success

  target="$(readlink "$CONSUMER/.claude/skills/grill-me")"
  [ "$target" = "../../.formann/framework/skills/grill-me" ]
}

# ---------------------------------------------------------------------------
# Real-file preservation
# ---------------------------------------------------------------------------

@test "installer leaves real Dockerfile alone (does not clobber consumer override)" {
  mkdir -p "$CONSUMER/runner"
  echo "sentinel-dockerfile" > "$CONSUMER/runner/Dockerfile"

  run _run_installer
  assert_success

  content="$(cat "$CONSUMER/runner/Dockerfile")"
  [ "$content" = "sentinel-dockerfile" ]
}

@test "installer leaves real directory at managed skill path alone" {
  mkdir -p "$CONSUMER/.claude/skills/grill-me/subdir"
  echo "real" > "$CONSUMER/.claude/skills/grill-me/subdir/file"

  run _run_installer
  assert_success

  [ -d "$CONSUMER/.claude/skills/grill-me" ]
  [ ! -L "$CONSUMER/.claude/skills/grill-me" ]
  [ -f "$CONSUMER/.claude/skills/grill-me/subdir/file" ]
}

# ---------------------------------------------------------------------------
# Installer not symlinked into consumer (.claude/skills/install* absent)
# ---------------------------------------------------------------------------

@test "no install* entry in consumer .claude/skills after install" {
  run _run_installer
  assert_success
  install_entries="$(find "$CONSUMER/.claude/skills" -name 'install*' 2>/dev/null || true)"
  [ -z "$install_entries" ]
}

@test "no install* entry in consumer .claude/agents after install" {
  run _run_installer
  assert_success
  install_entries="$(find "$CONSUMER/.claude/agents" -name 'install*' 2>/dev/null || true)"
  [ -z "$install_entries" ]
}

# ---------------------------------------------------------------------------
# No manifest.yaml parsing
# ---------------------------------------------------------------------------

@test "installer works without any manifest.yaml in the fixture" {
  # Verify no manifest.yaml exists in the fixture
  count="$(find "$FORMANN_FIXTURE" -name 'manifest.yaml' 2>/dev/null | wc -l)"
  [ "$count" -eq 0 ]

  run _run_installer
  assert_success
}

# ---------------------------------------------------------------------------
# Regression: missing .gitignore append step causes test failure
# (tests must fail when an install step is missing)
# ---------------------------------------------------------------------------

@test "REGRESSION: .gitignore missing /.formann entry fails assertion" {
  # Run installer but manually remove the /.formann line after.
  # Uses awk (portable, returns 0 when no lines match) rather than `sed -i`,
  # which differs between GNU and BSD.
  _run_installer
  awk '!/^\/\.formann$/' "$CONSUMER/.gitignore" > "$CONSUMER/.gitignore.tmp"
  mv "$CONSUMER/.gitignore.tmp" "$CONSUMER/.gitignore"

  # This assertion would fail if .gitignore were missing the entry
  run grep -qxF '/.formann' "$CONSUMER/.gitignore"
  assert_failure
}

# ---------------------------------------------------------------------------
# Regression: missing skill symlink causes test failure
# ---------------------------------------------------------------------------

@test "REGRESSION: missing skill symlink fails assertion" {
  _run_installer
  rm "$CONSUMER/.claude/skills/grill-me"

  run test -L "$CONSUMER/.claude/skills/grill-me"
  assert_failure
}

# ---------------------------------------------------------------------------
# Invalid binding rejection
# ---------------------------------------------------------------------------

@test "installer rejects unknown impl name with a clear diagnostic" {
  run env FORMANN_PATH="$FORMANN_FIXTURE" \
    FORMANN_INSTALL_BINDING_issue_tracker=nonexistent-impl \
    bash "$INSTALL_SH" "$CONSUMER"
  assert_failure
  assert_output --partial "nonexistent-impl"
  assert_output --partial "issue-tracker"
  # No broken symlink left behind.
  [ ! -e "$CONSUMER/docs/formann/issue-tracker" ]
}

@test "installer rejects blank impl name from interactive prompt" {
  # Bypass env var and pipe an empty line into the interactive read.
  run bash -c "echo '' | FORMANN_PATH='$FORMANN_FIXTURE' bash '$INSTALL_SH' '$CONSUMER'"
  assert_failure
  assert_output --partial "issue-tracker"
  [ ! -e "$CONSUMER/docs/formann/issue-tracker" ]
}

# ---------------------------------------------------------------------------
# Warning when framework source dir is missing
# ---------------------------------------------------------------------------

@test "installer warns and continues when framework/skills directory is missing" {
  rm -rf "$FORMANN_FIXTURE/framework/skills"
  run _run_installer
  assert_success
  assert_output --partial "skipping skills"
}

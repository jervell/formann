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
  cp "$INSTALLER_DIR/templates/manifest.md" "$FORMANN_FIXTURE/installer/templates/manifest.md"
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
  [ "$resolved" = "$FORMANN_FIXTURE/framework" ]
}

# ---------------------------------------------------------------------------
# docs/formann role surface
# ---------------------------------------------------------------------------

@test "docs/formann/issue-tracker is a symlink resolving through .formann/bindings" {
  run _run_installer
  assert_success
  [ -L "$CONSUMER/docs/formann/issue-tracker" ]
  target="$(readlink "$CONSUMER/docs/formann/issue-tracker")"
  [ "$target" = "../../.formann/bindings/issue-tracker/local-markdown" ]
}

@test "docs/formann/lifecycle.md symlink exists and resolves through .formann" {
  run _run_installer
  assert_success
  [ -L "$CONSUMER/docs/formann/lifecycle.md" ]
  target="$(readlink "$CONSUMER/docs/formann/lifecycle.md")"
  [ "$target" = "../../.formann/lifecycle.md" ]
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

@test ".claude/skills/grill-me is a symlink resolving through .formann/skills" {
  run _run_installer
  assert_success
  [ -L "$CONSUMER/.claude/skills/grill-me" ]
  target="$(readlink "$CONSUMER/.claude/skills/grill-me")"
  [ "$target" = "../../.formann/skills/grill-me" ]
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
  [ "$target" = "../../.formann/agents/review-feature.md" ]
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
  grep -q "temurin-25-jdk" "$CONSUMER/runner/Dockerfile"
  grep -q "@anthropic-ai/claude-code" "$CONSUMER/runner/Dockerfile"
  grep -q "RUNNER_UID" "$CONSUMER/runner/Dockerfile"
  grep -q "ulimit -c 0" "$CONSUMER/runner/Dockerfile"
  grep -q "ulimit -c soft=" "$CONSUMER/runner/Dockerfile"
  grep -q "ulimit -Hc" "$CONSUMER/runner/Dockerfile"
  grep -q "core_pattern=" "$CONSUMER/runner/Dockerfile"
}

# ---------------------------------------------------------------------------
# runner/manifest.md
# ---------------------------------------------------------------------------

@test "runner/manifest.md is created as a real file (not a symlink)" {
  run _run_installer
  assert_success
  [ ! -L "$CONSUMER/runner/manifest.md" ]
  [ -f "$CONSUMER/runner/manifest.md" ]
}

@test "runner/manifest.md contains the default review-and-gate entry" {
  run _run_installer
  assert_success
  grep -qx "review-and-gate.md" "$CONSUMER/runner/manifest.md"
}

@test "installer leaves real manifest.md alone (does not clobber consumer override)" {
  mkdir -p "$CONSUMER/runner"
  echo "sentinel-manifest" > "$CONSUMER/runner/manifest.md"

  run _run_installer
  assert_success

  content="$(cat "$CONSUMER/runner/manifest.md")"
  [ "$content" = "sentinel-manifest" ]
}

# ---------------------------------------------------------------------------
# .gitignore
# ---------------------------------------------------------------------------

@test ".gitignore contains /.formann after install" {
  run _run_installer
  assert_success
  grep -qxF '/.formann' "$CONSUMER/.gitignore"
}

@test ".gitignore contains /.runner-state/ after install (framework runtime artifact)" {
  run _run_installer
  assert_success
  grep -qxF '/.runner-state/' "$CONSUMER/.gitignore"
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
# CLAUDE.md snippet suppression
# ---------------------------------------------------------------------------

@test "snippet suppressed when CLAUDE.md already contains the snippet verbatim" {
  bats_require_minimum_version 1.5.0
  cp "$FORMANN_FIXTURE/installer/templates/claude-md-snippet.md" "$CONSUMER/CLAUDE.md"
  run --separate-stderr _run_installer
  assert_success
  refute_output --partial "══"
  refute_output --partial "Paste the following"
  echo "$stderr" | grep -qF "CLAUDE.md already contains the Formann section, skipping snippet print"
}

@test "snippet prints when CLAUDE.md exists but lacks the snippet" {
  echo "# My project docs" > "$CONSUMER/CLAUDE.md"
  run _run_installer
  assert_success
  assert_output --partial "## Formann"
  assert_output --partial "══"
}

@test "snippet prints when CLAUDE.md has a minor edit to the snippet (fuzzy match not supported)" {
  sed 's/^## Formann$/## Formann methodology/' \
    "$FORMANN_FIXTURE/installer/templates/claude-md-snippet.md" \
    > "$CONSUMER/CLAUDE.md"
  run _run_installer
  assert_success
  assert_output --partial "══"
  assert_output --partial "Paste the following"
}

# ---------------------------------------------------------------------------
# Idempotency
# ---------------------------------------------------------------------------

@test "running installer twice produces no diff (idempotent)" {
  _run_installer
  snapshot_before="$(find "$CONSUMER" -mindepth 1 | sort)"
  gitignore_before="$(cat "$CONSUMER/.gitignore")"
  dockerfile_before="$(cat "$CONSUMER/runner/Dockerfile")"
  manifest_before="$(cat "$CONSUMER/runner/manifest.md")"

  _run_installer

  snapshot_after="$(find "$CONSUMER" -mindepth 1 | sort)"
  gitignore_after="$(cat "$CONSUMER/.gitignore")"
  dockerfile_after="$(cat "$CONSUMER/runner/Dockerfile")"
  manifest_after="$(cat "$CONSUMER/runner/manifest.md")"

  [ "$snapshot_before" = "$snapshot_after" ]
  [ "$gitignore_before" = "$gitignore_after" ]
  [ "$dockerfile_before" = "$dockerfile_after" ]
  [ "$manifest_before" = "$manifest_after" ]
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
  [ "$target" = "../../.formann/skills/grill-me" ]
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

# ---------------------------------------------------------------------------
# Per-binding setup hook
# ---------------------------------------------------------------------------

@test "installer invokes setup hook when binding ships an executable one" {
  setup_marker="$BATS_TEST_TMPDIR/setup-hook-fired"
  cat > "$FORMANN_FIXTURE/framework/bindings/issue-tracker/local-markdown/setup" <<'SETUP'
#!/usr/bin/env bash
touch "$SETUP_MARKER"
SETUP
  chmod +x "$FORMANN_FIXTURE/framework/bindings/issue-tracker/local-markdown/setup"

  run env SETUP_MARKER="$setup_marker" \
    FORMANN_PATH="$FORMANN_FIXTURE" \
    FORMANN_INSTALL_BINDING_issue_tracker=local-markdown \
    bash "$INSTALL_SH" "$CONSUMER"
  assert_success
  [ -f "$setup_marker" ]
}

@test "installer skips silently when binding has no setup hook" {
  # local-markdown fixture ships no setup script; installer must succeed with no error
  [ ! -f "$FORMANN_FIXTURE/framework/bindings/issue-tracker/local-markdown/setup" ]
  run _run_installer
  assert_success
}

@test "setup hook runs with CWD set to consumer path" {
  cat > "$FORMANN_FIXTURE/framework/bindings/issue-tracker/local-markdown/setup" <<'SETUP'
#!/usr/bin/env bash
touch ./setup-was-here
SETUP
  chmod +x "$FORMANN_FIXTURE/framework/bindings/issue-tracker/local-markdown/setup"

  run _run_installer
  assert_success
  [ -f "$CONSUMER/setup-was-here" ]
}

# ---------------------------------------------------------------------------
# Suggest current binding on re-install (AC1–AC7)
# ---------------------------------------------------------------------------

@test "re-install: empty input keeps the current binding" {
  # AC2 / AC6 — valid current binding, empty interactive input → keep it
  _run_installer  # first install: creates docs/formann/issue-tracker → local-markdown

  # second run: no env var, empty input via pipe
  run bash -c "echo '' | FORMANN_PATH='$FORMANN_FIXTURE' bash '$INSTALL_SH' '$CONSUMER'"
  assert_success

  target="$(readlink "$CONSUMER/docs/formann/issue-tracker")"
  [ "$target" = "../../.formann/bindings/issue-tracker/local-markdown" ]
}

@test "re-install: closed stdin (non-interactive) keeps the current binding" {
  # AC6 — empty input via closed stdin in non-interactive mode
  _run_installer

  run bash -c "FORMANN_PATH='$FORMANN_FIXTURE' bash '$INSTALL_SH' '$CONSUMER' </dev/null"
  assert_success

  target="$(readlink "$CONSUMER/docs/formann/issue-tracker")"
  [ "$target" = "../../.formann/bindings/issue-tracker/local-markdown" ]
}

@test "re-install: typing a different valid impl switches the current binding" {
  # AC2 — interactive switch sub-path: non-empty input names a different impl
  mkdir -p "$FORMANN_FIXTURE/framework/bindings/issue-tracker/github-issues"
  _run_installer  # first install: creates docs/formann/issue-tracker → local-markdown

  # second run: no env var, type 'github-issues' at the interactive prompt.
  # (The read prompt itself is silent when stdin is a pipe — bash only emits
  # the prompt to a TTY — so the assertion is on the symlink, not the text.)
  run bash -c "echo 'github-issues' | FORMANN_PATH='$FORMANN_FIXTURE' bash '$INSTALL_SH' '$CONSUMER'"
  assert_success
  refute_output --partial "switching"  # interactive switch, not env-var switch

  target="$(readlink "$CONSUMER/docs/formann/issue-tracker")"
  [ "$target" = "../../.formann/bindings/issue-tracker/github-issues" ]
}

@test "stale binding (impl removed from framework): stale diagnostic on stderr, installer continues" {
  # AC3 — current impl disappears from framework → stale message, prompt falls through
  _run_installer  # installs local-markdown

  # make local-markdown stale: remove from fixture, add a different impl
  rm -rf "$FORMANN_FIXTURE/framework/bindings/issue-tracker/local-markdown"
  mkdir -p "$FORMANN_FIXTURE/framework/bindings/issue-tracker/github-issues"

  run env FORMANN_PATH="$FORMANN_FIXTURE" \
    FORMANN_INSTALL_BINDING_issue_tracker=github-issues \
    bash "$INSTALL_SH" "$CONSUMER"
  assert_success

  # stale diagnostic must name the vanished impl
  assert_output --partial "local-markdown"
  assert_output --partial "stale"

  # symlink re-pointed to the new impl
  target="$(readlink "$CONSUMER/docs/formann/issue-tracker")"
  [ "$target" = "../../.formann/bindings/issue-tracker/github-issues" ]
}

@test "stale binding (dangling symlink — impl not in framework): stale diagnostic, installer continues" {
  # AC3 — symlink points to impl that never existed in framework
  mkdir -p "$CONSUMER/docs/formann"
  ln -s "../../.formann/bindings/issue-tracker/old-impl" "$CONSUMER/docs/formann/issue-tracker"

  run _run_installer
  assert_success

  assert_output --partial "old-impl"
  assert_output --partial "stale"

  # symlink updated to the valid impl chosen via env var
  target="$(readlink "$CONSUMER/docs/formann/issue-tracker")"
  [ "$target" = "../../.formann/bindings/issue-tracker/local-markdown" ]
}

@test "stale binding (off-shape symlink target): stale diagnostic, installer continues" {
  # AC3 — symlink target does not follow .formann/bindings/<role>/<impl> shape
  mkdir -p "$CONSUMER/docs/formann"
  ln -s "../../some-other/path" "$CONSUMER/docs/formann/issue-tracker"

  run _run_installer
  assert_success

  assert_output --partial "stale"
  refute_output --partial "switching"
}

@test "env var matches current binding: no switching message emitted" {
  # AC4 — env var equals current; installer stays silent
  _run_installer  # installs local-markdown via env var

  run _run_installer  # same env var again
  assert_success
  refute_output --partial "switching"
}

@test "env var differs from current binding: switching message on stderr" {
  # AC5 — env var names a different impl → one stderr line 'switching … from … to …'
  mkdir -p "$FORMANN_FIXTURE/framework/bindings/issue-tracker/github-issues"
  _run_installer  # installs local-markdown

  run env FORMANN_PATH="$FORMANN_FIXTURE" \
    FORMANN_INSTALL_BINDING_issue_tracker=github-issues \
    bash "$INSTALL_SH" "$CONSUMER"
  assert_success
  assert_output --partial "switching 'issue-tracker' from local-markdown to github-issues"
}

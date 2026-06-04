#!/usr/bin/env bats
bats_require_minimum_version 1.5.0

setup() {
  load 'test_helper/bats-support/load'
  load 'test_helper/bats-assert/load'

  HERE="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)"
  RESOLVER_SCRIPT="$HERE/../resolve-manifest.sh"
  # Source the resolver so its pure function is callable in-process.
  # shellcheck source=../resolve-manifest.sh
  source "$RESOLVER_SCRIPT"

  # Synthetic prompt roots backed by temp dirs.
  FW_ROOT="$(mktemp -d)"
  CONSUMER_ROOT="$(mktemp -d)"

  # Framework-root prompt files (the framework's building-block steps).
  touch "$FW_ROOT/review-and-gate.md"
  touch "$FW_ROOT/review.md"
  touch "$FW_ROOT/gate.md"
  touch "$FW_ROOT/fix.md"
  # Consumer-root prompt files.
  touch "$CONSUMER_ROOT/custom-review.md"
  touch "$CONSUMER_ROOT/my-check.md"
}

teardown() {
  rm -rf "$FW_ROOT" "$CONSUMER_ROOT"
}

# === AC1: empty manifest =====================================================

@test "resolve_manifest — empty string manifest produces no output and exits 0" {
  run resolve_manifest "" "$FW_ROOT" "$CONSUMER_ROOT"
  assert_success
  assert_output ""
}

@test "resolve_manifest — whitespace-only manifest produces no output and exits 0" {
  run resolve_manifest $'  \n\n\t\n  ' "$FW_ROOT" "$CONSUMER_ROOT"
  assert_success
  assert_output ""
}

# === AC1: comments and blank lines ===========================================

@test "resolve_manifest — comment-only manifest produces no output and exits 0" {
  manifest=$'# this is a comment\n# another comment'
  run resolve_manifest "$manifest" "$FW_ROOT" "$CONSUMER_ROOT"
  assert_success
  assert_output ""
}

@test "resolve_manifest — blank lines between entries are ignored" {
  manifest=$'review-and-gate.md\n\nfix.md'
  run resolve_manifest "$manifest" "$FW_ROOT" "$CONSUMER_ROOT"
  assert_success
  assert_line --index 0 "review-and-gate	$FW_ROOT/review-and-gate.md"
  assert_line --index 1 "fix	$FW_ROOT/fix.md"
}

@test "resolve_manifest — inline comments between entries are ignored" {
  manifest=$'# header\nreview-and-gate.md\n# between\nfix.md\n# tail'
  run resolve_manifest "$manifest" "$FW_ROOT" "$CONSUMER_ROOT"
  assert_success
  assert_line --index 0 "review-and-gate	$FW_ROOT/review-and-gate.md"
  assert_line --index 1 "fix	$FW_ROOT/fix.md"
  [ "${#lines[@]}" -eq 2 ]
}

@test "resolve_manifest — indented comment line is ignored" {
  manifest=$'  # indented comment\nreview-and-gate.md'
  run resolve_manifest "$manifest" "$FW_ROOT" "$CONSUMER_ROOT"
  assert_success
  assert_line --index 0 "review-and-gate	$FW_ROOT/review-and-gate.md"
  [ "${#lines[@]}" -eq 1 ]
}

# === AC2: framework-root resolution ==========================================

@test "resolve_manifest — path resolves against framework root when absent from consumer root" {
  run resolve_manifest "review-and-gate.md" "$FW_ROOT" "$CONSUMER_ROOT"
  assert_success
  assert_output "review-and-gate	$FW_ROOT/review-and-gate.md"
}

@test "resolve_manifest — label is the filename without .md" {
  run resolve_manifest "review.md" "$FW_ROOT" "$CONSUMER_ROOT"
  assert_success
  assert_output "review	$FW_ROOT/review.md"
}

@test "resolve_manifest — label for fix.md is fix" {
  run resolve_manifest "fix.md" "$FW_ROOT" "$CONSUMER_ROOT"
  assert_success
  assert_output "fix	$FW_ROOT/fix.md"
}

# === AC2: consumer-first resolution ==========================================

@test "resolve_manifest — consumer root is searched before framework root" {
  run resolve_manifest "custom-review.md" "$FW_ROOT" "$CONSUMER_ROOT"
  assert_success
  assert_output "custom-review	$CONSUMER_ROOT/custom-review.md"
}

@test "resolve_manifest — consumer file shadows framework file of same name" {
  touch "$CONSUMER_ROOT/review.md"
  run resolve_manifest "review.md" "$FW_ROOT" "$CONSUMER_ROOT"
  assert_success
  assert_output "review	$CONSUMER_ROOT/review.md"
}

@test "resolve_manifest — mixed consumer and framework entries" {
  manifest=$'review-and-gate.md\ncustom-review.md'
  run resolve_manifest "$manifest" "$FW_ROOT" "$CONSUMER_ROOT"
  assert_success
  assert_line --index 0 "review-and-gate	$FW_ROOT/review-and-gate.md"
  assert_line --index 1 "custom-review	$CONSUMER_ROOT/custom-review.md"
}

# === AC3: label derived from filename ========================================

@test "resolve_manifest — label for review-and-gate.md is review-and-gate" {
  run resolve_manifest "review-and-gate.md" "$FW_ROOT" "$CONSUMER_ROOT"
  assert_success
  assert_output "review-and-gate	$FW_ROOT/review-and-gate.md"
}

@test "resolve_manifest — leading and trailing whitespace around path is trimmed" {
  run resolve_manifest "  review-and-gate.md  " "$FW_ROOT" "$CONSUMER_ROOT"
  assert_success
  assert_output "review-and-gate	$FW_ROOT/review-and-gate.md"
}

# === AC3: order and repeated entries =========================================

@test "resolve_manifest — entries are returned in manifest order" {
  manifest=$'review-and-gate.md\nfix.md\ngate.md'
  run resolve_manifest "$manifest" "$FW_ROOT" "$CONSUMER_ROOT"
  assert_success
  assert_line --index 0 "review-and-gate	$FW_ROOT/review-and-gate.md"
  assert_line --index 1 "fix	$FW_ROOT/fix.md"
  assert_line --index 2 "gate	$FW_ROOT/gate.md"
  [ "${#lines[@]}" -eq 3 ]
}

@test "resolve_manifest — repeated entries are preserved (iterate loop uses repeats)" {
  manifest=$'review-and-gate.md\nfix.md\nreview-and-gate.md'
  run resolve_manifest "$manifest" "$FW_ROOT" "$CONSUMER_ROOT"
  assert_success
  assert_line --index 0 "review-and-gate	$FW_ROOT/review-and-gate.md"
  assert_line --index 1 "fix	$FW_ROOT/fix.md"
  assert_line --index 2 "review-and-gate	$FW_ROOT/review-and-gate.md"
  [ "${#lines[@]}" -eq 3 ]
}

@test "resolve_manifest — same entry repeated many times is preserved" {
  manifest=$'gate.md\ngate.md\ngate.md'
  run resolve_manifest "$manifest" "$FW_ROOT" "$CONSUMER_ROOT"
  assert_success
  [ "${#lines[@]}" -eq 3 ]
  assert_line --index 0 "gate	$FW_ROOT/gate.md"
  assert_line --index 1 "gate	$FW_ROOT/gate.md"
  assert_line --index 2 "gate	$FW_ROOT/gate.md"
}

# === AC4: subfolder paths ====================================================

@test "resolve_manifest — subfolder path resolves in consumer root" {
  mkdir -p "$CONSUMER_ROOT/custom"
  touch "$CONSUMER_ROOT/custom/my-prompt.md"
  run resolve_manifest "custom/my-prompt.md" "$FW_ROOT" "$CONSUMER_ROOT"
  assert_success
  assert_output "my-prompt	$CONSUMER_ROOT/custom/my-prompt.md"
}

@test "resolve_manifest — subfolder path resolves in framework root" {
  mkdir -p "$FW_ROOT/extra"
  touch "$FW_ROOT/extra/special.md"
  run resolve_manifest "extra/special.md" "$FW_ROOT" "$CONSUMER_ROOT"
  assert_success
  assert_output "special	$FW_ROOT/extra/special.md"
}

@test "resolve_manifest — subfolder label is basename only, without .md" {
  mkdir -p "$FW_ROOT/sub"
  touch "$FW_ROOT/sub/my-check.md"
  run resolve_manifest "sub/my-check.md" "$FW_ROOT" "$CONSUMER_ROOT"
  assert_success
  assert_output "my-check	$FW_ROOT/sub/my-check.md"
}

# === AC4: validation rejects .. segments =====================================

@test "resolve_manifest — bare .. exits 1" {
  run resolve_manifest ".." "$FW_ROOT" "$CONSUMER_ROOT"
  assert_failure
}

@test "resolve_manifest — leading ../ exits 1" {
  run resolve_manifest "../secret.md" "$FW_ROOT" "$CONSUMER_ROOT"
  assert_failure
}

@test "resolve_manifest — mid-path .. exits 1" {
  run resolve_manifest "steps/../secret.md" "$FW_ROOT" "$CONSUMER_ROOT"
  assert_failure
}

@test "resolve_manifest — trailing /.. exits 1" {
  run resolve_manifest "steps/.." "$FW_ROOT" "$CONSUMER_ROOT"
  assert_failure
}

@test "resolve_manifest — .. validation names the offending reference in stderr" {
  local stderr_file
  stderr_file="$BATS_TEST_TMPDIR/stderr.txt"
  resolve_manifest "../secret.md" "$FW_ROOT" "$CONSUMER_ROOT" 2>"$stderr_file" || true
  [ -s "$stderr_file" ]
}

# === AC4: validation rejects leading / =======================================

@test "resolve_manifest — leading / exits 1" {
  run resolve_manifest "/absolute/path.md" "$FW_ROOT" "$CONSUMER_ROOT"
  assert_failure
}

@test "resolve_manifest — leading / produces a validation error in stderr" {
  local stderr_file
  stderr_file="$BATS_TEST_TMPDIR/stderr.txt"
  resolve_manifest "/absolute/path.md" "$FW_ROOT" "$CONSUMER_ROOT" 2>"$stderr_file" || true
  [ -s "$stderr_file" ]
}

# === AC6: unresolved reference ===============================================

@test "resolve_manifest — non-existent prompt exits 1" {
  run resolve_manifest "nonexistent.md" "$FW_ROOT" "$CONSUMER_ROOT"
  assert_failure
}

@test "resolve_manifest — non-existent prompt names the offending reference in stderr" {
  local stderr_file
  stderr_file="$BATS_TEST_TMPDIR/stderr.txt"
  resolve_manifest "nonexistent.md" "$FW_ROOT" "$CONSUMER_ROOT" 2>"$stderr_file" || true
  grep -q "nonexistent.md" "$stderr_file"
}

@test "resolve_manifest — non-existent prompt produces no valid output lines" {
  run --separate-stderr resolve_manifest "nonexistent.md" "$FW_ROOT" "$CONSUMER_ROOT"
  assert_failure
  assert_output ""
}

@test "resolve_manifest — only valid entries appear in output when mixed with missing" {
  manifest=$'review-and-gate.md\nnonexistent.md'
  run --separate-stderr resolve_manifest "$manifest" "$FW_ROOT" "$CONSUMER_ROOT"
  assert_failure
  # The valid entry MUST NOT appear — the whole manifest fails validation.
  assert_output ""
}

# === AC6: multiple errors collected ==========================================

@test "resolve_manifest — multiple invalid entries all produce errors (all collected)" {
  manifest=$'../bad1.md\n/bad2.md\nnonexistent.md'
  run --separate-stderr resolve_manifest "$manifest" "$FW_ROOT" "$CONSUMER_ROOT"
  assert_failure
  assert_output ""
}

@test "resolve_manifest — error in one entry does not block reporting errors in others" {
  manifest=$'nonexistent1.md\nnonexistent2.md'
  local stderr_file
  stderr_file="$BATS_TEST_TMPDIR/stderr.txt"
  resolve_manifest "$manifest" "$FW_ROOT" "$CONSUMER_ROOT" 2>"$stderr_file" || true
  # Both missing refs must be named in stderr.
  grep -q "nonexistent1.md" "$stderr_file"
  grep -q "nonexistent2.md" "$stderr_file"
}

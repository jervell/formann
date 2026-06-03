#!/usr/bin/env bats

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

  # Pre-create prompt files referenced by the tests below.
  touch "$FW_ROOT/review-and-gate.md"
  touch "$FW_ROOT/review.md"
  touch "$FW_ROOT/gate.md"
  touch "$FW_ROOT/fix.md"
  touch "$CONSUMER_ROOT/custom-review.md"
  touch "$CONSUMER_ROOT/my-check.md"
}

teardown() {
  rm -rf "$FW_ROOT" "$CONSUMER_ROOT"
}

# === AC6: empty manifest =====================================================

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

# === AC2: comments and blank lines ===========================================

@test "resolve_manifest — comment-only manifest produces no output and exits 0" {
  manifest=$'# this is a comment\n# another comment'
  run resolve_manifest "$manifest" "$FW_ROOT" "$CONSUMER_ROOT"
  assert_success
  assert_output ""
}

@test "resolve_manifest — blank lines between entries are ignored" {
  manifest=$'review → framework:review-and-gate.md\n\nfix → framework:fix.md'
  run resolve_manifest "$manifest" "$FW_ROOT" "$CONSUMER_ROOT"
  assert_success
  assert_line --index 0 "review	$FW_ROOT/review-and-gate.md"
  assert_line --index 1 "fix	$FW_ROOT/fix.md"
}

@test "resolve_manifest — inline comments between entries are ignored" {
  manifest=$'# header\nreview → framework:review-and-gate.md\n# between\nfix → framework:fix.md\n# tail'
  run resolve_manifest "$manifest" "$FW_ROOT" "$CONSUMER_ROOT"
  assert_success
  assert_line --index 0 "review	$FW_ROOT/review-and-gate.md"
  assert_line --index 1 "fix	$FW_ROOT/fix.md"
  [ "${#lines[@]}" -eq 2 ]
}

@test "resolve_manifest — indented comment line is ignored" {
  manifest=$'  # indented comment\nreview → framework:review-and-gate.md'
  run resolve_manifest "$manifest" "$FW_ROOT" "$CONSUMER_ROOT"
  assert_success
  assert_line --index 0 "review	$FW_ROOT/review-and-gate.md"
  [ "${#lines[@]}" -eq 1 ]
}

# === AC3: namespace resolution ===============================================

@test "resolve_manifest — framework: reference resolves to framework root" {
  run resolve_manifest "review → framework:review-and-gate.md" "$FW_ROOT" "$CONSUMER_ROOT"
  assert_success
  assert_output "review	$FW_ROOT/review-and-gate.md"
}

@test "resolve_manifest — consumer: reference resolves to consumer root" {
  run resolve_manifest "custom → consumer:custom-review.md" "$FW_ROOT" "$CONSUMER_ROOT"
  assert_success
  assert_output "custom	$CONSUMER_ROOT/custom-review.md"
}

@test "resolve_manifest — mixed framework and consumer references" {
  manifest=$'step1 → framework:review-and-gate.md\nstep2 → consumer:my-check.md'
  run resolve_manifest "$manifest" "$FW_ROOT" "$CONSUMER_ROOT"
  assert_success
  assert_line --index 0 "step1	$FW_ROOT/review-and-gate.md"
  assert_line --index 1 "step2	$CONSUMER_ROOT/my-check.md"
}

@test "resolve_manifest — label with spaces is preserved verbatim" {
  run resolve_manifest "review and gate → framework:review-and-gate.md" "$FW_ROOT" "$CONSUMER_ROOT"
  assert_success
  assert_output "review and gate	$FW_ROOT/review-and-gate.md"
}

@test "resolve_manifest — leading and trailing whitespace around label and ref is trimmed" {
  run resolve_manifest "  review  →  framework:review-and-gate.md  " "$FW_ROOT" "$CONSUMER_ROOT"
  assert_success
  assert_output "review	$FW_ROOT/review-and-gate.md"
}

# === AC1: order and repeated entries =========================================

@test "resolve_manifest — entries are returned in manifest order" {
  manifest=$'step1 → framework:review-and-gate.md\nstep2 → framework:fix.md\nstep3 → framework:gate.md'
  run resolve_manifest "$manifest" "$FW_ROOT" "$CONSUMER_ROOT"
  assert_success
  assert_line --index 0 "step1	$FW_ROOT/review-and-gate.md"
  assert_line --index 1 "step2	$FW_ROOT/fix.md"
  assert_line --index 2 "step3	$FW_ROOT/gate.md"
  [ "${#lines[@]}" -eq 3 ]
}

@test "resolve_manifest — repeated entries are preserved (iterate loop uses repeats)" {
  manifest=$'review → framework:review-and-gate.md\nfix → framework:fix.md\nreview → framework:review-and-gate.md'
  run resolve_manifest "$manifest" "$FW_ROOT" "$CONSUMER_ROOT"
  assert_success
  assert_line --index 0 "review	$FW_ROOT/review-and-gate.md"
  assert_line --index 1 "fix	$FW_ROOT/fix.md"
  assert_line --index 2 "review	$FW_ROOT/review-and-gate.md"
  [ "${#lines[@]}" -eq 3 ]
}

@test "resolve_manifest — same label repeated many times is preserved" {
  manifest=$'gate → framework:gate.md\ngate → framework:gate.md\ngate → framework:gate.md'
  run resolve_manifest "$manifest" "$FW_ROOT" "$CONSUMER_ROOT"
  assert_success
  [ "${#lines[@]}" -eq 3 ]
  assert_line --index 0 "gate	$FW_ROOT/gate.md"
  assert_line --index 1 "gate	$FW_ROOT/gate.md"
  assert_line --index 2 "gate	$FW_ROOT/gate.md"
}

# === AC4: unresolved reference ===============================================

@test "resolve_manifest — non-existent framework prompt exits 1" {
  run resolve_manifest "step → framework:nonexistent.md" "$FW_ROOT" "$CONSUMER_ROOT"
  assert_failure
}

@test "resolve_manifest — non-existent framework prompt names the offending reference in stderr" {
  local stderr_file
  stderr_file="$BATS_TEST_TMPDIR/stderr.txt"
  resolve_manifest "step → framework:nonexistent.md" "$FW_ROOT" "$CONSUMER_ROOT" 2>"$stderr_file" || true
  grep -q "framework:nonexistent.md" "$stderr_file"
}

@test "resolve_manifest — non-existent consumer prompt exits 1" {
  run resolve_manifest "step → consumer:missing.md" "$FW_ROOT" "$CONSUMER_ROOT"
  assert_failure
}

@test "resolve_manifest — non-existent consumer prompt names the offending reference in stderr" {
  local stderr_file
  stderr_file="$BATS_TEST_TMPDIR/stderr.txt"
  resolve_manifest "step → consumer:missing.md" "$FW_ROOT" "$CONSUMER_ROOT" 2>"$stderr_file" || true
  grep -q "consumer:missing.md" "$stderr_file"
}

@test "resolve_manifest — non-existent prompt produces no valid output lines" {
  run --separate-stderr resolve_manifest "step → framework:nonexistent.md" "$FW_ROOT" "$CONSUMER_ROOT"
  assert_failure
  assert_output ""
}

@test "resolve_manifest — only valid entries appear in output when mixed with missing" {
  manifest=$'good → framework:review-and-gate.md\nmissing → framework:nonexistent.md'
  run --separate-stderr resolve_manifest "$manifest" "$FW_ROOT" "$CONSUMER_ROOT"
  assert_failure
  # The valid entry MUST NOT appear — the whole manifest fails validation.
  # (All errors are collected; exit 1 suppresses partial output.)
  assert_output ""
}

# === AC5: malformed entries ==================================================

@test "resolve_manifest — entry with no separator exits 1" {
  run resolve_manifest "no-separator-here" "$FW_ROOT" "$CONSUMER_ROOT"
  assert_failure
}

@test "resolve_manifest — entry with no separator produces a validation error in stderr" {
  local stderr_file
  stderr_file="$BATS_TEST_TMPDIR/stderr.txt"
  resolve_manifest "no-separator-here" "$FW_ROOT" "$CONSUMER_ROOT" 2>"$stderr_file" || true
  [ -s "$stderr_file" ]
}

@test "resolve_manifest — entry with empty label exits 1" {
  run resolve_manifest " → framework:review-and-gate.md" "$FW_ROOT" "$CONSUMER_ROOT"
  assert_failure
}

@test "resolve_manifest — entry with empty reference exits 1" {
  run resolve_manifest "step → " "$FW_ROOT" "$CONSUMER_ROOT"
  assert_failure
}

@test "resolve_manifest — unknown namespace exits 1" {
  run resolve_manifest "step → unknown:something.md" "$FW_ROOT" "$CONSUMER_ROOT"
  assert_failure
}

@test "resolve_manifest — unknown namespace names the bad namespace in stderr" {
  local stderr_file
  stderr_file="$BATS_TEST_TMPDIR/stderr.txt"
  resolve_manifest "step → unknown:something.md" "$FW_ROOT" "$CONSUMER_ROOT" 2>"$stderr_file" || true
  grep -q "unknown" "$stderr_file"
}

@test "resolve_manifest — namespace with no prompt name exits 1" {
  run resolve_manifest "step → framework:" "$FW_ROOT" "$CONSUMER_ROOT"
  assert_failure
}

@test "resolve_manifest — consumer namespace with no prompt name exits 1" {
  run resolve_manifest "step → consumer:" "$FW_ROOT" "$CONSUMER_ROOT"
  assert_failure
}

# === Multiple errors collected ===============================================

@test "resolve_manifest — multiple malformed entries all produce errors (all collected)" {
  manifest=$'bad1\nbad2 → unknown:x\nbad3 → framework:missing.md'
  run --separate-stderr resolve_manifest "$manifest" "$FW_ROOT" "$CONSUMER_ROOT"
  assert_failure
  # No valid output on stdout.
  assert_output ""
}

@test "resolve_manifest — error in one entry does not block reporting errors in others" {
  manifest=$'step1 → framework:nonexistent1.md\nstep2 → framework:nonexistent2.md'
  local stderr_file
  stderr_file="$BATS_TEST_TMPDIR/stderr.txt"
  resolve_manifest "$manifest" "$FW_ROOT" "$CONSUMER_ROOT" 2>"$stderr_file" || true
  # Both missing refs must be named in stderr.
  grep -q "nonexistent1.md" "$stderr_file"
  grep -q "nonexistent2.md" "$stderr_file"
}

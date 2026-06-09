#!/usr/bin/env bats
bats_require_minimum_version 1.5.0

# Pure-module suite for liveness.sh — the phase deriver and line formatter
# behind the runner's liveness line (issue #72). Synthetic single-event
# fixtures live under fixtures/liveness-events/; the retry/backoff cases are
# the real `system/api_retry` captures lifted from fixtures/transport-crashes/
# (#70's stream captures, landed by #71). No container, no terminal, no clock.

setup() {
  load 'test_helper/bats-support/load'
  load 'test_helper/bats-assert/load'

  HERE="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)"
  LIVENESS_SCRIPT="$HERE/../liveness.sh"
  # Source the module so its pure functions are callable in-process.
  # shellcheck source=../liveness.sh
  source "$LIVENESS_SCRIPT"

  EVENTS="$HERE/fixtures/liveness-events"
  CRASHES="$HERE/fixtures/transport-crashes"
}

# Read the single event line from a liveness-events fixture.
event() { cat "$EVENTS/$1"; }

# === derive_phase — running-tool (assistant tool_use) ======================

@test "derive_phase — tool-use event yields the running-tool phase (Bash command)" {
  run -0 derive_phase "$(event assistant-tool-use-bash.jsonl)"
  assert_output "Bash: bats -p framework/runner/tests"
}

@test "derive_phase — Read tool-use names the file being read" {
  run -0 derive_phase "$(event assistant-tool-use-read.jsonl)"
  assert_output "Read: /repo/framework/runner/lib.sh"
}

@test "derive_phase — tool-use without command/file_path falls back to description" {
  run -0 derive_phase "$(event assistant-tool-use-task.jsonl)"
  assert_output "Task: Explore the runner tests"
}

@test "derive_phase — tool-use with empty input yields the bare tool name" {
  run -0 derive_phase "$(event assistant-tool-use-bare.jsonl)"
  assert_output "ExitPlanMode"
}

@test "derive_phase — multiline tool command collapses to single-spaced label" {
  run -0 derive_phase "$(event assistant-tool-use-multiline.jsonl)"
  assert_output "Bash: cd /repo && mvn -q verify 2>&1"
}

@test "derive_phase — parallel tool-use blocks: first block wins" {
  run -0 derive_phase "$(event assistant-parallel-tool-use.jsonl)"
  assert_output "Read: /repo/README.md"
}

@test "derive_phase — text-only assistant event is no phase change" {
  run -0 derive_phase "$(event assistant-text-only.jsonl)"
  assert_output ""
}

# === derive_phase — thinking (user tool_result) ============================

@test "derive_phase — tool-result event yields the thinking phase" {
  run -0 derive_phase "$(event user-tool-result.jsonl)"
  assert_output "thinking"
}

@test "derive_phase — plain user text event is no phase change" {
  run -0 derive_phase "$(event user-plain-text.jsonl)"
  assert_output ""
}

# === derive_phase — retry/backoff (system api_retry, lifted captures) ======

@test "derive_phase — api_retry with HTTP status yields retry phase with status reason (429)" {
  # Line 4 of the http429 capture is attempt 3 of 10, error_status 429.
  run -0 derive_phase "$(sed -n '4p' "$CRASHES/http429.stdout.jsonl")"
  assert_output "retry 3/10 (429)"
}

@test "derive_phase — api_retry 503 yields retry phase with status reason" {
  # Line 2 of the http503 capture is attempt 1 of 10, error_status 503.
  run -0 derive_phase "$(sed -n '2p' "$CRASHES/http503.stdout.jsonl")"
  assert_output "retry 1/10 (503)"
}

@test "derive_phase — api_retry with null status falls back to the error token" {
  # Line 2 of the econnreset capture is attempt 1 of 10, error_status null,
  # error "unknown".
  run -0 derive_phase "$(sed -n '2p' "$CRASHES/econnreset.stdout.jsonl")"
  assert_output "retry 1/10 (unknown)"
}

@test "derive_phase — successive api_retry attempts are distinct phases (timer resets per attempt)" {
  # Phase identity includes the attempt number: each new api_retry event must
  # derive a different label, so the renderer's time-in-phase resets and an
  # advancing attempt counter reads as liveness.
  attempt1="$(derive_phase "$(sed -n '2p' "$CRASHES/http429.stdout.jsonl")")"
  attempt2="$(derive_phase "$(sed -n '3p' "$CRASHES/http429.stdout.jsonl")")"
  [ -n "$attempt1" ]
  [ -n "$attempt2" ]
  [ "$attempt1" != "$attempt2" ]
}

# === derive_phase — irrelevant and malformed input =========================

@test "derive_phase — system init event is no phase change" {
  run -0 derive_phase "$(sed -n '1p' "$CRASHES/http429.stdout.jsonl")"
  assert_output ""
}

@test "derive_phase — terminal result event is no phase change" {
  run -0 derive_phase "$(tail -n 1 "$CRASHES/http429.stdout.jsonl")"
  assert_output ""
}

@test "derive_phase — malformed JSON degrades to no phase change, exit 0" {
  run -0 derive_phase '{"type":"assistant","message":{'
  assert_output ""
}

@test "derive_phase — empty line degrades to no phase change, exit 0" {
  run -0 derive_phase ''
  assert_output ""
}

# === format_liveness_line ==================================================

@test "format_liveness_line — renders feature/issue, stage, elapsed, phase, time-in-phase" {
  run -0 format_liveness_line runner-liveness-line 72 implement \
    "Bash: bats -p framework/runner/tests" 754 62 200
  assert_output "runner-liveness-line/72 implement 12m 34s | Bash: bats -p framework/runner/tests (1m 2s)"
}

@test "format_liveness_line — thinking phase with sub-minute durations" {
  run -0 format_liveness_line f 01 review-and-gate thinking 185 12 200
  assert_output "f/01 review-and-gate 3m 5s | thinking (12s)"
}

@test "format_liveness_line — retry phase renders like any other phase" {
  run -0 format_liveness_line f 01 implement "retry 3/10 (429)" 490 45 200
  assert_output "f/01 implement 8m 10s | retry 3/10 (429) (45s)"
}

@test "format_liveness_line — long tool label truncates to width-1 (no wrap)" {
  local long_phase
  long_phase="Bash: $(printf 'x%.0s' $(seq 1 200))"
  full="$(format_liveness_line f 01 implement "$long_phase" 65 3 500)"
  run -0 format_liveness_line f 01 implement "$long_phase" 65 3 40
  [ "${#output}" -eq 39 ]
  [ "$output" = "${full:0:39}" ]
}

@test "format_liveness_line — short line is emitted unmodified" {
  run -0 format_liveness_line f 01 implement thinking 5 5 80
  assert_output "f/01 implement 5s | thinking (5s)"
}

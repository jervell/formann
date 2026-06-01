#!/usr/bin/env bats

setup() {
  load 'test_helper/bats-support/load'
  load 'test_helper/bats-assert/load'

  HERE="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)"
  RUNNER_SCRIPT="$HERE/../run-the-queue.sh"
  # Source the runner so its pure functions are callable in-process. The
  # source-guard inside the script prevents `main` from running.
  # shellcheck source=../run-the-queue.sh
  source "$RUNNER_SCRIPT"
}

# A minimal tracker-snapshot envelope with one issue at the given status.
# Bash 3.2 compatible — no associative arrays.
snapshot_one() {
  local ref="$1" status="$2"
  printf '{"feature":"f","issues":[{"ref":"%s","status":"%s","category":"enhancement","type":"AFK","blocked_by":[],"eligible":false}]}' \
    "$ref" "$status"
}

@test "classify_outcome — ready-for-agent → in-review is success" {
  pre="$(snapshot_one f/01 ready-for-agent)"
  post="$(snapshot_one f/01 in-review)"
  result="$(classify_outcome "$pre" "$post" f/01)"
  [ "$result" = "success" ]
}

@test "classify_outcome — ready-for-agent → done is success" {
  pre="$(snapshot_one f/01 ready-for-agent)"
  post="$(snapshot_one f/01 done)"
  result="$(classify_outcome "$pre" "$post" f/01)"
  [ "$result" = "success" ]
}

@test "classify_outcome — no status change is failure" {
  pre="$(snapshot_one f/01 ready-for-agent)"
  post="$(snapshot_one f/01 ready-for-agent)"
  result="$(classify_outcome "$pre" "$post" f/01)"
  [ "$result" = "failure" ]
}

@test "classify_outcome — pre-status not ready-for-agent is failure" {
  pre="$(snapshot_one f/01 needs-info)"
  post="$(snapshot_one f/01 in-review)"
  result="$(classify_outcome "$pre" "$post" f/01)"
  [ "$result" = "failure" ]
}

@test "classify_outcome — flip to wontfix is failure" {
  pre="$(snapshot_one f/01 ready-for-agent)"
  post="$(snapshot_one f/01 wontfix)"
  result="$(classify_outcome "$pre" "$post" f/01)"
  [ "$result" = "failure" ]
}

@test "classify_outcome — flip to needs-info is failure" {
  pre="$(snapshot_one f/01 ready-for-agent)"
  post="$(snapshot_one f/01 needs-info)"
  result="$(classify_outcome "$pre" "$post" f/01)"
  [ "$result" = "failure" ]
}

@test "classify_outcome — missing ref in either snapshot is failure" {
  pre='{"feature":"f","issues":[]}'
  post="$(snapshot_one f/01 in-review)"
  result="$(classify_outcome "$pre" "$post" f/01)"
  [ "$result" = "failure" ]

  pre="$(snapshot_one f/01 ready-for-agent)"
  post='{"feature":"f","issues":[]}'
  result="$(classify_outcome "$pre" "$post" f/01)"
  [ "$result" = "failure" ]
}

@test "classify_outcome — only the named ref is consulted" {
  pre='{"feature":"f","issues":[
    {"ref":"f/01","status":"ready-for-agent","category":"enhancement","type":"AFK","blocked_by":[],"eligible":true},
    {"ref":"f/02","status":"done","category":"enhancement","type":"AFK","blocked_by":[],"eligible":false}
  ]}'
  post='{"feature":"f","issues":[
    {"ref":"f/01","status":"ready-for-agent","category":"enhancement","type":"AFK","blocked_by":[],"eligible":true},
    {"ref":"f/02","status":"in-review","category":"enhancement","type":"AFK","blocked_by":[],"eligible":false}
  ]}'
  # f/01 didn't move — failure, even though f/02 advanced.
  result="$(classify_outcome "$pre" "$post" f/01)"
  [ "$result" = "failure" ]
  # f/02 advanced — but pre-status was `done`, not `ready-for-agent` — still failure.
  result="$(classify_outcome "$pre" "$post" f/02)"
  [ "$result" = "failure" ]
}

# === classify_gate_outcome =================================================
#
# Pure classifier for the post-implement review-and-gate dispatch. Inputs:
# (pre-gate snapshot, post-gate snapshot, ref, exit_code). Returns one of
# `clean | blocked | gate-failed`. The gate's pre-snapshot is the
# post-implement state — issue at in-review.

@test "classify_gate_outcome — exit 0 + post.status=done is clean" {
  pre="$(snapshot_one f/01 in-review)"
  post="$(snapshot_one f/01 done)"
  result="$(classify_gate_outcome "$pre" "$post" f/01 0)"
  [ "$result" = "clean" ]
}

@test "classify_gate_outcome — exit 0 + post.status=in-review is blocked" {
  pre="$(snapshot_one f/01 in-review)"
  post="$(snapshot_one f/01 in-review)"
  result="$(classify_gate_outcome "$pre" "$post" f/01 0)"
  [ "$result" = "blocked" ]
}

@test "classify_gate_outcome — nonzero exit is gate-failed regardless of status" {
  pre="$(snapshot_one f/01 in-review)"
  post="$(snapshot_one f/01 done)"
  result="$(classify_gate_outcome "$pre" "$post" f/01 1)"
  [ "$result" = "gate-failed" ]
  result="$(classify_gate_outcome "$pre" "$post" f/01 137)"
  [ "$result" = "gate-failed" ]
}

@test "classify_gate_outcome — exit 0 + off-mission post-status (ready-for-agent) is gate-failed" {
  pre="$(snapshot_one f/01 in-review)"
  post="$(snapshot_one f/01 ready-for-agent)"
  result="$(classify_gate_outcome "$pre" "$post" f/01 0)"
  [ "$result" = "gate-failed" ]
}

@test "classify_gate_outcome — exit 0 + off-mission post-status (wontfix) is gate-failed" {
  pre="$(snapshot_one f/01 in-review)"
  post="$(snapshot_one f/01 wontfix)"
  result="$(classify_gate_outcome "$pre" "$post" f/01 0)"
  [ "$result" = "gate-failed" ]
}

@test "classify_gate_outcome — exit 0 + ref absent from post snapshot is clean (github-issues binding: done closes issue)" {
  # pre=in-review, exit 0, ref gone from snapshot → binding-native done → clean.
  pre="$(snapshot_one f/01 in-review)"
  post='{"feature":"f","issues":[]}'
  result="$(classify_gate_outcome "$pre" "$post" f/01 0)"
  [ "$result" = "clean" ]

  # pre=done, exit 0, ref gone from snapshot → also clean.
  pre="$(snapshot_one f/01 done)"
  result="$(classify_gate_outcome "$pre" "$post" f/01 0)"
  [ "$result" = "clean" ]
}

@test "classify_gate_outcome — only the named ref is consulted" {
  pre='{"feature":"f","issues":[
    {"ref":"f/01","status":"in-review","category":"enhancement","type":"AFK","blocked_by":[],"eligible":false},
    {"ref":"f/02","status":"in-review","category":"enhancement","type":"AFK","blocked_by":[],"eligible":false}
  ]}'
  post='{"feature":"f","issues":[
    {"ref":"f/01","status":"in-review","category":"enhancement","type":"AFK","blocked_by":[],"eligible":false},
    {"ref":"f/02","status":"done","category":"enhancement","type":"AFK","blocked_by":[],"eligible":false}
  ]}'
  # f/01 stayed at in-review — blocked.
  [ "$(classify_gate_outcome "$pre" "$post" f/01 0)" = "blocked" ]
  # f/02 flipped to done — clean.
  [ "$(classify_gate_outcome "$pre" "$post" f/02 0)" = "clean" ]
}

@test "classify_gate_outcome — pre.status outside {in-review, done} is gate-failed" {
  # Guards against argument-order swaps: if the caller accidentally passes
  # pre at ready-for-agent (implement stage snapshot) the function should
  # refuse rather than silently misclassify.
  pre="$(snapshot_one f/01 ready-for-agent)"
  post="$(snapshot_one f/01 done)"
  result="$(classify_gate_outcome "$pre" "$post" f/01 0)"
  [ "$result" = "gate-failed" ]

  pre="$(snapshot_one f/01 wontfix)"
  result="$(classify_gate_outcome "$pre" "$post" f/01 0)"
  [ "$result" = "gate-failed" ]
}

@test "classify_gate_outcome — transport-crash=true + nonzero exit is review-aborted" {
  pre="$(snapshot_one f/01 in-review)"
  post="$(snapshot_one f/01 in-review)"
  result="$(classify_gate_outcome "$pre" "$post" f/01 1 true)"
  [ "$result" = "review-aborted" ]
}

@test "classify_gate_outcome — transport-crash=true does not override clean/blocked/pre-status guard" {
  # clean: exit 0 + post=done → still clean, transport-crash irrelevant.
  pre="$(snapshot_one f/01 in-review)"
  post="$(snapshot_one f/01 done)"
  [ "$(classify_gate_outcome "$pre" "$post" f/01 0 true)" = "clean" ]
  # blocked: exit 0 + post=in-review → still blocked.
  post="$(snapshot_one f/01 in-review)"
  [ "$(classify_gate_outcome "$pre" "$post" f/01 0 true)" = "blocked" ]
  # pre-status guard: pre=ready-for-agent → gate-failed (not review-aborted).
  pre="$(snapshot_one f/01 ready-for-agent)"
  post="$(snapshot_one f/01 done)"
  [ "$(classify_gate_outcome "$pre" "$post" f/01 1 true)" = "gate-failed" ]
}

@test "classify_outcome — transport-crash=true + failure is dispatch-aborted" {
  pre="$(snapshot_one f/01 ready-for-agent)"
  post="$(snapshot_one f/01 ready-for-agent)"
  result="$(classify_outcome "$pre" "$post" f/01 true)"
  [ "$result" = "dispatch-aborted" ]
}

@test "classify_outcome — transport-crash=true does not override success" {
  pre="$(snapshot_one f/01 ready-for-agent)"
  post="$(snapshot_one f/01 in-review)"
  result="$(classify_outcome "$pre" "$post" f/01 true)"
  [ "$result" = "success" ]
}

# === is_transport_crash =======================================================
#
# Pure predicate: returns exit 0 when a dispatch log carries a transport-class
# failure signature (empty/whitespace log, API 5xx/429 error, network errors).

@test "is_transport_crash — empty log is a crash" {
  HERE="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)"
  is_transport_crash "$HERE/fixtures/transport-crashes/empty.log"
}

@test "is_transport_crash — whitespace-only log is a crash" {
  HERE="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)"
  is_transport_crash "$HERE/fixtures/transport-crashes/whitespace-only.log"
}

@test "is_transport_crash — API 5xx log is a crash" {
  HERE="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)"
  is_transport_crash "$HERE/fixtures/transport-crashes/5xx.log"
}

@test "is_transport_crash — API 429 log is a crash" {
  HERE="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)"
  is_transport_crash "$HERE/fixtures/transport-crashes/429.log"
}

@test "is_transport_crash — fetch failed log is a crash" {
  HERE="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)"
  is_transport_crash "$HERE/fixtures/transport-crashes/fetch-failed.log"
}

@test "is_transport_crash — ECONNRESET log is a crash" {
  HERE="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)"
  is_transport_crash "$HERE/fixtures/transport-crashes/econnreset.log"
}

@test "is_transport_crash — ETIMEDOUT log is a crash" {
  HERE="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)"
  is_transport_crash "$HERE/fixtures/transport-crashes/etimedout.log"
}

@test "is_transport_crash — getaddrinfo log is a crash" {
  HERE="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)"
  is_transport_crash "$HERE/fixtures/transport-crashes/getaddrinfo.log"
}

@test "is_transport_crash — model-produced output without crash signature is not a crash" {
  local log_file="$BATS_TEST_TMPDIR/model-exit.log"
  printf 'claude: The brief is insufficient. Cannot implement without a clearer spec.\nexit status 0\n' >"$log_file"
  ! is_transport_crash "$log_file"
}

@test "is_transport_crash — intentional prompt-error exit is not a crash" {
  local log_file="$BATS_TEST_TMPDIR/prompt-error.log"
  printf 'Error: prompt file not found: /path/to/review-and-gate.md\nexit status 1\n' >"$log_file"
  ! is_transport_crash "$log_file"
}

# === with_transport_retry =====================================================
#
# Wraps a sandbox dispatch with bounded exponential backoff on transport-class
# failures. Sets TRANSPORT_RETRY_ATTEMPTS to the actual attempt count. All
# tests shim `sleep` to a no-op and use small backoff values
# (RUNNER_TRANSPORT_RETRY_BACKOFFS="1 2 3") so the suite runs in seconds.
# The schedule is verified by counting the number of `sleep 1` calls.

_setup_retry_test() {
  HOST_CHECKOUT="$BATS_TEST_TMPDIR/checkout"
  mkdir -p "$HOST_CHECKOUT"
  git -C "$HOST_CHECKOUT" init --quiet
  git -C "$HOST_CHECKOUT" -c user.email=t@t -c user.name=t \
    commit --allow-empty --quiet -m init
  RUNNER_INTERRUPTED=0
  RUNNER_TRANSPORT_RETRY_MAX_ATTEMPTS=3
  RUNNER_TRANSPORT_RETRY_BACKOFFS="1 2 3"
  RUNNER_DISABLE_TRANSPORT_RETRY=0
  TRANSPORT_RETRY_ATTEMPTS=0
  SLEEP_ARGS_FILE="$BATS_TEST_TMPDIR/sleep-args"
  : >"$SLEEP_ARGS_FILE"
  sleep() { echo "$@" >>"$SLEEP_ARGS_FILE"; }
}

@test "with_transport_retry — first-attempt success: no retry, no log archival, attempts=1" {
  _setup_retry_test
  local log_file="$BATS_TEST_TMPDIR/test.log"
  fake_dispatch() { : >"$1"; return 0; }

  with_transport_retry "$log_file" fake_dispatch
  [ "$TRANSPORT_RETRY_ATTEMPTS" -eq 1 ]
  [ ! -f "${log_file}.attempt-1" ]
  [ "$(wc -l <"$SLEEP_ARGS_FILE" | tr -d ' ')" -eq 0 ]
}

@test "with_transport_retry — transport crash then success: .attempt-1 archived, schedule honoured, attempts=2" {
  _setup_retry_test
  local log_file="$BATS_TEST_TMPDIR/test.log"
  local call_count=0
  fake_dispatch() {
    call_count=$(( call_count + 1 ))
    if [ "$call_count" -eq 1 ]; then
      printf 'API Error: 500 Internal server error.\n' >"$1"
      return 1
    fi
    printf 'success output\n' >"$1"
    return 0
  }

  set +e
  with_transport_retry "$log_file" fake_dispatch
  local rc=$?
  set -e

  [ "$rc" -eq 0 ]
  [ "$TRANSPORT_RETRY_ATTEMPTS" -eq 2 ]
  # attempt-1 archived, carries the transport-crash content
  [ -f "${log_file}.attempt-1" ]
  grep -q "500" "${log_file}.attempt-1"
  # No second archived log — final attempt succeeded
  [ ! -f "${log_file}.attempt-2" ]
  # Backoff for attempt 1 is RUNNER_TRANSPORT_RETRY_BACKOFFS[0]=1 → 1 sleep call
  [ "$(wc -l <"$SLEEP_ARGS_FILE" | tr -d ' ')" -eq 1 ]
  grep -qx "1" "$SLEEP_ARGS_FILE"
}

@test "with_transport_retry — three transport crashes: budget exhausted, two archived logs, final log at log_file, attempts=3" {
  _setup_retry_test
  local log_file="$BATS_TEST_TMPDIR/test.log"
  fake_dispatch() {
    printf 'API Error: 500 Internal server error.\n' >"$1"
    return 1
  }

  set +e
  with_transport_retry "$log_file" fake_dispatch
  local rc=$?
  set -e

  [ "$rc" -ne 0 ]
  [ "$TRANSPORT_RETRY_ATTEMPTS" -eq 3 ]
  # Attempts 1 and 2 archived; final attempt's log stays at $log_file
  [ -f "${log_file}.attempt-1" ]
  [ -f "${log_file}.attempt-2" ]
  [ ! -f "${log_file}.attempt-3" ]
  [ -f "$log_file" ]
  # Sleep calls: backoff[0]=1 (attempt 1) + backoff[1]=2 (attempt 2) = 3 total
  [ "$(wc -l <"$SLEEP_ARGS_FILE" | tr -d ' ')" -eq 3 ]
}

@test "with_transport_retry — non-transport failure: no retry, exit code passed through, no archival" {
  _setup_retry_test
  local log_file="$BATS_TEST_TMPDIR/test.log"
  fake_dispatch() {
    printf 'Error: brief is insufficient.\n' >"$1"
    return 42
  }

  set +e
  with_transport_retry "$log_file" fake_dispatch
  local rc=$?
  set -e

  [ "$rc" -eq 42 ]
  [ "$TRANSPORT_RETRY_ATTEMPTS" -eq 1 ]
  [ ! -f "${log_file}.attempt-1" ]
  [ "$(wc -l <"$SLEEP_ARGS_FILE" | tr -d ' ')" -eq 0 ]
}

@test "with_transport_retry — RUNNER_INTERRUPTED during backoff: returns without consuming another attempt" {
  _setup_retry_test
  # The sleep shim sets RUNNER_INTERRUPTED=1, simulating Ctrl-C mid-backoff.
  sleep() {
    echo "$@" >>"$SLEEP_ARGS_FILE"
    RUNNER_INTERRUPTED=1
  }
  local log_file="$BATS_TEST_TMPDIR/test.log"
  fake_dispatch() {
    printf 'API Error: 500 Internal server error.\n' >"$1"
    return 1
  }

  set +e
  with_transport_retry "$log_file" fake_dispatch
  local rc=$?
  set -e

  # Returned non-zero (the dispatch's exit code); interrupt not disguised as abort
  [ "$rc" -ne 0 ]
  # Only one attempt consumed — interrupt fired during the first backoff
  [ "$TRANSPORT_RETRY_ATTEMPTS" -eq 1 ]
  [ "$RUNNER_INTERRUPTED" -eq 1 ]
}

@test "with_transport_retry — new-commits guard: HEAD advances between attempts, wrapper refuses retry" {
  _setup_retry_test
  local log_file="$BATS_TEST_TMPDIR/test.log"
  # The dispatch function advances HOST_CHECKOUT's HEAD, simulating partial work.
  fake_dispatch() {
    printf 'API Error: 500 Internal server error.\n' >"$1"
    git -C "$HOST_CHECKOUT" -c user.email=t@t -c user.name=t \
      commit --allow-empty --quiet -m "partial work"
    return 1
  }

  set +e
  with_transport_retry "$log_file" fake_dispatch
  local rc=$?
  set -e

  [ "$rc" -ne 0 ]
  # Only one attempt — guard fired after noticing HEAD advanced
  [ "$TRANSPORT_RETRY_ATTEMPTS" -eq 1 ]
  # No sleep — guard fires before the backoff loop
  [ "$(wc -l <"$SLEEP_ARGS_FILE" | tr -d ' ')" -eq 0 ]
}

@test "with_transport_retry — RUNNER_DISABLE_TRANSPORT_RETRY=1: single attempt regardless of crash" {
  _setup_retry_test
  RUNNER_DISABLE_TRANSPORT_RETRY=1
  local log_file="$BATS_TEST_TMPDIR/test.log"
  fake_dispatch() {
    printf 'API Error: 500 Internal server error.\n' >"$1"
    return 1
  }

  set +e
  with_transport_retry "$log_file" fake_dispatch
  local rc=$?
  set -e

  [ "$rc" -ne 0 ]
  [ "$TRANSPORT_RETRY_ATTEMPTS" -eq 1 ]
  [ ! -f "${log_file}.attempt-1" ]
  [ "$(wc -l <"$SLEEP_ARGS_FILE" | tr -d ' ')" -eq 0 ]
}

@test "dispatch_one — retry-then-success: second attempt succeeds, .attempt-1 archived, no abort flag" {
  setup_dispatch_one_test
  # Shim sleep to no-op and use small backoffs so the test runs in milliseconds.
  sleep() { :; }
  RUNNER_TRANSPORT_RETRY_MAX_ATTEMPTS=3
  RUNNER_TRANSPORT_RETRY_BACKOFFS="0 0 0"

  # Restore the real with_transport_retry wiring in run_dispatch_container.
  # (setup_dispatch_one_test replaces it with a simple commit-and-return mock.)
  SANDBOX_CALL_COUNT_FILE="$BATS_TEST_TMPDIR/sandbox-calls"
  echo 0 >"$SANDBOX_CALL_COUNT_FILE"

  run_sandbox_container() {
    local lf="$1"
    local n
    n=$(( $(cat "$SANDBOX_CALL_COUNT_FILE") + 1 ))
    echo "$n" >"$SANDBOX_CALL_COUNT_FILE"
    if [ "$n" -eq 1 ]; then
      # First implement attempt: transport crash
      printf 'API Error: 500 Internal server error.\n' >"$lf"
      return 1
    fi
    # Second implement attempt: success — commit so impl_has_runner_commits=1
    git -C "$HOST_CHECKOUT" -c user.email=t@t -c user.name=t \
      commit --allow-empty --quiet -m "tracker: f/01 (test)"
    : >"$lf"
    return 0
  }

  run_dispatch_container() {
    local ref="$1" log_file="$2"
    with_transport_retry "$log_file" run_sandbox_container \
      claude -p "/implement $ref" --dangerously-skip-permissions
  }
  # keep setup_dispatch_one_test's run_gate_container (no-op returning 0)
  propagate_feature() { :; }

  RUNNER_INTERRUPTED=0
  set +e
  dispatch_one "f" "01" "$TEST_RUN_DIR"
  local dispatch_rc=$?
  set -e

  # Implement succeeded (issue flipped to in-review); gate ran (blocked — snapshot
  # didn't advance further, so classify_gate_outcome returns blocked / clean).
  [ "$dispatch_rc" -eq 0 ]

  # .attempt-1 was archived during the retry backoff
  [ -f "$TEST_RUN_DIR/01.log.attempt-1" ]

  # No abort flag written for a successful dispatch
  [ ! -f "$HOST_ABORT_DIR/f/01" ]

  # Verify the sandbox was called at least twice (crash attempt + success attempt)
  [ "$(cat "$SANDBOX_CALL_COUNT_FILE")" -ge 2 ]
}

# === check_gate_prompt =====================================================
#
# Pre-flight invariant: the gate prompt file must exist on disk before
# the loop starts. Fail-fast with `runner: gate-prompt: <path> not found`
# if absent. Without this guard, a missing prompt would only be noticed
# mid-run when the gate dispatch tries to read it — by which point time
# was already burned on /implement.

@test "check_gate_prompt — missing prompt fails with the gate-prompt invariant message" {
  # Point HERE at an empty tempdir so the prompt lookup misses.
  HERE="$BATS_TEST_TMPDIR/no-prompt"
  mkdir -p "$HERE"
  # Suppress the EXIT trap (it expects RUN_DIR plumbing we haven't set up).
  trap - EXIT

  run check_gate_prompt
  [ "$status" -eq 2 ]
  [[ "$output" == *"runner: gate-prompt:"* ]]
  [[ "$output" == *"$HERE/review-and-gate.md not found"* ]]
}

@test "check_gate_prompt — present prompt passes silently" {
  HERE="$BATS_TEST_TMPDIR/with-prompt"
  mkdir -p "$HERE"
  : >"$HERE/review-and-gate.md"
  trap - EXIT

  run check_gate_prompt
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

# === acquire_lock ==========================================================
#
# Atomic pidfile lock. `mkdir` semantics or noclobber guarantee only one
# concurrent winner. Stale lock (dead PID) is reclaimed on the next call.

@test "acquire_lock — succeeds when no lock exists" {
  HOST_LOCK="$BATS_TEST_TMPDIR/runner.lock"
  trap - EXIT
  acquire_lock
  [ "$LOCK_HELD" -eq 1 ]
  [ -f "$HOST_LOCK" ]
  [ "$(cat "$HOST_LOCK")" = "$$" ]
  release_lock
  [ ! -f "$HOST_LOCK" ]
}

@test "acquire_lock — refuses when another live runner holds the lock" {
  HOST_LOCK="$BATS_TEST_TMPDIR/runner.lock"
  # Write the current test PID as a live owner.
  echo "$$" >"$HOST_LOCK"
  trap - EXIT

  run acquire_lock
  [ "$status" -eq 2 ]
  [[ "$output" == *"runner: no-other-runner:"* ]]
}

@test "acquire_lock — reclaims a stale lock with a dead PID" {
  HOST_LOCK="$BATS_TEST_TMPDIR/runner.lock"
  # Spawn and kill a subshell to obtain a definitely-dead PID.
  local dead_pid
  (sleep 100) &
  dead_pid=$!
  kill "$dead_pid" 2>/dev/null
  wait "$dead_pid" 2>/dev/null || true
  echo "$dead_pid" >"$HOST_LOCK"
  trap - EXIT

  acquire_lock
  [ "$LOCK_HELD" -eq 1 ]
  [ "$(cat "$HOST_LOCK")" = "$$" ]
  release_lock
}

# === next_eligible_ref =====================================================
#
# Reads the snapshot's `eligible` field, returns the first ref where
# `eligible == true` in source order, or empty if none. Pass-through over
# tracker-snapshot's eligibility decision (which is golden-tested in
# tracker-snapshot.bats) — pinning the consumer here.

@test "next_eligible_ref — empty issues array returns empty" {
  result="$(next_eligible_ref '{"feature":"f","issues":[]}')"
  [ -z "$result" ]
}

@test "next_eligible_ref — all ineligible returns empty" {
  snap='{"feature":"f","issues":[
    {"ref":"f/01","status":"done","category":"enhancement","type":"AFK","blocked_by":[],"eligible":false},
    {"ref":"f/02","status":"ready-for-agent","category":"enhancement","type":"HITL","blocked_by":[],"eligible":false}
  ]}'
  result="$(next_eligible_ref "$snap")"
  [ -z "$result" ]
}

@test "next_eligible_ref — single eligible returns its ref" {
  snap='{"feature":"f","issues":[
    {"ref":"f/01","status":"ready-for-agent","category":"enhancement","type":"AFK","blocked_by":[],"eligible":true}
  ]}'
  result="$(next_eligible_ref "$snap")"
  [ "$result" = "f/01" ]
}

@test "next_eligible_ref — picks first eligible in source order" {
  snap='{"feature":"f","issues":[
    {"ref":"f/01","status":"done","category":"enhancement","type":"AFK","blocked_by":[],"eligible":false},
    {"ref":"f/02","status":"ready-for-agent","category":"enhancement","type":"AFK","blocked_by":[],"eligible":true},
    {"ref":"f/03","status":"ready-for-agent","category":"enhancement","type":"AFK","blocked_by":[],"eligible":true}
  ]}'
  result="$(next_eligible_ref "$snap")"
  [ "$result" = "f/02" ]
}

@test "next_eligible_ref — eligible after blocked entries (cross-feature) still picked" {
  # Cross-feature blocker forces eligible:false in tracker-snapshot. The
  # predicate consumes that flag — it should skip f/01 and pick f/02.
  snap='{"feature":"f","issues":[
    {"ref":"f/01","status":"ready-for-agent","category":"enhancement","type":"AFK","blocked_by":["other/01"],"eligible":false},
    {"ref":"f/02","status":"ready-for-agent","category":"enhancement","type":"AFK","blocked_by":[],"eligible":true}
  ]}'
  result="$(next_eligible_ref "$snap")"
  [ "$result" = "f/02" ]
}

# === run_loop — mechanics with mocked dispatch =============================
#
# The loop's external dependencies — take_snapshot, ensure_runner_checkout,
# dispatch_one — are stubbed in each test so we exercise the loop's
# scheduling and stop-condition logic without docker, claude, or real
# git. This is the cheapest way to pin "drain" / "interrupted" semantics;
# the live demo (real docker) is a separate AC.
#
# State that mocks mutate (queue, dispatched-list, outcomes) lives in
# files under $BATS_TEST_TMPDIR so it survives across the subshell that
# bats's `run` opens around its target.

setup_loop_test() {
  TEST_QUEUE_FILE="$BATS_TEST_TMPDIR/queue"
  TEST_DISPATCHED_FILE="$BATS_TEST_TMPDIR/dispatched"
  TEST_OUTCOMES_FILE="$BATS_TEST_TMPDIR/outcomes"
  : >"$TEST_QUEUE_FILE"
  : >"$TEST_DISPATCHED_FILE"
  : >"$TEST_OUTCOMES_FILE"

  take_snapshot() {
    local first
    first="$(head -n 1 "$TEST_QUEUE_FILE" 2>/dev/null || true)"
    if [ -z "$first" ]; then
      printf '{"feature":"f","issues":[]}'
      return 0
    fi
    printf '{"feature":"f","issues":[{"ref":"f/%s","nn":"%s","status":"ready-for-agent","category":"enhancement","type":"AFK","blocked_by":[],"eligible":true}]}' "$first" "$first"
  }

  ensure_runner_checkout() { :; }
  propagate_feature() { :; }

  dispatch_one() {
    local feature="$1" nn="$2"
    echo "$feature/$nn" >>"$TEST_DISPATCHED_FILE"
    # Pop the head of the queue.
    local rest
    rest="$(tail -n +2 "$TEST_QUEUE_FILE" 2>/dev/null || true)"
    printf '%s\n' "$rest" >"$TEST_QUEUE_FILE"
    # Strip the trailing blank if rest is empty.
    [ -s "$TEST_QUEUE_FILE" ] || : >"$TEST_QUEUE_FILE"
    # Take the first planned outcome (default: success). Return 0 for
    # success, 1 for anything else.
    local outcome
    outcome="$(head -n 1 "$TEST_OUTCOMES_FILE" 2>/dev/null || true)"
    if [ -n "$outcome" ]; then
      local rest_o
      rest_o="$(tail -n +2 "$TEST_OUTCOMES_FILE" 2>/dev/null || true)"
      printf '%s\n' "$rest_o" >"$TEST_OUTCOMES_FILE"
      [ -s "$TEST_OUTCOMES_FILE" ] || : >"$TEST_OUTCOMES_FILE"
    else
      outcome="success"
    fi
    [ "$outcome" = "success" ]
  }

  TARGET_FEATURE="f"
  DISCOVERY_JSON='["f"]'
  HOST_RUNS="$BATS_TEST_TMPDIR/runs"
  HOST_ABORT_DIR="$BATS_TEST_TMPDIR/aborted"
  RUNNER_INTERRUPTED=0
  # Provide a minimal HOST_REPO with HEAD on a branch other than the feature
  # so drain_one_feature's gate cascade picks drain.
  HOST_REPO="$BATS_TEST_TMPDIR/host-repo"
  if [ ! -d "$HOST_REPO" ]; then
    mkdir -p "$HOST_REPO"
    git -C "$HOST_REPO" init --quiet --initial-branch=main
    git -C "$HOST_REPO" -c user.email=t@t -c user.name=t \
      commit --allow-empty --quiet -m init
  fi
}

# Helpers for asserting dispatch state.
dispatched_count() { wc -l <"$TEST_DISPATCHED_FILE" | tr -d ' '; }
dispatched_nth()   { sed -n "${1}p" "$TEST_DISPATCHED_FILE"; }

plant_queue()      { printf '%s\n' "$@" >"$TEST_QUEUE_FILE"; }
plant_outcomes()   { printf '%s\n' "$@" >"$TEST_OUTCOMES_FILE"; }

@test "run_loop — drains a 2-issue queue then stops on empty" {
  setup_loop_test
  plant_queue 01 02

  run run_loop
  assert_success
  assert_output --partial "queue empty"

  [ "$(dispatched_nth 1)" = "f/01" ]
  [ "$(dispatched_nth 2)" = "f/02" ]
  [ "$(dispatched_count)" = "2" ]
}

@test "run_loop — empty queue from the start exits immediately" {
  setup_loop_test
  : >"$TEST_QUEUE_FILE"

  run run_loop
  assert_success
  assert_output --partial "queue empty"
  [ "$(dispatched_count)" = "0" ]
}

@test "run_loop — interrupt mid-dispatch prevents further iterations" {
  setup_loop_test
  plant_queue 01 02 03
  # Intercept dispatch_one to flip the interrupt flag during the first
  # call — simulates Ctrl-C arriving during the in-flight container.
  dispatch_one() {
    local feature="$1" nn="$2"
    echo "$feature/$nn" >>"$TEST_DISPATCHED_FILE"
    local rest
    rest="$(tail -n +2 "$TEST_QUEUE_FILE" 2>/dev/null || true)"
    printf '%s\n' "$rest" >"$TEST_QUEUE_FILE"
    [ -s "$TEST_QUEUE_FILE" ] || : >"$TEST_QUEUE_FILE"
    if [ "$(dispatched_count)" = "1" ]; then
      RUNNER_INTERRUPTED=1
    fi
    return 0
  }

  run run_loop
  assert_success
  assert_output --partial "interrupted during dispatch"

  # Only the first issue dispatched; the loop bailed before f/02.
  [ "$(dispatched_nth 1)" = "f/01" ]
  [ "$(dispatched_count)" = "1" ]
}

@test "run_loop — snapshot failure surfaces as snapshot-failed stop reason" {
  # Regression: take_snapshot failure (e.g. corrupt runner-checkout, jq
  # missing, tracker-snapshot crash) used to surface as `queue-empty`
  # because command-substitution-into-local-assignment under set -e
  # doesn't propagate the inner non-zero, leaving snap="" and the loop
  # treating an empty issues array as "no eligible refs". The fix wraps
  # the call in `if ! snap=…` and sets a distinct stop reason so SUMMARY.md
  # tells the operator what actually broke.
  setup_loop_test
  plant_queue 01

  take_snapshot() {
    echo "runner: simulated tracker-snapshot failure" >&2
    return 1
  }

  RUN_STOP_REASON=""
  set +e
  run_loop
  local rc=$?
  set -e

  [ "$rc" -ne 0 ]
  [ "$RUN_STOP_REASON" = "snapshot-failed" ]
  # No dispatch should have fired.
  [ "$(dispatched_count)" = "0" ]
}

@test "run_loop — interrupt at the top of an iteration bails before dispatch" {
  setup_loop_test
  plant_queue 01 02
  RUNNER_INTERRUPTED=1

  run run_loop
  assert_success
  assert_output --partial "interrupted; not starting next iteration"
  [ "$(dispatched_count)" = "0" ]
}

# === ensure_runner_checkout — dispatch hygiene ===========================
#
# Regression for an incident where a kernel core dump from a process that
# crashed inside the dispatch container (Linux default `core_pattern=core`,
# CWD-relative) landed as an untracked file in the runner-checkout. The
# sync was `git fetch + reset --hard origin/<branch>`, which scrubs
# tracked changes but leaves untracked files alone — the comment at
# run_loop:1175–1177 claiming "any stray uncommitted dirt … never leaks"
# was a lie for the untracked case. The implement stage's
# `git status --porcelain` diagnostic would then surface the stale file
# and misattribute prior dispatch leakage to *this* iteration's
# `/implement`. Cleaning untracked files at sync time makes the comment
# true and keeps the implement-stage diagnostic honest about *this*
# iteration's leakage.

# Build a HOST_REPO + HOST_CHECKOUT pair with one commit on the target
# branch. After this returns, ensure_runner_checkout's invariants (host
# repo exists, branch reachable) are satisfied.
setup_ensure_checkout_test() {
  HOST_REPO="$BATS_TEST_TMPDIR/host"
  HOST_CHECKOUT="$BATS_TEST_TMPDIR/checkout"
  TARGET_FEATURE="f"

  mkdir -p "$HOST_REPO"
  git -C "$HOST_REPO" init --quiet --initial-branch=f
  git -C "$HOST_REPO" -c user.email=t@t -c user.name=t \
    commit --allow-empty --quiet -m init

  # Pre-clone so ensure_runner_checkout exercises the sync path, not the
  # initial-clone path. The sync is where the regression lived.
  git clone --quiet "$HOST_REPO" "$HOST_CHECKOUT" >&2
  git -C "$HOST_CHECKOUT" checkout --quiet -B "$TARGET_FEATURE" "origin/$TARGET_FEATURE"
}

@test "ensure_runner_checkout — removes untracked files left from a previous dispatch" {
  setup_ensure_checkout_test

  # Simulate a stray artifact from a prior in-container crash (or any
  # process that wrote to a CWD-relative path without committing).
  mkdir -p "$HOST_CHECKOUT/framework/runner/tests"
  : >"$HOST_CHECKOUT/framework/runner/tests/core"
  [ -f "$HOST_CHECKOUT/framework/runner/tests/core" ]

  ensure_runner_checkout

  [ ! -f "$HOST_CHECKOUT/framework/runner/tests/core" ]
  [ -z "$(git -C "$HOST_CHECKOUT" status --porcelain)" ]
}

@test "ensure_runner_checkout — also removes untracked directories" {
  setup_ensure_checkout_test

  # `git clean -f` (without -d) skips untracked directories; the regression
  # would still leak through to the next iteration's implement-stage
  # diagnostic if a crash dropped a directory rather than a single file.
  # Pin -d behavior explicitly.
  mkdir -p "$HOST_CHECKOUT/stray-dir"
  : >"$HOST_CHECKOUT/stray-dir/leaf"

  ensure_runner_checkout

  [ ! -d "$HOST_CHECKOUT/stray-dir" ]
  [ -z "$(git -C "$HOST_CHECKOUT" status --porcelain)" ]
}

@test "ensure_runner_checkout — same-name tag does not shadow branch in sync-base selection" {
  # Regression: rev-parse --verify "<branch>" resolves tags before branches
  # (gitrevisions(7) precedence). A tag named the same as the feature branch
  # returns the tag's SHA instead of the branch tip, making parking_rel wrong
  # and picking the wrong sync base. Using refs/heads/<branch> pins the lookup
  # to the branch namespace.
  #
  # Scenario: host branch `f` is at C (latest), tag `f` is at A (initial),
  # parking ref is at B (behind C but ahead of A). Correct sync verdict is
  # "behind" (parking behind branch) → sync to host-branch (C). Wrong verdict
  # with old code: "ahead" (parking C ahead of tag A) → sync to parking-ref (B).
  HOST_REPO="$BATS_TEST_TMPDIR/tag-shadow-host"
  HOST_CHECKOUT="$BATS_TEST_TMPDIR/tag-shadow-checkout"
  TARGET_FEATURE="f"

  mkdir -p "$HOST_REPO"
  git -C "$HOST_REPO" init --quiet --initial-branch=f
  git -C "$HOST_REPO" -c user.email=t@t -c user.name=t \
    commit --allow-empty --quiet -m "A: init"
  sha_A="$(git -C "$HOST_REPO" rev-parse HEAD)"

  # Tag `f` at the initial commit.
  git -C "$HOST_REPO" tag f

  # Advance branch `f` to B, then C.
  git -C "$HOST_REPO" -c user.email=t@t -c user.name=t \
    commit --allow-empty --quiet -m "B: first advance"
  sha_B="$(git -C "$HOST_REPO" rev-parse HEAD)"
  git -C "$HOST_REPO" -c user.email=t@t -c user.name=t \
    commit --allow-empty --quiet -m "C: second advance"
  sha_C="$(git -C "$HOST_REPO" rev-parse HEAD)"

  # Parking ref at B (one behind branch tip C).
  git -C "$HOST_REPO" update-ref "refs/remotes/runner/f" "$sha_B"

  # Clone (no checkout yet; ensure_runner_checkout_on_branch handles sync).
  git clone --quiet "$HOST_REPO" "$HOST_CHECKOUT" >&2
  git -C "$HOST_CHECKOUT" checkout --quiet -B f origin/f

  ensure_runner_checkout

  # Sync verdict must be "host-branch" (parking B is behind branch C),
  # so the runner-checkout lands at C — the branch tip, not the parking SHA.
  checkout_head="$(git -C "$HOST_CHECKOUT" rev-parse HEAD)"
  [ "$checkout_head" = "$sha_C" ]
}

# === dispatch_one + run_loop — propagation error halts the loop ============
#
# Regression for a bug where a parking-ref publish failure inside
# dispatch_one returned 1 but left RUN_STOP_REASON unset, so run_loop
# continued to the next iteration. The next iteration's
# `ensure_runner_checkout` `git reset --hard origin/<branch>`d the
# un-published commit out of the runner-checkout, losing the work.
# The fix sets RUN_STOP_REASON="propagation-error" so run_loop breaks
# immediately and the runner-checkout's tip is preserved for recovery.

# Build the minimum scaffolding to drive real `dispatch_one` end-to-end
# without docker, claude, or the live tracker. We need:
#   - take_snapshot: returns a pre-snapshot at ready-for-agent and a
#     post-snapshot at in-review (so classify_outcome → success);
#   - run_dispatch_container: pretends `/implement` ran (no-op);
#   - propagate_feature: simulates a halt (returns 1);
#   - $HOST_CHECKOUT: a real, clean git dir so dispatch_one's
#     `git -C status --porcelain` diagnostic doesn't fail.
setup_dispatch_one_test() {
  TEST_RUN_DIR="$BATS_TEST_TMPDIR/run"
  mkdir -p "$TEST_RUN_DIR"

  HOST_CHECKOUT="$BATS_TEST_TMPDIR/checkout"
  mkdir -p "$HOST_CHECKOUT"
  git -C "$HOST_CHECKOUT" init --quiet
  git -C "$HOST_CHECKOUT" -c user.email=t@t -c user.name=t \
    commit --allow-empty --quiet -m init

  TEST_SNAPSHOT_PHASE="$BATS_TEST_TMPDIR/snapshot-phase"
  echo "pre" >"$TEST_SNAPSHOT_PHASE"
  # Default fixture: a 2-phase AFK snapshot covering pre-implement
  # (ready-for-agent + AFK) and post-implement (in-review + AFK). Tests
  # that drive the gate stage end-to-end use `install_afk_snapshots` to
  # add a third post-gate phase; halt-stage tests use this default and
  # halt propagation before the gate is reached.
  take_snapshot() {
    local phase
    phase="$(cat "$TEST_SNAPSHOT_PHASE")"
    if [ "$phase" = "pre" ]; then
      echo "post" >"$TEST_SNAPSHOT_PHASE"
      printf '{"feature":"f","issues":[{"ref":"f/01","nn":"01","status":"ready-for-agent","category":"enhancement","type":"AFK","blocked_by":[],"eligible":true}]}'
    else
      printf '{"feature":"f","issues":[{"ref":"f/01","nn":"01","status":"in-review","category":"enhancement","type":"AFK","blocked_by":[],"eligible":false}]}'
    fi
  }

  run_dispatch_container() {
    # Simulate a dispatched container that exited 0 and committed at
    # least one `tracker:` change to the runner-checkout — the typical
    # /implement output (status flip + summary comment, or comment-only
    # bail). Tests that need to simulate a container that died before
    # any commit override this with a no-commit variant.
    git -C "$HOST_CHECKOUT" -c user.email=t@t -c user.name=t \
      commit --allow-empty --quiet -m "tracker: f/01 (test)"
    return 0
  }

  # Default mock: no-op gate. AFK gate-stage tests override
  # run_gate_container to drive the desired gate verdict.
  run_gate_container() {
    return 0
  }

  TARGET_FEATURE="f"
  HOST_RUNS="$TEST_RUN_DIR"
  HOST_REPO="$BATS_TEST_TMPDIR"
  HOST_ABORT_DIR="$BATS_TEST_TMPDIR/aborted"
}

# Helper: install a 3-phase snapshot mock for AFK gate tests. Phases:
#   pre           → ready-for-agent + AFK
#   post-implement → in-review + AFK
#   post-gate      → $1 (the post-gate status — done|in-review|wontfix|…)
install_afk_snapshots() {
  local post_gate_status="$1"
  echo "pre" >"$TEST_SNAPSHOT_PHASE"
  TEST_POST_GATE_STATUS="$post_gate_status"
  take_snapshot() {
    local phase
    phase="$(cat "$TEST_SNAPSHOT_PHASE")"
    case "$phase" in
      pre)
        echo "post-implement" >"$TEST_SNAPSHOT_PHASE"
        printf '{"feature":"f","issues":[{"ref":"f/01","nn":"01","status":"ready-for-agent","category":"enhancement","type":"AFK","blocked_by":[],"eligible":true}]}'
        ;;
      post-implement)
        echo "post-gate" >"$TEST_SNAPSHOT_PHASE"
        printf '{"feature":"f","issues":[{"ref":"f/01","nn":"01","status":"in-review","category":"enhancement","type":"AFK","blocked_by":[],"eligible":false}]}'
        ;;
      post-gate)
        printf '{"feature":"f","issues":[{"ref":"f/01","nn":"01","status":"%s","category":"enhancement","type":"AFK","blocked_by":[],"eligible":false}]}' \
          "$TEST_POST_GATE_STATUS"
        ;;
    esac
  }
}

@test "dispatch_one — propagation error sets RUN_STOP_REASON=propagation-error even when classifier says success" {
  setup_dispatch_one_test

  # Classifier verdict will be "success" (snapshots flip
  # ready-for-agent → in-review), but propagation errors (parking-ref fail).
  propagate_feature() {
    echo "runner: simulated propagation error" >&2
    return 1
  }

  RUN_STOP_REASON=""
  set +e
  dispatch_one "f" "01" "$TEST_RUN_DIR"
  local rc=$?
  set -e

  [ "$rc" -ne 0 ]
  [ "$RUN_STOP_REASON" = "propagation-error" ]
}

@test "dispatch_one — implement-stage propagation error emits a halt → FAIL follow-up line" {
  # Regression: the implement-stage outcome line was emitted before the
  # propagation decision, so on error the operator's terminal showed
  # `implement → in-review` while SUMMARY.md recorded `FAIL`. The fix
  # keeps the original outcome line (so the forensic story `implement
  # landed; propagation error` survives in runner.log) and emits a
  # follow-up `halt → FAIL` line so the visible record matches the
  # SUMMARY.md row.
  setup_dispatch_one_test
  propagate_feature() { return 1; }

  run dispatch_one "f" "01" "$TEST_RUN_DIR"

  [ "$status" -ne 0 ]
  # Original outcome line preserved — implement step itself succeeded.
  assert_output --partial "implement → in-review"
  # Follow-up halt line emitted after the propagation decision.
  assert_output --partial "implement → halt → FAIL"
}

@test "dispatch_one — gate-stage propagation error emits a halt → gate-failed follow-up line" {
  # Same regression at the gate stage. Gate-clean post-implement, then
  # the post-gate propagation errors. Original `review → clean → done`
  # line stays for forensics; follow-up `review → halt → gate-failed`
  # line matches the SUMMARY.md row.
  setup_dispatch_one_test
  install_afk_snapshots done

  local prop_count_file="$BATS_TEST_TMPDIR/prop-count"
  echo 0 >"$prop_count_file"
  propagate_feature() {
    local n
    n="$(cat "$prop_count_file")"
    echo $((n + 1)) >"$prop_count_file"
    # Post-implement propagation succeeds; post-gate halts.
    [ "$n" -eq 0 ]
  }
  # local-markdown-shaped gate commit so the HEAD delta triggers
  # gate-stage propagation (the path under test).
  run_gate_container() {
    git -C "$HOST_CHECKOUT" -c user.email=t@t -c user.name=t \
      commit --allow-empty --quiet -m "tracker: review f/01 → done"
    return 0
  }

  run dispatch_one "f" "01" "$TEST_RUN_DIR"

  [ "$status" -ne 0 ]
  assert_output --partial "review → clean → done"
  assert_output --partial "review → halt → gate-failed"
}

@test "dispatch_one — propagation error sets RUN_STOP_REASON=propagation-error and preserves runner-checkout HEAD" {
  # AC: On propagate_feature returning error from the implement stage,
  # dispatch_one sets RUN_STOP_REASON="propagation-error", records FAIL,
  # and returns 1; the runner-checkout's branch tip equals the
  # post-/implement SHA at run exit.
  setup_dispatch_one_test

  local pre_sha post_sha
  pre_sha="$(git -C "$HOST_CHECKOUT" rev-parse HEAD)"

  # run_dispatch_container commits one tracker: commit (as setup_dispatch_one_test
  # arranges), advancing the runner-checkout's HEAD past pre_sha.
  propagate_feature() { return 1; }

  RUN_STOP_REASON=""
  set +e
  dispatch_one "f" "01" "$TEST_RUN_DIR"
  local rc=$?
  set -e

  post_sha="$(git -C "$HOST_CHECKOUT" rev-parse HEAD)"

  [ "$rc" -ne 0 ]
  [ "$RUN_STOP_REASON" = "propagation-error" ]
  # The runner-checkout advanced beyond pre_sha (the tracker: commit landed).
  [ "$post_sha" != "$pre_sha" ]
}

@test "dispatch_one — gate-stage propagation error sets RUN_STOP_REASON=propagation-error" {
  # AC: Same on the gate stage: propagate_feature error from gate-stage
  # propagation sets RUN_STOP_REASON="propagation-error", records gate-failed,
  # returns 1.
  setup_dispatch_one_test
  install_afk_snapshots done

  local prop_count_file="$BATS_TEST_TMPDIR/prop-count2"
  echo 0 >"$prop_count_file"
  propagate_feature() {
    local n
    n="$(cat "$prop_count_file")"
    echo $((n + 1)) >"$prop_count_file"
    # Post-implement propagation succeeds; post-gate halts.
    [ "$n" -eq 0 ]
  }
  # local-markdown-shaped gate commit so the HEAD delta triggers
  # gate-stage propagation (the path under test).
  run_gate_container() {
    git -C "$HOST_CHECKOUT" -c user.email=t@t -c user.name=t \
      commit --allow-empty --quiet -m "tracker: review f/01 → done"
    return 0
  }

  RUN_STOP_REASON=""
  set +e
  dispatch_one "f" "01" "$TEST_RUN_DIR"
  local rc=$?
  set -e

  [ "$rc" -ne 0 ]
  [ "$RUN_STOP_REASON" = "propagation-error" ]
}

@test "run_loop — propagation error halts the loop and preserves runner-checkout HEAD" {
  # AC: run_loop breaks on RUN_STOP_REASON="propagation-error" after
  # dispatch_one returns; the loop does not enter another iteration's
  # ensure_runner_checkout (which would wipe the un-published commits).
  setup_loop_test
  plant_queue 01 02

  local post_impl_sha_file="$BATS_TEST_TMPDIR/post-impl-sha"

  # Override dispatch_one to simulate a propagation error on the first issue.
  # Records the HEAD the runner-checkout was at when dispatch_one exited, to
  # verify the loop didn't reset it on the next iteration.
  dispatch_one() {
    local feature="$1" nn="$2"
    echo "$feature/$nn" >>"$TEST_DISPATCHED_FILE"
    # Pop the queue so the snapshot mock would see 02 as next eligible.
    local rest
    rest="$(tail -n +2 "$TEST_QUEUE_FILE" 2>/dev/null || true)"
    printf '%s\n' "$rest" >"$TEST_QUEUE_FILE"
    [ -s "$TEST_QUEUE_FILE" ] || : >"$TEST_QUEUE_FILE"
    # Simulate propagation error: set the stop reason and return 1.
    RUN_STOP_REASON="propagation-error"
    git -C "$HOST_CHECKOUT" rev-parse HEAD >"$post_impl_sha_file"
    return 1
  }
  # Intercept ensure_runner_checkout — if called, it would reset HEAD.
  local checkout_call_file="$BATS_TEST_TMPDIR/checkout-called"
  : >"$checkout_call_file"
  ensure_runner_checkout() {
    echo "called" >>"$checkout_call_file"
  }

  RUN_STOP_REASON=""
  set +e
  run_loop
  local rc=$?
  set -e

  # Loop must have exited with the propagation-error stop.
  [ "$rc" -ne 0 ]
  [ "$RUN_STOP_REASON" = "propagation-error" ]
  # Only the first issue was dispatched; f/02 was not reached.
  [ "$(dispatched_count)" = "1" ]
  [ "$(dispatched_nth 1)" = "f/01" ]
  # ensure_runner_checkout was not called again after the propagation error,
  # so the runner-checkout's HEAD is the value recorded by dispatch_one.
  # The first call (before f/01 was dispatched) fired exactly once; the
  # second iteration that would have reset to origin never ran.
  [ "$(cat "$checkout_call_file" | wc -l | tr -d ' ')" = "1" ]
}

@test "run_drain — propagation-error from first feature halts drain; second feature not considered" {
  # AC: In drain mode, propagation-error raised inside any feature's
  # run_loop halts the outer run_drain: no subsequent feature is
  # considered, and SUMMARY's stop-reason line is propagation-error.
  setup_drain_test
  DISCOVERY_JSON='["alpha","beta"]'
  git -C "$HOST_REPO" branch alpha
  git -C "$HOST_REPO" branch beta

  # Override run_loop to simulate a propagation error for alpha.
  run_loop() {
    echo "$TARGET_FEATURE" >>"$DRAIN_DRAINED_FILE"
    if [ "$TARGET_FEATURE" = "alpha" ]; then
      RUN_STOP_REASON="propagation-error"
      return 1
    fi
    RUN_STOP_REASON="queue-empty"
    return 0
  }

  RUN_STOP_REASON=""
  local rc=0
  run_drain || rc=$?

  [ "$rc" -ne 0 ]
  [ "$RUN_STOP_REASON" = "propagation-error" ]
  # alpha was processed; beta was not considered.
  [ "$(drained_features_count)" = "1" ]
  # No feature outcome row for alpha (the iteration's FAIL row tells the story).
  [ "$(drain_outcomes_count)" = "0" ]
}

# === collect_binding_env — sandbox-env hook ================================
#
# Verifies the binding-agnostic hook that invokes a role-surface sandbox-env
# script and validates its output before passing env vars to the container.

@test "collect_binding_env — no script on role surface returns empty (no-op)" {
  result="$(collect_binding_env "$BATS_TEST_TMPDIR/nonexistent/sandbox-env")"
  [ -z "$result" ]
}

@test "collect_binding_env — non-executable script treated as absent (no-op)" {
  local script="$BATS_TEST_TMPDIR/sandbox-env"
  printf '#!/usr/bin/env bash\necho GH_TOKEN=tok\n' >"$script"
  # Do NOT chmod +x — should be treated as absent.
  result="$(collect_binding_env "$script")"
  [ -z "$result" ]
}

@test "collect_binding_env — valid KEY=value lines are passed through" {
  local script="$BATS_TEST_TMPDIR/sandbox-env"
  cat >"$script" <<'EOF'
#!/usr/bin/env bash
echo "GH_TOKEN=ghp_test_token"
echo "ANOTHER_VAR=value"
EOF
  chmod +x "$script"

  result="$(collect_binding_env "$script")"
  [ "$result" = "$(printf 'GH_TOKEN=ghp_test_token\nANOTHER_VAR=value')" ]
}

@test "collect_binding_env — empty lines in script output are silently skipped" {
  local script="$BATS_TEST_TMPDIR/sandbox-env"
  cat >"$script" <<'EOF'
#!/usr/bin/env bash
echo ""
echo "GH_TOKEN=tok"
echo ""
EOF
  chmod +x "$script"

  result="$(collect_binding_env "$script")"
  [ "$result" = "GH_TOKEN=tok" ]
}

@test "collect_binding_env — malformed line (no =) causes failure with error" {
  local script="$BATS_TEST_TMPDIR/sandbox-env"
  cat >"$script" <<'EOF'
#!/usr/bin/env bash
echo "NOT_A_VALID_LINE_WITHOUT_EQUALS"
EOF
  chmod +x "$script"

  run collect_binding_env "$script"
  [ "$status" -ne 0 ]
  [[ "$output" == *"malformed line"* ]]
}

@test "collect_binding_env — lowercase key causes failure (uppercase required)" {
  local script="$BATS_TEST_TMPDIR/sandbox-env"
  cat >"$script" <<'EOF'
#!/usr/bin/env bash
echo "gh_token=value"
EOF
  chmod +x "$script"

  run collect_binding_env "$script"
  [ "$status" -ne 0 ]
  [[ "$output" == *"malformed line"* ]]
}

@test "collect_binding_env — script exits non-zero causes failure" {
  local script="$BATS_TEST_TMPDIR/sandbox-env"
  cat >"$script" <<'EOF'
#!/usr/bin/env bash
echo "sandbox-env: Keychain entry not found" >&2
exit 1
EOF
  chmod +x "$script"

  run collect_binding_env "$script"
  [ "$status" -ne 0 ]
  [[ "$output" == *"sandbox-env exited non-zero"* ]]
}

@test "collect_binding_env — malformed line with uppercase key (mixed case) does not leak value" {
  # Regression: the error message used to echo the full $line, which would
  # expose the post-= value (e.g. a token) in stderr/runner.log. The fix
  # drops the line content from the message entirely.
  local script="$BATS_TEST_TMPDIR/sandbox-env"
  cat >"$script" <<'EOF'
#!/usr/bin/env bash
echo "gH_TOKEN=ghp_secret-payload"
EOF
  chmod +x "$script"

  run collect_binding_env "$script"
  [ "$status" -ne 0 ]
  [[ "$output" == *"malformed line"* ]]
  # The secret payload must not appear anywhere in the error output.
  [[ "$output" != *"secret-payload"* ]]
  [[ "$output" != *"ghp_"* ]]
}

@test "collect_binding_env — malformed line with no '=' does not leak the bare value" {
  # Regression: ${line%%=*} returns the entire string when '=' is absent,
  # so a sandbox-env script that emitted a bare token (no KEY= prefix)
  # would leak the whole token to stderr/runner.log. The fix drops the
  # line content from the message entirely.
  local script="$BATS_TEST_TMPDIR/sandbox-env"
  cat >"$script" <<'EOF'
#!/usr/bin/env bash
echo "ghp_bare_secret_no_equals"
EOF
  chmod +x "$script"

  run collect_binding_env "$script"
  [ "$status" -ne 0 ]
  [[ "$output" == *"malformed line"* ]]
  # The bare value must not appear anywhere in the error output.
  [[ "$output" != *"bare_secret"* ]]
  [[ "$output" != *"ghp_"* ]]
}

@test "collect_binding_env — fixture script picks up env vars that reach docker" {
  # Integration proxy: verifies that a fixture sandbox-env script on the role
  # surface produces valid output that the runner would pass to docker via
  # --env-file. Does not invoke docker; validates that the hook's output
  # satisfies the KEY=value contract.
  local role_surface="$BATS_TEST_TMPDIR/role-surface"
  mkdir -p "$role_surface"
  cat >"$role_surface/sandbox-env" <<'EOF'
#!/usr/bin/env bash
echo "GH_TOKEN=fixture_token_123"
EOF
  chmod +x "$role_surface/sandbox-env"

  result="$(collect_binding_env "$role_surface/sandbox-env")"
  [ "$result" = "GH_TOKEN=fixture_token_123" ]
  # Key matches the KEY=value format that docker --env-file accepts.
  validate_binding_env_output "$result"
}

# === dispatch_one — snapshot failure mid-dispatch =========================
#
# Regression: the three take_snapshot calls inside dispatch_one were bare
# assignments (`var="$(cmd)"`) where the `local` was on a separate earlier
# line, so set -e propagated the inner non-zero and silently exited the
# script. The EXIT trap then fired with RUN_STOP_REASON unset, and
# finalize_run wrote `stop reason: unknown` to SUMMARY.md. The in-flight
# iteration's record_dispatch was never reached, leaving a missing row.
# The fix guards each callsite with `if !`, records the iteration with a
# FAIL outcome, sets a named stop reason, and returns 1 cleanly.

@test "dispatch_one — pre-implement snapshot failure sets named stop reason and records iteration" {
  setup_dispatch_one_test
  RUN_DISPATCHES=()
  RUN_STOP_REASON=""

  take_snapshot() {
    echo "runner: simulated tracker-snapshot failure" >&2
    return 1
  }

  set +e
  dispatch_one "f" "01" "$TEST_RUN_DIR" 2>/dev/null
  local rc=$?
  set -e

  [ "$rc" -eq 1 ]
  [ "$RUN_STOP_REASON" = "snapshot-failed-mid-dispatch:pre" ]
  [ "${#RUN_DISPATCHES[@]}" -eq 1 ]
  # Pre-snapshot failure → no snapshot to resolve the binding-native ref
  # against, so `(unresolved)` is the recorded placeholder.
  [[ "${RUN_DISPATCHES[0]}" == "f|01|(unresolved)|FAIL|"* ]]
}

@test "dispatch_one — post-implement snapshot failure sets named stop reason and records iteration" {
  setup_dispatch_one_test
  RUN_DISPATCHES=()
  RUN_STOP_REASON=""

  SNAP_CALL_FILE="$BATS_TEST_TMPDIR/snap-calls"
  echo 0 >"$SNAP_CALL_FILE"
  take_snapshot() {
    local n
    n="$(cat "$SNAP_CALL_FILE")"
    echo $((n + 1)) >"$SNAP_CALL_FILE"
    if [ "$n" -eq 0 ]; then
      printf '{"feature":"f","issues":[{"ref":"f/01","nn":"01","status":"ready-for-agent","category":"enhancement","type":"AFK","blocked_by":[],"eligible":true}]}'
      return 0
    fi
    echo "runner: simulated tracker-snapshot failure" >&2
    return 1
  }

  # The default run_dispatch_container commits, so dispatch_one parks the
  # work to the parking ref before bailing. Mock propagate_feature to
  # return success — the snapshot-failure stop reason still wins.
  propagate_feature() {
    RUNNER_LAST_PROPAGATION="propagated → host"
    return 0
  }

  set +e
  dispatch_one "f" "01" "$TEST_RUN_DIR" 2>/dev/null
  local rc=$?
  set -e

  [ "$rc" -eq 1 ]
  [ "$RUN_STOP_REASON" = "snapshot-failed-mid-dispatch:post-implement" ]
  [ "${#RUN_DISPATCHES[@]}" -eq 1 ]
  [[ "${RUN_DISPATCHES[0]}" == "f|01|f/01|FAIL|"* ]]
  # The record's trailing propagation column is filled from the mock's
  # RUNNER_LAST_PROPAGATION value — the FAIL row reflects that the
  # commit reached the parking ref.
  [[ "${RUN_DISPATCHES[0]}" == *"|propagated → host" ]]
}

@test "dispatch_one — post-gate snapshot failure sets named stop reason and records iteration" {
  setup_dispatch_one_test
  RUN_DISPATCHES=()
  RUN_STOP_REASON=""
  RUNNER_INTERRUPTED=0

  SNAP_CALL_FILE="$BATS_TEST_TMPDIR/snap-calls"
  echo 0 >"$SNAP_CALL_FILE"
  take_snapshot() {
    local n
    n="$(cat "$SNAP_CALL_FILE")"
    echo $((n + 1)) >"$SNAP_CALL_FILE"
    case "$n" in
      0)
        printf '{"feature":"f","issues":[{"ref":"f/01","nn":"01","status":"ready-for-agent","category":"enhancement","type":"AFK","blocked_by":[],"eligible":true}]}'
        return 0
        ;;
      1)
        printf '{"feature":"f","issues":[{"ref":"f/01","nn":"01","status":"in-review","category":"enhancement","type":"AFK","blocked_by":[],"eligible":false}]}'
        return 0
        ;;
      *)
        echo "runner: simulated tracker-snapshot failure" >&2
        return 1
        ;;
    esac
  }

  # Stub classify_outcome so the implement stage is classified as success
  # without requiring jq. The post_status jq call (for impl_label) will
  # produce an empty result, leaving impl_label=FAIL — acceptable here
  # since this test is verifying the post-gate snapshot guard, not the label.
  classify_outcome() { echo "success"; }

  propagate_feature() { return 0; }
  run_gate_container() { return 0; }

  set +e
  dispatch_one "f" "01" "$TEST_RUN_DIR" 2>/dev/null
  local rc=$?
  set -e

  [ "$rc" -eq 1 ]
  [ "$RUN_STOP_REASON" = "snapshot-failed-mid-dispatch:post-gate" ]
  [ "${#RUN_DISPATCHES[@]}" -eq 1 ]
  [[ "${RUN_DISPATCHES[0]}" == "f|01|f/01|FAIL|"* ]]
}

# === dispatch_one — failure-path propagation ==============================
#
# Regression: dispatch_one had three early-return paths between the
# implement commit and propagate_feature that bypassed propagation:
#   1. post-implement snapshot failure
#   2. post-gate snapshot failure
#   3. gate-failed / review-aborted verdict
# When the dispatched container committed work to the runner-checkout,
# these paths returned FAIL without ever calling propagate_feature — and
# the next dispatch's lazy-init reset the runner-checkout to host's tip,
# silently wiping the commit. The fix replicates the success-path
# `if [ "$_has_runner_commits" -eq 1 ]; then propagate_feature ...; fi`
# guard on each failure-exit path.

@test "dispatch_one — post-implement snapshot failure with commits propagates before bailing" {
  # AC: When the dispatched container committed and the post-implement
  # snapshot fails, propagate_feature runs before FAIL is returned.
  setup_dispatch_one_test
  RUN_DISPATCHES=()
  RUN_STOP_REASON=""

  SNAP_CALL_FILE="$BATS_TEST_TMPDIR/snap-calls"
  echo 0 >"$SNAP_CALL_FILE"
  take_snapshot() {
    local n
    n="$(cat "$SNAP_CALL_FILE")"
    echo $((n + 1)) >"$SNAP_CALL_FILE"
    if [ "$n" -eq 0 ]; then
      printf '{"feature":"f","issues":[{"ref":"f/01","nn":"01","status":"ready-for-agent","category":"enhancement","type":"AFK","blocked_by":[],"eligible":true}]}'
      return 0
    fi
    return 1
  }

  # Capture each propagate_feature call and the runner-checkout HEAD at
  # call time, so we can prove the commit was still reachable when
  # propagation ran.
  TEST_PROPAGATE_CALLS="$BATS_TEST_TMPDIR/prop-calls"
  TEST_PROPAGATE_HEAD="$BATS_TEST_TMPDIR/prop-head"
  : >"$TEST_PROPAGATE_CALLS"
  propagate_feature() {
    echo "$1" >>"$TEST_PROPAGATE_CALLS"
    git -C "$HOST_CHECKOUT" rev-parse HEAD >"$TEST_PROPAGATE_HEAD"
    RUNNER_LAST_PROPAGATION="propagated → host"
    return 0
  }

  local pre_sha
  pre_sha="$(git -C "$HOST_CHECKOUT" rev-parse HEAD)"

  set +e
  dispatch_one "f" "01" "$TEST_RUN_DIR" 2>/dev/null
  local rc=$?
  set -e

  [ "$rc" -eq 1 ]
  [ "$RUN_STOP_REASON" = "snapshot-failed-mid-dispatch:post-implement" ]
  # Propagation was called exactly once, with the feature name as $1.
  [ "$(wc -l <"$TEST_PROPAGATE_CALLS" | tr -d ' ')" = "1" ]
  [ "$(cat "$TEST_PROPAGATE_CALLS")" = "f" ]
  # The runner-checkout HEAD at propagation time was the post-dispatch
  # tip — i.e. the commit was reachable, not wiped.
  local prop_head post_sha
  prop_head="$(cat "$TEST_PROPAGATE_HEAD")"
  post_sha="$(git -C "$HOST_CHECKOUT" rev-parse HEAD)"
  [ "$prop_head" = "$post_sha" ]
  [ "$prop_head" != "$pre_sha" ]
}

@test "dispatch_one — post-implement snapshot failure with commits sets propagation-error when propagation fails" {
  # AC: When propagation itself fails on the failure-exit path, the
  # existing parking-ref-publish-failure handling fires
  # (RUN_STOP_REASON="propagation-error"), matching the success-path
  # behavior. The propagation error takes precedence over the
  # snapshot-failure stop reason because work-loss is the more critical
  # signal.
  setup_dispatch_one_test
  RUN_DISPATCHES=()
  RUN_STOP_REASON=""

  SNAP_CALL_FILE="$BATS_TEST_TMPDIR/snap-calls"
  echo 0 >"$SNAP_CALL_FILE"
  take_snapshot() {
    local n
    n="$(cat "$SNAP_CALL_FILE")"
    echo $((n + 1)) >"$SNAP_CALL_FILE"
    if [ "$n" -eq 0 ]; then
      printf '{"feature":"f","issues":[{"ref":"f/01","nn":"01","status":"ready-for-agent","category":"enhancement","type":"AFK","blocked_by":[],"eligible":true}]}'
      return 0
    fi
    return 1
  }

  propagate_feature() {
    echo "runner: simulated propagation error" >&2
    RUNNER_LAST_PROPAGATION=""
    return 1
  }

  set +e
  dispatch_one "f" "01" "$TEST_RUN_DIR" 2>/dev/null
  local rc=$?
  set -e

  [ "$rc" -eq 1 ]
  [ "$RUN_STOP_REASON" = "propagation-error" ]
  [ "${#RUN_DISPATCHES[@]}" -eq 1 ]
}

@test "dispatch_one — post-implement snapshot failure without commits skips propagation" {
  # AC (no regression): when the dispatched container did not commit,
  # the failure path still returns FAIL without calling propagate_feature.
  setup_dispatch_one_test
  RUN_DISPATCHES=()
  RUN_STOP_REASON=""

  # Override the default committing container with a no-commit one.
  run_dispatch_container() {
    return 0
  }

  SNAP_CALL_FILE="$BATS_TEST_TMPDIR/snap-calls"
  echo 0 >"$SNAP_CALL_FILE"
  take_snapshot() {
    local n
    n="$(cat "$SNAP_CALL_FILE")"
    echo $((n + 1)) >"$SNAP_CALL_FILE"
    if [ "$n" -eq 0 ]; then
      printf '{"feature":"f","issues":[{"ref":"f/01","nn":"01","status":"ready-for-agent","category":"enhancement","type":"AFK","blocked_by":[],"eligible":true}]}'
      return 0
    fi
    return 1
  }

  TEST_PROPAGATE_CALLS="$BATS_TEST_TMPDIR/prop-calls"
  : >"$TEST_PROPAGATE_CALLS"
  propagate_feature() {
    echo "called" >>"$TEST_PROPAGATE_CALLS"
    return 0
  }

  set +e
  dispatch_one "f" "01" "$TEST_RUN_DIR" 2>/dev/null
  local rc=$?
  set -e

  [ "$rc" -eq 1 ]
  [ "$RUN_STOP_REASON" = "snapshot-failed-mid-dispatch:post-implement" ]
  # Propagation was NOT called — there were no commits to publish.
  [ ! -s "$TEST_PROPAGATE_CALLS" ]
}

@test "dispatch_one — post-gate snapshot failure with gate commits propagates before bailing" {
  # AC: When the gate container committed and the post-gate snapshot
  # fails, propagate_feature runs (twice: once on the success-path
  # post-implement step, once on the post-gate failure step) before
  # FAIL is returned.
  setup_dispatch_one_test
  install_afk_snapshots done
  RUN_DISPATCHES=()
  RUN_STOP_REASON=""
  RUNNER_INTERRUPTED=0

  # Override the snapshot mock to fail on the post-gate (3rd) call only.
  SNAP_CALL_FILE="$BATS_TEST_TMPDIR/snap-calls"
  echo 0 >"$SNAP_CALL_FILE"
  take_snapshot() {
    local n
    n="$(cat "$SNAP_CALL_FILE")"
    echo $((n + 1)) >"$SNAP_CALL_FILE"
    case "$n" in
      0)
        printf '{"feature":"f","issues":[{"ref":"f/01","nn":"01","status":"ready-for-agent","category":"enhancement","type":"AFK","blocked_by":[],"eligible":true}]}'
        ;;
      1)
        printf '{"feature":"f","issues":[{"ref":"f/01","nn":"01","status":"in-review","category":"enhancement","type":"AFK","blocked_by":[],"eligible":false}]}'
        ;;
      *)
        return 1
        ;;
    esac
  }
  classify_outcome() { echo "success"; }

  TEST_PROPAGATE_CALLS="$BATS_TEST_TMPDIR/prop-calls"
  TEST_PROPAGATE_HEAD="$BATS_TEST_TMPDIR/prop-head"
  : >"$TEST_PROPAGATE_CALLS"
  propagate_feature() {
    echo "$1" >>"$TEST_PROPAGATE_CALLS"
    git -C "$HOST_CHECKOUT" rev-parse HEAD >"$TEST_PROPAGATE_HEAD"
    RUNNER_LAST_PROPAGATION="propagated → host"
    return 0
  }

  # local-markdown-shaped gate: commits a `tracker:` row, so the post-gate
  # HEAD delta is non-empty and gate-stage propagation must fire even
  # though the snapshot fails right after.
  run_gate_container() {
    git -C "$HOST_CHECKOUT" -c user.email=t@t -c user.name=t \
      commit --allow-empty --quiet -m "tracker: review f/01 → done"
    return 0
  }

  set +e
  dispatch_one "f" "01" "$TEST_RUN_DIR" 2>/dev/null
  local rc=$?
  set -e

  [ "$rc" -eq 1 ]
  [ "$RUN_STOP_REASON" = "snapshot-failed-mid-dispatch:post-gate" ]
  # Propagation was called twice (post-implement + post-gate-fail).
  [ "$(wc -l <"$TEST_PROPAGATE_CALLS" | tr -d ' ')" = "2" ]
  # The last propagation captured the post-gate tip — the gate commit is
  # reachable from the parking ref.
  local prop_head post_sha
  prop_head="$(cat "$TEST_PROPAGATE_HEAD")"
  post_sha="$(git -C "$HOST_CHECKOUT" rev-parse HEAD)"
  [ "$prop_head" = "$post_sha" ]
  # The FAIL row records the propagation indicator, not `-`.
  [[ "${RUN_DISPATCHES[0]}" == *"|propagated → host" ]]
}

@test "dispatch_one — gate-failed verdict with gate commits propagates before bailing" {
  # AC: When the gate container committed and the verdict is gate-failed
  # (nonzero exit, non-transport log), propagate_feature runs on the
  # gate-stage failure path before the gate-failed record is written.
  # Under local-markdown the gate prompt commits a `tracker:` row on
  # every gate outcome — including gate-failed — so this is the active
  # data-loss path for that binding.
  setup_dispatch_one_test
  install_afk_snapshots in-review
  RUN_DISPATCHES=()
  RUN_STOP_REASON=""
  RUNNER_INTERRUPTED=0

  TEST_PROPAGATE_CALLS="$BATS_TEST_TMPDIR/prop-calls"
  TEST_PROPAGATE_HEAD="$BATS_TEST_TMPDIR/prop-head"
  : >"$TEST_PROPAGATE_CALLS"
  propagate_feature() {
    echo "$1" >>"$TEST_PROPAGATE_CALLS"
    git -C "$HOST_CHECKOUT" rev-parse HEAD >"$TEST_PROPAGATE_HEAD"
    RUNNER_LAST_PROPAGATION="propagated → host"
    return 0
  }

  # Gate commits AND exits nonzero with a non-transport-crash log
  # (`Killed` — typical OOM kill output). The classifier sees exit_code
  # != 0 and not-a-transport-crash → verdict = gate-failed.
  run_gate_container() {
    git -C "$HOST_CHECKOUT" -c user.email=t@t -c user.name=t \
      commit --allow-empty --quiet -m "tracker: review f/01 → blocked (gate notes)"
    echo "Killed" >"$2"
    return 137
  }

  set +e
  dispatch_one "f" "01" "$TEST_RUN_DIR" 2>/dev/null
  local rc=$?
  set -e

  [ "$rc" -ne 0 ]
  # Two propagations: post-implement (success path) and post-gate-failed
  # (new failure-path propagation).
  [ "$(wc -l <"$TEST_PROPAGATE_CALLS" | tr -d ' ')" = "2" ]
  # Final propagate_feature captured the gate's commit tip.
  local prop_head post_sha
  prop_head="$(cat "$TEST_PROPAGATE_HEAD")"
  post_sha="$(git -C "$HOST_CHECKOUT" rev-parse HEAD)"
  [ "$prop_head" = "$post_sha" ]
  # Dispatch record carries the gate-failed label and the propagation
  # indicator in the trailing column.
  [[ "${RUN_DISPATCHES[0]}" == "f|01|f/01|gate-failed|"*"|y|"*"|propagated → host" ]]
}

# === run_single — refusal cases ===========================================
#
# The runner contract is "dispatches eligible AFK refs only" — both modes
# share that gate. Loop mode enforces it via the snapshot's `eligible`
# flag at selection time; single-dispatch reads the same flag for the
# named ref before delegating to dispatch_one. Refusal sets
# RUN_STOP_REASON to `single-dispatch (refused: <reason>)`, prints a
# stderr diagnostic naming the reason, and returns 2 (same exit code
# argparse uses for input-validation rejections). No container runs.

setup_run_single_test() {
  TEST_DISPATCH_CALLED="$BATS_TEST_TMPDIR/dispatch-called"
  : >"$TEST_DISPATCH_CALLED"
  dispatch_one() {
    echo "called" >>"$TEST_DISPATCH_CALLED"
    return 0
  }
  RUN_DIR="$BATS_TEST_TMPDIR/run-single"
  mkdir -p "$RUN_DIR"
  RUN_DISPATCHES=()
  RUN_STOP_REASON=""
  RUNNER_STDERR="$BATS_TEST_TMPDIR/run-single.stderr"
  : >"$RUNNER_STDERR"
  # DISCOVERY_JSON must contain the test feature so the discovery gate passes.
  # HOST_REPO is left pointing at a non-git dir so symbolic-ref returns empty
  # and drain_one_feature's gate cascade picks drain.
  DISCOVERY_JSON='["f"]'
  HOST_REPO="$BATS_TEST_TMPDIR"
}

@test "run_single — refuses HITL ref with exit 2, stderr diagnostic, no dispatch" {
  setup_run_single_test
  ARG_ISSUE_REF="f/01"
  ISSUE_FEATURE="f"
  ISSUE_NN="01"
  take_snapshot() {
    printf '{"feature":"f","issues":[{"ref":"f/01","nn":"01","status":"ready-for-agent","category":"enhancement","type":"HITL","blocked_by":[],"eligible":false}]}'
  }

  set +e
  run_single 2>"$RUNNER_STDERR"
  local rc=$?
  set -e

  [ "$rc" -eq 2 ]
  [ "$RUN_STOP_REASON" = "single-dispatch (refused: HITL)" ]
  grep -q "single-dispatch refused" "$RUNNER_STDERR"
  grep -q "HITL" "$RUNNER_STDERR"
  # No container dispatched.
  [ ! -s "$TEST_DISPATCH_CALLED" ]
}

@test "run_single — refuses ref with wrong status (already in-review)" {
  setup_run_single_test
  ARG_ISSUE_REF="f/01"
  ISSUE_FEATURE="f"
  ISSUE_NN="01"
  take_snapshot() {
    printf '{"feature":"f","issues":[{"ref":"f/01","nn":"01","status":"in-review","category":"enhancement","type":"AFK","blocked_by":[],"eligible":false}]}'
  }

  set +e
  run_single 2>"$RUNNER_STDERR"
  local rc=$?
  set -e

  [ "$rc" -eq 2 ]
  [ "$RUN_STOP_REASON" = "single-dispatch (refused: wrong-status)" ]
  grep -q "single-dispatch refused" "$RUNNER_STDERR"
  grep -q "in-review" "$RUNNER_STDERR"
  [ ! -s "$TEST_DISPATCH_CALLED" ]
}

@test "run_single — refuses ref missing from feature snapshot" {
  setup_run_single_test
  ARG_ISSUE_REF="f/99"
  ISSUE_FEATURE="f"
  ISSUE_NN="99"
  take_snapshot() {
    printf '{"feature":"f","issues":[{"ref":"f/01","nn":"01","status":"ready-for-agent","category":"enhancement","type":"AFK","blocked_by":[],"eligible":true}]}'
  }

  set +e
  run_single 2>"$RUNNER_STDERR"
  local rc=$?
  set -e

  [ "$rc" -eq 2 ]
  [ "$RUN_STOP_REASON" = "single-dispatch (refused: missing)" ]
  grep -q "single-dispatch refused" "$RUNNER_STDERR"
  grep -q "f/99" "$RUNNER_STDERR"
  [ ! -s "$TEST_DISPATCH_CALLED" ]
}

@test "run_single — eligible AFK ref proceeds to dispatch_one" {
  setup_run_single_test
  ARG_ISSUE_REF="f/01"
  ISSUE_FEATURE="f"
  ISSUE_NN="01"
  take_snapshot() {
    printf '{"feature":"f","issues":[{"ref":"f/01","nn":"01","status":"ready-for-agent","category":"enhancement","type":"AFK","blocked_by":[],"eligible":true}]}'
  }

  set +e
  run_single
  local rc=$?
  set -e

  [ "$rc" -eq 0 ]
  [ "$RUN_STOP_REASON" = "single-dispatch (success)" ]
  [ -s "$TEST_DISPATCH_CALLED" ]
}

@test "run_single — padded CLI nn resolves unpadded snapshot entry (03 vs 3)" {
  setup_run_single_test
  ARG_ISSUE_REF="f/03"
  ISSUE_FEATURE="f"
  ISSUE_NN="03"
  take_snapshot() {
    printf '{"feature":"f","issues":[{"ref":"f/3","nn":"3","status":"ready-for-agent","category":"enhancement","type":"AFK","blocked_by":[],"eligible":true}]}'
  }

  set +e
  run_single
  local rc=$?
  set -e

  [ "$rc" -eq 0 ]
  [ "$RUN_STOP_REASON" = "single-dispatch (success)" ]
  [ -s "$TEST_DISPATCH_CALLED" ]
}

@test "run_single — unpadded CLI nn resolves padded snapshot entry (3 vs 03)" {
  setup_run_single_test
  ARG_ISSUE_REF="f/3"
  ISSUE_FEATURE="f"
  ISSUE_NN="3"
  take_snapshot() {
    printf '{"feature":"f","issues":[{"ref":"f/03","nn":"03","status":"ready-for-agent","category":"enhancement","type":"AFK","blocked_by":[],"eligible":true}]}'
  }

  set +e
  run_single
  local rc=$?
  set -e

  [ "$rc" -eq 0 ]
  [ "$RUN_STOP_REASON" = "single-dispatch (success)" ]
  [ -s "$TEST_DISPATCH_CALLED" ]
}

# === check_feature_eligibility — CLI-input gate inside preflight ===========
#
# `--feature <slug>` / `--issue <feature>/<NN>` get their refusal here
# (unknown-feature only). The gate runs before `ensure_runner_checkout` so
# an unknown slug surfaces the AC-mandated `feature-restricted (refused:
# unknown-feature)` / `single-dispatch (refused: unknown-feature)` instead
# of an opaque failure. Return 2 propagates via `set -e` in main; the EXIT
# trap then writes SUMMARY.md against RUN_STOP_REASON (not
# RUN_PREFLIGHT_INVARIANT).

setup_eligibility_test() {
  HOST_REPO="$BATS_TEST_TMPDIR/elig-host"
  mkdir -p "$HOST_REPO"
  git -C "$HOST_REPO" init --quiet --initial-branch=main
  git -C "$HOST_REPO" -c user.email=t@t -c user.name=t \
    commit --allow-empty --quiet -m init
  RUN_STOP_REASON=""
  ELIG_STDERR="$BATS_TEST_TMPDIR/elig.stderr"
  : >"$ELIG_STDERR"
}

@test "check_feature_eligibility — loop mode: unknown feature → feature-restricted (refused: unknown-feature)" {
  setup_eligibility_test
  RUN_MODE="loop"
  TARGET_FEATURE="missing"
  DISCOVERY_JSON='["other"]'

  check_feature_eligibility 2>"$ELIG_STDERR" || rc=$?
  [ "${rc:-0}" -eq 2 ]
  [ "$RUN_STOP_REASON" = "feature-restricted (refused: unknown-feature)" ]
  grep -q "^runner: feature-restricted refused: feature 'missing' not in discovery output$" "$ELIG_STDERR"
}

@test "check_feature_eligibility — single mode: unknown feature → single-dispatch (refused: unknown-feature)" {
  setup_eligibility_test
  RUN_MODE="single"
  TARGET_FEATURE="missing"
  DISCOVERY_JSON='["other"]'

  check_feature_eligibility 2>"$ELIG_STDERR" || rc=$?
  [ "${rc:-0}" -eq 2 ]
  [ "$RUN_STOP_REASON" = "single-dispatch (refused: unknown-feature)" ]
  grep -q "^runner: single-dispatch refused: feature 'missing' not in discovery output$" "$ELIG_STDERR"
}

@test "check_feature_eligibility — feature in discovery, host on same branch, branch exists → passes silently" {
  setup_eligibility_test
  # The runner is branch-state-agnostic on the host side: the eligibility
  # gate passes whether or not host has the feature branch checked out.
  git -C "$HOST_REPO" checkout --quiet -B "my-feature"
  RUN_MODE="loop"
  TARGET_FEATURE="my-feature"
  DISCOVERY_JSON='["my-feature"]'

  check_feature_eligibility 2>"$ELIG_STDERR"
  [ -z "$RUN_STOP_REASON" ]
  [ ! -s "$ELIG_STDERR" ]
}

@test "check_feature_eligibility — feature in discovery and branch exists → passes silently" {
  setup_eligibility_test
  git -C "$HOST_REPO" branch my-feature
  RUN_MODE="loop"
  TARGET_FEATURE="my-feature"
  DISCOVERY_JSON='["my-feature","other"]'

  check_feature_eligibility 2>"$ELIG_STDERR"
  [ -z "$RUN_STOP_REASON" ]
  [ ! -s "$ELIG_STDERR" ]
}

@test "check_feature_eligibility — loop mode: slug in discovery, no host branch → passes silently" {
  # After lazy-init, branch-missing is no longer a refusal. A slug that is in
  # discovery but has no refs/heads/<slug> on host should pass the eligibility
  # gate so the runner-checkout can lazily initialize from main.
  setup_eligibility_test
  # Host stays on main; 'my-feature' branch is intentionally NOT created.
  RUN_MODE="loop"
  TARGET_FEATURE="my-feature"
  DISCOVERY_JSON='["my-feature","other"]'

  check_feature_eligibility 2>"$ELIG_STDERR"
  [ -z "$RUN_STOP_REASON" ]
  [ ! -s "$ELIG_STDERR" ]
}

@test "check_feature_eligibility — single mode: slug in discovery, no host branch → passes silently" {
  setup_eligibility_test
  RUN_MODE="single"
  TARGET_FEATURE="my-feature"
  DISCOVERY_JSON='["my-feature"]'

  check_feature_eligibility 2>"$ELIG_STDERR"
  [ -z "$RUN_STOP_REASON" ]
  [ ! -s "$ELIG_STDERR" ]
}

@test "preflight — refuses unknown feature before running ensure_runner_checkout" {
  # Pin the contract: an unknown `--feature <slug>` must surface
  # `feature-restricted (refused: unknown-feature)` from
  # `check_feature_eligibility` before `ensure_runner_checkout` runs.
  # Otherwise `git fetch origin <slug>` would fail first and the runner
  # would report `preflight-abort: runner-checkout` instead. Mock
  # `ensure_runner_checkout` to fail loudly if called; the test passes only
  # when `check_feature_eligibility` fires first.
  setup_eligibility_test
  TEST_CHECKOUT_SENTINEL="$BATS_TEST_TMPDIR/checkout-called"
  acquire_lock() { :; }
  check_discovery() { DISCOVERY_JSON='["other"]'; }
  ensure_runner_checkout_exists() { :; }
  ensure_runner_remote() { :; }
  ensure_runner_checkout() {
    echo "ensure_runner_checkout invoked before refusal" >"$TEST_CHECKOUT_SENTINEL"
    return 99
  }
  check_docker_daemon() { :; }
  ensure_image() { :; }
  check_gate_prompt() { :; }
  ensure_mvn_cache() { :; }
  ensure_network() { :; }
  retrieve_oauth_token() { :; }

  RUN_MODE="loop"
  TARGET_FEATURE="missing"

  preflight 2>"$ELIG_STDERR" || rc=$?
  [ "${rc:-0}" -eq 2 ]
  [ "$RUN_STOP_REASON" = "feature-restricted (refused: unknown-feature)" ]
  [ ! -f "$TEST_CHECKOUT_SENTINEL" ]
}

@test "dispatch_one — AFK clean review records done and propagates twice" {
  setup_dispatch_one_test
  install_afk_snapshots done

  TEST_PROPAGATE_CALLS="$BATS_TEST_TMPDIR/prop-calls"
  : >"$TEST_PROPAGATE_CALLS"
  propagate_feature() {
    echo "called" >>"$TEST_PROPAGATE_CALLS"
    return 0
  }
  # local-markdown-shaped gate: commits a `tracker:` row on clean and
  # blocked alike. The HEAD delta triggers gate-stage propagation.
  run_gate_container() {
    git -C "$HOST_CHECKOUT" -c user.email=t@t -c user.name=t \
      commit --allow-empty --quiet -m "tracker: review f/01 → done"
    return 0
  }

  RUN_DISPATCHES=()
  set +e
  dispatch_one "f" "01" "$TEST_RUN_DIR"
  local rc=$?
  set -e

  [ "$rc" -eq 0 ]
  # One record, combined label `done`, review-log marker present.
  [ "${#RUN_DISPATCHES[@]}" -eq 1 ]
  [[ "${RUN_DISPATCHES[0]}" == "f|01|f/01|done|"*"|y|"* ]]
  # Two propagations: post-implement and post-gate.
  [ "$(wc -l <"$TEST_PROPAGATE_CALLS" | tr -d ' ')" = "2" ]
}

@test "dispatch_one — gate that produces no commits skips post-gate propagation" {
  # Regression: the gate-stage propagate_feature call was unconditional,
  # mirroring the local-markdown binding's "gate prompt always commits"
  # contract. Under the github-issues binding the gate's comment + set-state
  # are API calls — no runner-checkout commit. The implement stage already
  # gates propagation on the HEAD delta; the gate stage must do the same so
  # a no-commit gate dispatch does not produce a redundant parking-ref
  # publish (and, on an on-branch maintainer, a spurious "parked → runner"
  # ledger entry telling the maintainer to pull nothing).
  setup_dispatch_one_test
  install_afk_snapshots done

  TEST_PROPAGATE_CALLS="$BATS_TEST_TMPDIR/prop-calls"
  : >"$TEST_PROPAGATE_CALLS"
  propagate_feature() {
    echo "called" >>"$TEST_PROPAGATE_CALLS"
    return 0
  }
  # github-issues-shaped gate: state flip and comment go through API calls,
  # leaving the runner-checkout HEAD unchanged.
  run_gate_container() {
    return 0
  }

  RUN_DISPATCHES=()
  set +e
  dispatch_one "f" "01" "$TEST_RUN_DIR"
  local rc=$?
  set -e

  [ "$rc" -eq 0 ]
  [ "${#RUN_DISPATCHES[@]}" -eq 1 ]
  [[ "${RUN_DISPATCHES[0]}" == "f|01|f/01|done|"*"|y|"* ]]
  # Only the implement-stage propagate ran; the gate-stage call was gated
  # out by the empty HEAD delta.
  [ "$(wc -l <"$TEST_PROPAGATE_CALLS" | tr -d ' ')" = "1" ]
}

@test "dispatch_one — gate that commits still propagates twice" {
  # Companion to the above: under local-markdown the gate commits a
  # `tracker:` row, so the post-gate HEAD delta is non-empty and the
  # gate-stage propagation must still fire. This pins the local-markdown
  # path's invariant after the gate-stage commit-delta gate is added.
  setup_dispatch_one_test
  install_afk_snapshots done

  TEST_PROPAGATE_CALLS="$BATS_TEST_TMPDIR/prop-calls"
  : >"$TEST_PROPAGATE_CALLS"
  propagate_feature() {
    echo "called" >>"$TEST_PROPAGATE_CALLS"
    return 0
  }
  # local-markdown-shaped gate: contracts to commit on clean and blocked
  # alike (the tracker mutation lands as a git commit, not an API call).
  run_gate_container() {
    git -C "$HOST_CHECKOUT" -c user.email=t@t -c user.name=t \
      commit --allow-empty --quiet -m "tracker: review f/01 → done"
    return 0
  }

  set +e
  dispatch_one "f" "01" "$TEST_RUN_DIR"
  set -e

  [ "$(wc -l <"$TEST_PROPAGATE_CALLS" | tr -d ' ')" = "2" ]
}

@test "dispatch_one — both propagate_feature call sites pass the feature branch as \$1" {
  # Pin the contract: both `dispatch_one` call sites of `propagate_feature`
  # pass TARGET_FEATURE as $1. A missing argument leaves branch="" in the
  # callee, and `git fetch <checkout> ":refs/remotes/runner/"` would fail,
  # orphaning the gate's `tracker:` commit in the runner-checkout while the
  # runner reports success.
  setup_dispatch_one_test
  install_afk_snapshots done

  TEST_PROPAGATE_ARGS="$BATS_TEST_TMPDIR/prop-args"
  : >"$TEST_PROPAGATE_ARGS"
  propagate_feature() {
    # Record the literal argument received — empty string is recorded as
    # an empty line, which `grep -c` and `wc -l` both see distinctly from
    # a non-empty record.
    printf '%s\n' "${1-}" >>"$TEST_PROPAGATE_ARGS"
    return 0
  }
  # local-markdown-shaped gate commit so the HEAD delta triggers
  # gate-stage propagation.
  run_gate_container() {
    git -C "$HOST_CHECKOUT" -c user.email=t@t -c user.name=t \
      commit --allow-empty --quiet -m "tracker: review f/01 → done"
    return 0
  }

  set +e
  dispatch_one "f" "01" "$TEST_RUN_DIR"
  set -e

  [ "$(wc -l <"$TEST_PROPAGATE_ARGS" | tr -d ' ')" = "2" ]
  # Every recorded call must carry the feature ("f") as $1.
  [ "$(grep -c '^f$' "$TEST_PROPAGATE_ARGS")" = "2" ]
}

@test "dispatch_one — AFK Critical-finding review records blocked and propagates twice" {
  setup_dispatch_one_test
  install_afk_snapshots in-review

  TEST_PROPAGATE_CALLS="$BATS_TEST_TMPDIR/prop-calls"
  : >"$TEST_PROPAGATE_CALLS"
  propagate_feature() {
    echo "called" >>"$TEST_PROPAGATE_CALLS"
    return 0
  }
  # local-markdown-shaped gate: commits a `tracker:` row even on blocked
  # (the gate prompt contracts to commit on clean and blocked alike).
  # The HEAD delta triggers gate-stage propagation.
  run_gate_container() {
    git -C "$HOST_CHECKOUT" -c user.email=t@t -c user.name=t \
      commit --allow-empty --quiet -m "tracker: review f/01 → blocked"
    return 0
  }

  RUN_DISPATCHES=()
  set +e
  dispatch_one "f" "01" "$TEST_RUN_DIR"
  local rc=$?
  set -e

  [ "$rc" -eq 0 ]
  # Blocked is operationally clean — counter resets, no failure.
  [ "${#RUN_DISPATCHES[@]}" -eq 1 ]
  [[ "${RUN_DISPATCHES[0]}" == "f|01|f/01|blocked|"*"|y|"* ]]
  [ "$(wc -l <"$TEST_PROPAGATE_CALLS" | tr -d ' ')" = "2" ]
}

@test "dispatch_one — AFK gate-failed (nonzero exit) returns 1" {
  setup_dispatch_one_test
  install_afk_snapshots in-review

  TEST_PROPAGATE_CALLS="$BATS_TEST_TMPDIR/prop-calls"
  : >"$TEST_PROPAGATE_CALLS"
  propagate_feature() {
    echo "called" >>"$TEST_PROPAGATE_CALLS"
    return 0
  }
  run_gate_container() {
    # Container crashed (OOM kill) — nonzero exit. We must write a non-whitespace
    # line to the log ($2) so is_transport_crash doesn't misclassify the empty log
    # as a transport crash and flip the verdict to review-aborted.
    echo "Killed" >"$2"
    return 137
  }

  RUN_DISPATCHES=()
  set +e
  dispatch_one "f" "01" "$TEST_RUN_DIR"
  local rc=$?
  set -e

  [ "$rc" -ne 0 ]
  [ "${#RUN_DISPATCHES[@]}" -eq 1 ]
  [[ "${RUN_DISPATCHES[0]}" == "f|01|f/01|gate-failed|"*"|y|"* ]]
  # Only the post-implement propagation ran; the gate-failed branch
  # does not propagate.
  [ "$(wc -l <"$TEST_PROPAGATE_CALLS" | tr -d ' ')" = "1" ]
}

@test "dispatch_one — AFK off-mission post-gate status is gate-failed" {
  setup_dispatch_one_test
  install_afk_snapshots wontfix

  propagate_feature() { return 0; }
  run_gate_container() {
    # Exit 0 but post-gate status is wontfix — classify as gate-failed.
    return 0
  }

  RUN_DISPATCHES=()
  set +e
  dispatch_one "f" "01" "$TEST_RUN_DIR"
  local rc=$?
  set -e

  [ "$rc" -ne 0 ]
  [[ "${RUN_DISPATCHES[0]}" == "f|01|f/01|gate-failed|"*"|y|"* ]]
}

@test "dispatch_one — RUNNER_INTERRUPTED between implement and gate prevents gate dispatch" {
  # Simulates Ctrl-C arriving after run_dispatch_container returns (i.e.
  # IN_FLIGHT_CID_FILE has been cleared) but before run_gate_container is
  # called. The fix must check RUNNER_INTERRUPTED and return before
  # spawning the gate container.
  setup_dispatch_one_test
  install_afk_snapshots done

  propagate_feature() { return 0; }

  TEST_GATE_CALLED="$BATS_TEST_TMPDIR/gate-called"
  : >"$TEST_GATE_CALLED"
  run_gate_container() {
    echo "called" >>"$TEST_GATE_CALLED"
    return 0
  }

  # Simulate RUNNER_INTERRUPTED arriving just as the implement container exits.
  run_dispatch_container() {
    RUNNER_INTERRUPTED=1
    return 0
  }

  RUNNER_INTERRUPTED=0
  RUN_DISPATCHES=()
  set +e
  dispatch_one "f" "01" "$TEST_RUN_DIR"
  local rc=$?
  set -e

  [ "$rc" -eq 0 ]
  # Gate must NOT have been dispatched.
  [ ! -s "$TEST_GATE_CALLED" ]
  # Implement label recorded (in-review since implement succeeded).
  [ "${#RUN_DISPATCHES[@]}" -eq 1 ]
  [[ "${RUN_DISPATCHES[0]}" == "f|01|f/01|in-review|"* ]]
}

@test "dispatch_one — AFK gate blocked verdict survives dirty checkout" {
  # Contract: an inherited working-tree leftover from a prior in-container
  # crash (here, a 0-byte kernel core dump at `framework/runner/tests/core`)
  # does not override the classifier's verdict. The gate produces a clean
  # `blocked` verdict; the runner propagates the gate's tracker commit to
  # host so the maintainer sees the review's findings. The
  # implement-stage warning at line ~1524 already reported the leak; the
  # gate stage does not re-warn. The next iteration's
  # `ensure_runner_checkout` clears the leftover via `git clean -fd`.
  setup_dispatch_one_test
  install_afk_snapshots in-review

  TEST_PROPAGATE_CALLS="$BATS_TEST_TMPDIR/prop-calls"
  : >"$TEST_PROPAGATE_CALLS"
  propagate_feature() {
    echo "called" >>"$TEST_PROPAGATE_CALLS"
    return 0
  }
  run_dispatch_container() {
    # Mirror issue 21's incident shape: the implement stage commits real
    # tracker work AND leaks an uncommitted file (a kernel core dump from
    # a crashed in-container subprocess; default `core_pattern=core` writes
    # CWD-relative). The leftover persists into the gate stage's working
    # tree without the gate having touched it.
    git -C "$HOST_CHECKOUT" -c user.email=t@t -c user.name=t \
      commit --allow-empty --quiet -m "tracker: f/01 (test)"
    mkdir -p "$HOST_CHECKOUT/framework/runner/tests"
    : >"$HOST_CHECKOUT/framework/runner/tests/core"
    return 0
  }
  run_gate_container() {
    # local-markdown-shaped gate: commits a `tracker:` row even on
    # blocked. The classifier still sees status unchanged
    # (in-review → in-review) and returns `blocked`; the HEAD delta
    # triggers gate-stage propagation so the tracker commit reaches host.
    git -C "$HOST_CHECKOUT" -c user.email=t@t -c user.name=t \
      commit --allow-empty --quiet -m "tracker: review f/01 → blocked"
    return 0
  }

  RUN_DISPATCHES=()
  set +e
  dispatch_one "f" "01" "$TEST_RUN_DIR"
  local rc=$?
  set -e

  # Classifier verdict (`blocked`) propagates unchanged despite the dirty
  # working tree.
  [ "$rc" -eq 0 ]
  [ "${#RUN_DISPATCHES[@]}" -eq 1 ]
  [[ "${RUN_DISPATCHES[0]}" == "f|01|f/01|blocked|"*"|y|"* ]]
  # Both the post-implement and post-gate propagations ran — the gate's
  # tracker commit reaches host.
  [ "$(wc -l <"$TEST_PROPAGATE_CALLS" | tr -d ' ')" = "2" ]
}

# === capture_dispatch_core_files ==========================================

@test "capture_dispatch_core_files — copies root-level core to run-state dir" {
  setup_dispatch_one_test
  touch "$HOST_CHECKOUT/core"
  local dirty="?? core"
  capture_dispatch_core_files "$dirty" "$TEST_RUN_DIR" "f" "01"
  [ -f "$TEST_RUN_DIR/f/01-core.core" ]
}

@test "capture_dispatch_core_files — copies cwd-relative core to run-state dir" {
  setup_dispatch_one_test
  mkdir -p "$HOST_CHECKOUT/framework/runner/tests"
  touch "$HOST_CHECKOUT/framework/runner/tests/core"
  local dirty="?? framework/runner/tests/core"
  capture_dispatch_core_files "$dirty" "$TEST_RUN_DIR" "f" "01"
  [ -f "$TEST_RUN_DIR/f/01-core.framework-runner-tests-core" ]
}

@test "capture_dispatch_core_files — both root and subdir cores preserved without collision" {
  setup_dispatch_one_test
  mkdir -p "$HOST_CHECKOUT/framework/runner/tests"
  touch "$HOST_CHECKOUT/core"
  touch "$HOST_CHECKOUT/framework/runner/tests/core"
  local dirty="?? core
?? framework/runner/tests/core"
  capture_dispatch_core_files "$dirty" "$TEST_RUN_DIR" "f" "01"
  [ -f "$TEST_RUN_DIR/f/01-core.core" ]
  [ -f "$TEST_RUN_DIR/f/01-core.framework-runner-tests-core" ]
}

@test "capture_dispatch_core_files — no-op when dirty list has no core-pattern file" {
  setup_dispatch_one_test
  local dirty="?? some-unrelated-file.txt"
  capture_dispatch_core_files "$dirty" "$TEST_RUN_DIR" "f" "01"
  [ ! -f "$TEST_RUN_DIR/f/01-core.some-unrelated-file.txt" ]
  [ ! -f "$TEST_RUN_DIR/f/01-core.core" ]
}

@test "capture_dispatch_core_files — no-op when dirty list is empty" {
  setup_dispatch_one_test
  capture_dispatch_core_files "" "$TEST_RUN_DIR" "f" "01"
  [ ! -f "$TEST_RUN_DIR/f/01-core.core" ]
}

@test "capture_dispatch_core_files — safe re-entry when source already removed" {
  setup_dispatch_one_test
  # Dirty list mentions a core that no longer exists (already swept)
  local dirty="?? core"
  capture_dispatch_core_files "$dirty" "$TEST_RUN_DIR" "f" "01"
  [ ! -f "$TEST_RUN_DIR/f/01-core.core" ]
}

@test "capture_dispatch_core_files — captures core inside untracked directory" {
  setup_dispatch_one_test
  mkdir -p "$HOST_CHECKOUT/target"
  touch "$HOST_CHECKOUT/target/core"
  # `git status --porcelain --untracked-files=all` enumerates files
  # inside untracked directories; the helper depends on the caller
  # producing that form rather than the default `?? target/` summary.
  local dirty="?? target/core"
  capture_dispatch_core_files "$dirty" "$TEST_RUN_DIR" "f" "01"
  [ -f "$TEST_RUN_DIR/f/01-core.target-core" ]
}

@test "capture_dispatch_core_files — collapsed untracked-dir summary line is ignored" {
  setup_dispatch_one_test
  mkdir -p "$HOST_CHECKOUT/target"
  touch "$HOST_CHECKOUT/target/core"
  # Default `git status --porcelain` collapses an untracked directory to
  # a single `?? target/` line. The helper basename-matches on
  # `core | core.*`; the collapsed entry's basename is the directory
  # itself, so nothing matches and nothing is captured. This pins why
  # `dispatch_one` must invoke git with `--untracked-files=all`: drop
  # the flag and cores inside untracked subdirs become invisible.
  local dirty="?? target/"
  capture_dispatch_core_files "$dirty" "$TEST_RUN_DIR" "f" "01"
  [ ! -e "$TEST_RUN_DIR/f/01-core.target" ]
  [ ! -e "$TEST_RUN_DIR/f/01-core.target-core" ]
}

# === Output formatters =====================================================
#
# Pin the exact stdout shape and SUMMARY.md shape the AC requires. The
# formatters are pure (stdin→stdout, no globals) so the tests pass
# fixture inputs and string-compare the output.

# === humanize_duration =====================================================

@test "humanize_duration — 1s" {
  [ "$(humanize_duration 1)" = "1s" ]
}

@test "humanize_duration — 59s" {
  [ "$(humanize_duration 59)" = "59s" ]
}

@test "humanize_duration — 60 → 1m 0s" {
  [ "$(humanize_duration 60)" = "1m 0s" ]
}

@test "humanize_duration — 61 → 1m 1s" {
  [ "$(humanize_duration 61)" = "1m 1s" ]
}

@test "humanize_duration — 612 → 10m 12s" {
  [ "$(humanize_duration 612)" = "10m 12s" ]
}

@test "humanize_duration — 3599 → 59m 59s" {
  [ "$(humanize_duration 3599)" = "59m 59s" ]
}

@test "humanize_duration — 3600 → 1h 0m" {
  [ "$(humanize_duration 3600)" = "1h 0m" ]
}

@test "humanize_duration — 3601 → 1h 0m (seconds dropped)" {
  [ "$(humanize_duration 3601)" = "1h 0m" ]
}

@test "humanize_duration — 3660 → 1h 1m" {
  [ "$(humanize_duration 3660)" = "1h 1m" ]
}

@test "format_progress_outcome — duration ≥ 60s renders in human form" {
  result="$(format_progress_outcome "09:22:00" "afk-runner/07" "implement" "in-review" 612)"
  [ "$result" = "[09:22:00] afk-runner/07 implement → in-review (10m 12s)" ]
}

@test "format_progress_start — implement stage" {
  result="$(format_progress_start "09:12:45" "afk-runner/06" "implement")"
  [ "$result" = "[09:12:45] afk-runner/06 implement → starting" ]
}

@test "format_progress_start — review stage" {
  result="$(format_progress_start "09:14:05" "afk-runner/06" "review")"
  [ "$result" = "[09:14:05] afk-runner/06 review → starting" ]
}

@test "format_progress_outcome — implement in-review" {
  result="$(format_progress_outcome "09:13:27" "afk-runner/06" "implement" "in-review" 42)"
  [ "$result" = "[09:13:27] afk-runner/06 implement → in-review (42s)" ]
}

@test "format_progress_outcome — implement FAIL" {
  result="$(format_progress_outcome "09:13:27" "afk-runner/06" "implement" "FAIL" 18)"
  [ "$result" = "[09:13:27] afk-runner/06 implement → FAIL (18s)" ]
}

@test "format_progress_outcome — review clean → done" {
  result="$(format_progress_outcome "09:14:09" "afk-runner/06" "review" "clean → done" 4)"
  [ "$result" = "[09:14:09] afk-runner/06 review → clean → done (4s)" ]
}

@test "format_progress_outcome — review blocked" {
  result="$(format_progress_outcome "09:14:09" "afk-runner/06" "review" "blocked" 4)"
  [ "$result" = "[09:14:09] afk-runner/06 review → blocked (4s)" ]
}

@test "format_progress_outcome — review gate-failed" {
  result="$(format_progress_outcome "09:14:09" "afk-runner/06" "review" "gate-failed" 4)"
  [ "$result" = "[09:14:09] afk-runner/06 review → gate-failed (4s)" ]
}

@test "format_end_of_run_table — header, rows, trailing stop reason" {
  # New-schema records: feature|nn|ref|outcome|duration|review_present.
  input='afk-runner|01|afk-runner/01|in-review|42|
afk-runner|02|afk-runner/02|FAIL|18|
afk-runner|03|afk-runner/03|done|301|y'
  result="$(printf '%s\n' "$input" | format_end_of_run_table queue-empty)"
  # Header line — column names in order (propagation column added).
  echo "$result" | head -n 1 | grep -q '^issue ' || { echo "header missing 'issue'"; echo "$result"; false; }
  echo "$result" | head -n 1 | grep -q ' outcome ' || { echo "header missing 'outcome'"; false; }
  echo "$result" | head -n 1 | grep -q ' duration ' || { echo "header missing 'duration'"; false; }
  echo "$result" | head -n 1 | grep -q ' propagation' || { echo "header missing 'propagation'"; echo "$result"; false; }
  # One row per dispatch — `issue` column shows the binding-native ref.
  # Propagation field missing → shows '-' in the propagation column.
  echo "$result" | grep -q '^afk-runner/01 .*in-review.* 42s ' || { echo "row 01 missing"; echo "$result"; false; }
  echo "$result" | grep -q '^afk-runner/02 .*FAIL.* 18s ' || { echo "row 02 missing"; echo "$result"; false; }
  echo "$result" | grep -q '^afk-runner/03 .*done.* 5m 1s ' || { echo "row 03 missing"; echo "$result"; false; }
  # `feature` and `nn` are not exposed in their own columns.
  ! echo "$result" | head -n 2 | tail -n 1 | grep -qE '^afk-runner +01 ' || { echo "feature/nn leaked into issue/outcome columns"; echo "$result"; false; }
  # Trailing stop-reason line below the table.
  echo "$result" | tail -n 1 | grep -q '^stop reason: queue-empty$' || { echo "stop reason missing"; echo "$result"; false; }
}

@test "format_end_of_run_table — GH-shaped ref (#N) renders binding-native issue column" {
  # Under the github-issues binding the ref carries no `/`. The previous
  # schema relied on the operator-visible `issue` column to be the ref;
  # this test pins that contract under a GH-shaped ref so future schema
  # drift can't silently break the operator-facing table.
  input='afk-runner|42|#42|in-review|12|
afk-runner|43|#43|FAIL|5|y'
  result="$(printf '%s\n' "$input" | format_end_of_run_table queue-empty)"
  echo "$result" | grep -q '^#42 .*in-review.* 12s ' || { echo "GH row 42 missing"; echo "$result"; false; }
  echo "$result" | grep -q '^#43 .*FAIL.* 5s ' || { echo "GH row 43 missing"; echo "$result"; false; }
}

@test "format_end_of_run_table — empty input still prints header + stop reason" {
  result="$(printf '' | format_end_of_run_table queue-empty)"
  echo "$result" | head -n 1 | grep -q '^issue ' || { echo "header missing"; false; }
  echo "$result" | tail -n 1 | grep -q '^stop reason: queue-empty$' || false
}

@test "format_summary_md — heading, run line, stop reason, per-issue table with logs" {
  input='afk-runner|01|afk-runner/01|in-review|42|
afk-runner|02|afk-runner/02|FAIL|18|'
  result="$(printf '%s\n' "$input" | format_summary_md \
    afk-runner 20260506-091245 09:12:45 09:25:33 ended queue-empty)"

  # Heading carries the feature slug.
  echo "$result" | grep -q '^# AFK runner — afk-runner$' || { echo "$result"; false; }
  # Run line carries the timestamp + start/end clocks + state.
  echo "$result" | grep -q -- '- Run: 20260506-091245.*started 09:12:45.*ended 09:25:33' || { echo "$result"; false; }
  # Stop reason line.
  echo "$result" | grep -q -- '- Stop reason: queue-empty$' || { echo "$result"; false; }
  # Per-issue table headers + rows. The `propagation` column is new; records
  # without a propagation field show `-`. The `logs` column carries one or two
  # links depending on whether the iteration produced a `<NN>-review.log`.
  echo "$result" | grep -q '^| issue | outcome | duration | propagation | logs |$' || { echo "$result"; false; }
  echo "$result" | grep -qF '| afk-runner/01 | in-review | 42s | - | [01.log](01.log) |' || { echo "$result"; false; }
  echo "$result" | grep -qF '| afk-runner/02 | FAIL | 18s | - | [02.log](02.log) |' || { echo "$result"; false; }
}

@test "format_summary_md — gate-bearing rows include the review-log link" {
  input='afk-runner|01|afk-runner/01|done|42|y
afk-runner|02|afk-runner/02|blocked|36|y
afk-runner|03|afk-runner/03|gate-failed|11|y
afk-runner|04|afk-runner/04|in-review|17|
afk-runner|05|afk-runner/05|FAIL|3|'
  result="$(printf '%s\n' "$input" | format_summary_md \
    afk-runner 20260506-091245 09:12:45 09:25:33 ended queue-empty)"

  # AFK rows (clean / blocked / gate-failed) carry both the dispatch
  # log and the review log. Propagation field absent → '-' indicator.
  echo "$result" | grep -qF '| afk-runner/01 | done | 42s | - | [01.log](01.log) [01-review.log](01-review.log) |' \
    || { echo "$result"; false; }
  echo "$result" | grep -qF '| afk-runner/02 | blocked | 36s | - | [02.log](02.log) [02-review.log](02-review.log) |' \
    || { echo "$result"; false; }
  echo "$result" | grep -qF '| afk-runner/03 | gate-failed | 11s | - | [03.log](03.log) [03-review.log](03-review.log) |' \
    || { echo "$result"; false; }
  # Interrupt-between-stages row (implement-step recorded `in-review`,
  # interrupted before gate) and implement-FAIL row carry only the
  # dispatch log.
  echo "$result" | grep -qF '| afk-runner/04 | in-review | 17s | - | [04.log](04.log) |' \
    || { echo "$result"; false; }
  echo "$result" | grep -qF '| afk-runner/05 | FAIL | 3s | - | [05.log](05.log) |' \
    || { echo "$result"; false; }
}

@test "format_summary_md — interrupted state surfaces in the run line" {
  result="$(printf 'afk-runner|01|afk-runner/01|in-review|42\n' | format_summary_md \
    afk-runner 20260506-091245 09:12:45 09:13:27 interrupted interrupted)"
  echo "$result" | grep -q -- '- Run: 20260506-091245.*started 09:12:45.*interrupted 09:13:27' || { echo "$result"; false; }
  echo "$result" | grep -q -- '- Stop reason: interrupted$' || { echo "$result"; false; }
}

@test "format_summary_md — empty dispatch list still emits headers" {
  result="$(printf '' | format_summary_md afk-runner 20260506-091245 09:12:45 09:12:46 ended queue-empty)"
  echo "$result" | grep -q '^# AFK runner — afk-runner$' || false
  echo "$result" | grep -q '^| issue | outcome | duration | propagation | logs |$' || false
  # No data rows expected.
  ! echo "$result" | grep -q '^| afk-' || false
}

@test "format_summary_md — GH-shaped ref (#N) emits working nn-based log link" {
  # Record schema: feature|nn|ref|outcome|duration|review_present
  input='some-feature|42|#42|in-review|37|'
  result="$(printf '%s\n' "$input" | format_summary_md \
    some-feature 20260506-091245 09:12:45 09:13:22 ended queue-empty)"

  # Issue column shows binding-native ref (#42); log link uses plain nn (42.log).
  # Propagation field absent in this record → '-' indicator.
  echo "$result" | grep -qF '| #42 | in-review | 37s | - | [42.log](42.log) |' \
    || { echo "$result"; false; }
}

@test "format_summary_md — dispatch-aborted and review-aborted render as outcome labels" {
  # dispatch-aborted has no review log; review-aborted does (gate stage ran).
  input='afk-runner|01|afk-runner/01|dispatch-aborted|12|
afk-runner|02|afk-runner/02|review-aborted|38|y'
  result="$(printf '%s\n' "$input" | format_summary_md \
    afk-runner 20260506-091245 09:12:45 09:25:33 ended queue-empty)"

  echo "$result" | grep -qF '| afk-runner/01 | dispatch-aborted | 12s | - | [01.log](01.log) |' \
    || { echo "$result"; false; }
  echo "$result" | grep -qF '| afk-runner/02 | review-aborted | 38s | - | [02.log](02.log) [02-review.log](02-review.log) |' \
    || { echo "$result"; false; }
}

@test "format_summary_md — attempt_count=1 omits the attempts suffix" {
  # When attempt_count is present but equals 1, no suffix is appended.
  input='afk-runner|01|afk-runner/01|dispatch-aborted|12||1'
  result="$(printf '%s\n' "$input" | format_summary_md \
    afk-runner 20260506-091245 09:12:45 09:25:33 ended queue-empty)"

  echo "$result" | grep -qF '| afk-runner/01 | dispatch-aborted | 12s |' \
    || { echo "$result"; false; }
  ! echo "$result" | grep -q 'attempts' || { echo "$result"; false; }
}

@test "format_summary_md — attempt_count > 1 appends the attempts suffix" {
  input='afk-runner|01|afk-runner/01|dispatch-aborted|12||2'
  result="$(printf '%s\n' "$input" | format_summary_md \
    afk-runner 20260506-091245 09:12:45 09:25:33 ended queue-empty)"

  echo "$result" | grep -qF '| afk-runner/01 | dispatch-aborted (2 attempts) | 12s | - | [01.log](01.log) |' \
    || { echo "$result"; false; }
}

@test "format_summary_md — propagated dispatch shows indicator column" {
  input='afk-runner|01|afk-runner/01|done|42|y||propagated'
  result="$(printf '%s\n' "$input" | format_summary_md \
    afk-runner 20260506-091245 09:12:45 09:25:33 ended queue-empty)"

  echo "$result" | grep -qF '| afk-runner/01 | done | 42s | propagated | [01.log](01.log)' \
    || { echo "$result"; false; }
  # No end-of-run parked section — dispatch was propagated, not parked.
  ! echo "$result" | grep -q 'Unpulled parked work' || { echo "$result"; false; }
}

@test "format_summary_md — parked dispatch shows indicator column and end-of-run section" {
  input='afk-runner|01|afk-runner/01|done|42|y||parked → runner/afk-runner'
  result="$(printf '%s\n' "$input" | format_summary_md \
    afk-runner 20260506-091245 09:12:45 09:25:33 ended queue-empty)"

  echo "$result" | grep -qF '| afk-runner/01 | done | 42s | parked → runner/afk-runner | [01.log](01.log)' \
    || { echo "$result"; false; }
  # End-of-run section appears.
  echo "$result" | grep -q '## Unpulled parked work' || { echo "$result"; false; }
  echo "$result" | grep -q '(1 dispatch).*git pull runner afk-runner' \
    || { echo "$result"; false; }
}

@test "format_summary_md — multiple parked dispatches counted per feature" {
  input='afk-runner|01|afk-runner/01|done|42|y||parked → runner/afk-runner
afk-runner|02|afk-runner/02|in-review|30|||parked → runner/afk-runner'
  result="$(printf '%s\n' "$input" | format_summary_md \
    afk-runner 20260506-091245 09:12:45 09:25:33 ended queue-empty)"

  echo "$result" | grep -q '## Unpulled parked work' || { echo "$result"; false; }
  echo "$result" | grep -q '(2 dispatches).*git pull runner afk-runner' \
    || { echo "$result"; false; }
}

@test "format_summary_md — no parked section when all dispatches propagated" {
  input='afk-runner|01|afk-runner/01|done|42|y||propagated
afk-runner|02|afk-runner/02|FAIL|5|||'
  result="$(printf '%s\n' "$input" | format_summary_md \
    afk-runner 20260506-091245 09:12:45 09:25:33 ended queue-empty)"

  ! echo "$result" | grep -q 'Unpulled parked work' || { echo "$result"; false; }
}

# === format_parked_ledger — pure aggregator ================================
#
# Pure function that reads dispatch records and emits the "## Unpulled
# parked work" section for SUMMARY.md. Called by `format_summary_md` and
# `format_multi_feature_summary_md`; emits nothing when no dispatch has
# propagation == parked.
#
# Input record schema:
#   feature|nn|ref|label|duration|review_present|attempt_count|propagation
# The function only cares about fields 1 (feature) and 8 (propagation).

@test "format_parked_ledger — empty input emits nothing" {
  result="$(printf '' | format_parked_ledger)"
  [ -z "$result" ]
}

@test "format_parked_ledger — one parked dispatch: single feature entry" {
  input='afk-runner|01|afk-runner/01|done|42|y|1|parked → runner/afk-runner'
  result="$(printf '%s\n' "$input" | format_parked_ledger)"

  echo "$result" | grep -q '## Unpulled parked work' || { echo "$result"; false; }
  echo "$result" | grep -q 'afk-runner.*1 dispatch.*git pull runner afk-runner' \
    || { echo "$result"; false; }
}

@test "format_parked_ledger — multiple parked dispatches same feature: count aggregated" {
  input='afk-runner|01|afk-runner/01|done|42|y|1|parked → runner/afk-runner
afk-runner|02|afk-runner/02|done|31||1|parked → runner/afk-runner'
  result="$(printf '%s\n' "$input" | format_parked_ledger)"

  echo "$result" | grep -q '## Unpulled parked work' || { echo "$result"; false; }
  echo "$result" | grep -q 'afk-runner.*2 dispatches.*git pull runner afk-runner' \
    || { echo "$result"; false; }
  # Only one feature entry.
  count="$(echo "$result" | grep -c 'afk-runner')"
  [ "$count" -eq 1 ]
}

@test "format_parked_ledger — multiple parked dispatches across features: grouped per feature" {
  input='afk-runner|01|afk-runner/01|done|42|y|1|parked → runner/afk-runner
other-feat|01|other-feat/01|done|13||1|parked → runner/other-feat
afk-runner|02|afk-runner/02|in-review|20||1|parked → runner/afk-runner'
  result="$(printf '%s\n' "$input" | format_parked_ledger)"

  echo "$result" | grep -q '## Unpulled parked work' || { echo "$result"; false; }
  echo "$result" | grep -q 'afk-runner.*2 dispatches.*git pull runner afk-runner' \
    || { echo "$result"; false; }
  echo "$result" | grep -q 'other-feat.*1 dispatch.*git pull runner other-feat' \
    || { echo "$result"; false; }
}

@test "format_parked_ledger — propagated-only records emit nothing" {
  input='afk-runner|01|afk-runner/01|done|42|y|1|propagated
other-feat|01|other-feat/01|FAIL|5||1|'
  result="$(printf '%s\n' "$input" | format_parked_ledger)"
  [ -z "$result" ]
}

@test "format_parked_ledger — features emitted in encounter (first-sighting) order" {
  # Regression: `for (f in parked)` iterates awk associative arrays in
  # implementation-defined (often hash-bucket) order. Features must appear in
  # the same order as the per-feature drained sections above the ledger, which
  # is encounter order (the order features first appear in the input stream).
  input='beta-feat|01|beta-feat/01|done|10|y|1|parked → runner/beta-feat
alpha-feat|01|alpha-feat/01|done|20|y|1|parked → runner/alpha-feat
gamma-feat|01|gamma-feat/01|done|30|y|1|parked → runner/gamma-feat
beta-feat|02|beta-feat/02|done|11|y|1|parked → runner/beta-feat'
  result="$(printf '%s\n' "$input" | format_parked_ledger)"

  # Extract the sequence of feature names from the ledger lines.
  seq="$(echo "$result" | grep -o '\*\*[^*]*\*\*' | tr -d '*')"
  expected="$(printf 'beta-feat\nalpha-feat\ngamma-feat')"
  [ "$seq" = "$expected" ] || {
    echo "expected order: beta-feat, alpha-feat, gamma-feat"
    echo "got: $seq"
    false
  }
}

@test "format_preflight_summary_md — names the failing invariant" {
  result="$(format_preflight_summary_md afk-runner 20260506-091245 09:12:45 09:12:46 docker-daemon)"
  echo "$result" | grep -q '^# AFK runner — afk-runner$' || { echo "$result"; false; }
  echo "$result" | grep -q -- '- Run: 20260506-091245.*started 09:12:45.*aborted 09:12:46' || { echo "$result"; false; }
  echo "$result" | grep -q -- '- Stop reason: preflight-abort: docker-daemon$' || { echo "$result"; false; }
  echo "$result" | grep -q 'invariant `docker-daemon` failed' || { echo "$result"; false; }
}

@test "format_preflight_summary_md — feature undetermined falls back to placeholder" {
  result="$(format_preflight_summary_md '' 20260506-091245 09:12:45 09:12:46 feature-determinable)"
  echo "$result" | grep -q '^# AFK runner — (undetermined)$' || { echo "$result"; false; }
  echo "$result" | grep -q -- '- Stop reason: preflight-abort: feature-determinable$' || false
}

@test "dispatch_one — classifier failure with no committed change skips propagation" {
  # Genuine technical failure: the container died before any commit
  # landed. The runner-checkout's HEAD is unchanged from host's tip, so
  # there's nothing to propagate. The new propagation rule respects this
  # by checking the runner-checkout's HEAD delta — not the classifier
  # verdict — to decide whether to fast-forward.
  setup_dispatch_one_test

  # Override snapshots so post-status doesn't flip → classifier says failure.
  echo "pre" >"$TEST_SNAPSHOT_PHASE"
  take_snapshot() {
    local phase
    phase="$(cat "$TEST_SNAPSHOT_PHASE")"
    if [ "$phase" = "pre" ]; then
      echo "post" >"$TEST_SNAPSHOT_PHASE"
      printf '{"feature":"f","issues":[{"ref":"f/01","nn":"01","status":"ready-for-agent","category":"enhancement","type":"AFK","blocked_by":[],"eligible":true}]}'
    else
      # Status didn't move — classifier should call this failure.
      printf '{"feature":"f","issues":[{"ref":"f/01","nn":"01","status":"ready-for-agent","category":"enhancement","type":"AFK","blocked_by":[],"eligible":true}]}'
    fi
  }

  # Simulate a container that died before any commit landed.
  run_dispatch_container() {
    return 1
  }

  TEST_PROPAGATE_CALLED="$BATS_TEST_TMPDIR/prop-called"
  : >"$TEST_PROPAGATE_CALLED"
  propagate_feature() {
    echo "called" >>"$TEST_PROPAGATE_CALLED"
    return 0
  }

  set +e
  dispatch_one "f" "01" "$TEST_RUN_DIR"
  local rc=$?
  set -e

  [ "$rc" -ne 0 ]
  # No committed change → nothing to propagate, runner does not call
  # propagate_feature at all.
  [ ! -s "$TEST_PROPAGATE_CALLED" ]
}

# === dispatch_one — propagate-on-any-commit rule ==========================
#
# The implement-stage propagation gate is the runner-checkout having any
# committed change ahead of the host's branch tip — not the classifier
# verdict. This lets /implement's documented bail behavior (status stays at
# `ready-for-agent`, `tracker:` comment-only commit) reach the host before
# the next iteration's `ensure_runner_checkout` resets the checkout, while
# the classifier still records the iteration as a failure (the classifier
# verdict is independent of propagation).

@test "dispatch_one — non-success classifier with committed change still propagates" {
  setup_dispatch_one_test

  # Snapshots: status stays at ready-for-agent → classifier=failure.
  echo "pre" >"$TEST_SNAPSHOT_PHASE"
  take_snapshot() {
    local phase
    phase="$(cat "$TEST_SNAPSHOT_PHASE")"
    if [ "$phase" = "pre" ]; then
      echo "post" >"$TEST_SNAPSHOT_PHASE"
    fi
    printf '{"feature":"f","issues":[{"ref":"f/01","nn":"01","status":"ready-for-agent","category":"enhancement","type":"AFK","blocked_by":[],"eligible":true}]}'
  }

  # Mirror an /implement bail: comment-only `tracker:` commit lands.
  run_dispatch_container() {
    git -C "$HOST_CHECKOUT" -c user.email=t@t -c user.name=t \
      commit --allow-empty --quiet -m "tracker: f/01 bail comment"
    return 0
  }

  TEST_PROPAGATE_CALLED="$BATS_TEST_TMPDIR/prop-called"
  : >"$TEST_PROPAGATE_CALLED"
  propagate_feature() {
    echo "called" >>"$TEST_PROPAGATE_CALLED"
    return 0
  }

  RUN_DISPATCHES=()
  set +e
  dispatch_one "f" "01" "$TEST_RUN_DIR"
  local rc=$?
  set -e

  # Iteration is a failure (classifier verdict is independent of
  # propagation), but the bail comment must reach the host.
  [ "$rc" -ne 0 ]
  [ "$(wc -l <"$TEST_PROPAGATE_CALLED" | tr -d ' ')" = "1" ]
  [ "${#RUN_DISPATCHES[@]}" -eq 1 ]
  [[ "${RUN_DISPATCHES[0]}" == "f|01|f/01|FAIL|"* ]]
}

@test "dispatch_one — non-success classifier with commit but propagation halt records failure" {
  setup_dispatch_one_test

  echo "pre" >"$TEST_SNAPSHOT_PHASE"
  take_snapshot() {
    local phase
    phase="$(cat "$TEST_SNAPSHOT_PHASE")"
    if [ "$phase" = "pre" ]; then
      echo "post" >"$TEST_SNAPSHOT_PHASE"
    fi
    printf '{"feature":"f","issues":[{"ref":"f/01","nn":"01","status":"ready-for-agent","category":"enhancement","type":"AFK","blocked_by":[],"eligible":true}]}'
  }

  run_dispatch_container() {
    git -C "$HOST_CHECKOUT" -c user.email=t@t -c user.name=t \
      commit --allow-empty --quiet -m "tracker: f/01 bail comment"
    return 0
  }

  TEST_PROPAGATE_CALLED="$BATS_TEST_TMPDIR/prop-called"
  : >"$TEST_PROPAGATE_CALLED"
  propagate_feature() {
    echo "called" >>"$TEST_PROPAGATE_CALLED"
    return 1
  }

  RUN_DISPATCHES=()
  RUN_STOP_REASON=""
  set +e
  dispatch_one "f" "01" "$TEST_RUN_DIR"
  local rc=$?
  set -e

  [ "$rc" -ne 0 ]
  [ "$RUN_STOP_REASON" = "propagation-error" ]
  # Propagation was attempted (and halted) — the runner doesn't silently
  # swallow the halt just because the classifier already said failure.
  [ "$(wc -l <"$TEST_PROPAGATE_CALLED" | tr -d ' ')" = "1" ]
  [ "${#RUN_DISPATCHES[@]}" -eq 1 ]
  [[ "${RUN_DISPATCHES[0]}" == "f|01|f/01|FAIL|"* ]]
}

# === run_loop — end-to-end output capture ==================================
#
# Drive run_loop with the existing mocked harness, plus the new run-dir
# globals + finalize_run, and assert the AC outputs land:
#   - per-run dir exists
#   - dispatch records are accumulated via record_dispatch
#   - finalize_run writes SUMMARY.md with the expected shape
#   - the end-of-run table goes to stdout

setup_loop_output_test() {
  setup_loop_test
  # Layer record_dispatch on top of the loop's mock so dispatch records
  # make it into RUN_DISPATCHES.
  dispatch_one() {
    local feature="$1" nn="$2"
    local ref="$feature/$nn"
    echo "$ref" >>"$TEST_DISPATCHED_FILE"
    local rest
    rest="$(tail -n +2 "$TEST_QUEUE_FILE" 2>/dev/null || true)"
    printf '%s\n' "$rest" >"$TEST_QUEUE_FILE"
    [ -s "$TEST_QUEUE_FILE" ] || : >"$TEST_QUEUE_FILE"
    local outcome
    outcome="$(head -n 1 "$TEST_OUTCOMES_FILE" 2>/dev/null || true)"
    if [ -n "$outcome" ]; then
      local rest_o
      rest_o="$(tail -n +2 "$TEST_OUTCOMES_FILE" 2>/dev/null || true)"
      printf '%s\n' "$rest_o" >"$TEST_OUTCOMES_FILE"
      [ -s "$TEST_OUTCOMES_FILE" ] || : >"$TEST_OUTCOMES_FILE"
    else
      outcome="success"
    fi
    local label
    if [ "$outcome" = "success" ]; then label="in-review"; else label="FAIL"; fi
    record_dispatch "$feature" "$nn" "$ref" "$label" 1
    [ "$outcome" = "success" ]
  }

  RUN_TS="20260506-091245"
  RUN_START_CLOCK="09:12:45"
  RUN_FEATURE="f"
  RUN_DIR="$BATS_TEST_TMPDIR/run-out"
  mkdir -p "$RUN_DIR"
  RUN_DISPATCHES=()
  RUN_STOP_REASON=""
  RUN_PREFLIGHT_INVARIANT=""
}

@test "run_loop + finalize_run — drains queue, writes SUMMARY.md, prints stdout table" {
  setup_loop_output_test
  plant_queue 01 02

  run bash -c '
    source "'"$RUNNER_SCRIPT"'"
    '"$(declare -f setup_loop_test setup_loop_output_test plant_queue plant_outcomes)"'
    setup_loop_output_test
    plant_queue 01 02
    run_loop
    finalize_run
  '
  assert_success

  # End-of-run table on stdout — header + 2 rows + stop reason. Row-shape
  # regexes anchor `ref` to the issue column and `duration` to its own
  # column so a future field-index drift can't slip through a partial match
  # (e.g. `f/01` leaking into the duration column as `f/01s`).
  assert_output --partial "issue"
  assert_output --partial "outcome"
  assert_output --partial "duration"
  assert_output --regexp 'f/01 +in-review +1s'
  assert_output --regexp 'f/02 +in-review +1s'
  assert_output --partial "stop reason: queue-empty"
}

@test "finalize_run — writes SUMMARY.md with feature, run line, stop reason, dispatch rows" {
  setup_loop_output_test

  RUN_DIR="$BATS_TEST_TMPDIR/run-summary"
  mkdir -p "$RUN_DIR"
  RUN_DISPATCHES=("f|01|f/01|in-review|42" "f|02|f/02|FAIL|18")
  RUN_STOP_REASON="queue-empty"
  RUNNER_INTERRUPTED=0

  # finalize_run reads $? at entry; ensure rc=0 going in.
  ( finalize_run ) || true

  [ -f "$RUN_DIR/SUMMARY.md" ]
  grep -q '^# AFK runner — f$' "$RUN_DIR/SUMMARY.md"
  grep -q -- '- Run: 20260506-091245.*started 09:12:45.*ended ' "$RUN_DIR/SUMMARY.md"
  grep -q -- '- Stop reason: queue-empty$' "$RUN_DIR/SUMMARY.md"
  grep -qF '| f/01 | in-review | 42s | - | [01.log](01.log) |' "$RUN_DIR/SUMMARY.md"
  grep -qF '| f/02 | FAIL | 18s | - | [02.log](02.log) |' "$RUN_DIR/SUMMARY.md"
}

@test "finalize_run — pre-flight abort writes a SUMMARY.md naming the invariant" {
  setup_loop_output_test
  RUN_DIR="$BATS_TEST_TMPDIR/run-preflight"
  mkdir -p "$RUN_DIR"
  RUN_DISPATCHES=()
  RUN_PREFLIGHT_INVARIANT="docker-daemon"

  ( finalize_run ) || true

  [ -f "$RUN_DIR/SUMMARY.md" ]
  grep -q '^# AFK runner — f$' "$RUN_DIR/SUMMARY.md"
  grep -q -- '- Stop reason: preflight-abort: docker-daemon$' "$RUN_DIR/SUMMARY.md"
  grep -q 'invariant `docker-daemon` failed' "$RUN_DIR/SUMMARY.md"
}

@test "start_runner_log_capture + stop — runner.log captures the trailing burst without truncation" {
  # Drives a subshell that turns on log capture, emits a heavy stdout
  # burst (the kind finalize_run produces), and then exits. Without
  # stop_runner_log_capture the parent shell would race the tee child
  # and runner.log could land truncated. Ten thousand lines is enough
  # to cross typical pipe-buffer thresholds (64 KiB) on macOS / Linux.
  RUN_DIR="$BATS_TEST_TMPDIR/log-flush"
  mkdir -p "$RUN_DIR"

  bash -c '
    set -e
    source "'"$RUNNER_SCRIPT"'"
    RUN_DIR="'"$RUN_DIR"'"
    start_runner_log_capture
    for i in $(seq 1 10000); do
      printf "burst %d\n" "$i"
    done
    stop_runner_log_capture
  '

  [ -f "$RUN_DIR/runner.log" ]
  local lines
  lines="$(wc -l <"$RUN_DIR/runner.log" | tr -d ' ')"
  [ "$lines" = "10000" ] || { echo "expected 10000 lines, got $lines"; tail -3 "$RUN_DIR/runner.log"; false; }
  # Last line must be the final burst — proves no tail was dropped.
  [ "$(tail -n 1 "$RUN_DIR/runner.log")" = "burst 10000" ]
  # Fifo cleaned up.
  [ ! -e "$RUN_DIR/.runner.log.fifo" ]
}

@test "finalize_run — pre-flight SIGINT produces non-unknown stop reason in SUMMARY.md" {
  # Regression for: SIGINT during preflight had no INT/TERM trap installed,
  # so bash used the default (exit). finalize_run fired with RUN_STOP_REASON
  # empty and wrote "Stop reason: unknown". The fix installs a pre-flight
  # handler that sets RUN_STOP_REASON="interrupted-during-preflight" before
  # exiting. This test drives finalize_run with those exact globals to verify
  # the correct value lands in SUMMARY.md.
  setup_loop_output_test
  RUN_DIR="$BATS_TEST_TMPDIR/run-preflight-int"
  mkdir -p "$RUN_DIR"
  RUN_DISPATCHES=()
  RUN_PREFLIGHT_INVARIANT=""
  RUN_STOP_REASON="interrupted-during-preflight"
  RUNNER_INTERRUPTED=0

  ( finalize_run ) || true

  [ -f "$RUN_DIR/SUMMARY.md" ]
  grep -q -- '- Stop reason: interrupted-during-preflight$' "$RUN_DIR/SUMMARY.md"
  # Must NOT fall back to "unknown".
  ! grep -q 'unknown' "$RUN_DIR/SUMMARY.md"
}

# === abort-flag mechanism =================================================
#
# Runner-private abort flags at .runner-state/aborted/<feature>/<NN>. Written
# when a dispatch fails in a way that leaves the issue stuck in an eligible
# state — preventing infinite re-dispatch across runs. The maintainer removes
# the flag with `rm` to re-include the ref.
#
# Flag format (plain text):
#   type: technical
#   dispatch: implement|gate
#   at: <ISO-8601 UTC>
#   exit: <container exit code>
#   log: <relative path to dispatch log>

# Helper shared across abort-flag tests.
setup_abort_test() {
  setup_dispatch_one_test
  HOST_ABORT_DIR="$BATS_TEST_TMPDIR/aborted"
  HOST_REPO="$HOST_CHECKOUT"   # write_abort_flag strips HOST_REPO prefix from log path
}

@test "write_abort_flag — creates flag file with documented fields" {
  setup_abort_test
  local flag_dir="$HOST_ABORT_DIR/f"
  local flag_file="$flag_dir/01"
  local log_path="$HOST_REPO/.runner-state/runs/20260507-141233/01.log"

  write_abort_flag "f" "01" "implement" 137 "$log_path"

  [ -f "$flag_file" ]
  grep -q '^type: technical$' "$flag_file"
  grep -q '^dispatch: implement$' "$flag_file"
  grep -q '^at: ' "$flag_file"
  grep -q '^exit: 137$' "$flag_file"
  grep -q '^log: ' "$flag_file"
}

@test "write_abort_flag — gate dispatch stores dispatch: gate" {
  setup_abort_test
  local flag_file="$HOST_ABORT_DIR/f/01"
  write_abort_flag "f" "01" "gate" 0 "$HOST_REPO/.runner-state/runs/ts/01-review.log"
  grep -q '^dispatch: gate$' "$flag_file"
}

@test "write_abort_flag — overwrite-on-repeat replaces prior content" {
  setup_abort_test
  local flag_file="$HOST_ABORT_DIR/f/01"
  local log="$HOST_REPO/.runner-state/runs/ts/01.log"

  write_abort_flag "f" "01" "implement" 137 "$log"
  local first_at
  first_at="$(grep '^at:' "$flag_file")"

  # Small sleep so timestamp differs.
  sleep 1
  write_abort_flag "f" "01" "implement" 1 "$log"
  local second_at
  second_at="$(grep '^at:' "$flag_file")"

  grep -q '^exit: 1$' "$flag_file"
  # at field changed, not a stale write.
  [ "$first_at" != "$second_at" ]
}

@test "write_abort_flag — log path is repo-relative" {
  setup_abort_test
  local flag_file="$HOST_ABORT_DIR/f/01"
  write_abort_flag "f" "01" "implement" 0 "$HOST_REPO/.runner-state/runs/ts/01.log"
  grep -q '^log: .runner-state/' "$flag_file"
  # Must not contain the absolute host-repo prefix.
  local log_line
  log_line="$(grep '^log:' "$flag_file")"
  [[ "$log_line" != *"$HOST_REPO"* ]]
}

@test "write_abort_flag — type: transport written when 6th arg is transport" {
  setup_abort_test
  local flag_file="$HOST_ABORT_DIR/f/01"
  write_abort_flag "f" "01" "gate" 1 "$HOST_REPO/.runner-state/runs/ts/01-review.log" "transport"
  grep -q '^type: transport$' "$flag_file"
}

@test "dispatch_one — implement-stuck: classifier failure + eligible post-status writes abort flag" {
  setup_abort_test
  # Snapshots: status stays at ready-for-agent (eligible=true) → classifier=failure.
  echo "pre" >"$TEST_SNAPSHOT_PHASE"
  take_snapshot() {
    local phase
    phase="$(cat "$TEST_SNAPSHOT_PHASE")"
    if [ "$phase" = "pre" ]; then
      echo "post" >"$TEST_SNAPSHOT_PHASE"
    fi
    printf '{"feature":"f","issues":[{"ref":"f/01","nn":"01","status":"ready-for-agent","category":"enhancement","type":"AFK","blocked_by":[],"eligible":true}]}'
  }
  run_dispatch_container() { return 0; }
  propagate_feature() { return 0; }

  RUN_DISPATCHES=()
  set +e
  dispatch_one "f" "01" "$TEST_RUN_DIR"
  set -e

  [ -f "$HOST_ABORT_DIR/f/01" ]
  grep -q '^dispatch: implement$' "$HOST_ABORT_DIR/f/01"
}

@test "dispatch_one — non-eligible post-status (needs-info): no abort flag written" {
  setup_abort_test
  # Status flips to needs-info (non-eligible) → classifier=failure, but no flag.
  echo "pre" >"$TEST_SNAPSHOT_PHASE"
  take_snapshot() {
    local phase
    phase="$(cat "$TEST_SNAPSHOT_PHASE")"
    if [ "$phase" = "pre" ]; then
      echo "post" >"$TEST_SNAPSHOT_PHASE"
      printf '{"feature":"f","issues":[{"ref":"f/01","nn":"01","status":"ready-for-agent","category":"enhancement","type":"AFK","blocked_by":[],"eligible":true}]}'
    else
      printf '{"feature":"f","issues":[{"ref":"f/01","nn":"01","status":"needs-info","category":"enhancement","type":"AFK","blocked_by":[],"eligible":false}]}'
    fi
  }
  run_dispatch_container() {
    git -C "$HOST_CHECKOUT" -c user.email=t@t -c user.name=t \
      commit --allow-empty --quiet -m "tracker: f/01 bail"
    return 0
  }
  propagate_feature() { return 0; }

  RUN_DISPATCHES=()
  set +e
  dispatch_one "f" "01" "$TEST_RUN_DIR"
  set -e

  [ ! -f "$HOST_ABORT_DIR/f/01" ]
}

@test "dispatch_one — gate-failed writes abort flag with dispatch: gate" {
  setup_abort_test
  install_afk_snapshots in-review

  propagate_feature() { return 0; }
  run_gate_container() {
    # Non-transport gate failure (e.g. OOM kill). The log must carry a
    # non-whitespace line so is_transport_crash doesn't misclassify the empty
    # log as a transport crash and flip the verdict to review-aborted.
    echo "Killed" >"$2"
    return 137
  }

  RUN_DISPATCHES=()
  set +e
  dispatch_one "f" "01" "$TEST_RUN_DIR"
  set -e

  [ -f "$HOST_ABORT_DIR/f/01" ]
  grep -q '^dispatch: gate$' "$HOST_ABORT_DIR/f/01"
  # Pin the gate-failed (non-transport) verdict explicitly — without these the
  # test passes silently against the review-aborted path too.
  grep -q '^type: technical$' "$HOST_ABORT_DIR/f/01"
  [[ "${RUN_DISPATCHES[0]}" == *"|gate-failed|"* ]]
}

@test "dispatch_one — RUNNER_INTERRUPTED during implement-dispatch suppresses abort flag" {
  # Simulates Ctrl-C arriving while the implement container is running. The
  # signal trap sets RUNNER_INTERRUPTED=1 and kills the container; the
  # container exits non-zero with the issue still eligible. write_abort_flag
  # must be suppressed — the operator's intent is to stop, not mark the issue
  # as stuck; the next run re-dispatches normally.
  setup_abort_test
  echo "pre" >"$TEST_SNAPSHOT_PHASE"
  take_snapshot() {
    local phase
    phase="$(cat "$TEST_SNAPSHOT_PHASE")"
    if [ "$phase" = "pre" ]; then
      echo "post" >"$TEST_SNAPSHOT_PHASE"
    fi
    printf '{"feature":"f","issues":[{"ref":"f/01","nn":"01","status":"ready-for-agent","category":"enhancement","type":"AFK","blocked_by":[],"eligible":true}]}'
  }
  # Simulate the signal trap firing: RUNNER_INTERRUPTED is set and the
  # container exits with SIGTERM's conventional code.
  run_dispatch_container() {
    RUNNER_INTERRUPTED=1
    return 143
  }
  propagate_feature() { return 0; }

  RUNNER_INTERRUPTED=0
  RUN_DISPATCHES=()
  set +e
  dispatch_one "f" "01" "$TEST_RUN_DIR"
  set -e

  [ ! -f "$HOST_ABORT_DIR/f/01" ]
}

@test "dispatch_one — transport crash on implement sets dispatch-aborted and transport abort flag" {
  # Behavioural guarantee for AC #8: is_transport_crash fires on the implement
  # log, classify_outcome returns dispatch-aborted, and write_abort_flag records
  # type: transport. The dispatch record carries dispatch-aborted, not FAIL.
  setup_abort_test
  # Both snapshots return ready-for-agent so classify_outcome sees a transport
  # crash on the non-success path.
  take_snapshot() {
    printf '{"feature":"f","issues":[{"ref":"f/01","nn":"01","status":"ready-for-agent","category":"enhancement","type":"AFK","blocked_by":[],"eligible":true}]}'
  }
  run_dispatch_container() {
    # Transport-signature log + nonzero exit — triggers is_transport_crash.
    echo "API Error: 503 " >"$2"
    return 1
  }
  propagate_feature() { return 0; }

  RUNNER_INTERRUPTED=0
  RUN_DISPATCHES=()
  set +e
  dispatch_one "f" "01" "$TEST_RUN_DIR"
  set -e

  # Dispatch record carries dispatch-aborted.
  [ "${#RUN_DISPATCHES[@]}" -eq 1 ]
  [[ "${RUN_DISPATCHES[0]}" == *"|dispatch-aborted|"* ]]
  # Abort flag written with type: transport and dispatch: implement.
  [ -f "$HOST_ABORT_DIR/f/01" ]
  grep -q '^type: transport$' "$HOST_ABORT_DIR/f/01"
  grep -q '^dispatch: implement$' "$HOST_ABORT_DIR/f/01"
}

@test "dispatch_one — transport crash on gate sets review-aborted and transport abort flag" {
  # Behavioural guarantee for AC #8 (gate path): is_transport_crash fires on
  # the review log, classify_gate_outcome returns review-aborted, and
  # write_abort_flag records type: transport. The dispatch record carries
  # review-aborted, not gate-failed.
  setup_abort_test
  install_afk_snapshots in-review
  propagate_feature() { return 0; }
  run_gate_container() {
    # Transport-signature log + nonzero exit — triggers is_transport_crash.
    echo "API Error: 503 " >"$2"
    return 1
  }

  RUNNER_INTERRUPTED=0
  RUN_DISPATCHES=()
  set +e
  dispatch_one "f" "01" "$TEST_RUN_DIR"
  set -e

  # Dispatch record carries review-aborted (not gate-failed).
  [ "${#RUN_DISPATCHES[@]}" -eq 1 ]
  [[ "${RUN_DISPATCHES[0]}" == *"|review-aborted|"* ]]
  # Abort flag written with type: transport and dispatch: gate.
  [ -f "$HOST_ABORT_DIR/f/01" ]
  grep -q '^type: transport$' "$HOST_ABORT_DIR/f/01"
  grep -q '^dispatch: gate$' "$HOST_ABORT_DIR/f/01"
}

@test "run_loop — aborted ref is skipped with rm recipe in stdout" {
  setup_loop_test
  HOST_ABORT_DIR="$BATS_TEST_TMPDIR/aborted"
  plant_queue 01 02

  # Override take_snapshot to return ALL remaining queue items as eligible
  # so the abort filter can skip 01 and still find 02.
  take_snapshot() {
    local issues="" nn
    while IFS= read -r nn; do
      [ -z "$nn" ] && continue
      [ -n "$issues" ] && issues="$issues,"
      issues="${issues}{\"ref\":\"f/$nn\",\"nn\":\"$nn\",\"status\":\"ready-for-agent\",\"category\":\"enhancement\",\"type\":\"AFK\",\"blocked_by\":[],\"eligible\":true}"
    done <"$TEST_QUEUE_FILE"
    printf '{"feature":"f","issues":[%s]}' "$issues"
  }

  # Override dispatch_one to pop the DISPATCHED nn from the queue (not the
  # head), so skipping 01 doesn't cause 02 to be dispatched twice.
  dispatch_one() {
    local feature="$1" nn="$2"
    echo "$feature/$nn" >>"$TEST_DISPATCHED_FILE"
    local remaining
    remaining="$(grep -v "^${nn}$" "$TEST_QUEUE_FILE" 2>/dev/null || true)"
    printf '%s\n' "$remaining" >"$TEST_QUEUE_FILE"
    [ -s "$TEST_QUEUE_FILE" ] || : >"$TEST_QUEUE_FILE"
    return 0
  }

  # Plant an abort flag for f/01.
  mkdir -p "$HOST_ABORT_DIR/f"
  printf 'type: technical\ndispatch: implement\nat: 2026-05-07T10:00:00Z\nexit: 0\nlog: .runner-state/runs/ts/01.log\n' \
    >"$HOST_ABORT_DIR/f/01"

  run run_loop
  assert_success
  # f/01 was skipped; f/02 dispatched.
  [ "$(dispatched_nth 1)" = "f/02" ]
  [ "$(dispatched_count)" = "1" ]
  # Runner emitted a skip line mentioning f/01 and the rm recipe.
  assert_output --partial "skipping aborted f/01"
  assert_output --partial "rm $HOST_ABORT_DIR/f/01"
}

@test "run_loop — all eligible refs aborted → queue empty" {
  setup_loop_test
  HOST_ABORT_DIR="$BATS_TEST_TMPDIR/aborted"
  plant_queue 01

  mkdir -p "$HOST_ABORT_DIR/f"
  printf 'type: technical\ndispatch: implement\nat: 2026-05-07T10:00:00Z\nexit: 0\nlog: .runner-state/runs/ts/01.log\n' \
    >"$HOST_ABORT_DIR/f/01"

  run run_loop
  assert_success
  assert_output --partial "queue empty"
  [ "$(dispatched_count)" = "0" ]
}

@test "run_loop — rm abort flag re-includes ref on next iteration" {
  setup_loop_test
  HOST_ABORT_DIR="$BATS_TEST_TMPDIR/aborted"
  plant_queue 01

  mkdir -p "$HOST_ABORT_DIR/f"
  printf 'type: technical\ndispatch: implement\nat: 2026-05-07T10:00:00Z\nexit: 0\nlog: .runner-state/runs/ts/01.log\n' \
    >"$HOST_ABORT_DIR/f/01"

  # Override dispatch_one to remove the abort flag and push 01 back onto
  # the queue so the loop sees it as eligible again on the next iteration.
  TEST_ITER_FILE="$BATS_TEST_TMPDIR/iter"
  echo 0 >"$TEST_ITER_FILE"
  dispatch_one() {
    local feature="$1" nn="$2"
    echo "$feature/$nn" >>"$TEST_DISPATCHED_FILE"
    local iter
    iter="$(cat "$TEST_ITER_FILE")"
    echo $((iter + 1)) >"$TEST_ITER_FILE"
    local rest
    rest="$(tail -n +2 "$TEST_QUEUE_FILE" 2>/dev/null || true)"
    printf '%s\n' "$rest" >"$TEST_QUEUE_FILE"
    [ -s "$TEST_QUEUE_FILE" ] || : >"$TEST_QUEUE_FILE"
    return 0
  }

  # Start with the flag present — first pass: f/01 should be skipped.
  # Then remove the flag and plant 01 again.
  # (This test drives a single loop iteration and verifies skip happens,
  #  then simulates removal by running run_loop a second time without the flag.)

  # First run: f/01 is aborted → queue empty.
  run run_loop
  assert_success
  assert_output --partial "queue empty"
  [ "$(dispatched_count)" = "0" ]

  # Remove the flag and run again.
  rm "$HOST_ABORT_DIR/f/01"
  plant_queue 01
  : >"$TEST_DISPATCHED_FILE"

  run run_loop
  assert_success
  assert_output --partial "queue empty"
  [ "$(dispatched_nth 1)" = "f/01" ]
  [ "$(dispatched_count)" = "1" ]
}

@test "finalize_run — interrupted state surfaces in SUMMARY.md run line" {
  setup_loop_output_test
  RUN_DIR="$BATS_TEST_TMPDIR/run-interrupted"
  mkdir -p "$RUN_DIR"
  RUN_DISPATCHES=("f/01|in-review|3")
  RUN_STOP_REASON="interrupted"
  RUNNER_INTERRUPTED=1

  ( finalize_run ) || true

  [ -f "$RUN_DIR/SUMMARY.md" ]
  grep -q -- '- Run: 20260506-091245.*started 09:12:45.*interrupted ' "$RUN_DIR/SUMMARY.md"
  grep -q -- '- Stop reason: interrupted$' "$RUN_DIR/SUMMARY.md"
}

# === propagate_feature <branch> — parking-ref publish + best-effort ff ======
#
# propagate_feature always writes to refs/remotes/runner/<branch> (step 1),
# then attempts refs/heads/<branch> fast-forward without --update-head-ok
# (step 2). Step 2 refusal (HEAD-on-target or non-ff) is parked-only —
# not an error. Only step 1 failure is an error (return 1).
#
# M2 classifier cases verified against a real host + runner-checkout pair:
#   propagated-to-host — both steps succeed
#   parked-only (HEAD-on-target) — step 1 ok, step 2 refused by git
#   parked-only (non-ff) — step 1 ok, step 2 refused by git
#   error — step 1 fails
#
# All cases use ephemeral git repos created in BATS_TEST_TMPDIR.

setup_propagate_test() {
  HOST_REPO="$BATS_TEST_TMPDIR/prop-host"
  HOST_CHECKOUT="$BATS_TEST_TMPDIR/prop-checkout"
  TARGET_FEATURE="f"

  mkdir -p "$HOST_REPO"
  git -C "$HOST_REPO" init --quiet --initial-branch=f
  git -C "$HOST_REPO" -c user.email=t@t -c user.name=t \
    commit --allow-empty --quiet -m init

  git clone --quiet "$HOST_REPO" "$HOST_CHECKOUT" >&2
  git -C "$HOST_CHECKOUT" checkout --quiet -B f origin/f

  # Register the runner remote to mirror real-world setup
  # (`ensure_runner_remote` does this in pre-flight). `propagate_feature`
  # itself fetches by path (`$HOST_CHECKOUT`), not by remote name, so the
  # named remote is not required for the fetch to work — but its presence
  # matches what a real run looks like.
  git -C "$HOST_REPO" remote add runner "$HOST_CHECKOUT"
}

@test "propagate_feature — propagated-to-host: clean ff advances both host branch and parking ref" {
  setup_propagate_test

  # Runner-checkout advances past host's f tip.
  git -C "$HOST_CHECKOUT" -c user.email=t@t -c user.name=t \
    commit --allow-empty --quiet -m "tracker: f/01 → in-review"

  # Host HEAD is on a different branch so fast-forward succeeds.
  git -C "$HOST_REPO" checkout --quiet -b master

  local host_f_before checkout_tip
  host_f_before="$(git -C "$HOST_REPO" rev-parse f)"
  checkout_tip="$(git -C "$HOST_CHECKOUT" rev-parse HEAD)"

  propagate_feature "f"

  local host_f_after parking_after
  host_f_after="$(git -C "$HOST_REPO" rev-parse f)"
  parking_after="$(git -C "$HOST_REPO" rev-parse refs/remotes/runner/f)"

  # Both host branch and parking ref advance to the runner-checkout tip.
  [ "$host_f_after" = "$checkout_tip" ]
  [ "$parking_after" = "$checkout_tip" ]
  [ "$RUNNER_LAST_PROPAGATION" = "propagated → host" ]
  # host HEAD (master) must not have moved.
  [ "$(git -C "$HOST_REPO" symbolic-ref --short HEAD)" = "master" ]
}

@test "propagate_feature — parked-only (HEAD-on-target): parking ref advances, host branch unchanged" {
  setup_propagate_test

  # Runner-checkout advances; host HEAD stays on f.
  git -C "$HOST_CHECKOUT" -c user.email=t@t -c user.name=t \
    commit --allow-empty --quiet -m "tracker: f/01 → in-review"
  # Host HEAD is already on f (init default) — git fetch f:f will refuse.

  local host_f_before checkout_tip
  host_f_before="$(git -C "$HOST_REPO" rev-parse f)"
  checkout_tip="$(git -C "$HOST_CHECKOUT" rev-parse HEAD)"

  local err_file="$BATS_TEST_TMPDIR/propagate-err.txt"
  propagate_feature "f" 2>"$err_file"

  local host_f_after parking_after
  host_f_after="$(git -C "$HOST_REPO" rev-parse f)"
  parking_after="$(git -C "$HOST_REPO" rev-parse refs/remotes/runner/f)"

  # Parking ref advanced; host branch ref is unchanged (HEAD-on-target).
  [ "$parking_after" = "$checkout_tip" ]
  [ "$host_f_after" = "$host_f_before" ]
  [ "$RUNNER_LAST_PROPAGATION" = "parked → runner/f" ]
  # HEAD-on-target is an expected refusal; no unexpected-error diagnostic.
  ! grep -q 'unexpected step-2' "$err_file" || { cat "$err_file"; false; }
}

@test "propagate_feature — parked-only (non-ff): parking ref advances, host branch unchanged" {
  setup_propagate_test

  # Diverge: runner-checkout gets commit B, host's f gets commit C.
  git -C "$HOST_CHECKOUT" -c user.email=t@t -c user.name=t \
    commit --allow-empty --quiet -m "checkout diverge"
  git -C "$HOST_REPO" -c user.email=t@t -c user.name=t \
    commit --allow-empty --quiet -m "host diverge"

  # Host HEAD on a different branch so HEAD-on-target doesn't apply.
  git -C "$HOST_REPO" checkout --quiet -b master

  local host_f_before checkout_tip
  host_f_before="$(git -C "$HOST_REPO" rev-parse f)"
  checkout_tip="$(git -C "$HOST_CHECKOUT" rev-parse HEAD)"

  local err_file="$BATS_TEST_TMPDIR/propagate-err.txt"
  propagate_feature "f" 2>"$err_file"

  local host_f_after parking_after
  host_f_after="$(git -C "$HOST_REPO" rev-parse f)"
  parking_after="$(git -C "$HOST_REPO" rev-parse refs/remotes/runner/f)"

  # Parking ref advanced to runner-checkout tip; host branch stays at its
  # divergent tip (non-ff refusal).
  [ "$parking_after" = "$checkout_tip" ]
  [ "$host_f_after" = "$host_f_before" ]
  [ "$RUNNER_LAST_PROPAGATION" = "parked → runner/f" ]
  # Non-ff is an expected refusal; no unexpected-error diagnostic.
  ! grep -q 'unexpected step-2' "$err_file" || { cat "$err_file"; false; }
}

@test "propagate_feature — diverged dispatch tip force-updates the parking ref" {
  # Pin that the `+` on the step-1 refspec lets the parking ref move
  # sideways: when a dispatch's tip is not in an ancestor relation with the
  # prior parking-ref tip (e.g. after the maintainer pulled and rebased),
  # the non-fast-forward refspec would refuse without `+` and propagation
  # would error.
  setup_propagate_test

  # Dispatch 1: runner-checkout advances; host stays on f → parked-only.
  git -C "$HOST_CHECKOUT" -c user.email=t@t -c user.name=t \
    commit --allow-empty --quiet -m "dispatch 1 (parked)"
  local d1_tip
  d1_tip="$(git -C "$HOST_CHECKOUT" rev-parse HEAD)"

  propagate_feature "f"
  [ "$RUNNER_LAST_PROPAGATION" = "parked → runner/f" ]
  [ "$(git -C "$HOST_REPO" rev-parse refs/remotes/runner/f)" = "$d1_tip" ]

  # Set up the diverged-tip scenario: reset the runner-checkout back to
  # host's branch tip, then add a fresh commit. The resulting tip is a
  # sibling of the prior parking-ref tip (neither is an ancestor of the
  # other), so a non-`+` refspec would refuse to update the parking ref.
  local host_tip
  host_tip="$(git -C "$HOST_REPO" rev-parse f)"
  git -C "$HOST_CHECKOUT" reset --quiet --hard "$host_tip"

  git -C "$HOST_CHECKOUT" -c user.email=t@t -c user.name=t \
    commit --allow-empty --quiet -m "dispatch 2 (sibling of d1)"
  local d2_tip
  d2_tip="$(git -C "$HOST_CHECKOUT" rev-parse HEAD)"

  # Confirm the diverged-tip precondition.
  ! git -C "$HOST_REPO" merge-base --is-ancestor "$d1_tip" "$d2_tip" 2>/dev/null
  ! git -C "$HOST_REPO" merge-base --is-ancestor "$d2_tip" "$d1_tip" 2>/dev/null

  propagate_feature "f"

  # The parking ref moves to d2_tip and the dispatch is parked, not errored.
  [ "$RUNNER_LAST_PROPAGATION" = "parked → runner/f" ]
  [ "$(git -C "$HOST_REPO" rev-parse refs/remotes/runner/f)" = "$d2_tip" ]
}

@test "propagate_feature — error: parking-ref publish fails, returns 1, RUNNER_LAST_PROPAGATION cleared" {
  setup_propagate_test

  # Runner-checkout advances.
  git -C "$HOST_CHECKOUT" -c user.email=t@t -c user.name=t \
    commit --allow-empty --quiet -m "tracker: f/01 → in-review"

  # Break HOST_CHECKOUT so step-1 fetch (publish to parking ref) fails.
  # propagate_feature uses $HOST_CHECKOUT directly, not a named remote.
  HOST_CHECKOUT="/nonexistent/path"

  # Call directly (not via bats `run`) so that the RUNNER_LAST_PROPAGATION
  # assignment inside propagate_feature survives back to the parent shell.
  RUNNER_LAST_PROPAGATION="stale"
  local err_file="$BATS_TEST_TMPDIR/propagate-err.txt"
  local propagate_rc=0
  propagate_feature "f" >"$err_file" 2>&1 || propagate_rc=$?

  [ "$propagate_rc" -ne 0 ]
  grep -q "propagation error" "$err_file"
  grep -q "refs/remotes/runner/f" "$err_file"
  [ "$RUNNER_LAST_PROPAGATION" = "" ]
}

@test "propagate_feature — error: git's own diagnostic survives to stderr" {
  # Regression: step 1 used to silence git's stderr via 2>/dev/null, so the
  # operator saw only the runner's generic "propagation error" line and the
  # recovery recipe — with no signal as to WHY publish failed (FS error,
  # lock contention, disk full, permissions). The recipe had to be re-run
  # manually just to surface git's error. Step 2 captures stderr and
  # conditionally surfaces it; step 1 should be at least as informative on
  # a fail-fatal path.
  setup_propagate_test

  git -C "$HOST_CHECKOUT" -c user.email=t@t -c user.name=t \
    commit --allow-empty --quiet -m "tracker: f/01 → in-review"

  HOST_CHECKOUT="/nonexistent/path"

  RUNNER_LAST_PROPAGATION="stale"
  local err_file="$BATS_TEST_TMPDIR/propagate-err.txt"
  local propagate_rc=0
  propagate_feature "f" >"$err_file" 2>&1 || propagate_rc=$?

  [ "$propagate_rc" -ne 0 ]
  # Git's own diagnostic must reach the captured stream alongside the
  # runner's heredoc — otherwise the operator can't tell publish-failed
  # from any other publish-failed.
  grep -q "does not appear to be a git repository" "$err_file" || {
    echo "expected git's diagnostic in stderr; got:"
    cat "$err_file"
    false
  }
}

# === select_sync_base — pre-dispatch sync-base selector ====================
#
# Pure function: takes a pre-computed parking-ref relation and returns
# which tip the runner-checkout should sync to.
#
# Relation vocabulary: absent | equal | ahead | behind | diverged
# Rules:
#   absent   → host-branch   (no prior runner output)
#   equal    → host-branch   (runner output already at host tip)
#   ahead    → parking-ref   (runner output is ahead; chain from it)
#   behind   → host-branch   (host has moved past runner output)
#   diverged → parking-ref   (runner chain authoritative; maintainer reconciles)

@test "select_sync_base — absent: no parking ref → host-branch" {
  result="$(select_sync_base absent)"
  [ "$result" = "host-branch" ]
}

@test "select_sync_base — equal: parking ref equals host's branch → host-branch" {
  result="$(select_sync_base equal)"
  [ "$result" = "host-branch" ]
}

@test "select_sync_base — ahead: parking ref strictly ahead of host's branch → parking-ref" {
  result="$(select_sync_base ahead)"
  [ "$result" = "parking-ref" ]
}

@test "select_sync_base — behind: host's branch strictly ahead of parking ref → host-branch" {
  result="$(select_sync_base behind)"
  [ "$result" = "host-branch" ]
}

@test "select_sync_base — diverged: neither ancestor → parking-ref" {
  result="$(select_sync_base diverged)"
  [ "$result" = "parking-ref" ]
}

# === ensure_runner_checkout_on_branch — parking-ref sync path ==============
#
# Integration test: when the parking ref is strictly ahead of host's branch
# tip, ensure_runner_checkout_on_branch must sync to the parking-ref tip so
# successive on-branch dispatches build linearly on prior runner output.

setup_ensure_checkout_parking_test() {
  HOST_REPO="$BATS_TEST_TMPDIR/park-host"
  HOST_CHECKOUT="$BATS_TEST_TMPDIR/park-checkout"
  TARGET_FEATURE="f"

  mkdir -p "$HOST_REPO"
  git -C "$HOST_REPO" init --quiet --initial-branch=f
  git -C "$HOST_REPO" -c user.email=t@t -c user.name=t \
    commit --allow-empty --quiet -m init

  git clone --quiet "$HOST_REPO" "$HOST_CHECKOUT" >&2
  git -C "$HOST_CHECKOUT" checkout --quiet -B f origin/f
}

@test "ensure_runner_checkout_on_branch — parking-ref strictly ahead: syncs to parking-ref tip" {
  # Verify that when the parking ref is strictly ahead of host's branch, the
  # runner-checkout is synced to the parking-ref tip (not host's branch tip).
  # This is the linear-chaining property: the second dispatch's starting commit
  # is the first dispatch's parked commit, so its output builds on top of it.
  setup_ensure_checkout_parking_test

  # Simulate dispatch 1: runner-checkout advances past host's f tip.
  git -C "$HOST_CHECKOUT" -c user.email=t@t -c user.name=t \
    commit --allow-empty --quiet -m "dispatch 1"
  local d1_tip
  d1_tip="$(git -C "$HOST_CHECKOUT" rev-parse HEAD)"

  # Publish the dispatch-1 commit to the parking ref on host
  # (mirrors propagate_feature step 1 when fast-forward is refused).
  git -C "$HOST_REPO" fetch --quiet "$HOST_CHECKOUT" "+f:refs/remotes/runner/f" >&2

  # Reset runner-checkout back to host's branch tip (mirrors the pre-issue
  # ensure_runner_checkout_on_branch resetting to origin/<branch>).
  local host_tip
  host_tip="$(git -C "$HOST_REPO" rev-parse f)"
  git -C "$HOST_CHECKOUT" reset --quiet --hard "$host_tip"
  git -C "$HOST_CHECKOUT" clean --quiet -fd

  # Precondition: parking ref is strictly ahead of host's f.
  git -C "$HOST_REPO" merge-base --is-ancestor "$host_tip" "$d1_tip"
  ! git -C "$HOST_REPO" merge-base --is-ancestor "$d1_tip" "$host_tip" 2>/dev/null

  # Call the function under test.
  ensure_runner_checkout_on_branch "f"

  # The runner-checkout HEAD must equal the parking-ref tip, not host's f tip.
  local checkout_head
  checkout_head="$(git -C "$HOST_CHECKOUT" rev-parse HEAD)"
  [ "$checkout_head" = "$d1_tip" ]
}

@test "ensure_runner_checkout_on_branch — host-branch: returns 0 when host advances mid-sync" {
  # Regression test for TOCTOU: host branch advances between the early
  # rev-parse of host_tip and the runner-checkout's fetch.  With the
  # post-sync HEAD assertion removed, the function must return 0 and land
  # on the post-fetch tip (not abort with "post-sync HEAD mismatch").
  setup_ensure_checkout_parking_test

  # No parking ref → parking_rel=absent → sync_verdict=host-branch.

  # Capture what host_tip will see before the shim fires.
  local pre_fetch_tip
  pre_fetch_tip="$(git -C "$HOST_REPO" rev-parse f)"

  # Resolve real git before mutating PATH.
  local real_git
  real_git="$(command -v git)"

  # Build a git shim that, on the first "git -C <HOST_CHECKOUT> fetch …"
  # call, commits to HOST_REPO (simulating the TOCTOU advance), then
  # delegates to the real git so the fetch brings the new tip across.
  local fake_bin fired_file
  fake_bin="$BATS_TEST_TMPDIR/fake_bin"
  fired_file="$BATS_TEST_TMPDIR/shim_fired"
  mkdir -p "$fake_bin"

  export SHIM_HOST_CHECKOUT="$HOST_CHECKOUT"
  export SHIM_HOST_REPO="$HOST_REPO"
  export SHIM_FIRED_FILE="$fired_file"
  export SHIM_REAL_GIT="$real_git"

  cat >"$fake_bin/git" <<'SHIM'
#!/usr/bin/env bash
# On first "git -C <HOST_CHECKOUT> fetch …": advance HOST_REPO, then delegate.
if [ "${1:-}" = "-C" ] && [ "${2:-}" = "$SHIM_HOST_CHECKOUT" ] && [ "${3:-}" = "fetch" ]; then
  if [ ! -f "$SHIM_FIRED_FILE" ]; then
    touch "$SHIM_FIRED_FILE"
    "$SHIM_REAL_GIT" -C "$SHIM_HOST_REPO" \
      -c user.email=t@t -c user.name=t \
      commit --allow-empty --quiet -m "host advance mid-sync"
  fi
fi
exec "$SHIM_REAL_GIT" "$@"
SHIM
  chmod +x "$fake_bin/git"

  export PATH="$fake_bin:$PATH"

  # Must return 0 — the TOCTOU race no longer aborts the sync.
  ensure_runner_checkout_on_branch "f"

  # Confirm the shim actually fired (the race scenario ran).
  [ -f "$fired_file" ]

  # Runner-checkout must be at the post-advance tip, not the stale pre-fetch tip.
  local checkout_head post_advance_tip
  checkout_head="$(git -C "$HOST_CHECKOUT" rev-parse HEAD)"
  post_advance_tip="$(git -C "$HOST_REPO" rev-parse f)"
  [ "$checkout_head" = "$post_advance_tip" ]
  [ "$checkout_head" != "$pre_fetch_tip" ]
}

@test "ensure_runner_checkout_on_branch — lazy init from main when host has no branch ref and no parking ref" {
  # When neither refs/heads/<branch> nor refs/remotes/runner/<branch> exists on
  # host, the function must initialize the runner-checkout's branch from main
  # rather than failing. After the call the runner-checkout must be on the
  # target branch at the main tip.
  HOST_REPO="$BATS_TEST_TMPDIR/lazy-host"
  HOST_CHECKOUT="$BATS_TEST_TMPDIR/lazy-checkout"
  TARGET_FEATURE="new-feature"

  mkdir -p "$HOST_REPO"
  git -C "$HOST_REPO" init --quiet --initial-branch=main
  git -C "$HOST_REPO" -c user.email=t@t -c user.name=t \
    commit --allow-empty --quiet -m "initial main commit"

  git clone --quiet "$HOST_REPO" "$HOST_CHECKOUT" >&2

  # Preconditions: no refs/heads/new-feature or parking ref on host.
  ! git -C "$HOST_REPO" show-ref --quiet --verify "refs/heads/new-feature" 2>/dev/null
  ! git -C "$HOST_REPO" show-ref --quiet --verify "refs/remotes/runner/new-feature" 2>/dev/null

  local main_tip
  main_tip="$(git -C "$HOST_REPO" rev-parse refs/heads/main)"

  ensure_runner_checkout_on_branch "new-feature"

  # Runner-checkout must now be on new-feature at main's tip.
  local checkout_branch checkout_head
  checkout_branch="$(git -C "$HOST_CHECKOUT" symbolic-ref --short HEAD)"
  checkout_head="$(git -C "$HOST_CHECKOUT" rev-parse HEAD)"
  [ "$checkout_branch" = "new-feature" ]
  [ "$checkout_head" = "$main_tip" ]
}

# === ensure_runner_checkout_on_branch — unborn-HEAD recovery ==============

@test "ensure_runner_checkout_on_branch — unborn HEAD with intact origin/HEAD: recovers and syncs to target branch" {
  # When the runner-checkout HEAD symbolic-refs a deleted branch (unborn state,
  # as left by sweep_stale_parking_refs) and the WT has stray files that would
  # cause `git reset --hard HEAD` to fail, the function must detect unborn HEAD
  # before the dirty-WT scrub, recover, and then sync normally to the target.
  HOST_REPO="$BATS_TEST_TMPDIR/unborn-host"
  HOST_CHECKOUT="$BATS_TEST_TMPDIR/unborn-checkout"

  mkdir -p "$HOST_REPO"
  git -C "$HOST_REPO" init --quiet --initial-branch=main
  git -C "$HOST_REPO" -c user.email=t@t -c user.name=t \
    commit --allow-empty --quiet -m "initial"
  git -C "$HOST_REPO" checkout --quiet -b feature
  git -C "$HOST_REPO" -c user.email=t@t -c user.name=t \
    commit --allow-empty --quiet -m "feature commit"
  local feature_tip
  feature_tip="$(git -C "$HOST_REPO" rev-parse refs/heads/feature)"
  git -C "$HOST_REPO" checkout --quiet main

  git clone --quiet "$HOST_REPO" "$HOST_CHECKOUT" >&2
  git -C "$HOST_CHECKOUT" checkout --quiet -b feature "origin/feature"

  # Simulate unborn HEAD: HEAD still points at refs/heads/feature but the
  # branch ref is deleted — the state left by sweep_stale_parking_refs.
  git -C "$HOST_CHECKOUT" symbolic-ref HEAD refs/heads/feature
  git -C "$HOST_CHECKOUT" update-ref -d refs/heads/feature

  # Leave a stray file in the WT to exercise the dirty-WT scrub. With unborn
  # HEAD, `git reset --hard HEAD` fails — the fix detects this and recovers
  # before the scrub runs.
  echo "stray" > "$HOST_CHECKOUT/stray.txt"

  # Precondition: HEAD is unborn and WT is dirty.
  run git -C "$HOST_CHECKOUT" rev-parse --verify --quiet HEAD
  [ "$status" -ne 0 ]

  ensure_runner_checkout_on_branch "feature"

  local checkout_branch checkout_head
  checkout_branch="$(git -C "$HOST_CHECKOUT" symbolic-ref --short HEAD)"
  checkout_head="$(git -C "$HOST_CHECKOUT" rev-parse HEAD)"
  [ "$checkout_branch" = "feature" ]
  [ "$checkout_head" = "$feature_tip" ]
}

@test "ensure_runner_checkout_on_branch — unborn HEAD with staged conflict against origin/HEAD: recovers and syncs to target branch" {
  # Regression for the routine post-PR-merge cleanup path. The previous
  # recovery used `git checkout -B <default> origin/HEAD`, which refuses on
  # an index/WT whose tracked files conflict with origin/HEAD's tree. That
  # is the dominant real-world state: sweep_stale_parking_refs deleted the
  # branch HEAD pointed at (→ unborn HEAD), and the merged dispatch's
  # staged changes to tracked files (CHANGELOG.md, .inbox.md, …) sit in
  # the index — superseded by the squash-merged versions on origin/HEAD,
  # but the checkout porcelain doesn't know that and bails. Recovery must
  # use plumbing (update-ref + symbolic-ref) that never touches the WT;
  # the dirty-WT scrub below then clears the conflicting index against
  # the now-valid HEAD.
  HOST_REPO="$BATS_TEST_TMPDIR/unborn-conflict-host"
  HOST_CHECKOUT="$BATS_TEST_TMPDIR/unborn-conflict-checkout"

  mkdir -p "$HOST_REPO"
  git -C "$HOST_REPO" init --quiet --initial-branch=main
  echo "main-content" > "$HOST_REPO/CHANGELOG.md"
  git -C "$HOST_REPO" add CHANGELOG.md
  git -C "$HOST_REPO" -c user.email=t@t -c user.name=t \
    commit --quiet -m "initial"
  git -C "$HOST_REPO" checkout --quiet -b feature
  git -C "$HOST_REPO" -c user.email=t@t -c user.name=t \
    commit --allow-empty --quiet -m "feature commit"
  local feature_tip
  feature_tip="$(git -C "$HOST_REPO" rev-parse refs/heads/feature)"
  git -C "$HOST_REPO" checkout --quiet main

  git clone --quiet "$HOST_REPO" "$HOST_CHECKOUT" >&2
  git -C "$HOST_CHECKOUT" checkout --quiet -b feature "origin/feature"

  # Stage a conflicting modification to CHANGELOG.md (differs from
  # origin/HEAD's version), then drop the branch ref so HEAD is unborn.
  echo "stale-dispatch-content" > "$HOST_CHECKOUT/CHANGELOG.md"
  git -C "$HOST_CHECKOUT" add CHANGELOG.md
  git -C "$HOST_CHECKOUT" symbolic-ref HEAD refs/heads/feature
  git -C "$HOST_CHECKOUT" update-ref -d refs/heads/feature

  # Precondition: HEAD is unborn and the index has a staged conflict.
  run git -C "$HOST_CHECKOUT" rev-parse --verify --quiet HEAD
  [ "$status" -ne 0 ]
  run git -C "$HOST_CHECKOUT" status --porcelain
  [ -n "$output" ]

  ensure_runner_checkout_on_branch "feature"

  local checkout_branch checkout_head changelog
  checkout_branch="$(git -C "$HOST_CHECKOUT" symbolic-ref --short HEAD)"
  checkout_head="$(git -C "$HOST_CHECKOUT" rev-parse HEAD)"
  changelog="$(cat "$HOST_CHECKOUT/CHANGELOG.md")"
  [ "$checkout_branch" = "feature" ]
  [ "$checkout_head" = "$feature_tip" ]
  [ "$changelog" = "main-content" ]
}

@test "ensure_runner_checkout_on_branch — unborn HEAD with missing refs/remotes/origin/HEAD: returns 1 with diagnostic" {
  # When the runner-checkout is in unborn-HEAD state and refs/remotes/origin/HEAD
  # is absent (and set-head --auto cannot restore it), the function must return 1
  # and emit a diagnostic naming the missing ref. No infinite loop.
  HOST_REPO="$BATS_TEST_TMPDIR/unborn-nohead-host"
  HOST_CHECKOUT="$BATS_TEST_TMPDIR/unborn-nohead-checkout"

  mkdir -p "$HOST_REPO"
  git -C "$HOST_REPO" init --quiet --initial-branch=main
  git -C "$HOST_REPO" -c user.email=t@t -c user.name=t \
    commit --allow-empty --quiet -m "initial"

  git clone --quiet "$HOST_REPO" "$HOST_CHECKOUT" >&2

  # Force unborn HEAD.
  git -C "$HOST_CHECKOUT" symbolic-ref HEAD refs/heads/main
  git -C "$HOST_CHECKOUT" update-ref -d refs/heads/main 2>/dev/null || true

  # Remove refs/remotes/origin/HEAD so detection fails. Use symbolic-ref --delete
  # because update-ref -d silently no-ops on symrefs in some git versions.
  git -C "$HOST_CHECKOUT" symbolic-ref --delete refs/remotes/origin/HEAD 2>/dev/null || \
    git -C "$HOST_CHECKOUT" update-ref -d refs/remotes/origin/HEAD 2>/dev/null || true

  # Point origin at a nonexistent path so set-head --auto cannot reach the
  # remote and therefore cannot restore refs/remotes/origin/HEAD.
  git -C "$HOST_CHECKOUT" remote set-url origin "$BATS_TEST_TMPDIR/nonexistent"

  run ensure_runner_checkout_on_branch "main"
  [ "$status" -ne 0 ]
  echo "$output" | grep -q "refs/remotes/origin/HEAD"
}

@test "ensure_runner_checkout_on_branch — lazy-init guard refuses when checkout branch is ahead of the remote default" {
  # Anomaly: runner-checkout has a local branch with unpublished commits but
  # no host branch and no parking ref exist. A plain lazy-init reset would
  # silently destroy those commits. The guard must detect this, log a
  # diagnostic, and return non-zero without touching the branch ref. The
  # guard's primary protection is the non-zero return; the surviving branch
  # ref is the load-bearing assertion below.
  HOST_REPO="$BATS_TEST_TMPDIR/guard-host"
  HOST_CHECKOUT="$BATS_TEST_TMPDIR/guard-checkout"
  HOST_ABORT_DIR="$BATS_TEST_TMPDIR/guard-aborted"

  mkdir -p "$HOST_REPO"
  git -C "$HOST_REPO" init --quiet --initial-branch=main
  git -C "$HOST_REPO" -c user.email=t@t -c user.name=t \
    commit --allow-empty --quiet -m "base: initial main commit"

  # Clone host to runner-checkout (establishes refs/remotes/origin/HEAD).
  git clone --quiet "$HOST_REPO" "$HOST_CHECKOUT" >&2

  # Create local branch f in the runner-checkout with one commit beyond the
  # remote default.
  git -C "$HOST_CHECKOUT" checkout --quiet -b f
  git -C "$HOST_CHECKOUT" -c user.email=t@t -c user.name=t \
    commit --allow-empty --quiet -m "unpublished work on f"
  local ahead_sha
  ahead_sha="$(git -C "$HOST_CHECKOUT" rev-parse HEAD)"

  # Preconditions: no host branch and no parking ref for f.
  ! git -C "$HOST_REPO" show-ref --quiet --verify "refs/heads/f" 2>/dev/null
  ! git -C "$HOST_REPO" show-ref --quiet --verify "refs/remotes/runner/f" 2>/dev/null

  run ensure_runner_checkout_on_branch "f"

  # Guard must refuse.
  [ "$status" -ne 0 ]

  # The unpublished commit must still be reachable from refs/heads/f.
  local surviving_sha
  surviving_sha="$(git -C "$HOST_CHECKOUT" rev-parse refs/heads/f)"
  [ "$surviving_sha" = "$ahead_sha" ]
}

# === next_eligible_feature — outer-loop selection =========================
#
# Analogue of next_eligible_ref but at the feature level. Picks the next
# feature the runner should consider — either the first unconsidered slug
# in discovery order (drain mode, $3 empty), or the narrowed slug if
# unconsidered (`--feature`/`--issue` modes), else empty.
#
# Signature: next_eligible_feature <discovery_json> <considered_slugs> <narrow_to>
#
#   considered_slugs is newline-delimited slugs already attempted in this run.
#   narrow_to is empty in drain mode; a slug otherwise.

@test "next_eligible_feature — empty discovery returns empty" {
  result="$(next_eligible_feature '[]' '' '')"
  [ -z "$result" ]
}

@test "next_eligible_feature — drain mode picks first slug when nothing considered" {
  result="$(next_eligible_feature '["alpha","beta","gamma"]' '' '')"
  [ "$result" = "alpha" ]
}

@test "next_eligible_feature — drain mode picks next slug after a considered one" {
  result="$(next_eligible_feature '["alpha","beta","gamma"]' 'alpha' '')"
  [ "$result" = "beta" ]
}

@test "next_eligible_feature — drain mode skips over multiple considered slugs" {
  considered="$(printf 'alpha\nbeta\n')"
  result="$(next_eligible_feature '["alpha","beta","gamma"]' "$considered" '')"
  [ "$result" = "gamma" ]
}

@test "next_eligible_feature — drain mode returns empty when all considered" {
  considered="$(printf 'alpha\nbeta\ngamma\n')"
  result="$(next_eligible_feature '["alpha","beta","gamma"]' "$considered" '')"
  [ -z "$result" ]
}

@test "next_eligible_feature — narrow mode returns the narrowed slug" {
  result="$(next_eligible_feature '["alpha","beta","gamma"]' '' 'beta')"
  [ "$result" = "beta" ]
}

@test "next_eligible_feature — narrow mode returns empty once the narrowed slug is considered" {
  result="$(next_eligible_feature '["alpha","beta","gamma"]' 'beta' 'beta')"
  [ -z "$result" ]
}

@test "next_eligible_feature — narrow mode returns empty when narrowed slug is not in discovery" {
  result="$(next_eligible_feature '["alpha","beta","gamma"]' '' 'unknown')"
  [ -z "$result" ]
}

@test "next_eligible_feature — drain mode preserves discovery ordering (not alphabetic)" {
  # Ordering must come from the discovery array verbatim — not from any
  # sort the selector applies. A binding that emits non-alphabetic order
  # would be miscompared if the function re-sorted internally.
  result="$(next_eligible_feature '["zulu","alpha","mike"]' '' '')"
  [ "$result" = "zulu" ]
  result="$(next_eligible_feature '["zulu","alpha","mike"]' 'zulu' '')"
  [ "$result" = "alpha" ]
}

# === format_multi_feature_summary_md — drain-mode SUMMARY shape ===========
#
# Multi-feature runs render per-feature sections. Drained features carry
# the per-issue table (same row shape as the single-feature SUMMARY);
# skipped features carry a one-line "skipped: <reason>" section (no
# table). Encounter order is preserved — the formatter renders sections
# in the order they arrive on stdin.
#
# Input lines (one per record):
#   F|<feature>|drained
#   F|<feature>|skipped:<reason>
#   F|<feature>|feature-snapshot-failed
#   I|<ref>|<outcome>|<duration>|<review_present>
#
# `I` rows belong to the most recent `F|<slug>|drained` section.

@test "format_multi_feature_summary_md — heading, run line, stop reason, encounter-order sections" {
  input='F|alpha|drained
I|alpha|01|alpha/01|done|42|y
F|beta|skip:fetch-failed
F|gamma|drained
I|gamma|01|gamma/01|in-review|13|'
  result="$(printf '%s\n' "$input" | format_multi_feature_summary_md \
    20260513-101010 10:10:10 10:30:00 ended completed)"

  # Heading is the run identity, not a feature slug.
  echo "$result" | grep -q '^# AFK runner — multi-feature drain$' || { echo "$result"; false; }
  echo "$result" | grep -q -- '- Run: 20260513-101010.*started 10:10:10.*ended 10:30:00' || { echo "$result"; false; }
  echo "$result" | grep -q -- '- Stop reason: completed$' || { echo "$result"; false; }

  # Per-feature section headings, in encounter order.
  local alpha_line beta_line gamma_line
  alpha_line="$(printf '%s\n' "$result" | grep -n '^## alpha — drained$' | cut -d: -f1)"
  beta_line="$(printf '%s\n' "$result" | grep -n '^## beta — skipped: fetch-failed$' | cut -d: -f1)"
  gamma_line="$(printf '%s\n' "$result" | grep -n '^## gamma — drained$' | cut -d: -f1)"
  [ -n "$alpha_line" ] && [ -n "$beta_line" ] && [ -n "$gamma_line" ]
  [ "$alpha_line" -lt "$beta_line" ]
  [ "$beta_line" -lt "$gamma_line" ]

  # Drained features carry per-issue tables nested under their section.
  # Propagation field absent in these records → '-' indicator.
  echo "$result" | grep -qF '| alpha/01 | done | 42s | - | [alpha/01.log](alpha/01.log) [alpha/01-review.log](alpha/01-review.log) |' \
    || { echo "$result"; false; }
  echo "$result" | grep -qF '| gamma/01 | in-review | 13s | - | [gamma/01.log](gamma/01.log) |' \
    || { echo "$result"; false; }
}

@test "format_multi_feature_summary_md — skipped feature emits no issue table" {
  input='F|beta|skip:fetch-failed'
  result="$(printf '%s\n' "$input" | format_multi_feature_summary_md \
    20260513-101010 10:10:10 10:11:00 ended completed)"

  echo "$result" | grep -q '^## beta — skipped: fetch-failed$' || { echo "$result"; false; }
  # The skipped section must not produce a per-issue table for that feature.
  ! echo "$result" | grep -q '^| issue ' || { echo "$result"; false; }
}

@test "format_multi_feature_summary_md — feature-snapshot-failed renders without 'skipped:' prefix" {
  input='F|gamma|feature-snapshot-failed'
  result="$(printf '%s\n' "$input" | format_multi_feature_summary_md \
    20260513-101010 10:10:10 10:11:00 ended completed)"

  echo "$result" | grep -q '^## gamma — feature-snapshot-failed$' || { echo "$result"; false; }
  # Confirm it is NOT prefixed with "skipped:" — distinct outcome label.
  ! echo "$result" | grep -q '^## gamma — skipped' || { echo "$result"; false; }
}

@test "format_multi_feature_summary_md — empty input still emits heading + run line + stop reason" {
  result="$(printf '' | format_multi_feature_summary_md 20260513-101010 10:10:10 10:10:11 ended completed)"
  echo "$result" | grep -q '^# AFK runner — multi-feature drain$' || false
  echo "$result" | grep -q -- '- Stop reason: completed$' || false
  # No feature sections.
  ! echo "$result" | grep -q '^## ' || false
}

@test "format_multi_feature_summary_md — interrupted state surfaces in the run line" {
  result="$(printf 'F|alpha|drained\nI|alpha|01|alpha/01|in-review|3|\n' | format_multi_feature_summary_md \
    20260513-101010 10:10:10 10:10:13 interrupted interrupted)"
  echo "$result" | grep -q -- '- Run: 20260513-101010.*started 10:10:10.*interrupted 10:10:13' || { echo "$result"; false; }
  echo "$result" | grep -q -- '- Stop reason: interrupted$' || { echo "$result"; false; }
}

@test "format_multi_feature_summary_md — GH-shaped ref (#N) emits feature-path log link" {
  # I row schema: I|feature|nn|ref|outcome|duration|review_present
  # Log path uses feature/nn so per-run artifacts don't collide across features.
  input='F|some-feature|drained
I|some-feature|42|#42|done|25|y'
  result="$(printf '%s\n' "$input" | format_multi_feature_summary_md \
    20260513-101010 10:10:10 10:10:35 ended completed)"

  echo "$result" | grep -qF '| #42 | done | 25s | - | [some-feature/42.log](some-feature/42.log) [some-feature/42-review.log](some-feature/42-review.log) |' \
    || { echo "$result"; false; }
}

@test "format_multi_feature_summary_md — dispatch-aborted and review-aborted render as outcome labels" {
  input='F|alpha|drained
I|alpha|01|alpha/01|dispatch-aborted|12|
I|alpha|02|alpha/02|review-aborted|38|y'
  result="$(printf '%s\n' "$input" | format_multi_feature_summary_md \
    20260513-101010 10:10:10 10:30:00 ended completed)"

  echo "$result" | grep -qF '| alpha/01 | dispatch-aborted | 12s | - | [alpha/01.log](alpha/01.log) |' \
    || { echo "$result"; false; }
  echo "$result" | grep -qF '| alpha/02 | review-aborted | 38s | - | [alpha/02.log](alpha/02.log) [alpha/02-review.log](alpha/02-review.log) |' \
    || { echo "$result"; false; }
}

@test "format_multi_feature_summary_md — attempt_count=1 omits the attempts suffix" {
  input='F|alpha|drained
I|alpha|01|alpha/01|dispatch-aborted|12||1'
  result="$(printf '%s\n' "$input" | format_multi_feature_summary_md \
    20260513-101010 10:10:10 10:10:22 ended completed)"

  echo "$result" | grep -qF '| alpha/01 | dispatch-aborted | 12s |' \
    || { echo "$result"; false; }
  ! echo "$result" | grep -q 'attempts' || { echo "$result"; false; }
}

@test "format_multi_feature_summary_md — attempt_count > 1 appends the attempts suffix" {
  input='F|alpha|drained
I|alpha|01|alpha/01|dispatch-aborted|12||2'
  result="$(printf '%s\n' "$input" | format_multi_feature_summary_md \
    20260513-101010 10:10:10 10:10:22 ended completed)"

  echo "$result" | grep -qF '| alpha/01 | dispatch-aborted (2 attempts) | 12s | - | [alpha/01.log](alpha/01.log) |' \
    || { echo "$result"; false; }
}

@test "format_multi_feature_summary_md — propagation indicator column shown per row" {
  input='F|alpha|drained
I|alpha|01|alpha/01|done|42|y|1|propagated
I|alpha|02|alpha/02|done|30|y|1|parked → runner/alpha'
  result="$(printf '%s\n' "$input" | format_multi_feature_summary_md \
    20260513-101010 10:10:10 10:30:00 ended completed)"

  echo "$result" | grep -qF '| alpha/01 | done | 42s | propagated | [alpha/01.log](alpha/01.log)' \
    || { echo "$result"; false; }
  echo "$result" | grep -qF '| alpha/02 | done | 30s | parked → runner/alpha | [alpha/02.log](alpha/02.log)' \
    || { echo "$result"; false; }
}

@test "format_multi_feature_summary_md — parked dispatch produces end-of-run section" {
  input='F|alpha|drained
I|alpha|01|alpha/01|done|42|y|1|parked → runner/alpha
F|beta|drained
I|beta|01|beta/01|done|13||1|propagated'
  result="$(printf '%s\n' "$input" | format_multi_feature_summary_md \
    20260513-101010 10:10:10 10:30:00 ended completed)"

  echo "$result" | grep -q '## Unpulled parked work' || { echo "$result"; false; }
  echo "$result" | grep -q 'alpha.*1 dispatch.*git pull runner alpha' \
    || { echo "$result"; false; }
  # beta was propagated — not listed in the parked section.
  ! echo "$result" | grep -q '\*\*beta\*\*' || { echo "$result"; false; }
}

@test "format_multi_feature_summary_md — no parked section when all dispatches propagated" {
  input='F|alpha|drained
I|alpha|01|alpha/01|done|42|y|1|propagated'
  result="$(printf '%s\n' "$input" | format_multi_feature_summary_md \
    20260513-101010 10:10:10 10:30:00 ended completed)"

  ! echo "$result" | grep -q 'Unpulled parked work' || { echo "$result"; false; }
}

@test "format_end_of_run_table — propagation indicator column shown per row" {
  input='afk-runner|01|afk-runner/01|done|42||1|propagated
afk-runner|02|afk-runner/02|done|30||1|parked → runner/afk-runner'
  result="$(printf '%s\n' "$input" | format_end_of_run_table queue-empty)"

  echo "$result" | head -n 1 | grep -q ' propagation' || { echo "header missing 'propagation'"; echo "$result"; false; }
  echo "$result" | grep -q 'afk-runner/01.*propagated' || { echo "propagated row missing"; echo "$result"; false; }
  echo "$result" | grep -q 'afk-runner/02.*parked' || { echo "parked row missing"; echo "$result"; false; }
}

@test "format_end_of_run_table — header and data rows align visually under UTF-8 → indicator" {
  # Regression: awk's length() returns BYTES on BSD awk / mawk / busybox awk,
  # so column widths derived from length() over-counted "→" cells by 2 bytes
  # each, leaving the propagation column misaligned between the header row
  # (padded to byte width) and the data row (visual width 2 chars short of
  # the padding). Visual alignment requires the column-padding logic to use
  # display width (1 per code point), not byte count.
  input='f|01|f/01|done|10|y|1|propagated → host
f|02|f/02|done|20|y|1|parked → runner/f'
  result="$(printf '%s\n' "$input" | format_end_of_run_table completed)"

  # Count code points per row including trailing padding — alignment means
  # every row ends at the same display column. `wc -m` counts characters
  # (not bytes) when LC_ALL is a UTF-8 locale; the locale must be applied
  # to wc itself, not to printf. C.UTF-8 is a glibc built-in available in
  # debian:bookworm-slim without installing the locales package, and is
  # also present on modern macOS.
  local header data1 data2 wh wd1 wd2
  header="$(printf '%s\n' "$result" | sed -n '1p')"
  data1="$( printf '%s\n' "$result" | sed -n '2p')"
  data2="$( printf '%s\n' "$result" | sed -n '3p')"
  wh=$(  printf '%s' "$header" | LC_ALL=C.UTF-8 wc -m | tr -d ' ')
  wd1=$( printf '%s' "$data1"  | LC_ALL=C.UTF-8 wc -m | tr -d ' ')
  wd2=$( printf '%s' "$data2"  | LC_ALL=C.UTF-8 wc -m | tr -d ' ')

  [ "$wh" = "$wd1" ] || { echo "header($wh) ≠ data1($wd1):"; printf '[%s]\n[%s]\n' "$header" "$data1"; false; }
  [ "$wh" = "$wd2" ] || { echo "header($wh) ≠ data2($wd2):"; printf '[%s]\n[%s]\n' "$header" "$data2"; false; }
}

# === drain_one_feature + run_drain — outer-loop integration ================
#
# Drain mode wires the pure functions together: walk discovery, evaluate
# the gate per feature, record outcomes. These tests mock the side-effecting
# helpers (ensure_runner_checkout_on_branch, take_snapshot, ensure_mvn_cache_for,
# run_loop) so the loop's scheduling can be exercised without docker or
# real git. The pattern matches the existing run_loop tests.

setup_drain_test() {
  # Per-test scratch state — used by the mocks below to record what the
  # drain loop did and to plant per-feature responses.
  DRAIN_DRAINED_FILE="$BATS_TEST_TMPDIR/drained"
  DRAIN_FETCH_FAILURES_FILE="$BATS_TEST_TMPDIR/fetch-failures"
  DRAIN_SNAP_FAILURES_FILE="$BATS_TEST_TMPDIR/snap-failures"
  DRAIN_QUEUE_EMPTY_FILE="$BATS_TEST_TMPDIR/queue-empty"
  DRAIN_MVN_FAILURES_FILE="$BATS_TEST_TMPDIR/mvn-failures"
  DRAIN_MVN_CALLED_FILE="$BATS_TEST_TMPDIR/mvn-called"
  DRAIN_MID_SNAP_CRASH_FILE="$BATS_TEST_TMPDIR/mid-snap-crash"
  : >"$DRAIN_DRAINED_FILE"
  : >"$DRAIN_FETCH_FAILURES_FILE"
  : >"$DRAIN_SNAP_FAILURES_FILE"
  : >"$DRAIN_QUEUE_EMPTY_FILE"
  : >"$DRAIN_MVN_FAILURES_FILE"
  : >"$DRAIN_MVN_CALLED_FILE"
  : >"$DRAIN_MID_SNAP_CRASH_FILE"

  # Plant a host repo on a "parked" branch (master).
  HOST_REPO="$BATS_TEST_TMPDIR/drain-host"
  mkdir -p "$HOST_REPO"
  git -C "$HOST_REPO" init --quiet --initial-branch=master
  git -C "$HOST_REPO" -c user.email=t@t -c user.name=t \
    commit --allow-empty --quiet -m init

  HOST_ABORT_DIR="$BATS_TEST_TMPDIR/aborted"
  mkdir -p "$HOST_ABORT_DIR"

  # Mocks — all controllable via the scratch files above.
  ensure_runner_checkout_on_branch() {
    local branch="$1"
    if grep -Fxq -- "$branch" "$DRAIN_FETCH_FAILURES_FILE" 2>/dev/null; then
      return 1
    fi
    return 0
  }
  take_snapshot() {
    local feature="$1"
    if grep -Fxq -- "$feature" "$DRAIN_SNAP_FAILURES_FILE" 2>/dev/null; then
      return 1
    fi
    if grep -Fxq -- "$feature" "$DRAIN_QUEUE_EMPTY_FILE" 2>/dev/null; then
      # Empty queue — no eligible refs.
      printf '{"feature":"%s","issues":[]}' "$feature"
    else
      printf '{"feature":"%s","issues":[{"ref":"%s/01","nn":"01","status":"ready-for-agent","category":"enhancement","type":"AFK","blocked_by":[],"eligible":true}]}' "$feature" "$feature"
    fi
  }
  ensure_mvn_cache_for() {
    local feature="$1"
    echo "$feature" >>"$DRAIN_MVN_CALLED_FILE"
    if grep -Fxq -- "$feature" "$DRAIN_MVN_FAILURES_FILE" 2>/dev/null; then
      return 1
    fi
    MVN_VOLUME="runner-mvn-cache-$feature"
    return 0
  }
  # Capture the production run_loop before the test mock overwrites it.
  # Tests that need to exercise the real per-issue loop (e.g., to verify the
  # per-iteration ensure_runner_checkout soft-fail in drain mode) restore it
  # via `eval "$DRAIN_REAL_RUN_LOOP"`.
  DRAIN_REAL_RUN_LOOP="$(declare -f run_loop)"

  # Stand in for the per-issue loop. Records the feature so the test can
  # confirm the drain reached this point, and optionally simulates a
  # mid-feature snapshot crash via $DRAIN_MID_SNAP_CRASH_FILE.
  run_loop() {
    echo "$TARGET_FEATURE" >>"$DRAIN_DRAINED_FILE"
    if grep -Fxq -- "$TARGET_FEATURE" "$DRAIN_MID_SNAP_CRASH_FILE" 2>/dev/null; then
      RUN_STOP_REASON="snapshot-failed"
      return 1
    fi
    RUN_STOP_REASON="queue-empty"
    return 0
  }

  RUN_DIR="$BATS_TEST_TMPDIR/run"
  mkdir -p "$RUN_DIR"
  RUNNER_INTERRUPTED=0
  RUN_FEATURE_OUTCOMES=()
  RUN_DISPATCHES=()
  RUN_STOP_REASON=""
  TARGET_FEATURE=""
  RUN_MODE="drain"
}

# Helpers for assertions.
drain_outcomes_count() { echo "${#RUN_FEATURE_OUTCOMES[@]}"; }
drain_outcome_nth() { echo "${RUN_FEATURE_OUTCOMES[$1]}"; }
drained_features_count() { wc -l <"$DRAIN_DRAINED_FILE" | tr -d ' '; }

@test "drain_one_feature — records drained when gate passes" {
  setup_drain_test
  git -C "$HOST_REPO" branch alpha
  drain_one_feature "alpha"
  [ "$(drain_outcome_nth 0)" = "alpha|drained" ]
  [ "$(drained_features_count)" = "1" ]
}

@test "drain_one_feature — drains when host is on the feature branch (branch-state-agnostic)" {
  setup_drain_test
  git -C "$HOST_REPO" checkout --quiet -B "alpha"
  # Bypass jq-dependent queue probe — the test's concern is gate logic only.
  feature_has_dispatchable_ref() { return 0; }

  drain_one_feature "alpha"

  # Host being on the feature branch is not a skip condition; the feature
  # drains normally.
  [ "$(drain_outcome_nth 0)" = "alpha|drained" ]
  [ "$(drained_features_count)" = "1" ]
}

@test "drain_one_feature — drains feature with no host branch ref (lazy init)" {
  # After lazy-init, a feature with no host branch is dispatched normally
  # rather than skipped. ensure_runner_checkout_on_branch is mocked to succeed
  # (it handles lazy init internally when needed).
  setup_drain_test
  # `alpha` is never created on the host repo — lazy init path will handle it.

  drain_one_feature "alpha"

  [ "$(drain_outcome_nth 0)" = "alpha|drained" ]
  [ "$(drained_features_count)" = "1" ]
}

@test "drain_one_feature — records skip:fetch-failed when runner-checkout sync fails" {
  setup_drain_test
  git -C "$HOST_REPO" branch alpha
  echo "alpha" >"$DRAIN_FETCH_FAILURES_FILE"

  drain_one_feature "alpha"

  [ "$(drain_outcome_nth 0)" = "alpha|skip:fetch-failed" ]
  [ "$(drained_features_count)" = "0" ]
  [ ! -s "$DRAIN_MVN_CALLED_FILE" ]
}

@test "drain_one_feature — records feature-snapshot-failed when the pre-loop snapshot crashes" {
  setup_drain_test
  git -C "$HOST_REPO" branch alpha
  echo "alpha" >"$DRAIN_SNAP_FAILURES_FILE"

  drain_one_feature "alpha"

  [ "$(drain_outcome_nth 0)" = "alpha|feature-snapshot-failed" ]
  [ "$(drained_features_count)" = "0" ]
  [ ! -s "$DRAIN_MVN_CALLED_FILE" ]
}

@test "drain_one_feature — records skip:queue-empty when the snapshot has no eligible refs" {
  setup_drain_test
  git -C "$HOST_REPO" branch alpha
  echo "alpha" >"$DRAIN_QUEUE_EMPTY_FILE"

  drain_one_feature "alpha"

  [ "$(drain_outcome_nth 0)" = "alpha|skip:queue-empty" ]
  [ "$(drained_features_count)" = "0" ]
  [ ! -s "$DRAIN_MVN_CALLED_FILE" ]
}

@test "drain_one_feature — per-iteration ensure_runner_checkout failure (after a successful pre-feature sync) records skip:fetch-failed and the next feature still drains" {
  # AC: "A feature whose per-iteration `ensure_runner_checkout` fails (after
  # a successful pre-feature sync) records `skip:fetch-failed` for that
  # feature and continues to the next feature. Run-level stop reason ends
  # as `completed` … not `preflight-abort: runner-checkout`."
  #
  # Pre-fix the per-iteration wrapper call (`ensure_runner_checkout` inside
  # `run_loop`) ran `fail_invariant` on failure → `exit 2`. That terminated
  # the whole drain even though `drain_one_feature` wraps run_loop in
  # `set +e; run_loop; set -e`. Bats sees the exit and the test aborts —
  # which is the red signal here. Post-fix the wrapper soft-fails in drain
  # mode (sets RUN_STOP_REASON="fetch-failed", returns 1), run_loop returns
  # non-zero, and drain_one_feature maps the inner_reason to skip:fetch-failed.
  setup_drain_test
  DISCOVERY_JSON='["alpha","beta"]'
  git -C "$HOST_REPO" branch alpha
  git -C "$HOST_REPO" branch beta

  # Drop the wholesale run_loop mock from setup_drain_test so the production
  # run_loop is exercised. take_snapshot, ensure_mvn_cache_for, and
  # ensure_runner_checkout_on_branch remain mocked; we provide dispatch_one
  # below and override ensure_runner_checkout_on_branch to simulate a
  # mid-iteration sync failure for alpha only.
  eval "$DRAIN_REAL_RUN_LOOP"

  # The pre-feature sync is the first call to `ensure_runner_checkout_on_branch`
  # with branch=alpha (from drain_one_feature). The per-iteration sync is
  # the second such call (from the real ensure_runner_checkout wrapper
  # inside run_loop). Fail the second call; succeed the first.
  ALPHA_CHECKOUT_CALLS_FILE="$BATS_TEST_TMPDIR/alpha-checkout-calls"
  echo 0 >"$ALPHA_CHECKOUT_CALLS_FILE"
  ensure_runner_checkout_on_branch() {
    local branch="$1"
    if [ "$branch" = "alpha" ]; then
      local count
      count="$(cat "$ALPHA_CHECKOUT_CALLS_FILE")"
      count=$((count + 1))
      echo "$count" >"$ALPHA_CHECKOUT_CALLS_FILE"
      [ "$count" -eq 1 ]
      return
    fi
    return 0
  }

  # dispatch_one is unreachable for alpha (its per-iteration sync fails
  # first), so plant a sentinel that fails the test loudly if it's called
  # for alpha. Beta drains one issue successfully, then queue empties.
  BETA_DRAINED_FILE="$BATS_TEST_TMPDIR/beta-drained"
  : >"$BETA_DRAINED_FILE"
  dispatch_one() {
    local feature="$1" nn="$2"
    if [ "$feature" = "alpha" ]; then
      echo "dispatch_one unexpectedly invoked for alpha/$nn" >"$BATS_TEST_TMPDIR/alpha-dispatch-leak"
      return 1
    fi
    echo "$feature/$nn" >>"$BETA_DRAINED_FILE"
    return 0
  }

  # Override take_snapshot so beta's queue empties after its single dispatch.
  # Alpha's first iteration sees one eligible ref (irrelevant — the per-iteration
  # sync fails before selection is even acted on).
  take_snapshot() {
    local feature="$1"
    if [ "$feature" = "beta" ] && [ -s "$BETA_DRAINED_FILE" ]; then
      printf '{"feature":"beta","issues":[]}'
      return 0
    fi
    printf '{"feature":"%s","issues":[{"ref":"%s/01","nn":"01","status":"ready-for-agent","category":"enhancement","type":"AFK","blocked_by":[],"eligible":true}]}' "$feature" "$feature"
  }

  # Real run_loop needs HOST_CHECKOUT defined for the wrapper's diagnostic;
  # the directory is never read because the inner probe is mocked.
  HOST_CHECKOUT="$BATS_TEST_TMPDIR/never-used-checkout"

  run_drain

  [ "$RUN_STOP_REASON" = "completed" ]
  [ "$(drain_outcomes_count)" = "2" ]
  [ "$(drain_outcome_nth 0)" = "alpha|skip:fetch-failed" ]
  [ "$(drain_outcome_nth 1)" = "beta|drained" ]
  # dispatch_one was never called for alpha (the per-iteration sync failed first).
  [ ! -f "$BATS_TEST_TMPDIR/alpha-dispatch-leak" ]
}

@test "drain_one_feature — surfaces mid-feature snapshot crash as feature-snapshot-failed" {
  setup_drain_test
  git -C "$HOST_REPO" branch alpha
  echo "alpha" >"$DRAIN_MID_SNAP_CRASH_FILE"

  drain_one_feature "alpha"

  # The pre-loop snapshot succeeded (queue check passed); the crash
  # happened inside run_loop's per-iteration take_snapshot. AC: "A feature
  # whose `tracker-snapshot <slug>` crashes mid-run produces a SUMMARY row
  # `feature-snapshot-failed` and the run continues."
  [ "$(drain_outcome_nth 0)" = "alpha|feature-snapshot-failed" ]
  # run_loop was reached — distinguishes mid-feature crash from the
  # pre-loop snapshot-failed gate.
  [ "$(drained_features_count)" = "1" ]
  # Mid-feature crash must not leak as the run-level stop reason — the
  # outer loop owns that.
  [ -z "$RUN_STOP_REASON" ]
}

@test "drain_one_feature — drained features get an mvn cache lazily" {
  setup_drain_test
  git -C "$HOST_REPO" branch alpha
  drain_one_feature "alpha"
  # The drained feature created its volume; ensure_mvn_cache_for was called.
  grep -Fxq "alpha" "$DRAIN_MVN_CALLED_FILE"
}

@test "drain_one_feature — records skip:fetch-failed when mvn-cache materialization fails" {
  setup_drain_test
  git -C "$HOST_REPO" branch alpha
  echo "alpha" >"$DRAIN_MVN_FAILURES_FILE"

  drain_one_feature "alpha"

  [ "$(drain_outcome_nth 0)" = "alpha|skip:fetch-failed" ]
  [ "$(drained_features_count)" = "0" ]
}

@test "run_drain — walks every feature in discovery order, records each outcome, ends with completed" {
  setup_drain_test
  DISCOVERY_JSON='["alpha","beta","gamma"]'
  # gamma branch missing on host; alpha and beta exist.
  # After lazy-init, missing host branches no longer produce skip:branch-missing
  # — gamma is dispatched normally (ensure_runner_checkout_on_branch mocked).
  git -C "$HOST_REPO" branch alpha
  git -C "$HOST_REPO" branch beta
  # beta's snapshot crashes pre-loop → feature-snapshot-failed.
  echo "beta" >"$DRAIN_SNAP_FAILURES_FILE"

  run_drain

  [ "$RUN_STOP_REASON" = "completed" ]
  [ "$(drain_outcomes_count)" = "3" ]
  [ "$(drain_outcome_nth 0)" = "alpha|drained" ]
  [ "$(drain_outcome_nth 1)" = "beta|feature-snapshot-failed" ]
  [ "$(drain_outcome_nth 2)" = "gamma|drained" ]
  # mvn-cache created for alpha and gamma (drained features).
  [ "$(wc -l <"$DRAIN_MVN_CALLED_FILE" | tr -d ' ')" = "2" ]
  grep -Fxq "alpha" "$DRAIN_MVN_CALLED_FILE"
  grep -Fxq "gamma" "$DRAIN_MVN_CALLED_FILE"
}

@test "run_drain — interrupted between features stops the outer loop" {
  setup_drain_test
  DISCOVERY_JSON='["alpha","beta"]'
  git -C "$HOST_REPO" branch alpha
  git -C "$HOST_REPO" branch beta
  # First feature's run_loop flips the interrupt flag instead of draining.
  run_loop() {
    echo "$TARGET_FEATURE" >>"$DRAIN_DRAINED_FILE"
    RUNNER_INTERRUPTED=1
    RUN_STOP_REASON="interrupted"
    return 0
  }

  run_drain

  [ "$RUN_STOP_REASON" = "interrupted" ]
  # Only the first feature was considered.
  [ "$(drain_outcomes_count)" = "1" ]
  [ "$(drain_outcome_nth 0)" = "alpha|drained" ]
}

@test "run_drain — empty discovery ends immediately with completed" {
  setup_drain_test
  DISCOVERY_JSON='[]'

  run_drain

  [ "$RUN_STOP_REASON" = "completed" ]
  [ "$(drain_outcomes_count)" = "0" ]
}

@test "run_drain — feature-snapshot-failed continues the run (does not abort)" {
  # AC: "A feature whose `tracker-snapshot <slug>` crashes mid-run produces
  # a SUMMARY row `feature-snapshot-failed` and the run continues. Other
  # features still drain."
  setup_drain_test
  DISCOVERY_JSON='["alpha","beta"]'
  git -C "$HOST_REPO" branch alpha
  git -C "$HOST_REPO" branch beta
  echo "alpha" >"$DRAIN_SNAP_FAILURES_FILE"

  run_drain

  [ "$RUN_STOP_REASON" = "completed" ]
  [ "$(drain_outcomes_count)" = "2" ]
  [ "$(drain_outcome_nth 0)" = "alpha|feature-snapshot-failed" ]
  [ "$(drain_outcome_nth 1)" = "beta|drained" ]
}

# === parse_args — drain mode accepts bare invocation ======================

@test "parse_args — bare invocation enters drain mode (no refusal)" {
  ARG_FEATURE=""
  ARG_ISSUE_REF=""
  ISSUE_FEATURE=""
  ISSUE_NN=""
  RUN_MODE=""

  run parse_args
  assert_success
  # Side effect inspection happens in a clean shell since `run` forks; do
  # the assertion in the parent too so RUN_MODE is observable here.
  parse_args
  [ "$RUN_MODE" = "drain" ]
  [ -z "$ARG_FEATURE" ]
  [ -z "$ARG_ISSUE_REF" ]
}

@test "parse_args — --feature enters loop mode" {
  ARG_FEATURE=""
  ARG_ISSUE_REF=""
  ISSUE_FEATURE=""
  ISSUE_NN=""
  RUN_MODE=""

  parse_args --feature my-feature
  [ "$RUN_MODE" = "loop" ]
  [ "$ARG_FEATURE" = "my-feature" ]
}

@test "parse_args — --issue enters single mode" {
  ARG_FEATURE=""
  ARG_ISSUE_REF=""
  ISSUE_FEATURE=""
  ISSUE_NN=""
  RUN_MODE=""

  parse_args --issue my-feature/01
  [ "$RUN_MODE" = "single" ]
  [ "$ISSUE_FEATURE" = "my-feature" ]
  [ "$ISSUE_NN" = "01" ]
}

# === check_discovery — discovery.json persistence =========================

@test "finalize_run — drain mode writes per-feature-section SUMMARY.md" {
  # End-to-end: plant feature outcomes + dispatch rows, fire finalize_run,
  # then verify the SUMMARY.md file matches the multi-feature shape.
  HOST_RUNNER_STATE="$BATS_TEST_TMPDIR/state"
  HOST_LOCK="$HOST_RUNNER_STATE/lock"
  mkdir -p "$HOST_RUNNER_STATE"
  RUN_DIR="$BATS_TEST_TMPDIR/run-drain-summary"
  mkdir -p "$RUN_DIR"
  RUN_TS="20260513-101010"
  RUN_START_CLOCK="10:10:10"
  RUN_FEATURE=""
  RUN_MODE="drain"
  RUN_PREFLIGHT_INVARIANT=""
  RUN_STOP_REASON="completed"
  RUNNER_INTERRUPTED=0
  RUN_FEATURE_OUTCOMES=(
    "alpha|drained"
    "beta|skip:fetch-failed"
    "gamma|drained"
    "delta|feature-snapshot-failed"
  )
  RUN_DISPATCHES=(
    "alpha|01|alpha/01|done|42|y"
    "gamma|01|gamma/01|in-review|13|"
  )

  ( finalize_run ) || true

  [ -f "$RUN_DIR/SUMMARY.md" ]
  # Heading reflects multi-feature shape (not a feature slug).
  grep -q '^# AFK runner — multi-feature drain$' "$RUN_DIR/SUMMARY.md"
  # Run-level stop reason.
  grep -q -- '- Stop reason: completed$' "$RUN_DIR/SUMMARY.md"
  # Per-feature sections in encounter order — verified by line-number ordering.
  local a b c d
  a="$(grep -n '^## alpha — drained$' "$RUN_DIR/SUMMARY.md" | cut -d: -f1)"
  b="$(grep -n '^## beta — skipped: fetch-failed$' "$RUN_DIR/SUMMARY.md" | cut -d: -f1)"
  c="$(grep -n '^## gamma — drained$' "$RUN_DIR/SUMMARY.md" | cut -d: -f1)"
  d="$(grep -n '^## delta — feature-snapshot-failed$' "$RUN_DIR/SUMMARY.md" | cut -d: -f1)"
  [ -n "$a" ] && [ -n "$b" ] && [ -n "$c" ] && [ -n "$d" ]
  [ "$a" -lt "$b" ] && [ "$b" -lt "$c" ] && [ "$c" -lt "$d" ]
  # Drained features carry per-issue rows; skipped/snapshot-failed do not.
  grep -qF '| alpha/01 | done | 42s | - | [alpha/01.log](alpha/01.log) [alpha/01-review.log](alpha/01-review.log) |' "$RUN_DIR/SUMMARY.md"
  grep -qF '| gamma/01 | in-review | 13s | - | [gamma/01.log](gamma/01.log) |' "$RUN_DIR/SUMMARY.md"
  # Skipped features don't get a per-issue row.
  ! grep -qF '| beta/' "$RUN_DIR/SUMMARY.md"
  ! grep -qF '| delta/' "$RUN_DIR/SUMMARY.md"
}

@test "check_discovery — persists DISCOVERY_JSON to <run-dir>/discovery.json" {
  HOST_REPO="$BATS_TEST_TMPDIR/disc-host"
  mkdir -p "$HOST_REPO/.features/alpha" "$HOST_REPO/.features/beta"
  # check_discovery shells out to the binding's tracker-snapshot script.
  # Plant a minimal stub that emits a deterministic discovery list.
  local stub_dir="$HOST_REPO/docs/formann/issue-tracker"
  mkdir -p "$stub_dir"
  cat >"$stub_dir/tracker-snapshot" <<'EOF'
#!/usr/bin/env bash
if [ "$1" = "--list" ]; then
  printf '["alpha","beta"]\n'
fi
EOF
  chmod +x "$stub_dir/tracker-snapshot"

  RUN_DIR="$BATS_TEST_TMPDIR/disc-run"
  mkdir -p "$RUN_DIR"
  DISCOVERY_JSON=""
  trap - EXIT

  check_discovery

  [ -f "$RUN_DIR/discovery.json" ]
  # Round-trip via jq so the test asserts JSON equivalence (whitespace
  # tolerant), not byte-for-byte equality.
  diff <(jq -S '.' "$RUN_DIR/discovery.json") <(jq -S '.' <<<'["alpha","beta"]')
}

# Regression: framework-shaped skills (`.claude/skills/implement` and friends)
# are symlinks resolving through `.formann/` to the Formann checkout. Without
# the `.formann` bind-mount, the container sees a dangling symlink and claude
# reports `Unknown command: /implement` on first dispatch. Pin the mount.
@test "run_sandbox_container — bind-mounts .formann into /repo so framework-shaped skills resolve" {
  HOST_REPO="$BATS_TEST_TMPDIR/host"
  HOST_CHECKOUT="$BATS_TEST_TMPDIR/checkout"
  HOST_RUNNER_STATE="$BATS_TEST_TMPDIR/runner-state"
  MVN_VOLUME="test-mvn"
  NET_NAME="test-net"
  RUNNER_IMAGE_NAME="test-image"
  TOKEN="test-token"
  RUNNER_INTERRUPTED=0
  IN_FLIGHT_CID_FILE=""
  mkdir -p "$HOST_REPO" "$HOST_CHECKOUT" "$HOST_RUNNER_STATE"

  local args_file="$BATS_TEST_TMPDIR/docker-args"
  docker() {
    printf '%s\n' "$@" > "$args_file"
    return 0
  }

  run_sandbox_container "$BATS_TEST_TMPDIR/log" claude -p "/implement f/01"

  # The mount value `<host-repo>/.formann:/repo/.formann:ro` must appear as a
  # standalone arg on the `docker run` line (i.e. the value following a `-v`).
  grep -qFx -- "$HOST_REPO/.formann:/repo/.formann:ro" "$args_file"
}

# Pin the docs/formann bind-mount: the dispatch container reads the consumer's
# binding-view directory directly from the host, paralleling the .formann mount.
# Without it, the container falls back to a stale or missing docs/formann tree
# in the runner-checkout after git clean scrubs the gitignored installer products.
@test "run_sandbox_container — bind-mounts docs/formann into /repo so binding views are live from host" {
  HOST_REPO="$BATS_TEST_TMPDIR/host"
  HOST_CHECKOUT="$BATS_TEST_TMPDIR/checkout"
  HOST_RUNNER_STATE="$BATS_TEST_TMPDIR/runner-state"
  MVN_VOLUME="test-mvn"
  NET_NAME="test-net"
  RUNNER_IMAGE_NAME="test-image"
  TOKEN="test-token"
  RUNNER_INTERRUPTED=0
  IN_FLIGHT_CID_FILE=""
  mkdir -p "$HOST_REPO" "$HOST_CHECKOUT" "$HOST_RUNNER_STATE"

  local args_file="$BATS_TEST_TMPDIR/docker-args"
  docker() {
    printf '%s\n' "$@" > "$args_file"
    return 0
  }

  run_sandbox_container "$BATS_TEST_TMPDIR/log" claude -p "/implement f/01"

  # The mount value `<host-repo>/docs/formann:/repo/docs/formann:ro` must appear
  # as a standalone arg on the `docker run` line (i.e. the value following a `-v`).
  grep -qFx -- "$HOST_REPO/docs/formann:/repo/docs/formann:ro" "$args_file"
}

# Helper: minimal `run_sandbox_container` test scaffolding. Sets the globals
# the function reads, populates `$HOST_REPO/.claude/<subs>` for each requested
# subdir, stubs `docker` to capture its argv into $args_file, and runs the
# given wrapper (defaults to `run_sandbox_container`). Sets the variables
# `args_file` and `claude_subs_present` in the caller for assertions.
#
# Args: $1 = space-separated list of `.claude/<sub>` dirs to create on host
#       $2 = wrapper to invoke (`run_sandbox_container` | `run_dispatch_container` | `run_gate_container`)
_setup_mount_capture() {
  local subs="$1" wrapper="${2:-run_sandbox_container}"
  HOST_REPO="$BATS_TEST_TMPDIR/host"
  HOST_CHECKOUT="$BATS_TEST_TMPDIR/checkout"
  HOST_RUNNER_STATE="$BATS_TEST_TMPDIR/runner-state"
  MVN_VOLUME="test-mvn"
  NET_NAME="test-net"
  RUNNER_IMAGE_NAME="test-image"
  TOKEN="test-token"
  RUNNER_INTERRUPTED=0
  IN_FLIGHT_CID_FILE=""
  GATE_PROMPT_PATH="$BATS_TEST_TMPDIR/gate-prompt"
  mkdir -p "$HOST_REPO" "$HOST_CHECKOUT" "$HOST_RUNNER_STATE"
  printf 'gate prompt\n' > "$GATE_PROMPT_PATH"

  local sub
  for sub in $subs; do
    mkdir -p "$HOST_REPO/.claude/$sub"
  done

  args_file="$BATS_TEST_TMPDIR/docker-args"
  docker() {
    printf '%s\n' "$@" > "$args_file"
    return 0
  }

  case "$wrapper" in
    run_dispatch_container) run_dispatch_container "f/01" "$BATS_TEST_TMPDIR/log" ;;
    run_gate_container)     run_gate_container     "f/01" "$BATS_TEST_TMPDIR/log" ;;
    *)                      run_sandbox_container "$BATS_TEST_TMPDIR/log" claude -p "/implement f/01" ;;
  esac
}

@test "run_sandbox_container — mounts .claude/{skills,agents,rules} :ro when all three exist on host" {
  _setup_mount_capture "skills agents rules"

  grep -qFx -- "$HOST_REPO/.claude/skills:/repo/.claude/skills:ro" "$args_file"
  grep -qFx -- "$HOST_REPO/.claude/agents:/repo/.claude/agents:ro" "$args_file"
  grep -qFx -- "$HOST_REPO/.claude/rules:/repo/.claude/rules:ro" "$args_file"
}

@test "run_sandbox_container — omits the .claude/rules mount when the host dir is absent" {
  _setup_mount_capture "skills agents"

  grep -qFx -- "$HOST_REPO/.claude/skills:/repo/.claude/skills:ro" "$args_file"
  grep -qFx -- "$HOST_REPO/.claude/agents:/repo/.claude/agents:ro" "$args_file"
  ! grep -qF -- "/.claude/rules:" "$args_file"
}

@test "run_sandbox_container — omits every .claude/* mount when none of the host dirs exist" {
  # `set -u` mirrors production (main() enables `set -euo pipefail`). It also
  # pins the defensive `${arr[@]+"${arr[@]}"}` expansion of the mount array:
  # on bash 3.2 (macOS /bin/bash), the naive `"${arr[@]}"` form errors with
  # `unbound variable` when the array is empty. Without `set -u` here, a
  # regression to the naive form would silently pass this test and break in
  # production on a host with no `.claude/{skills,agents,rules}` dirs.
  set -u
  _setup_mount_capture ""

  # Sanity: the unconditional .formann mount is still present.
  grep -qFx -- "$HOST_REPO/.formann:/repo/.formann:ro" "$args_file"
  ! grep -qF -- "/.claude/skills:" "$args_file"
  ! grep -qF -- "/.claude/agents:" "$args_file"
  ! grep -qF -- "/.claude/rules:" "$args_file"
}

@test "run_sandbox_container — mounts an existing-but-empty .claude/<sub> (no special-casing)" {
  _setup_mount_capture "skills"
  # The .claude/skills dir is created by the helper but left empty — the mount
  # is still added, mirroring the AC contract.

  grep -qFx -- "$HOST_REPO/.claude/skills:/repo/.claude/skills:ro" "$args_file"
}

@test "run_sandbox_container — does not mount any other .claude/* subdir than skills, agents, rules" {
  HOST_REPO="$BATS_TEST_TMPDIR/host"
  mkdir -p "$HOST_REPO/.claude/skills" "$HOST_REPO/.claude/settings.local.json.d" \
           "$HOST_REPO/.claude/plugins" "$HOST_REPO/.claude/worktrees" \
           "$HOST_REPO/.claude/plans" "$HOST_REPO/.claude/scripts" \
           "$HOST_REPO/.claude/docs"
  _setup_mount_capture "skills"

  grep -qFx -- "$HOST_REPO/.claude/skills:/repo/.claude/skills:ro" "$args_file"
  # No other .claude subpath leaks into the docker args.
  ! grep -qF -- "/.claude/plugins:"   "$args_file"
  ! grep -qF -- "/.claude/worktrees:" "$args_file"
  ! grep -qF -- "/.claude/plans:"     "$args_file"
  ! grep -qF -- "/.claude/scripts:"   "$args_file"
  ! grep -qF -- "/.claude/docs:"      "$args_file"
  ! grep -qF -- "settings.local"      "$args_file"
}

# `run_dispatch_container` and `run_gate_container` both funnel through
# `run_sandbox_container`, so the mount logic is implemented in one place — but
# the brief asks for coverage at both invocation sites. Pin them.
@test "run_dispatch_container — forwards .claude/{skills,agents,rules} mounts when host has them" {
  _setup_mount_capture "skills agents rules" run_dispatch_container

  grep -qFx -- "$HOST_REPO/.claude/skills:/repo/.claude/skills:ro" "$args_file"
  grep -qFx -- "$HOST_REPO/.claude/agents:/repo/.claude/agents:ro" "$args_file"
  grep -qFx -- "$HOST_REPO/.claude/rules:/repo/.claude/rules:ro" "$args_file"
}

@test "run_gate_container — forwards .claude/{skills,agents,rules} mounts when host has them" {
  _setup_mount_capture "skills agents rules" run_gate_container

  grep -qFx -- "$HOST_REPO/.claude/skills:/repo/.claude/skills:ro" "$args_file"
  grep -qFx -- "$HOST_REPO/.claude/agents:/repo/.claude/agents:ro" "$args_file"
  grep -qFx -- "$HOST_REPO/.claude/rules:/repo/.claude/rules:ro" "$args_file"
}

# === binding_native_ref — pure lookup =========================================
#
# Binding-agnostic ref resolution: given (feature, nn, snapshot_json), returns
# the binding-native ref from the snapshot's `ref` field. The ref shape varies
# by binding (local-markdown: `feature/NN`; github-issues: `#N`). This is the
# single source of truth for nn → native ref resolution in the runner.

@test "binding_native_ref — returns correct ref for local-markdown-shaped snapshot" {
  local snap='{"feature":"f","issues":[{"ref":"f/01","nn":"01","status":"ready-for-agent","category":"enhancement","type":"AFK","blocked_by":[],"eligible":true}]}'
  result="$(binding_native_ref "f" "01" "$snap")"
  [ "$result" = "f/01" ]
}

@test "binding_native_ref — returns correct ref for github-issues-shaped snapshot" {
  local snap='{"feature":"f","issues":[{"ref":"#42","nn":"42","status":"ready-for-agent","category":"enhancement","type":"AFK","blocked_by":[],"eligible":true}]}'
  result="$(binding_native_ref "f" "42" "$snap")"
  [ "$result" = "#42" ]
}

@test "binding_native_ref — fails with non-zero exit and stderr message for unknown (feature, N)" {
  local snap='{"feature":"f","issues":[{"ref":"f/01","nn":"01","status":"ready-for-agent","category":"enhancement","type":"AFK","blocked_by":[],"eligible":true}]}'
  run binding_native_ref "f" "99" "$snap"
  [ "$status" -ne 0 ]
  [[ "$output" == *"binding_native_ref"* ]]
  [[ "$output" == *"not found"* ]]
}

@test "binding_native_ref — picks the right ref when snapshot has multiple issues" {
  local snap='{"feature":"f","issues":[
    {"ref":"#10","nn":"10","status":"done","category":"enhancement","type":"AFK","blocked_by":[],"eligible":false},
    {"ref":"#42","nn":"42","status":"ready-for-agent","category":"bug","type":"AFK","blocked_by":[],"eligible":true}
  ]}'
  result="$(binding_native_ref "f" "10" "$snap")"
  [ "$result" = "#10" ]
  result="$(binding_native_ref "f" "42" "$snap")"
  [ "$result" = "#42" ]
}

# Cross-padding tolerance: `binding_native_ref` is the second site (after the
# `run_single` eligibility gate) that receives user-typed `nn` from `--issue
# <feature>/<NN>`. local-markdown emits zero-padded nn (`"03"`); github-issues
# emits unpadded nn (`"3"`). The lookup compares numerically so the user can
# type either padding against either binding.

@test "binding_native_ref — padded nn resolves unpadded snapshot entry (03 vs 3)" {
  local snap='{"feature":"f","issues":[{"ref":"#3","nn":"3","status":"ready-for-agent","category":"enhancement","type":"AFK","blocked_by":[],"eligible":true}]}'
  result="$(binding_native_ref "f" "03" "$snap")"
  [ "$result" = "#3" ]
}

@test "binding_native_ref — unpadded nn resolves padded snapshot entry (3 vs 03)" {
  local snap='{"feature":"f","issues":[{"ref":"f/03","nn":"03","status":"ready-for-agent","category":"enhancement","type":"AFK","blocked_by":[],"eligible":true}]}'
  result="$(binding_native_ref "f" "3" "$snap")"
  [ "$result" = "f/03" ]
}

# === dispatch_one — GH-shaped ref plumbing ====================================
#
# Verifies that dispatch_one resolves the binding-native ref via
# binding_native_ref and forwards it to the dispatch container and classifier
# without regex-parsing. The ref shape "#N" (github-issues binding) differs
# from the local-markdown "feature/NN" shape — both must work identically.

@test "dispatch_one — GH-shaped binding-native ref forwarded to dispatch container and classifier" {
  setup_dispatch_one_test
  # Override snapshots to use GH-style refs: ref="#42", nn="42".
  local snap_phase_file="$TEST_SNAPSHOT_PHASE"
  echo "pre" >"$snap_phase_file"
  take_snapshot() {
    local phase
    phase="$(cat "$snap_phase_file")"
    case "$phase" in
      pre)
        echo "post-implement" >"$snap_phase_file"
        printf '{"feature":"f","issues":[{"ref":"#42","nn":"42","status":"ready-for-agent","category":"enhancement","type":"AFK","blocked_by":[],"eligible":true}]}'
        ;;
      post-implement)
        echo "post-gate" >"$snap_phase_file"
        printf '{"feature":"f","issues":[{"ref":"#42","nn":"42","status":"in-review","category":"enhancement","type":"AFK","blocked_by":[],"eligible":false}]}'
        ;;
      post-gate)
        printf '{"feature":"f","issues":[{"ref":"#42","nn":"42","status":"done","category":"enhancement","type":"AFK","blocked_by":[],"eligible":false}]}'
        ;;
    esac
  }

  # Capture the ref that run_dispatch_container and run_gate_container receive.
  TEST_DISPATCH_REF="$BATS_TEST_TMPDIR/dispatch-ref"
  TEST_GATE_REF="$BATS_TEST_TMPDIR/gate-ref"
  run_dispatch_container() {
    printf '%s' "$1" >"$TEST_DISPATCH_REF"
    git -C "$HOST_CHECKOUT" -c user.email=t@t -c user.name=t \
      commit --allow-empty --quiet -m "tracker: #42 (test)"
    return 0
  }
  run_gate_container() {
    printf '%s' "$1" >"$TEST_GATE_REF"
    return 0
  }
  propagate_feature() { return 0; }

  RUN_DISPATCHES=()
  set +e
  dispatch_one "f" "42" "$TEST_RUN_DIR"
  local rc=$?
  set -e

  [ "$rc" -eq 0 ]
  # The binding-native ref "#42" was forwarded to both dispatch stages.
  [ "$(cat "$TEST_DISPATCH_REF")" = "#42" ]
  [ "$(cat "$TEST_GATE_REF")" = "#42" ]
  # record_dispatch carries feature, nn, and native ref "#42".
  [ "${#RUN_DISPATCHES[@]}" -eq 1 ]
  [[ "${RUN_DISPATCHES[0]}" == "f|42|#42|done|"* ]]
}

# === ensure_runner_remote =====================================================

setup_runner_remote_test() {
  HOST_REPO="$BATS_TEST_TMPDIR/host"
  HOST_CHECKOUT="$BATS_TEST_TMPDIR/checkout"
  mkdir -p "$HOST_REPO"
  git -C "$HOST_REPO" init --quiet --initial-branch=main
  git -C "$HOST_REPO" -c user.email=t@t -c user.name=t \
    commit --allow-empty --quiet -m init
}

@test "ensure_runner_remote — fresh repo: adds runner remote pointing at HOST_CHECKOUT" {
  setup_runner_remote_test

  ensure_runner_remote

  url="$(git -C "$HOST_REPO" remote get-url runner)"
  [ "$url" = "$HOST_CHECKOUT" ]
}

@test "ensure_runner_remote — remote already exists with expected URL: no-op" {
  setup_runner_remote_test
  git -C "$HOST_REPO" remote add runner "$HOST_CHECKOUT"

  run ensure_runner_remote
  assert_success

  url="$(git -C "$HOST_REPO" remote get-url runner)"
  [ "$url" = "$HOST_CHECKOUT" ]
  # No duplicate remote entries.
  count="$(git -C "$HOST_REPO" remote | grep -c '^runner$')"
  [ "$count" -eq 1 ]
}

@test "ensure_runner_remote — remote exists with different URL: refuses with error" {
  setup_runner_remote_test
  git -C "$HOST_REPO" remote add runner "/some/other/path"

  # Override fail_invariant so the exit 2 doesn't kill the test process.
  RUN_PREFLIGHT_INVARIANT=""
  fail_invariant() { RUN_PREFLIGHT_INVARIANT="$1"; return 2; }

  set +e
  ensure_runner_remote
  local rc=$?
  set -e

  [ "$rc" -ne 0 ]
  [ "$RUN_PREFLIGHT_INVARIANT" = "runner-remote" ]
  # The conflicting URL still in place (helper didn't overwrite it).
  url="$(git -C "$HOST_REPO" remote get-url runner)"
  [ "$url" = "/some/other/path" ]
}

@test "ensure_runner_remote — mismatch stderr is multi-line: recovery commands on own lines" {
  # Regression: ensure_runner_remote passed three separate positional args to
  # fail_invariant, which joined them with single spaces into one long line.
  # The fix embeds newlines in the message string so recovery commands each
  # appear on their own line.
  setup_runner_remote_test
  git -C "$HOST_REPO" remote add runner "/some/other/path"

  stderr_out="$(ensure_runner_remote 2>&1)" || true

  # The recovery command must appear on its own line (not joined with spaces).
  echo "$stderr_out" | grep -q "^Fix with:" || {
    echo "expected 'Fix with:' on its own line; got:"
    echo "$stderr_out"
    false
  }
  echo "$stderr_out" | grep -q "^(or:" || {
    echo "expected '(or:' on its own line; got:"
    echo "$stderr_out"
    false
  }
}

# === Regression guard — runner never calls git push =========================
#
# The runner propagates via `git fetch` (host fetches from runner-checkout),
# never via `git push`. A future change accidentally adding a `git push`
# would silently break the sandbox model (no host credentials in container)
# and widen the mutation surface. Pin the current count so the suite catches
# any regression.

@test "regression guard — no git push in runner source scripts" {
  # Pin that the runner scripts never call 'git push'. The runner propagates
  # via `git fetch` (host fetches from runner-checkout); a `git push` would
  # widen the mutation surface and break the sandbox model.
  local count
  count="$(grep -RIn "git push" "$BATS_TEST_DIRNAME/../" \
    --include="*.sh" 2>/dev/null | wc -l | tr -d ' ')"
  [ "$count" -eq 0 ]
}

# === sweep_stale_parking_refs ==============================================
#
# Sweeps parking refs under refs/remotes/runner/* whose tip commit is
# reachable from another ref on host. Safe-by-construction: deletes only
# refs whose work is provably preserved elsewhere.

_setup_sweep_test() {
  HOST_REPO="$BATS_TEST_TMPDIR/host"
  mkdir -p "$HOST_REPO"
  git -c init.defaultBranch=main init --quiet "$HOST_REPO"
  git -C "$HOST_REPO" -c user.email=t@t -c user.name=t \
    commit --allow-empty --quiet -m "root"
  RUN_SWEPT_REFS=()
}

@test "sweep_stale_parking_refs — (a) tip reachable from refs/heads/main is deleted" {
  _setup_sweep_test
  local main_sha
  main_sha="$(git -C "$HOST_REPO" rev-parse refs/heads/main)"
  git -C "$HOST_REPO" update-ref "refs/remotes/runner/foo" "$main_sha"

  local sw_log="$BATS_TEST_TMPDIR/sw.log"
  sweep_stale_parking_refs >"$sw_log" 2>&1

  # Parking ref is gone.
  ! git -C "$HOST_REPO" rev-parse --verify "refs/remotes/runner/foo" >/dev/null 2>&1
  # Swept refs array populated.
  [ "${#RUN_SWEPT_REFS[@]}" -eq 1 ]
  [ "${RUN_SWEPT_REFS[0]}" = "refs/remotes/runner/foo" ]
  # Log line names the deleted ref and the witnessing ref.
  grep -q "swept stale parking ref refs/remotes/runner/foo" "$sw_log"
  grep -q "reachable from refs/heads/main" "$sw_log"
}

@test "sweep_stale_parking_refs — (b) tip reachable only from parking ref is kept (source untouched too)" {
  _setup_sweep_test
  # Create an orphaned commit reachable only from the parking ref.
  local orphan_sha
  orphan_sha="$(git -C "$HOST_REPO" commit-tree \
    "$(git -C "$HOST_REPO" rev-parse 'refs/heads/main^{tree}')" \
    -m "parking-only")"
  git -C "$HOST_REPO" update-ref "refs/remotes/runner/bar" "$orphan_sha"

  # Runner-checkout has a source branch for this slug. Locks in that when
  # the parking ref is kept (proof 1 fails), the source-side block is
  # skipped entirely — no chance of deleting the source.
  HOST_CHECKOUT="$BATS_TEST_TMPDIR/checkout"
  git clone --quiet "$HOST_REPO" "$HOST_CHECKOUT"
  local checkout_main_sha
  checkout_main_sha="$(git -C "$HOST_CHECKOUT" rev-parse refs/heads/main)"
  git -C "$HOST_CHECKOUT" update-ref "refs/heads/bar" "$checkout_main_sha"

  sweep_stale_parking_refs >/dev/null 2>&1

  # Parking ref preserved on host.
  git -C "$HOST_REPO" rev-parse --verify "refs/remotes/runner/bar" >/dev/null 2>&1
  # Source branch preserved on the runner-checkout.
  git -C "$HOST_CHECKOUT" rev-parse --verify "refs/heads/bar" >/dev/null 2>&1
  [ "${#RUN_SWEPT_REFS[@]}" -eq 0 ]
}

@test "sweep_stale_parking_refs — (c) tip reachable from refs/remotes/origin/* is deleted" {
  _setup_sweep_test
  # Create an orphaned commit — not reachable from refs/heads/main.
  local feat_sha
  feat_sha="$(git -C "$HOST_REPO" commit-tree \
    "$(git -C "$HOST_REPO" rev-parse 'refs/heads/main^{tree}')" \
    -m "feature commit")"
  # Expose it via origin/feature and a parking ref.
  git -C "$HOST_REPO" update-ref "refs/remotes/origin/feature" "$feat_sha"
  git -C "$HOST_REPO" update-ref "refs/remotes/runner/feat" "$feat_sha"

  local sw_log="$BATS_TEST_TMPDIR/sw.log"
  sweep_stale_parking_refs >"$sw_log" 2>&1

  # Parking ref swept — work preserved via origin/feature.
  ! git -C "$HOST_REPO" rev-parse --verify "refs/remotes/runner/feat" >/dev/null 2>&1
  [ "${#RUN_SWEPT_REFS[@]}" -eq 1 ]
  grep -q "reachable from refs/remotes/origin/feature" "$sw_log"
}

@test "sweep_stale_parking_refs — (d) refs/remotes/runner/HEAD is not deleted" {
  _setup_sweep_test
  local main_sha
  main_sha="$(git -C "$HOST_REPO" rev-parse refs/heads/main)"
  # Simulate HEAD ref git creates for the runner remote (points at main's tip
  # so it would be swept if not skipped).
  git -C "$HOST_REPO" update-ref "refs/remotes/runner/HEAD" "$main_sha"
  # Also create a stale parking ref to prove the sweep ran.
  git -C "$HOST_REPO" update-ref "refs/remotes/runner/stale" "$main_sha"

  sweep_stale_parking_refs >/dev/null 2>&1

  # HEAD still exists.
  git -C "$HOST_REPO" rev-parse --verify "refs/remotes/runner/HEAD" >/dev/null 2>&1
  # The stale parking ref was swept.
  ! git -C "$HOST_REPO" rev-parse --verify "refs/remotes/runner/stale" >/dev/null 2>&1
  [ "${#RUN_SWEPT_REFS[@]}" -eq 1 ]
  [ "${RUN_SWEPT_REFS[0]}" = "refs/remotes/runner/stale" ]
}

@test "sweep_stale_parking_refs — (e) corrupt tip is skipped with warning, sweep continues, exit success" {
  _setup_sweep_test
  local main_sha
  main_sha="$(git -C "$HOST_REPO" rev-parse refs/heads/main)"
  # Create a corrupt parking ref (non-existent object SHA).
  mkdir -p "$HOST_REPO/.git/refs/remotes/runner"
  printf '%s\n' "deadbeefdeadbeefdeadbeefdeadbeefdeadbeef" \
    >"$HOST_REPO/.git/refs/remotes/runner/corrupt"
  # A valid parking ref that should be swept.
  git -C "$HOST_REPO" update-ref "refs/remotes/runner/stale" "$main_sha"

  local sw_log="$BATS_TEST_TMPDIR/sw.log"
  set +e
  sweep_stale_parking_refs >"$sw_log" 2>&1
  local rc=$?
  set -e

  # Exit 0 even with a corrupt ref present.
  [ "$rc" -eq 0 ]
  # Warning emitted for the corrupt ref.
  grep -q "skipping.*corrupt" "$sw_log"
  # Sweep continued and deleted the valid stale ref.
  ! git -C "$HOST_REPO" rev-parse --verify "refs/remotes/runner/stale" >/dev/null 2>&1
  [ "${#RUN_SWEPT_REFS[@]}" -eq 1 ]
  [ "${RUN_SWEPT_REFS[0]}" = "refs/remotes/runner/stale" ]
}

# Helper for sweep tests that also exercise the source-side proof on the
# runner-checkout. HOST_CHECKOUT is cloned from HOST_REPO so the two repos
# share object history — operations on either side reference the same SHAs,
# matching the production relationship between the host repo and the
# runner-checkout. The source branch (if needed) is created by the test
# itself so each test controls the exact tip relationship.
_setup_sweep_test_with_checkout() {
  _setup_sweep_test
  HOST_CHECKOUT="$BATS_TEST_TMPDIR/checkout"
  git clone --quiet "$HOST_REPO" "$HOST_CHECKOUT"
}

@test "sweep_stale_parking_refs — (f) source branch on runner-checkout is deleted when parking ref is swept" {
  _setup_sweep_test_with_checkout
  local main_sha
  main_sha="$(git -C "$HOST_REPO" rev-parse refs/heads/main)"
  # Source branch on runner-checkout at the same tip as the parking ref —
  # the normal post-propagation state for a slug.
  git -C "$HOST_CHECKOUT" update-ref "refs/heads/foo" "$main_sha"
  # Host parking ref reachable from refs/heads/main.
  git -C "$HOST_REPO" update-ref "refs/remotes/runner/foo" "$main_sha"

  local sw_log="$BATS_TEST_TMPDIR/sw.log"
  sweep_stale_parking_refs >"$sw_log" 2>&1

  # Both refs gone — otherwise the next `git fetch runner` would restore
  # the host parking ref from the surviving source. `[ -z "$(for-each-ref)" ]`
  # is the set-e-safe negation: `! cmd` is exempt from set -e and would
  # silently pass even if the ref still existed.
  [ -z "$(git -C "$HOST_REPO" for-each-ref --format='%(refname)' refs/remotes/runner/foo)" ]
  [ -z "$(git -C "$HOST_CHECKOUT" for-each-ref --format='%(refname)' refs/heads/foo)" ]
  # Both deletions logged.
  grep -q "swept stale parking ref refs/remotes/runner/foo" "$sw_log"
  grep -q "swept runner-checkout source refs/heads/foo" "$sw_log"
  [ "${#RUN_SWEPT_REFS[@]}" -eq 1 ]
  [ "${RUN_SWEPT_REFS[0]}" = "refs/remotes/runner/foo" ]
}

@test "sweep_stale_parking_refs — (g) source ahead of parking ref is kept (no unpropagated commits lost)" {
  _setup_sweep_test_with_checkout
  local main_sha
  main_sha="$(git -C "$HOST_REPO" rev-parse refs/heads/main)"
  # Host parking ref at main's tip — first reachability proof would pass.
  git -C "$HOST_REPO" update-ref "refs/remotes/runner/foo" "$main_sha"
  # Source branch on runner-checkout points at a commit HOST_REPO does
  # not have — simulating a prior dispatch whose propagate-step failed
  # before publishing. The unpropagated commit lives only on the
  # runner-checkout side.
  git -C "$HOST_CHECKOUT" -c user.email=t@t -c user.name=t \
    checkout -b foo --quiet
  git -C "$HOST_CHECKOUT" -c user.email=t@t -c user.name=t \
    commit --allow-empty --quiet -m "unpropagated work"

  local sw_log="$BATS_TEST_TMPDIR/sw.log"
  sweep_stale_parking_refs >"$sw_log" 2>&1

  # Both refs preserved — deleting the source would lose the unpropagated
  # commit; deleting only the host ref would silently reintroduce the
  # original resurrection bug on the next fetch.
  git -C "$HOST_REPO" rev-parse --verify "refs/remotes/runner/foo" >/dev/null 2>&1
  git -C "$HOST_CHECKOUT" rev-parse --verify "refs/heads/foo" >/dev/null 2>&1
  # Warning logged.
  grep -q "keeping refs/remotes/runner/foo.*refs/heads/foo" "$sw_log"
  [ "${#RUN_SWEPT_REFS[@]}" -eq 0 ]
}

@test "sweep_stale_parking_refs — (h) corrupt source tip skips sweep with warning" {
  _setup_sweep_test_with_checkout
  local main_sha
  main_sha="$(git -C "$HOST_REPO" rev-parse refs/heads/main)"
  git -C "$HOST_REPO" update-ref "refs/remotes/runner/foo" "$main_sha"
  # Create a source ref entry whose tip object is missing from the
  # runner-checkout's object DB.
  mkdir -p "$HOST_CHECKOUT/.git/refs/heads"
  printf '%s\n' "deadbeefdeadbeefdeadbeefdeadbeefdeadbeef" \
    >"$HOST_CHECKOUT/.git/refs/heads/foo"

  local sw_log="$BATS_TEST_TMPDIR/sw.log"
  sweep_stale_parking_refs >"$sw_log" 2>&1

  # Both refs preserved — we can't prove the source's work is preserved
  # on host when its tip is unreadable, so we don't touch anything.
  git -C "$HOST_REPO" rev-parse --verify "refs/remotes/runner/foo" >/dev/null 2>&1
  [ -f "$HOST_CHECKOUT/.git/refs/heads/foo" ]
  # Warning logged.
  grep -q "refs/heads/foo tip unreadable" "$sw_log"
  [ "${#RUN_SWEPT_REFS[@]}" -eq 0 ]
}

@test "sweep_stale_parking_refs — (i) source-delete failure leaves host parking ref intact" {
  _setup_sweep_test_with_checkout
  local main_sha
  main_sha="$(git -C "$HOST_REPO" rev-parse refs/heads/main)"
  git -C "$HOST_REPO" update-ref "refs/remotes/runner/foo" "$main_sha"
  git -C "$HOST_CHECKOUT" update-ref "refs/heads/foo" "$main_sha"
  # Block update-ref by occupying the lock-file path it would create.
  # Git's ref-lock mechanism refuses to proceed when <ref>.lock already
  # exists (simulates a concurrent git operation holding the ref).
  printf 'sentinel\n' >"$HOST_CHECKOUT/.git/refs/heads/foo.lock"

  local sw_log="$BATS_TEST_TMPDIR/sw.log"
  set +e
  sweep_stale_parking_refs >"$sw_log" 2>&1
  local rc=$?
  set -e

  # Sweep does not abort the run.
  [ "$rc" -eq 0 ]
  # Host parking ref NOT deleted — proceeding without the source delete
  # would let the next IDE auto-fetch silently restore it from the
  # surviving source, reintroducing the original cluttering bug.
  git -C "$HOST_REPO" rev-parse --verify "refs/remotes/runner/foo" >/dev/null 2>&1
  # Source ref preserved (delete failed).
  git -C "$HOST_CHECKOUT" rev-parse --verify "refs/heads/foo" >/dev/null 2>&1
  # Warning logged.
  grep -q "failed to delete runner-checkout refs/heads/foo" "$sw_log"
  [ "${#RUN_SWEPT_REFS[@]}" -eq 0 ]
}

@test "sweep_stale_parking_refs — (j) host parking ref deleted when source is absent on runner-checkout" {
  _setup_sweep_test_with_checkout
  local main_sha
  main_sha="$(git -C "$HOST_REPO" rev-parse refs/heads/main)"
  git -C "$HOST_REPO" update-ref "refs/remotes/runner/foo" "$main_sha"
  # No refs/heads/foo on HOST_CHECKOUT — simulates a slug whose source
  # branch has already been cleaned manually.

  local sw_log="$BATS_TEST_TMPDIR/sw.log"
  sweep_stale_parking_refs >"$sw_log" 2>&1

  # Host parking ref deleted (the only thing there was to delete).
  [ -z "$(git -C "$HOST_REPO" for-each-ref --format='%(refname)' refs/remotes/runner/foo)" ]
  # No source-side log line (nothing to delete). `run` + status check
  # is set-e-safe; a bare `! grep` would be exempt from set -e and
  # silently pass even if the log line WERE present.
  run grep -q "swept runner-checkout source" "$sw_log"
  [ "$status" -ne 0 ]
  # Host-side log line emitted.
  grep -q "swept stale parking ref refs/remotes/runner/foo" "$sw_log"
  [ "${#RUN_SWEPT_REFS[@]}" -eq 1 ]
  [ "${RUN_SWEPT_REFS[0]}" = "refs/remotes/runner/foo" ]
}

@test "sweep_stale_parking_refs — (k) source branch that is current HEAD is deleted; runner-checkout stays functional" {
  _setup_sweep_test_with_checkout
  local main_sha
  main_sha="$(git -C "$HOST_REPO" rev-parse refs/heads/main)"
  git -C "$HOST_REPO" update-ref "refs/remotes/runner/foo" "$main_sha"
  # Source branch is the current HEAD on the runner-checkout — the
  # steady-state for the slug the runner last dispatched.
  git -C "$HOST_CHECKOUT" -c user.email=t@t -c user.name=t \
    checkout -b foo --quiet

  local sw_log="$BATS_TEST_TMPDIR/sw.log"
  sweep_stale_parking_refs >"$sw_log" 2>&1

  # Both refs gone.
  [ -z "$(git -C "$HOST_REPO" for-each-ref --format='%(refname)' refs/remotes/runner/foo)" ]
  [ -z "$(git -C "$HOST_CHECKOUT" for-each-ref --format='%(refname)' refs/heads/foo)" ]
  # HEAD on the runner-checkout is now unborn (still symbolic-refs the
  # deleted branch) but the repo remains functional — `git checkout main`
  # succeeds, which is the recovery path `ensure_runner_checkout_on_branch`
  # relies on.
  git -C "$HOST_CHECKOUT" checkout main --quiet
  [ "${#RUN_SWEPT_REFS[@]}" -eq 1 ]
  [ "${RUN_SWEPT_REFS[0]}" = "refs/remotes/runner/foo" ]
}

@test "sweep_stale_parking_refs — (l) source tip in host object DB but no host ref reaches it keeps both refs" {
  _setup_sweep_test_with_checkout
  local main_sha
  main_sha="$(git -C "$HOST_REPO" rev-parse refs/heads/main)"
  git -C "$HOST_REPO" update-ref "refs/remotes/runner/foo" "$main_sha"
  # Source has a commit beyond HOST_REPO's main.
  git -C "$HOST_CHECKOUT" -c user.email=t@t -c user.name=t \
    checkout -b foo --quiet
  git -C "$HOST_CHECKOUT" -c user.email=t@t -c user.name=t \
    commit --allow-empty --quiet -m "unpropagated work"
  # Bring the source's tip object into HOST_REPO via a temp ref, then drop
  # the ref. Distinguishes this case from (g) — there the source tip isn't
  # in HOST_REPO at all; here the object IS in HOST_REPO but unreachable
  # from any host ref. Both must be classified as "source not preserved on
  # host" and skip the sweep.
  git -C "$HOST_REPO" fetch --quiet "$HOST_CHECKOUT" \
    "refs/heads/foo:refs/tmp/imported"
  git -C "$HOST_REPO" update-ref -d "refs/tmp/imported"

  local sw_log="$BATS_TEST_TMPDIR/sw.log"
  sweep_stale_parking_refs >"$sw_log" 2>&1

  # Both refs preserved.
  git -C "$HOST_REPO" rev-parse --verify "refs/remotes/runner/foo" >/dev/null 2>&1
  git -C "$HOST_CHECKOUT" rev-parse --verify "refs/heads/foo" >/dev/null 2>&1
  # Warning logged.
  grep -q "keeping refs/remotes/runner/foo.*refs/heads/foo" "$sw_log"
  [ "${#RUN_SWEPT_REFS[@]}" -eq 0 ]
}

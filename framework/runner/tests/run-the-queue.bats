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

@test "classify_gate_outcome — exit 0 + missing post entry is gate-failed" {
  pre="$(snapshot_one f/01 in-review)"
  post='{"feature":"f","issues":[]}'
  result="$(classify_gate_outcome "$pre" "$post" f/01 0)"
  [ "$result" = "gate-failed" ]
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
  propagate_to_host() { :; }

  dispatch_one() {
    local feature="$1" nn="$2"
    echo "$feature/$nn" >>"$TEST_DISPATCHED_FILE"
    # Pop the head of the queue.
    local rest
    rest="$(tail -n +2 "$TEST_QUEUE_FILE" 2>/dev/null || true)"
    printf '%s\n' "$rest" >"$TEST_QUEUE_FILE"
    # Strip the trailing blank if rest is empty.
    [ -s "$TEST_QUEUE_FILE" ] || : >"$TEST_QUEUE_FILE"
    # Take the first planned outcome (default: success).
    local outcome
    outcome="$(head -n 1 "$TEST_OUTCOMES_FILE" 2>/dev/null || true)"
    if [ -n "$outcome" ]; then
      RUNNER_LAST_OUTCOME="$outcome"
      local rest_o
      rest_o="$(tail -n +2 "$TEST_OUTCOMES_FILE" 2>/dev/null || true)"
      printf '%s\n' "$rest_o" >"$TEST_OUTCOMES_FILE"
      [ -s "$TEST_OUTCOMES_FILE" ] || : >"$TEST_OUTCOMES_FILE"
    else
      RUNNER_LAST_OUTCOME="success"
    fi
    [ "$RUNNER_LAST_OUTCOME" = "success" ]
  }

  TARGET_FEATURE="f"
  DISCOVERY_JSON='["f"]'
  HOST_RUNS="$BATS_TEST_TMPDIR/runs"
  HOST_ABORT_DIR="$BATS_TEST_TMPDIR/aborted"
  RUNNER_INTERRUPTED=0
  RUNNER_LAST_OUTCOME=""
  # Provide a minimal HOST_REPO with HEAD on a branch other than the feature
  # so evaluate_feature_gate returns "drain".
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
    RUNNER_LAST_OUTCOME="success"
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
# CWD-relative) landed as an untracked file in the runner-checkout. Every
# subsequent dispatch's post-gate dirty-check fired on that stale file and
# misclassified clean gate runs as `gate-failed`, blocking propagation of
# the gate's `tracker: review … → done` commit to host. The sync was
# `git fetch + reset --hard origin/<branch>`, which scrubs tracked changes
# but leaves untracked files alone — the comment at run_loop:1175–1177
# claiming "any stray uncommitted dirt … never leaks" was a lie for the
# untracked case. Cleaning untracked files at sync time makes the comment
# true and ensures the dirty-check is always honest about *this*
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
  # would still mask the next dirty-check if a crash dropped a directory
  # rather than a single file. Pin -d behavior explicitly.
  mkdir -p "$HOST_CHECKOUT/stray-dir"
  : >"$HOST_CHECKOUT/stray-dir/leaf"

  ensure_runner_checkout

  [ ! -d "$HOST_CHECKOUT/stray-dir" ]
  [ -z "$(git -C "$HOST_CHECKOUT" status --porcelain)" ]
}

# === dispatch_one + run_loop — propagation halt is a failure ==============
#
# Regression for a bug where dispatch_one set RUNNER_LAST_OUTCOME to the
# classifier's verdict ("success" when the runner-checkout's status
# flipped) before propagation ran. If propagate_to_host then refused
# (host moved off-branch, dirty, or diverged), dispatch_one returned
# 1 — but RUNNER_LAST_OUTCOME stayed "success". An earlier loop body
# read RUNNER_LAST_OUTCOME instead of the return code, so the loop
# treated propagation halts as success; on the next iteration's
# `ensure_runner_checkout` it `git reset --hard origin/<branch>`d
# the dispatched commit out of the runner-checkout, the fresh
# snapshot saw the issue back at ready-for-agent, and the loop
# re-dispatched the same issue. The fix made return-code the source
# of truth; this test pins that contract.

# Build the minimum scaffolding to drive real `dispatch_one` end-to-end
# without docker, claude, or the live tracker. We need:
#   - take_snapshot: returns a pre-snapshot at ready-for-agent and a
#     post-snapshot at in-review (so classify_outcome → success);
#   - run_dispatch_container: pretends `/implement` ran (no-op);
#   - propagate_to_host: simulates a halt (returns 1);
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
  RUNNER_LAST_OUTCOME=""
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

@test "dispatch_one — propagation halt sets RUNNER_LAST_OUTCOME=failure even when classifier says success" {
  setup_dispatch_one_test

  # Classifier verdict will be "success" (snapshots flip
  # ready-for-agent → in-review), but propagation halts.
  propagate_to_host() {
    echo "runner: simulated propagation halt" >&2
    return 1
  }

  RUNNER_LAST_OUTCOME=""
  set +e
  dispatch_one "f" "01" "$TEST_RUN_DIR"
  local rc=$?
  set -e

  [ "$rc" -ne 0 ]
  [ "$RUNNER_LAST_OUTCOME" = "failure" ]
}

@test "dispatch_one — implement-stage propagation halt emits a halt → FAIL follow-up line" {
  # Regression: the implement-stage outcome line was emitted before the
  # propagation decision, so on halt the operator's terminal showed
  # `implement → in-review` while SUMMARY.md recorded `FAIL`. The fix
  # keeps the original outcome line (so the forensic story `implement
  # landed; propagation refused` survives in runner.log) and emits a
  # follow-up `halt → FAIL` line so the visible record matches the
  # SUMMARY.md row.
  setup_dispatch_one_test
  propagate_to_host() { return 1; }

  run dispatch_one "f" "01" "$TEST_RUN_DIR"

  [ "$status" -ne 0 ]
  # Original outcome line preserved — implement step itself succeeded.
  assert_output --partial "implement → in-review"
  # Follow-up halt line emitted after the propagation decision.
  assert_output --partial "implement → halt → FAIL"
}

@test "dispatch_one — gate-stage propagation halt emits a halt → gate-failed follow-up line" {
  # Same regression at the gate stage. Gate-clean post-implement, then
  # the post-gate propagation halts. Original `review → clean → done`
  # line stays for forensics; follow-up `review → halt → gate-failed`
  # line matches the SUMMARY.md row.
  setup_dispatch_one_test
  install_afk_snapshots done

  local prop_count_file="$BATS_TEST_TMPDIR/prop-count"
  echo 0 >"$prop_count_file"
  propagate_to_host() {
    local n
    n="$(cat "$prop_count_file")"
    echo $((n + 1)) >"$prop_count_file"
    # Post-implement propagation succeeds; post-gate halts.
    [ "$n" -eq 0 ]
  }
  run_gate_container() { return 0; }

  run dispatch_one "f" "01" "$TEST_RUN_DIR"

  [ "$status" -ne 0 ]
  assert_output --partial "review → clean → done"
  assert_output --partial "review → halt → gate-failed"
}

# === run_loop — propagation halt terminates the run =======================
#
# Regression: a propagation halt in loop mode continued the loop. The next
# iteration's ensure_runner_checkout hard-reset the runner-checkout to
# host's branch tip, wiping the commits the halt message promised were
# "parked in the runner-checkout" for the operator to recover manually.
#
# The fix sets RUNNER_HALT_OCCURRED=1 at both halt sites in dispatch_one;
# run_loop checks the flag after each dispatch and exits with stop reason
# "propagation-halt" before the second iteration's ensure_runner_checkout
# can wipe the parked commit.
#
# These tests allow ensure_runner_checkout to run for real (unmocked) so
# the second-iteration reset is observable: without the fix, HOST_CHECKOUT
# is reset to HOST_REPO's tip and the parked commit is gone.

setup_loop_halt_test() {
  HOST_REPO="$BATS_TEST_TMPDIR/host"
  TARGET_FEATURE="f"
  HOST_CHECKOUT="$HOST_REPO/$RUNNER_CHECKOUT_PATH"

  mkdir -p "$HOST_REPO"
  git -C "$HOST_REPO" init --quiet --initial-branch="$TARGET_FEATURE"
  git -C "$HOST_REPO" -c user.email=t@t -c user.name=t \
    commit --allow-empty --quiet -m init

  mkdir -p "$(dirname "$HOST_CHECKOUT")"
  git clone --quiet "$HOST_REPO" "$HOST_CHECKOUT" >&2
  git -C "$HOST_CHECKOUT" checkout --quiet -B "$TARGET_FEATURE" "origin/$TARGET_FEATURE"

  # Switch host HEAD off the feature branch so evaluate_feature_gate returns
  # "drain" and run_loop proceeds to the loop body.
  git -C "$HOST_REPO" checkout --quiet -b main

  HOST_RUNS="$HOST_REPO/.runner-state/runs"
  HOST_ABORT_DIR="$HOST_REPO/.runner-state/aborted"
  RUN_DIR="$HOST_RUNS/test-run"
  mkdir -p "$RUN_DIR"

  DISCOVERY_JSON='["f"]'
  RUNNER_INTERRUPTED=0
  RUNNER_LAST_OUTCOME=""
  RUNNER_HALT_OCCURRED=0
  RUN_STOP_REASON=""
  RUN_DISPATCHES=()

  SNAP_CALL_FILE="$BATS_TEST_TMPDIR/snap-calls"
  echo 0 >"$SNAP_CALL_FILE"
}

@test "run_loop — implement-stage propagation halt stops loop before second iteration" {
  # Without the fix, the loop continued; the second iteration's
  # ensure_runner_checkout reset HOST_CHECKOUT to HOST_REPO's tip (initial
  # commit), wiping the parked implement commit. The fix exits with stop
  # reason "propagation-halt" before that reset runs.
  setup_loop_halt_test

  # Three take_snapshot calls in iteration 1:
  #   call 0 — run_loop selection: f/01 eligible
  #   call 1 — dispatch_one pre_json: ready-for-agent
  #   call 2 — dispatch_one post_implement_json: in-review (classifier=success)
  # Calls 3+ only reachable in the buggy path (second iteration).
  take_snapshot() {
    local n
    n="$(cat "$SNAP_CALL_FILE")"
    echo $((n + 1)) >"$SNAP_CALL_FILE"
    case "$n" in
      0|1)
        printf '{"feature":"f","issues":[{"ref":"f/01","nn":"01","status":"ready-for-agent","category":"enhancement","type":"AFK","blocked_by":[],"eligible":true}]}'
        ;;
      *)
        printf '{"feature":"f","issues":[{"ref":"f/01","nn":"01","status":"in-review","category":"enhancement","type":"AFK","blocked_by":[],"eligible":false}]}'
        ;;
    esac
  }

  run_dispatch_container() {
    git -C "$HOST_CHECKOUT" -c user.email=t@t -c user.name=t \
      commit --allow-empty --quiet -m "tracker: f/01 implement (test)"
    return 0
  }
  run_gate_container() { return 0; }
  propagate_to_host() {
    echo "runner: simulated propagation halt" >&2
    return 1
  }

  local host_head_before
  host_head_before="$(git -C "$HOST_REPO" rev-parse HEAD)"

  set +e
  run_loop
  set -e

  [ "$RUN_STOP_REASON" = "propagation-halt" ]
  local checkout_head host_head
  checkout_head="$(git -C "$HOST_CHECKOUT" rev-parse HEAD)"
  host_head="$(git -C "$HOST_REPO" rev-parse HEAD)"
  # Parked commit must survive in runner-checkout.
  [ "$checkout_head" != "$host_head" ]
  # Host repo tip must be unchanged (propagation halted before advancing it).
  [ "$host_head" = "$host_head_before" ]
}

@test "run_loop — gate-stage propagation halt stops loop before second iteration" {
  # Implement propagation succeeds (host advances to the implement commit),
  # gate commits to runner-checkout, then gate propagation halts. The
  # parked gate commit must survive — the loop must not call
  # ensure_runner_checkout a second time.
  setup_loop_halt_test

  # Four take_snapshot calls in iteration 1:
  #   call 0 — run_loop selection: f/01 eligible
  #   call 1 — dispatch_one pre_json: ready-for-agent
  #   call 2 — dispatch_one post_implement_json: in-review (classifier=success)
  #   call 3 — dispatch_one post_gate_json: done (gate verdict=clean)
  # Calls 4+ only reachable in the buggy path.
  take_snapshot() {
    local n
    n="$(cat "$SNAP_CALL_FILE")"
    echo $((n + 1)) >"$SNAP_CALL_FILE"
    case "$n" in
      0|1)
        printf '{"feature":"f","issues":[{"ref":"f/01","nn":"01","status":"ready-for-agent","category":"enhancement","type":"AFK","blocked_by":[],"eligible":true}]}'
        ;;
      2)
        printf '{"feature":"f","issues":[{"ref":"f/01","nn":"01","status":"in-review","category":"enhancement","type":"AFK","blocked_by":[],"eligible":false}]}'
        ;;
      *)
        printf '{"feature":"f","issues":[{"ref":"f/01","nn":"01","status":"done","category":"enhancement","type":"AFK","blocked_by":[],"eligible":false}]}'
        ;;
    esac
  }

  run_dispatch_container() {
    git -C "$HOST_CHECKOUT" -c user.email=t@t -c user.name=t \
      commit --allow-empty --quiet -m "tracker: f/01 implement (test)"
    return 0
  }

  # Gate commits a tracker: entry — this is the parked commit that must survive.
  run_gate_container() {
    git -C "$HOST_CHECKOUT" -c user.email=t@t -c user.name=t \
      commit --allow-empty --quiet -m "tracker: f/01 review (test)"
    return 0
  }

  # Implement propagation succeeds (fast-forward HOST_REPO to implement
  # commit); gate propagation halts.
  PROP_CALL_FILE="$BATS_TEST_TMPDIR/prop-calls"
  echo 0 >"$PROP_CALL_FILE"
  propagate_to_host() {
    local n
    n="$(cat "$PROP_CALL_FILE")"
    echo $((n + 1)) >"$PROP_CALL_FILE"
    if [ "$n" -eq 0 ]; then
      git -C "$HOST_REPO" fetch --quiet "$HOST_CHECKOUT" "$TARGET_FEATURE" >&2
      git -C "$HOST_REPO" merge --quiet --ff-only FETCH_HEAD >&2
      return 0
    fi
    echo "runner: simulated gate-stage propagation halt" >&2
    return 1
  }

  set +e
  run_loop
  set -e

  [ "$RUN_STOP_REASON" = "propagation-halt" ]
  local checkout_head host_head
  checkout_head="$(git -C "$HOST_CHECKOUT" rev-parse HEAD)"
  host_head="$(git -C "$HOST_REPO" rev-parse HEAD)"
  # Gate commit parked in runner-checkout must not have been wiped.
  [ "$checkout_head" != "$host_head" ]
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
  # echoes only ${line%%=*} (the key portion).
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
  [[ "$result" =~ ^[A-Z_][A-Z0-9_]*=.* ]]
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
  [[ "${RUN_DISPATCHES[0]}" == "f|01|f/01|FAIL|"* ]]
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

  set +e
  dispatch_one "f" "01" "$TEST_RUN_DIR" 2>/dev/null
  local rc=$?
  set -e

  [ "$rc" -eq 1 ]
  [ "$RUN_STOP_REASON" = "snapshot-failed-mid-dispatch:post-implement" ]
  [ "${#RUN_DISPATCHES[@]}" -eq 1 ]
  [[ "${RUN_DISPATCHES[0]}" == "f|01|f/01|FAIL|"* ]]
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

  propagate_to_host() { return 0; }
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
  # and evaluate_feature_gate returns "drain".
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
# `--feature <slug>` / `--issue <feature>/<NN>` get their refusals here
# (unknown-feature, branch-checked-out). The gate runs before
# `ensure_runner_checkout` so an unknown slug surfaces the AC-mandated
# `feature-restricted (refused: unknown-feature)` / `single-dispatch
# (refused: unknown-feature)` instead of an opaque `git fetch origin
# <unknown>` failure. Return 2 propagates via `set -e` in main; the EXIT
# trap then writes SUMMARY.md against RUN_STOP_REASON (not
# RUN_PREFLIGHT_INVARIANT).

setup_eligibility_test() {
  # Minimal host repo for `git symbolic-ref --short HEAD`. Tests override
  # the initial branch as needed.
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

@test "check_feature_eligibility — loop mode: host on feature → feature-restricted (refused: branch-checked-out)" {
  setup_eligibility_test
  git -C "$HOST_REPO" checkout --quiet -B "my-feature"
  RUN_MODE="loop"
  TARGET_FEATURE="my-feature"
  DISCOVERY_JSON='["my-feature"]'

  check_feature_eligibility 2>"$ELIG_STDERR" || rc=$?
  [ "${rc:-0}" -eq 2 ]
  [ "$RUN_STOP_REASON" = "feature-restricted (refused: branch-checked-out)" ]
  grep -q "^runner: feature-restricted refused: feature 'my-feature' branch-checked-out$" "$ELIG_STDERR"
}

@test "check_feature_eligibility — single mode: host on feature → single-dispatch (refused: branch-checked-out)" {
  setup_eligibility_test
  git -C "$HOST_REPO" checkout --quiet -B "my-feature"
  RUN_MODE="single"
  TARGET_FEATURE="my-feature"
  DISCOVERY_JSON='["my-feature"]'

  check_feature_eligibility 2>"$ELIG_STDERR" || rc=$?
  [ "${rc:-0}" -eq 2 ]
  [ "$RUN_STOP_REASON" = "single-dispatch (refused: branch-checked-out)" ]
  grep -q "^runner: single-dispatch refused: feature 'my-feature' branch-checked-out$" "$ELIG_STDERR"
}

@test "check_feature_eligibility — feature in discovery and host on unrelated branch → passes silently" {
  setup_eligibility_test
  # Create the feature branch so it actually exists on host. Without this,
  # the branch-missing gate would (correctly) refuse — pinning the contract
  # that this happy-path test exercises only the discovery + branch-checked-out
  # axes.
  git -C "$HOST_REPO" branch my-feature
  RUN_MODE="loop"
  TARGET_FEATURE="my-feature"
  DISCOVERY_JSON='["my-feature","other"]'

  check_feature_eligibility 2>"$ELIG_STDERR"
  [ -z "$RUN_STOP_REASON" ]
  [ ! -s "$ELIG_STDERR" ]
}

@test "check_feature_eligibility — loop mode: slug in discovery but no host branch → feature-restricted (refused: branch-missing)" {
  # AC: --feature <slug-in-discovery-but-no-host-branch> exits 2 with
  # `runner: feature-restricted refused: feature '<slug>' branch-missing`
  # on stderr and SUMMARY stop reason `feature-restricted (refused:
  # branch-missing)`. Without computing branch_exists, the gate evaluator's
  # default (branch_exists=yes) suppresses this signal and the run falls
  # through to ensure_runner_checkout, surfacing `preflight-abort: runner-checkout`
  # instead — the exact opaque-failure pattern /01's unknown-feature hoisting
  # was supposed to close.
  setup_eligibility_test
  # Host stays on main; 'my-feature' branch is intentionally NOT created.
  RUN_MODE="loop"
  TARGET_FEATURE="my-feature"
  DISCOVERY_JSON='["my-feature","other"]'

  check_feature_eligibility 2>"$ELIG_STDERR" || rc=$?
  [ "${rc:-0}" -eq 2 ]
  [ "$RUN_STOP_REASON" = "feature-restricted (refused: branch-missing)" ]
  grep -q "^runner: feature-restricted refused: feature 'my-feature' branch-missing$" "$ELIG_STDERR"
}

@test "check_feature_eligibility — single mode: slug in discovery but no host branch → single-dispatch (refused: branch-missing)" {
  setup_eligibility_test
  RUN_MODE="single"
  TARGET_FEATURE="my-feature"
  DISCOVERY_JSON='["my-feature"]'

  check_feature_eligibility 2>"$ELIG_STDERR" || rc=$?
  [ "${rc:-0}" -eq 2 ]
  [ "$RUN_STOP_REASON" = "single-dispatch (refused: branch-missing)" ]
  grep -q "^runner: single-dispatch refused: feature 'my-feature' branch-missing$" "$ELIG_STDERR"
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
  propagate_to_host() {
    echo "called" >>"$TEST_PROPAGATE_CALLS"
    return 0
  }
  run_gate_container() {
    # Pretend the gate session succeeded (claude exit 0) and the
    # snapshot-mock will return status=done at post-gate phase.
    return 0
  }

  RUNNER_LAST_OUTCOME=""
  RUN_DISPATCHES=()
  set +e
  dispatch_one "f" "01" "$TEST_RUN_DIR"
  local rc=$?
  set -e

  [ "$rc" -eq 0 ]
  [ "$RUNNER_LAST_OUTCOME" = "success" ]
  # One record, combined label `done`, review-log marker present.
  [ "${#RUN_DISPATCHES[@]}" -eq 1 ]
  [[ "${RUN_DISPATCHES[0]}" == "f|01|f/01|done|"*"|y" ]]
  # Two propagations: post-implement and post-gate.
  [ "$(wc -l <"$TEST_PROPAGATE_CALLS" | tr -d ' ')" = "2" ]
}

@test "dispatch_one — both propagate_to_host call sites pass the feature branch as \$1" {
  # Pin the contract: both `dispatch_one` call sites of `propagate_to_host`
  # pass TARGET_FEATURE as $1. A missing argument leaves branch="" in the
  # callee, the branch-checked-out guard never fires, and
  # `git fetch <checkout> ":"` silently no-ops — orphaning the gate's
  # `tracker:` commit in the runner-checkout while the runner reports
  # success.
  setup_dispatch_one_test
  install_afk_snapshots done

  TEST_PROPAGATE_ARGS="$BATS_TEST_TMPDIR/prop-args"
  : >"$TEST_PROPAGATE_ARGS"
  propagate_to_host() {
    # Record the literal argument received — empty string is recorded as
    # an empty line, which `grep -c` and `wc -l` both see distinctly from
    # a non-empty record.
    printf '%s\n' "${1-}" >>"$TEST_PROPAGATE_ARGS"
    return 0
  }
  run_gate_container() { return 0; }

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
  propagate_to_host() {
    echo "called" >>"$TEST_PROPAGATE_CALLS"
    return 0
  }
  run_gate_container() {
    # Gate appended a comment but did not flip status; exit 0.
    return 0
  }

  RUNNER_LAST_OUTCOME=""
  RUN_DISPATCHES=()
  set +e
  dispatch_one "f" "01" "$TEST_RUN_DIR"
  local rc=$?
  set -e

  [ "$rc" -eq 0 ]
  # Blocked is operationally clean — counter resets, no failure.
  [ "$RUNNER_LAST_OUTCOME" = "success" ]
  [ "${#RUN_DISPATCHES[@]}" -eq 1 ]
  [[ "${RUN_DISPATCHES[0]}" == "f|01|f/01|blocked|"*"|y" ]]
  [ "$(wc -l <"$TEST_PROPAGATE_CALLS" | tr -d ' ')" = "2" ]
}

@test "dispatch_one — AFK gate-failed (nonzero exit) sets RUNNER_LAST_OUTCOME=failure" {
  setup_dispatch_one_test
  install_afk_snapshots in-review

  TEST_PROPAGATE_CALLS="$BATS_TEST_TMPDIR/prop-calls"
  : >"$TEST_PROPAGATE_CALLS"
  propagate_to_host() {
    echo "called" >>"$TEST_PROPAGATE_CALLS"
    return 0
  }
  run_gate_container() {
    # Container crashed — nonzero exit.
    return 137
  }

  RUNNER_LAST_OUTCOME=""
  RUN_DISPATCHES=()
  set +e
  dispatch_one "f" "01" "$TEST_RUN_DIR"
  local rc=$?
  set -e

  [ "$rc" -ne 0 ]
  [ "$RUNNER_LAST_OUTCOME" = "failure" ]
  [ "${#RUN_DISPATCHES[@]}" -eq 1 ]
  [[ "${RUN_DISPATCHES[0]}" == "f|01|f/01|gate-failed|"*"|y" ]]
  # Only the post-implement propagation ran; the gate-failed branch
  # does not propagate.
  [ "$(wc -l <"$TEST_PROPAGATE_CALLS" | tr -d ' ')" = "1" ]
}

@test "dispatch_one — AFK off-mission post-gate status is gate-failed" {
  setup_dispatch_one_test
  install_afk_snapshots wontfix

  propagate_to_host() { return 0; }
  run_gate_container() {
    # Exit 0 but post-gate status is wontfix — classify as gate-failed.
    return 0
  }

  RUNNER_LAST_OUTCOME=""
  RUN_DISPATCHES=()
  set +e
  dispatch_one "f" "01" "$TEST_RUN_DIR"
  local rc=$?
  set -e

  [ "$rc" -ne 0 ]
  [ "$RUNNER_LAST_OUTCOME" = "failure" ]
  [[ "${RUN_DISPATCHES[0]}" == "f|01|f/01|gate-failed|"*"|y" ]]
}

@test "dispatch_one — RUNNER_INTERRUPTED between implement and gate prevents gate dispatch" {
  # Simulates Ctrl-C arriving after run_dispatch_container returns (i.e.
  # IN_FLIGHT_CID_FILE has been cleared) but before run_gate_container is
  # called. The fix must check RUNNER_INTERRUPTED and return before
  # spawning the gate container.
  setup_dispatch_one_test
  install_afk_snapshots done

  propagate_to_host() { return 0; }

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
  RUNNER_LAST_OUTCOME=""
  RUN_DISPATCHES=()
  set +e
  dispatch_one "f" "01" "$TEST_RUN_DIR"
  local rc=$?
  set -e

  [ "$rc" -eq 0 ]
  [ "$RUNNER_LAST_OUTCOME" = "success" ]
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
  propagate_to_host() {
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
    # Exit 0 with no working-tree change of its own; the classifier sees
    # status unchanged (in-review → in-review) and returns `blocked`.
    return 0
  }

  RUNNER_LAST_OUTCOME=""
  RUN_DISPATCHES=()
  set +e
  dispatch_one "f" "01" "$TEST_RUN_DIR"
  local rc=$?
  set -e

  # Classifier verdict (`blocked`) propagates unchanged despite the dirty
  # working tree.
  [ "$rc" -eq 0 ]
  [ "$RUNNER_LAST_OUTCOME" = "success" ]
  [ "${#RUN_DISPATCHES[@]}" -eq 1 ]
  [[ "${RUN_DISPATCHES[0]}" == "f|01|f/01|blocked|"*"|y" ]]
  # Both the post-implement and post-gate propagations ran — the gate's
  # tracker commit reaches host.
  [ "$(wc -l <"$TEST_PROPAGATE_CALLS" | tr -d ' ')" = "2" ]
}

# === Output formatters =====================================================
#
# Pin the exact stdout shape and SUMMARY.md shape the AC requires. The
# formatters are pure (stdin→stdout, no globals) so the tests pass
# fixture inputs and string-compare the output.

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
  # Header line — column names in order.
  echo "$result" | head -n 1 | grep -q '^issue ' || { echo "header missing 'issue'"; echo "$result"; false; }
  echo "$result" | head -n 1 | grep -q ' outcome ' || { echo "header missing 'outcome'"; false; }
  echo "$result" | head -n 1 | grep -q ' duration' || { echo "header missing 'duration'"; false; }
  # One row per dispatch — `issue` column shows the binding-native ref.
  echo "$result" | grep -q '^afk-runner/01 .*in-review.* 42s *$' || { echo "row 01 missing"; echo "$result"; false; }
  echo "$result" | grep -q '^afk-runner/02 .*FAIL.* 18s *$' || { echo "row 02 missing"; echo "$result"; false; }
  echo "$result" | grep -q '^afk-runner/03 .*done.* 301s *$' || { echo "row 03 missing"; echo "$result"; false; }
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
  echo "$result" | grep -q '^#42 .*in-review.* 12s *$' || { echo "GH row 42 missing"; echo "$result"; false; }
  echo "$result" | grep -q '^#43 .*FAIL.* 5s *$' || { echo "GH row 43 missing"; echo "$result"; false; }
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
  # Per-issue table headers + rows. The `logs` column carries one or two
  # links depending on whether the iteration produced a `<NN>-review.log`.
  echo "$result" | grep -q '^| issue | outcome | duration | logs |$' || { echo "$result"; false; }
  echo "$result" | grep -q '| afk-runner/01 | in-review | 42s | \[01.log\](01.log) |' || { echo "$result"; false; }
  echo "$result" | grep -q '| afk-runner/02 | FAIL | 18s | \[02.log\](02.log) |' || { echo "$result"; false; }
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
  # log and the review log.
  echo "$result" | grep -qF '| afk-runner/01 | done | 42s | [01.log](01.log) [01-review.log](01-review.log) |' \
    || { echo "$result"; false; }
  echo "$result" | grep -qF '| afk-runner/02 | blocked | 36s | [02.log](02.log) [02-review.log](02-review.log) |' \
    || { echo "$result"; false; }
  echo "$result" | grep -qF '| afk-runner/03 | gate-failed | 11s | [03.log](03.log) [03-review.log](03-review.log) |' \
    || { echo "$result"; false; }
  # Interrupt-between-stages row (implement-step recorded `in-review`,
  # interrupted before gate) and implement-FAIL row carry only the
  # dispatch log.
  echo "$result" | grep -qF '| afk-runner/04 | in-review | 17s | [04.log](04.log) |' \
    || { echo "$result"; false; }
  echo "$result" | grep -qF '| afk-runner/05 | FAIL | 3s | [05.log](05.log) |' \
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
  echo "$result" | grep -q '^| issue | outcome | duration | logs |$' || false
  # No data rows expected.
  ! echo "$result" | grep -q '^| afk-' || false
}

@test "format_summary_md — GH-shaped ref (#N) emits working nn-based log link" {
  # Record schema: feature|nn|ref|outcome|duration|review_present
  input='some-feature|42|#42|in-review|37|'
  result="$(printf '%s\n' "$input" | format_summary_md \
    some-feature 20260506-091245 09:12:45 09:13:22 ended queue-empty)"

  # Issue column shows binding-native ref (#42); log link uses plain nn (42.log).
  echo "$result" | grep -qF '| #42 | in-review | 37s | [42.log](42.log) |' \
    || { echo "$result"; false; }
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
  propagate_to_host() {
    echo "called" >>"$TEST_PROPAGATE_CALLED"
    return 0
  }

  RUNNER_LAST_OUTCOME=""
  set +e
  dispatch_one "f" "01" "$TEST_RUN_DIR"
  local rc=$?
  set -e

  [ "$rc" -ne 0 ]
  [ "$RUNNER_LAST_OUTCOME" = "failure" ]
  # No committed change → nothing to propagate, runner does not call
  # propagate_to_host at all.
  [ ! -s "$TEST_PROPAGATE_CALLED" ]
}

# === dispatch_one — propagate-on-any-commit rule ==========================
#
# The implement-stage propagation gate is the runner-checkout having any
# committed change ahead of the host's branch tip — not the classifier
# verdict. /implement's documented bail behavior (status stays at
# `ready-for-agent`, `tracker:` comment-only commit) used to be wiped
# by the next iteration's `ensure_runner_checkout` reset because
# propagation was gated by the classifier's `success` verdict. The new
# rule lets bail comments reach the host while still recording the
# iteration as a failure (since the classifier verdict is independent).

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
  propagate_to_host() {
    echo "called" >>"$TEST_PROPAGATE_CALLED"
    return 0
  }

  RUNNER_LAST_OUTCOME=""
  RUN_DISPATCHES=()
  set +e
  dispatch_one "f" "01" "$TEST_RUN_DIR"
  local rc=$?
  set -e

  # Iteration is a failure (classifier verdict is independent of
  # propagation), but the bail comment must reach the host.
  [ "$rc" -ne 0 ]
  [ "$RUNNER_LAST_OUTCOME" = "failure" ]
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
  propagate_to_host() {
    echo "called" >>"$TEST_PROPAGATE_CALLED"
    return 1
  }

  RUNNER_LAST_OUTCOME=""
  RUN_DISPATCHES=()
  set +e
  dispatch_one "f" "01" "$TEST_RUN_DIR"
  local rc=$?
  set -e

  [ "$rc" -ne 0 ]
  [ "$RUNNER_LAST_OUTCOME" = "failure" ]
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
  # The loop's mock dispatch_one only sets RUNNER_LAST_OUTCOME. Layer on
  # record_dispatch so the records make it into RUN_DISPATCHES.
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
      RUNNER_LAST_OUTCOME="$outcome"
      local rest_o
      rest_o="$(tail -n +2 "$TEST_OUTCOMES_FILE" 2>/dev/null || true)"
      printf '%s\n' "$rest_o" >"$TEST_OUTCOMES_FILE"
      [ -s "$TEST_OUTCOMES_FILE" ] || : >"$TEST_OUTCOMES_FILE"
    else
      RUNNER_LAST_OUTCOME="success"
    fi
    local label
    if [ "$RUNNER_LAST_OUTCOME" = "success" ]; then label="in-review"; else label="FAIL"; fi
    record_dispatch "$feature" "$nn" "$ref" "$label" 1
    [ "$RUNNER_LAST_OUTCOME" = "success" ]
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
  grep -q '| f/01 | in-review | 42s | \[01.log\](01.log) |' "$RUN_DIR/SUMMARY.md"
  grep -q '| f/02 | FAIL | 18s | \[02.log\](02.log) |' "$RUN_DIR/SUMMARY.md"
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
  propagate_to_host() { return 0; }

  RUNNER_LAST_OUTCOME=""
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
  propagate_to_host() { return 0; }

  RUNNER_LAST_OUTCOME=""
  RUN_DISPATCHES=()
  set +e
  dispatch_one "f" "01" "$TEST_RUN_DIR"
  set -e

  [ ! -f "$HOST_ABORT_DIR/f/01" ]
}

@test "dispatch_one — implement propagation halt writes abort flag" {
  setup_abort_test
  # Status stays ready-for-agent but dispatch committed something → propagation halts.
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
      commit --allow-empty --quiet -m "tracker: f/01 bail"
    return 0
  }
  propagate_to_host() { return 1; }

  RUNNER_LAST_OUTCOME=""
  RUN_DISPATCHES=()
  set +e
  dispatch_one "f" "01" "$TEST_RUN_DIR"
  set -e

  [ -f "$HOST_ABORT_DIR/f/01" ]
  grep -q '^dispatch: implement$' "$HOST_ABORT_DIR/f/01"
}

@test "dispatch_one — gate-failed writes abort flag with dispatch: gate" {
  setup_abort_test
  install_afk_snapshots in-review

  propagate_to_host() { return 0; }
  run_gate_container() { return 137; }

  RUNNER_LAST_OUTCOME=""
  RUN_DISPATCHES=()
  set +e
  dispatch_one "f" "01" "$TEST_RUN_DIR"
  set -e

  [ -f "$HOST_ABORT_DIR/f/01" ]
  grep -q '^dispatch: gate$' "$HOST_ABORT_DIR/f/01"
}

@test "dispatch_one — gate propagation halt writes abort flag with dispatch: gate" {
  setup_abort_test
  install_afk_snapshots done

  local prop_count_file="$BATS_TEST_TMPDIR/prop-count"
  echo 0 >"$prop_count_file"
  propagate_to_host() {
    local n
    n="$(cat "$prop_count_file")"
    echo $((n + 1)) >"$prop_count_file"
    # First call (post-implement) succeeds; second (post-gate) halts.
    [ "$n" -eq 0 ]
  }
  run_gate_container() { return 0; }

  RUNNER_LAST_OUTCOME=""
  RUN_DISPATCHES=()
  set +e
  dispatch_one "f" "01" "$TEST_RUN_DIR"
  set -e

  [ -f "$HOST_ABORT_DIR/f/01" ]
  grep -q '^dispatch: gate$' "$HOST_ABORT_DIR/f/01"
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
  propagate_to_host() { return 0; }

  RUNNER_INTERRUPTED=0
  RUNNER_LAST_OUTCOME=""
  RUN_DISPATCHES=()
  set +e
  dispatch_one "f" "01" "$TEST_RUN_DIR"
  set -e

  [ ! -f "$HOST_ABORT_DIR/f/01" ]
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
    RUNNER_LAST_OUTCOME="success"
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
    RUNNER_LAST_OUTCOME="success"
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

# === propagate_to_host <branch> — fetch-into-ref propagation ================
#
# The new propagate_to_host <branch> uses `git fetch <runner-checkout>
# <branch>:<branch>` instead of `fetch + merge --ff-only FETCH_HEAD`. This
# advances the branch ref without touching host's HEAD, working tree, or
# index. Refusal modes: host is currently on the target branch (which would
# make the ref update affect HEAD), and non-fast-forward.
#
# All three cases use ephemeral git repos created in BATS_TEST_TMPDIR.

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
}

@test "propagate_to_host — succeeds on a non-HEAD branch, advances branch ref without touching HEAD" {
  setup_propagate_test

  # Add a commit to runner-checkout (simulates dispatch output).
  git -C "$HOST_CHECKOUT" -c user.email=t@t -c user.name=t \
    commit --allow-empty --quiet -m "tracker: f/01 → in-review"

  # Switch host HEAD to master so f is not checked out.
  git -C "$HOST_REPO" checkout --quiet -b master

  local host_f_before checkout_f host_master_before
  host_f_before="$(git -C "$HOST_REPO" rev-parse f)"
  checkout_f="$(git -C "$HOST_CHECKOUT" rev-parse HEAD)"
  host_master_before="$(git -C "$HOST_REPO" rev-parse HEAD)"

  propagate_to_host "f"

  local host_f_after host_master_after
  host_f_after="$(git -C "$HOST_REPO" rev-parse f)"
  host_master_after="$(git -C "$HOST_REPO" rev-parse HEAD)"

  # host's f branch advanced to match runner-checkout.
  [ "$host_f_after" = "$checkout_f" ]
  [ "$host_f_after" != "$host_f_before" ]
  # host HEAD (master) is unchanged — no working-tree effects.
  [ "$host_master_after" = "$host_master_before" ]
  [ "$(git -C "$HOST_REPO" symbolic-ref --short HEAD)" = "master" ]
}

@test "propagate_to_host — refuses when host is currently on the target branch" {
  setup_propagate_test

  # Runner-checkout has a new commit; host HEAD is on f (the target branch).
  git -C "$HOST_CHECKOUT" -c user.email=t@t -c user.name=t \
    commit --allow-empty --quiet -m "tracker: f/01 → in-review"
  # Host HEAD is already on f (init default).

  local host_f_before
  host_f_before="$(git -C "$HOST_REPO" rev-parse f)"

  run propagate_to_host "f"

  [ "$status" -ne 0 ]
  # The refusal must name the specific halt mode so the operator's
  # recovery-recipe-paste loop knows which case fired. A trivial substring
  # like "f" would pass against any output and hide regressions in the
  # diagnostic.
  assert_output --partial "propagation refused"
  assert_output --partial "host is currently on branch 'f'"
  # Host's f ref must not have advanced — the whole point of the refusal
  # is to leave host state untouched so the operator reconciles by hand.
  local host_f_after
  host_f_after="$(git -C "$HOST_REPO" rev-parse f)"
  [ "$host_f_after" = "$host_f_before" ]
}

@test "propagate_to_host — refuses on a non-fast-forward update" {
  setup_propagate_test

  # Diverge: runner-checkout gets commit B, host's f gets commit C.
  # Both children of the shared init commit A.
  git -C "$HOST_CHECKOUT" -c user.email=t@t -c user.name=t \
    commit --allow-empty --quiet -m "checkout diverge"
  git -C "$HOST_REPO" -c user.email=t@t -c user.name=t \
    commit --allow-empty --quiet -m "host diverge"

  # Switch host HEAD to master so the branch-checked-out guard doesn't fire.
  git -C "$HOST_REPO" checkout --quiet -b master

  local host_f_before
  host_f_before="$(git -C "$HOST_REPO" rev-parse f)"

  run propagate_to_host "f"

  [ "$status" -ne 0 ]
  # Refusal must name the fetch-failed mode (not the branch-checked-out
  # mode) so the operator knows the halt was caused by divergence.
  assert_output --partial "propagation refused"
  assert_output --partial "git fetch f:f failed"
  # Host's f ref must remain at its divergent tip — the runner never
  # rewrites host history on a non-ff refusal.
  local host_f_after
  host_f_after="$(git -C "$HOST_REPO" rev-parse f)"
  [ "$host_f_after" = "$host_f_before" ]
}

# === evaluate_feature_gate — branch-checked-out gate =======================
#
# Pure function: takes (slug, host_branch) and returns `drain` or
# `skip:branch-checked-out`. At this stage only the `branch-checked-out`
# reason is implemented; the rest come in /02.

@test "evaluate_feature_gate — returns drain when host branch differs from slug" {
  result="$(evaluate_feature_gate "my-feature" "master")"
  [ "$result" = "drain" ]
}

@test "evaluate_feature_gate — returns drain when host is on an unrelated branch" {
  result="$(evaluate_feature_gate "my-feature" "some-other-branch")"
  [ "$result" = "drain" ]
}

@test "evaluate_feature_gate — returns skip:branch-checked-out when host is on the slug" {
  result="$(evaluate_feature_gate "my-feature" "my-feature")"
  [ "$result" = "skip:branch-checked-out" ]
}

@test "evaluate_feature_gate — returns drain when host branch is empty (detached HEAD)" {
  result="$(evaluate_feature_gate "my-feature" "")"
  [ "$result" = "drain" ]
}

# === evaluate_feature_gate — full skip-reason matrix =======================
#
# The gate evaluator's full signal set: branch-checked-out, branch-missing,
# fetch-failed, feature-snapshot-failed, queue-empty. The drain loop
# short-circuits at the first failing gate, but the pure function takes
# the full bundle so bats can exercise priority order exhaustively.
#
# Signature: evaluate_feature_gate <slug> <host_branch> \
#                                  [branch_exists=yes] \
#                                  [snapshot_status=ok] \
#                                  [queue_status=nonempty] \
#                                  [fetch_status=ok]
#
# Verdict priority (top wins): branch-checked-out > branch-missing >
#                              fetch-failed > feature-snapshot-failed >
#                              queue-empty > drain.

@test "evaluate_feature_gate — skip:branch-missing when host has no branch ref" {
  result="$(evaluate_feature_gate "my-feature" "master" no)"
  [ "$result" = "skip:branch-missing" ]
}

@test "evaluate_feature_gate — skip:fetch-failed when fetch_status=failed" {
  result="$(evaluate_feature_gate "my-feature" "master" yes ok nonempty failed)"
  [ "$result" = "skip:fetch-failed" ]
}

@test "evaluate_feature_gate — skip:feature-snapshot-failed when snapshot_status=failed" {
  result="$(evaluate_feature_gate "my-feature" "master" yes failed nonempty ok)"
  [ "$result" = "skip:feature-snapshot-failed" ]
}

@test "evaluate_feature_gate — skip:queue-empty when queue_status=empty" {
  result="$(evaluate_feature_gate "my-feature" "master" yes ok empty ok)"
  [ "$result" = "skip:queue-empty" ]
}

@test "evaluate_feature_gate — branch-checked-out wins over branch-missing" {
  # If the host happens to be on a branch with the same name as the slug
  # but git reports no ref for it (impossible in practice — host's HEAD
  # is a ref), the gate still says branch-checked-out: the user is
  # demonstrably parked there.
  result="$(evaluate_feature_gate "my-feature" "my-feature" no)"
  [ "$result" = "skip:branch-checked-out" ]
}

@test "evaluate_feature_gate — branch-missing wins over fetch/snapshot/queue" {
  result="$(evaluate_feature_gate "my-feature" "master" no failed empty failed)"
  [ "$result" = "skip:branch-missing" ]
}

@test "evaluate_feature_gate — fetch-failed wins over feature-snapshot-failed and queue-empty" {
  result="$(evaluate_feature_gate "my-feature" "master" yes failed empty failed)"
  [ "$result" = "skip:fetch-failed" ]
}

@test "evaluate_feature_gate — feature-snapshot-failed wins over queue-empty" {
  result="$(evaluate_feature_gate "my-feature" "master" yes failed empty ok)"
  [ "$result" = "skip:feature-snapshot-failed" ]
}

@test "evaluate_feature_gate — all signals ok returns drain" {
  result="$(evaluate_feature_gate "my-feature" "master" yes ok nonempty ok)"
  [ "$result" = "drain" ]
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
F|beta|skipped:branch-missing
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
  beta_line="$(printf '%s\n' "$result" | grep -n '^## beta — skipped: branch-missing$' | cut -d: -f1)"
  gamma_line="$(printf '%s\n' "$result" | grep -n '^## gamma — drained$' | cut -d: -f1)"
  [ -n "$alpha_line" ] && [ -n "$beta_line" ] && [ -n "$gamma_line" ]
  [ "$alpha_line" -lt "$beta_line" ]
  [ "$beta_line" -lt "$gamma_line" ]

  # Drained features carry per-issue tables nested under their section.
  echo "$result" | grep -qF '| alpha/01 | done | 42s | [alpha/01.log](alpha/01.log) [alpha/01-review.log](alpha/01-review.log) |' \
    || { echo "$result"; false; }
  echo "$result" | grep -qF '| gamma/01 | in-review | 13s | [gamma/01.log](gamma/01.log) |' \
    || { echo "$result"; false; }
}

@test "format_multi_feature_summary_md — skipped feature emits no issue table" {
  input='F|beta|skipped:branch-checked-out'
  result="$(printf '%s\n' "$input" | format_multi_feature_summary_md \
    20260513-101010 10:10:10 10:11:00 ended completed)"

  echo "$result" | grep -q '^## beta — skipped: branch-checked-out$' || { echo "$result"; false; }
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

  echo "$result" | grep -qF '| #42 | done | 25s | [some-feature/42.log](some-feature/42.log) [some-feature/42-review.log](some-feature/42-review.log) |' \
    || { echo "$result"; false; }
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

  # Plant a host repo on a "parked" branch (master). Tests that want to
  # exercise branch-checked-out check out the target feature inside the
  # repo themselves.
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
  RUNNER_HALT_OCCURRED=0
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

@test "drain_one_feature — records skip:branch-checked-out when host is on the feature branch" {
  setup_drain_test
  git -C "$HOST_REPO" checkout --quiet -B "alpha"

  drain_one_feature "alpha"

  [ "$(drain_outcome_nth 0)" = "alpha|skip:branch-checked-out" ]
  # No per-issue work happens for a skipped feature.
  [ "$(drained_features_count)" = "0" ]
  # mvn-cache must NOT be created for a skipped feature (PRD §Per-feature
  # gates: "Created lazily — features the runner doesn't drain don't get
  # cache volumes.")
  [ ! -s "$DRAIN_MVN_CALLED_FILE" ]
}

@test "drain_one_feature — records skip:branch-missing when host has no branch ref" {
  setup_drain_test
  # `alpha` is never created on the host repo — show-ref will miss it.

  drain_one_feature "alpha"

  [ "$(drain_outcome_nth 0)" = "alpha|skip:branch-missing" ]
  [ "$(drained_features_count)" = "0" ]
  [ ! -s "$DRAIN_MVN_CALLED_FILE" ]
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
    RUNNER_LAST_OUTCOME="success"
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
  git -C "$HOST_REPO" branch alpha
  git -C "$HOST_REPO" branch beta
  # beta's snapshot crashes pre-loop → feature-snapshot-failed.
  echo "beta" >"$DRAIN_SNAP_FAILURES_FILE"

  run_drain

  [ "$RUN_STOP_REASON" = "completed" ]
  [ "$(drain_outcomes_count)" = "3" ]
  [ "$(drain_outcome_nth 0)" = "alpha|drained" ]
  [ "$(drain_outcome_nth 1)" = "beta|feature-snapshot-failed" ]
  [ "$(drain_outcome_nth 2)" = "gamma|skip:branch-missing" ]
  # mvn-cache created only for the drained feature.
  [ "$(wc -l <"$DRAIN_MVN_CALLED_FILE" | tr -d ' ')" = "1" ]
  grep -Fxq "alpha" "$DRAIN_MVN_CALLED_FILE"
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

@test "run_drain — propagation halt mid-drain stops the outer loop" {
  setup_drain_test
  DISCOVERY_JSON='["alpha","beta"]'
  git -C "$HOST_REPO" branch alpha
  git -C "$HOST_REPO" branch beta
  run_loop() {
    echo "$TARGET_FEATURE" >>"$DRAIN_DRAINED_FILE"
    RUNNER_HALT_OCCURRED=1
    RUN_STOP_REASON="propagation-halt"
    return 0
  }

  run_drain

  [ "$RUN_STOP_REASON" = "propagation-halt" ]
  # First feature drained; second one not considered.
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
    "beta|skip:branch-missing"
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
  b="$(grep -n '^## beta — skipped: branch-missing$' "$RUN_DIR/SUMMARY.md" | cut -d: -f1)"
  c="$(grep -n '^## gamma — drained$' "$RUN_DIR/SUMMARY.md" | cut -d: -f1)"
  d="$(grep -n '^## delta — feature-snapshot-failed$' "$RUN_DIR/SUMMARY.md" | cut -d: -f1)"
  [ -n "$a" ] && [ -n "$b" ] && [ -n "$c" ] && [ -n "$d" ]
  [ "$a" -lt "$b" ] && [ "$b" -lt "$c" ] && [ "$c" -lt "$d" ]
  # Drained features carry per-issue rows; skipped/snapshot-failed do not.
  grep -qF '| alpha/01 | done | 42s | [alpha/01.log](alpha/01.log) [alpha/01-review.log](alpha/01-review.log) |' "$RUN_DIR/SUMMARY.md"
  grep -qF '| gamma/01 | in-review | 13s | [gamma/01.log](gamma/01.log) |' "$RUN_DIR/SUMMARY.md"
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
  propagate_to_host() { return 0; }

  RUNNER_LAST_OUTCOME=""
  RUN_DISPATCHES=()
  set +e
  dispatch_one "f" "42" "$TEST_RUN_DIR"
  local rc=$?
  set -e

  [ "$rc" -eq 0 ]
  [ "$RUNNER_LAST_OUTCOME" = "success" ]
  # The binding-native ref "#42" was forwarded to both dispatch stages.
  [ "$(cat "$TEST_DISPATCH_REF")" = "#42" ]
  [ "$(cat "$TEST_GATE_REF")" = "#42" ]
  # record_dispatch carries feature, nn, and native ref "#42".
  [ "${#RUN_DISPATCHES[@]}" -eq 1 ]
  [[ "${RUN_DISPATCHES[0]}" == "f|42|#42|done|"* ]]
}

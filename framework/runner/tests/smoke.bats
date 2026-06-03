#!/usr/bin/env bats
#
# End-to-end smoke test for the AFK runner.
#
# Slow (~2–4 min) and expensive — drives real Docker, real claude
# inference, and a real fast-forward against a synthetic single-issue
# micro-feature in a throwaway workspace. Guarded behind the
# `RUNNER_SMOKE` env var so default `bats` invocations skip it; the
# operator runs it manually before milestones (Dockerfile changes,
# network-policy revisions, claude CLI bumps, framework refactors —
# anything the pure-logic bats suite can't see).
#
# Opt in:
#
#     RUNNER_SMOKE=1 bats framework/runner/tests/smoke.bats
#
# Two scenarios:
#
#   1. propagated → host (park=main). Workspace HEAD on `main`; the
#      `smoke` feature branch carries the fixture commit. The runner
#      dispatches, both propagation steps succeed, and host's
#      `refs/heads/smoke` fast-forwards.
#
#   2. parked → runner/smoke (park=smoke). Workspace HEAD on `smoke`.
#      The runner dispatches; propagation step 1 publishes to
#      `refs/remotes/runner/smoke`, step 2 refuses (HEAD-on-target),
#      and the work parks. Host's `refs/heads/smoke` does not move.
#
# Pre-requisites for a green run: Docker Desktop running, the OAuth
# token populated in Keychain (see runner/README.md → "OAuth token"),
# and a working `claude` CLI on the host (only needed to build the
# image; the dispatched container ships its own).

setup() {
  if [ "${RUNNER_SMOKE:-0}" != "1" ]; then
    skip "RUNNER_SMOKE=1 not set — opt in to run the slow end-to-end smoke test"
  fi
  load 'test_helper/bats-support/load'
  load 'test_helper/bats-assert/load'

  HERE="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)"
  HOST_REPO="$(cd "$HERE/../../.." && pwd)"
  FIXTURE_DIR="$HERE/fixtures/smoke"

  # Workspaces live under the host's gitignored `.runner-state/` so
  # their absolute path stays under $HOME — Docker Desktop on macOS
  # only bind-mounts paths under $HOME by default; bats's standard
  # `BATS_TEST_TMPDIR` (which resolves under /var/folders) would not
  # be reachable from inside the dispatch container.
  mkdir -p "$HOST_REPO/.runner-state/smoke-work"
  WORKSPACE="$(mktemp -d "$HOST_REPO/.runner-state/smoke-work/run.XXXXXX")"

  # Stage the workspace as a synthetic consumer of the host's live
  # framework, matching what the installer produces on a real machine:
  #   - `.formann` indirection symlink → host's framework checkout
  #     (so the runner's `.formann`-ancestor walk anchors HOST_REPO to
  #     the workspace, not the formann repo itself).
  #   - `docs/formann/issue-tracker` → the local-markdown binding, since
  #     the fixture is local-markdown shape. The active binding on the
  #     formann repo is github-issues, which would not see the fixture.
  #   - `.claude/` is a full copy of host's. Its `skills/*` and
  #     `agents/*` symlinks are relative (`../../.formann/...`), so they
  #     resolve through the workspace's own `.formann`.
  #   - `.gitignore` covers the installer-managed indirection paths and
  #     the runner's per-run state dir so pre-flight's "host clean"
  #     check passes after the runner creates `.runner-state/runs/`.
  ln -s "$HOST_REPO/framework" "$WORKSPACE/.formann"
  mkdir -p "$WORKSPACE/docs/formann"
  ln -s "../../.formann/bindings/issue-tracker/local-markdown" \
        "$WORKSPACE/docs/formann/issue-tracker"
  cp -RP "$HOST_REPO/.claude" "$WORKSPACE/.claude"
  mkdir -p "$WORKSPACE/runner"
  cp "$HOST_REPO/installer/templates/manifest.md" "$WORKSPACE/runner/manifest.md"
  cat >"$WORKSPACE/.gitignore" <<'EOF'
/.formann
/docs/formann/issue-tracker
/.claude
/.runner-state/
EOF

  # Initial scaffold commit on `main`. The runner's lazy-init code uses
  # refs/remotes/origin/HEAD to discover the default branch (see
  # `ensure_runner_checkout_on_branch` in run-the-queue.sh); not used in
  # these scenarios because `smoke` is pre-created, but matches a real
  # consumer's default branch so `git clone` can discover it.
  git -C "$WORKSPACE" init -q
  git -C "$WORKSPACE" symbolic-ref HEAD refs/heads/main
  git -C "$WORKSPACE" -c user.email=smoke@test -c user.name=smoke add -A
  git -C "$WORKSPACE" -c user.email=smoke@test -c user.name=smoke \
    commit -q -m "smoke: initial workspace scaffold"

  # `smoke` feature branch with the fixture committed. The runner's
  # per-feature snapshot (`take_snapshot`) archives `.features/` from
  # the runner-checkout's HEAD, so the fixture must be in a commit
  # reachable from `refs/heads/smoke`, not just the working tree.
  git -C "$WORKSPACE" -c user.email=smoke@test -c user.name=smoke \
    checkout -q -b smoke
  mkdir -p "$WORKSPACE/.features/smoke"
  cp "$FIXTURE_DIR/PRD.md" "$WORKSPACE/.features/smoke/"
  cp -R "$FIXTURE_DIR/issues" "$WORKSPACE/.features/smoke/"
  git -C "$WORKSPACE" -c user.email=smoke@test -c user.name=smoke add -A
  git -C "$WORKSPACE" -c user.email=smoke@test -c user.name=smoke \
    commit -q -m "smoke: install fixture"
  INITIAL_SMOKE_TIP="$(git -C "$WORKSPACE" rev-parse refs/heads/smoke)"
}

teardown() {
  # On failure, surface runner.log and per-issue logs from the
  # throwaway workspace before the cleanup `rm -rf` removes them. They
  # carry the diagnostic the operator needs to see why the dispatch
  # didn't advance.
  if [ -z "${BATS_TEST_COMPLETED:-}" ] \
     && [ -n "${WORKSPACE:-}" ] \
     && [ -d "$WORKSPACE/.runner-state/runs" ]; then
    echo "=== smoke teardown: runner.log + per-issue logs ===" >&2
    find "$WORKSPACE/.runner-state/runs" -type f \
      \( -name "runner.log" -o -name "*.log" -o -name "SUMMARY.md" \) \
      -print -exec sh -c 'echo "--- $1 ---"; cat "$1"' _ {} \; >&2 2>/dev/null || true
  fi
  if [ -n "${WORKSPACE:-}" ] && [ -d "$WORKSPACE" ]; then
    rm -rf "$WORKSPACE" || true
  fi
}

# Common assertions on the per-run dir. Both scenarios produce the same
# runner-output surface; only the propagation column / branch tips
# differ. Per-issue logs sit under `<run_dir>/<feature>/` — the runner
# groups them per-feature so drain-all runs over multiple features stay
# legible.
assert_run_artifacts() {
  shopt -s nullglob
  local runs_dir="$WORKSPACE/.runner-state/runs"
  [ -d "$runs_dir" ]
  local -a per_run
  per_run=("$runs_dir"/*/)
  [ "${#per_run[@]}" -eq 1 ]
  RUN_DIR="${per_run[0]}"
  [ -f "${RUN_DIR}runner.log" ]
  [ -f "${RUN_DIR}SUMMARY.md" ]
  [ -f "${RUN_DIR}smoke/01.log" ]
  [ -f "${RUN_DIR}smoke/01-review.log" ]
}

@test "smoke — propagated → host (park=main)" {
  # Park host on `main` so propagation step 2's `git fetch <checkout>
  # smoke:smoke` is free to fast-forward `refs/heads/smoke`.
  git -C "$WORKSPACE" -c user.email=smoke@test -c user.name=smoke \
    checkout -q main

  # Fixture has to be visible to `tracker-snapshot --list` (which reads
  # the host's working tree via TRACKER_ROOT). Drop it back in as
  # untracked so discovery sees the slug even though `main` doesn't
  # carry the commit.
  mkdir -p "$WORKSPACE/.features/smoke"
  cp "$FIXTURE_DIR/PRD.md" "$WORKSPACE/.features/smoke/"
  cp -R "$FIXTURE_DIR/issues" "$WORKSPACE/.features/smoke/"
  INITIAL_MAIN_TIP="$(git -C "$WORKSPACE" rev-parse refs/heads/main)"

  cd "$WORKSPACE"
  run bash "$WORKSPACE/.formann/runner/run-the-queue.sh"
  assert_success

  # smoke branch fast-forwarded with new commits.
  current_smoke="$(git -C "$WORKSPACE" rev-parse refs/heads/smoke)"
  [ "$current_smoke" != "$INITIAL_SMOKE_TIP" ]

  # Issue 01 status flipped to `done` on the propagated smoke tip.
  run git -C "$WORKSPACE" show smoke:.features/smoke/issues/01-stamp-marker.md
  assert_success
  echo "$output" | grep -qE '^status: done$'

  # Marker landed at the expected path on smoke.
  run git -C "$WORKSPACE" cat-file -e "smoke:.features/smoke/markers/MARKER-01.txt"
  assert_success

  # Park branch (main) did not move.
  current_main="$(git -C "$WORKSPACE" rev-parse refs/heads/main)"
  [ "$current_main" = "$INITIAL_MAIN_TIP" ]

  # Per-run artifacts present.
  assert_run_artifacts

  # smoke tip carries the gate's tracker commit. The agent picks the
  # exact phrasing (the gate prompt doesn't lock a subject template), so
  # match the intent rather than a literal string: `tracker:` prefix,
  # mentions the issue ref, mentions the `done` outcome.
  run git -C "$WORKSPACE" log --format="%s" -1 refs/heads/smoke
  echo "$output" | grep -qE '^tracker:.*smoke/01.*done'
}

@test "smoke — parked → runner/smoke (park=smoke)" {
  # Host stays on `smoke` (the feature branch). Propagation step 2 will
  # refuse `git fetch <checkout> smoke:smoke` because HEAD is on the
  # target branch; the work parks at refs/remotes/runner/smoke.

  cd "$WORKSPACE"
  run bash "$WORKSPACE/.formann/runner/run-the-queue.sh"
  assert_success

  # smoke branch did NOT advance — propagation parked.
  current_smoke="$(git -C "$WORKSPACE" rev-parse refs/heads/smoke)"
  [ "$current_smoke" = "$INITIAL_SMOKE_TIP" ]

  # Parking ref carries the new tip.
  parking_ref="refs/remotes/runner/smoke"
  parking_tip="$(git -C "$WORKSPACE" rev-parse --verify "$parking_ref")"
  [ "$parking_tip" != "$INITIAL_SMOKE_TIP" ]

  # Issue 01 status flipped to `done` on the parking tip.
  run git -C "$WORKSPACE" show "$parking_ref:.features/smoke/issues/01-stamp-marker.md"
  assert_success
  echo "$output" | grep -qE '^status: done$'

  # Marker landed at the expected path on the parking ref.
  run git -C "$WORKSPACE" cat-file -e \
    "$parking_ref:.features/smoke/markers/MARKER-01.txt"
  assert_success

  # Per-run artifacts present.
  assert_run_artifacts

  # Parking-ref tip carries the gate's tracker commit. See the
  # propagated scenario — the agent picks the subject phrasing.
  run git -C "$WORKSPACE" log --format="%s" -1 "$parking_ref"
  echo "$output" | grep -qE '^tracker:.*smoke/01.*done'

  # SUMMARY.md records the parked propagation outcome.
  grep -q "parked → runner/smoke" "${RUN_DIR}SUMMARY.md"
}

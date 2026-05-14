#!/usr/bin/env bats
#
# End-to-end smoke test for the AFK runner.
#
# Slow (~1–2 min) and expensive — drives real Docker, real claude
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
# Asserts, after one dispatch:
#
#   1. Issue 01's frontmatter flipped to `status: done` (gate ran clean).
#   2. The throwaway workspace's `smoke` branch fast-forwarded with a
#      new commit whose tree contains
#      `.scratch/smoke/markers/MARKER-01.txt`.
#   3. The per-run dir under `.runner-state/runs/<ts>/` contains both
#      `runner.log` and `SUMMARY.md` (sanity check on slice 06's
#      output surface).
#   4. The per-run dir contains `01-review.log` (gate forensic log).
#   5. The `smoke` branch tip carries the gate's tracker commit
#      (`tracker: review smoke/01 → done`).
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
  HOST_REPO="$(cd "$HERE/../../.." && pwd)"     # iot repo root
  FIXTURE_DIR="$HERE/fixtures/smoke"

  # Workspaces live under the host's gitignored `.runner-state/` so
  # their absolute path stays under $HOME — Docker Desktop on macOS
  # only bind-mounts paths under $HOME by default; bats's standard
  # `BATS_TEST_TMPDIR` (which resolves under /var/folders) would not
  # be reachable from inside the dispatch container.
  mkdir -p "$HOST_REPO/.runner-state/smoke-work"
  WORKSPACE="$(mktemp -d "$HOST_REPO/.runner-state/smoke-work/run.XXXXXX")"
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

@test "smoke — drain a single AFK issue end-to-end" {
  # 1. Stage framework + project-level skills + fixture into the workspace.
  #    `cp -RP` preserves symlinks (the .claude/skills/* symlinks all
  #    point at framework/skills/* via relative paths, so they continue
  #    to resolve correctly inside the workspace).
  cp -RP "$HOST_REPO/.agents" "$WORKSPACE/.agents"
  mkdir -p "$WORKSPACE/.claude"
  cp -RP "$HOST_REPO/.claude/skills" "$WORKSPACE/.claude/skills"
  cp -RP "$HOST_REPO/.claude/agents" "$WORKSPACE/.claude/agents"
  mkdir -p "$WORKSPACE/.scratch/smoke"
  cp "$FIXTURE_DIR/PRD.md" "$WORKSPACE/.scratch/smoke/"
  cp -R "$FIXTURE_DIR/issues" "$WORKSPACE/.scratch/smoke/"
  # `.runner-state/` must be gitignored so pre-flight's "host clean"
  # check passes after the runner creates the per-run dir.
  printf '/.runner-state/\n' >"$WORKSPACE/.gitignore"

  # 2. Initialise the workspace as a git repo on branch `smoke`. We
  #    set HEAD via `symbolic-ref` rather than `git init -b` for
  #    portability with older git versions.
  git -C "$WORKSPACE" init -q
  git -C "$WORKSPACE" symbolic-ref HEAD refs/heads/smoke
  git -C "$WORKSPACE" -c user.email=smoke@test -c user.name=smoke add -A
  git -C "$WORKSPACE" -c user.email=smoke@test -c user.name=smoke \
    commit -q -m "smoke: initial fixture"
  initial_head="$(git -C "$WORKSPACE" rev-parse HEAD)"

  # 3. Dispatch. The runner derives HOST_REPO from $HERE/../.. relative
  #    to its own location, so it picks up `$WORKSPACE` as the host repo
  #    regardless of cwd; `cd "$WORKSPACE"` is purely defensive.
  cd "$WORKSPACE"
  run bash "$WORKSPACE/framework/runner/run-the-queue.sh"
  assert_success

  # 4. Issue 01's frontmatter flipped to `done` (gate ran clean).
  run grep -E '^status: done$' \
    "$WORKSPACE/.scratch/smoke/issues/01-stamp-marker.md"
  assert_success

  # 5. Workspace's `smoke` branch fast-forwarded with a new commit
  #    whose tree contains the expected marker.
  current_head="$(git -C "$WORKSPACE" rev-parse HEAD)"
  [ "$current_head" != "$initial_head" ]
  run git -C "$WORKSPACE" cat-file -e \
    "smoke:.scratch/smoke/markers/MARKER-01.txt"
  assert_success

  # 6. Per-run dir contains runner.log and SUMMARY.md.
  shopt -s nullglob
  runs_dir="$WORKSPACE/.runner-state/runs"
  [ -d "$runs_dir" ]
  per_run=("$runs_dir"/*/)
  [ "${#per_run[@]}" -eq 1 ]
  run_dir="${per_run[0]}"
  [ -f "${run_dir}runner.log" ]
  [ -f "${run_dir}SUMMARY.md" ]
  [ -f "${run_dir}01-review.log" ]

  # 7. Gate's `tracker:` commit is present at `smoke` branch tip.
  run git -C "$WORKSPACE" log --format="%s" -1
  assert_output "tracker: review smoke/01 → done"
}

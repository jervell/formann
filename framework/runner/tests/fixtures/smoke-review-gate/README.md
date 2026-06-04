# smoke-review-gate fixture

Smoke fixture for the `[review, gate]` manifest composition. Exercises the
separate `review` and `gate` building-block steps together: `review` posts
findings; `gate` reads the latest findings comment and applies the
Critical-findings threshold.

## Layout

```
smoke-review-gate/
├── README.md                 (this file)
├── PRD.md                    installs at .features/smoke-review-gate/PRD.md
├── manifest.md               install as runner/manifest.md in the workspace
└── issues/
    └── 01-stamp-marker.md    trivial AFK task — write MARKER-01.txt
```

## Claimed outcome

After the runner drains the queue with this manifest:

1. `/implement` runs and lands the issue at `in-review`.
2. The `review` step runs: a severity-tagged "Review (AFK runner)"
   comment is posted on the issue. Issue stays at `in-review`.
3. The `gate` step runs: reads the latest findings comment and applies
   the threshold.
   - If no Critical findings → issue promoted to `done`.
   - If Critical findings → issue stays at `in-review`.
4. Step logs: `01-01-review.log` and `01-02-gate.log` both exist.
5. `SUMMARY.md` records `done` (clean path) or `left-for-human` (blocked path).

For a trivial marker-write issue, the review is expected to be clean
and the gate should promote to `done`.

## Runbook

### Setup

```sh
mkdir -p .runner-state/smoke-work
ws=$(mktemp -d "$(pwd)/.runner-state/smoke-work/run.XXXXXX")

ln -s "$(pwd)/framework" "$ws/.formann"
mkdir -p "$ws/docs/formann"
ln -s ../../.formann/bindings/issue-tracker/local-markdown \
      "$ws/docs/formann/issue-tracker"
cp -RP .claude "$ws/.claude"
cat >"$ws/.gitignore" <<'EOF'
/.formann
/docs/formann/issue-tracker
/.claude
/.runner-state/
EOF

mkdir -p "$ws/runner"
cp framework/runner/tests/fixtures/smoke-review-gate/manifest.md \
   "$ws/runner/manifest.md"

git -C "$ws" init -q
git -C "$ws" symbolic-ref HEAD refs/heads/main
git -C "$ws" -c user.email=smoke@test -c user.name=smoke add -A
git -C "$ws" -c user.email=smoke@test -c user.name=smoke \
  commit -q -m "smoke-review-gate: initial workspace scaffold"
git -C "$ws" -c user.email=smoke@test -c user.name=smoke checkout -q -b smoke-review-gate
mkdir -p "$ws/.features/smoke-review-gate"
cp framework/runner/tests/fixtures/smoke-review-gate/PRD.md \
   "$ws/.features/smoke-review-gate/"
cp -R framework/runner/tests/fixtures/smoke-review-gate/issues \
      "$ws/.features/smoke-review-gate/"
git -C "$ws" -c user.email=smoke@test -c user.name=smoke add -A
git -C "$ws" -c user.email=smoke@test -c user.name=smoke \
  commit -q -m "smoke-review-gate: install fixture"

git -C "$ws" -c user.email=smoke@test -c user.name=smoke checkout -q main
mkdir -p "$ws/.features/smoke-review-gate"
cp framework/runner/tests/fixtures/smoke-review-gate/PRD.md \
   "$ws/.features/smoke-review-gate/"
cp -R framework/runner/tests/fixtures/smoke-review-gate/issues \
      "$ws/.features/smoke-review-gate/"
```

### Run

```sh
( cd "$ws" && bash "$ws/.formann/runner/run-the-queue.sh" )
```

### Verify

```sh
# The runner propagates to the feature-branch ref; the host working tree stays
# on `main`. Inspect the propagated `smoke-review-gate` branch, not the
# checked-out files (which still show the pre-dispatch scaffold).

# Clean path: issue promoted to done.
git -C "$ws" show smoke-review-gate:.features/smoke-review-gate/issues/01-stamp-marker.md | grep '^status:'
# → status: done

# Both step logs exist (drain mode nests logs under the feature slug).
ls "$ws/.runner-state/runs/"*/smoke-review-gate/01-01-review.log
ls "$ws/.runner-state/runs/"*/smoke-review-gate/01-02-gate.log

# SUMMARY.md shows done.
grep 'done' "$ws/.runner-state/runs/"*/SUMMARY.md
```

### Teardown

```sh
rm -rf "$ws"
docker volume rm runner-mvn-cache-smoke-review-gate 2>/dev/null || true
```

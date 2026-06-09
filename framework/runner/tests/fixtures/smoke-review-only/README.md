# smoke-review-only fixture

Smoke fixture for the `[review]` manifest composition. Exercises the
`review` building-block step in isolation: findings are posted, the
issue stays at `in-review`, and no state promotion occurs.

## Layout

```
smoke-review-only/
├── README.md                 (this file)
├── PRD.md                    installs at .features/smoke-review-only/PRD.md
├── manifest.md               install as runner/manifest.md in the workspace
└── issues/
    └── 01-stamp-marker.md    trivial AFK task — write MARKER-01.txt
```

## Claimed outcome

After the runner drains the queue with this manifest:

1. `/implement` runs and lands the issue at `in-review`.
2. The `review` step runs: a severity-tagged "Review (AFK runner)"
   comment is posted on the issue.
3. The issue remains at `in-review` — no state promotion.
4. The step event stream (`01-01-review.stdout.jsonl`) contains the review findings and
   a `verdict:` line.
5. `SUMMARY.md` records `left-for-human` (the manifest was exhausted
   without reaching `done`).

## Runbook

### Setup

```sh
# Workspace must live under $HOME for Docker Desktop's bind-mount.
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

# Install runner directory with the review-only manifest.
mkdir -p "$ws/runner"
cp framework/runner/tests/fixtures/smoke-review-only/manifest.md \
   "$ws/runner/manifest.md"

# Scaffold commit on main, then feature branch with fixture committed.
git -C "$ws" init -q
git -C "$ws" symbolic-ref HEAD refs/heads/main
git -C "$ws" -c user.email=smoke@test -c user.name=smoke add -A
git -C "$ws" -c user.email=smoke@test -c user.name=smoke \
  commit -q -m "smoke-review-only: initial workspace scaffold"
git -C "$ws" -c user.email=smoke@test -c user.name=smoke checkout -q -b smoke-review-only
mkdir -p "$ws/.features/smoke-review-only"
cp framework/runner/tests/fixtures/smoke-review-only/PRD.md \
   "$ws/.features/smoke-review-only/"
cp -R framework/runner/tests/fixtures/smoke-review-only/issues \
      "$ws/.features/smoke-review-only/"
git -C "$ws" -c user.email=smoke@test -c user.name=smoke add -A
git -C "$ws" -c user.email=smoke@test -c user.name=smoke \
  commit -q -m "smoke-review-only: install fixture"

git -C "$ws" -c user.email=smoke@test -c user.name=smoke checkout -q main
mkdir -p "$ws/.features/smoke-review-only"
cp framework/runner/tests/fixtures/smoke-review-only/PRD.md \
   "$ws/.features/smoke-review-only/"
cp -R framework/runner/tests/fixtures/smoke-review-only/issues \
      "$ws/.features/smoke-review-only/"
```

### Run

```sh
( cd "$ws" && bash "$ws/.formann/runner/run-the-queue.sh" )
```

### Verify

```sh
# The runner propagates to the feature-branch ref; the host working tree stays
# on `main`. Inspect the propagated `smoke-review-only` branch, not the
# checked-out files (which still show the pre-dispatch scaffold).

# Issue stays at in-review.
git -C "$ws" show smoke-review-only:.features/smoke-review-only/issues/01-stamp-marker.md | grep '^status:'
# → status: in-review

# A findings comment was posted (review-issue output under a "Review (AFK runner)" heading).
git -C "$ws" show smoke-review-only:.features/smoke-review-only/issues/01-stamp-marker.md | grep -F '### Review (AFK runner)'

# The step event stream exists (drain mode nests logs under the feature slug).
ls "$ws/.runner-state/runs/"*/smoke-review-only/01-01-review.stdout.jsonl

# SUMMARY.md shows left-for-human.
grep 'left-for-human' "$ws/.runner-state/runs/"*/SUMMARY.md
```

### Teardown

```sh
rm -rf "$ws"
docker volume rm runner-mvn-cache-smoke-review-only 2>/dev/null || true
```

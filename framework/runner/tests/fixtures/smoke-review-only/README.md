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
4. The step log (`01-01-review.log`) contains the review findings and
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
# Issue stays at in-review.
grep '^status:' "$ws/.features/smoke-review-only/issues/01-stamp-marker.md"
# → status: in-review

# A findings comment was posted (local-markdown: check .features/… comments dir or issue body).
# The step log exists.
ls "$ws/.runner-state/runs/"*/01-01-review.log

# SUMMARY.md shows left-for-human.
grep 'left-for-human' "$ws/.runner-state/runs/"*/SUMMARY.md
```

### Teardown

```sh
rm -rf "$ws"
docker volume rm runner-mvn-cache-smoke-review-only 2>/dev/null || true
```

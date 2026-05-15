# Synthetic-drain fixture

A two-issue micro-feature template used to drive the AFK runner's
loop end-to-end without depending on the live `afk-runner` queue.
Slice 05 demos against this; slice 08's end-to-end smoke test reuses it.

## Layout

```
synthetic-drain/
├── README.md                    (this file)
├── PRD.md                       installs at .features/synthetic-drain/PRD.md
└── issues/
    ├── 01-stamp-marker-one.md   trivial AFK task — write MARKER-01.txt
    └── 02-stamp-marker-two.md   trivial AFK task — write MARKER-02.txt
```

Each issue's "What to build" tells `/implement` to create a single
one-line marker file under `.features/synthetic-drain/markers/` and
commit it. Both issues are AFK + `ready-for-agent` with no blockers,
so both are eligible from the first iteration.

## How to drive the demo

The runner expects the host branch to match the feature slug and
`.features/<slug>/` to exist. Install the fixture, switch branches, run.

```sh
# 1. Switch to a fresh branch named after the feature.
git checkout -b synthetic-drain

# 2. Copy the fixture into .features/.
mkdir -p .features/synthetic-drain
cp -R framework/runner/tests/fixtures/synthetic-drain/PRD.md \
      .features/synthetic-drain/
cp -R framework/runner/tests/fixtures/synthetic-drain/issues \
      .features/synthetic-drain/

# 3. Drop the template tree on this branch so /implement matches one
#    file, not two. (Template and live issue share the same path shape;
#    leaving both on the same branch makes /implement's resolution
#    nondeterministic.)
if [ -d framework/runner/tests/fixtures/synthetic-drain ]; then
  git rm -r framework/runner/tests/fixtures/synthetic-drain
fi

# 4. Commit so the fixture lives at HEAD (the runner reads
#    .features from the runner-checkout's HEAD, not its working tree).
git add .features/synthetic-drain
git commit -m "synthetic-drain: install demo fixture"

# 5. Park host on master so the runner can drain synthetic-drain
#    (any feature whose branch is currently checked out is skipped
#    with `branch-checked-out`, including under `--feature`).
git checkout master

# 6. Re-stage the fixture as an untracked dir in master's working tree
#    so `tracker-snapshot --list` (which scans the host working tree)
#    discovers the slug. Without this, `--feature synthetic-drain` is
#    refused with `unknown-feature` regardless of merge state.
#    Mirrors multi-feature-drain's setup step 3. Do NOT commit on master.
mkdir -p .features/synthetic-drain
cp -R framework/runner/tests/fixtures/synthetic-drain/PRD.md \
      .features/synthetic-drain/
cp -R framework/runner/tests/fixtures/synthetic-drain/issues \
      .features/synthetic-drain/
bash framework/bindings/issue-tracker/local-markdown/tracker-snapshot --list \
  | grep -q synthetic-drain   # sanity-check: slug now in discovery output

# 7. Drain just this feature.
bash framework/runner/run-the-queue.sh --feature synthetic-drain
```

The runner should dispatch issue 01, propagate the commit into host's
`synthetic-drain` ref, then issue 02, then report `queue empty`. Markers
land at `.features/synthetic-drain/markers/MARKER-{01,02}.txt` on the
`synthetic-drain` branch.

## Ctrl-C demo

While the runner is mid-dispatch (you'll see `[hh:mm:ss] dispatch
start: synthetic-drain/01`), press Ctrl-C. The runner sends SIGTERM
to the in-flight container, escalates to SIGKILL after
`RUNNER_KILL_GRACE_SECONDS` (10s) if needed, prints
`runner: interrupted during dispatch …`, and exits without starting
the next iteration.

## Tear-down

```sh
git checkout <your-working-branch>  # back to the working branch
rm -rf .features/synthetic-drain     # drop the seeded untracked fixture
git branch -D synthetic-drain       # delete the demo branch
docker volume rm runner-mvn-cache-synthetic-drain
```

The `.runner-state/` dir lives under the host repo root and is
gitignored — nothing leaks into committed history.

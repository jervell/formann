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

The runner expects `.features/<slug>/` to exist in the working tree so
`tracker-snapshot --list` discovers the slug. A host branch is no longer
required — the runner lazily creates it from `main` on first dispatch.

```sh
# 1. Seed the fixture into .features/ (working tree only; no branch switch needed).
mkdir -p .features/synthetic-drain
cp -R framework/runner/tests/fixtures/synthetic-drain/PRD.md \
      .features/synthetic-drain/
cp -R framework/runner/tests/fixtures/synthetic-drain/issues \
      .features/synthetic-drain/
bash framework/bindings/issue-tracker/local-markdown/tracker-snapshot --list \
  | grep -q synthetic-drain   # sanity-check: slug now in discovery output

# 2. Drain just this feature.
bash framework/runner/run-the-queue.sh --feature synthetic-drain
```

The runner will:
1. Detect that `refs/heads/synthetic-drain` is absent on host and lazily
   initialize the runner-checkout's branch from `refs/heads/main`.
2. Dispatch issue 01 and propagate the commit, creating `refs/heads/synthetic-drain`
   on host from the runner's commits.
3. Dispatch issue 02, then report `queue empty`.

Markers land at `.features/synthetic-drain/markers/MARKER-{01,02}.txt` on the
`synthetic-drain` branch.

### Pre-creating the branch (optional)

You may still create the branch manually before running if you want to start
from a specific tip rather than `main`:

```sh
git checkout -b synthetic-drain
# … commit the fixture onto the branch …
git checkout master
```

The runner detects the existing branch and syncs to it as before.

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

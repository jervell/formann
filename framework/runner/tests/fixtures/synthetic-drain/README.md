# Synthetic-drain fixture

A two-issue micro-feature for driving the AFK runner's loop end-to-end
against real Docker, real claude inference, and real `git fetch`
propagation — without touching the live `afk-runner` queue. The dispatch
container has no Docker socket, so this is **operator-attended**: drive it
from the host, not from inside the runner.

## Layout

```
synthetic-drain/
├── README.md                    (this file)
├── PRD.md                       → .features/synthetic-drain/PRD.md
└── issues/
    ├── 01-stamp-marker-one.md   trivial AFK task — write MARKER-01.txt
    └── 02-stamp-marker-two.md   trivial AFK task — write MARKER-02.txt
```

Both issues are `ready-for-agent + AFK` with no blockers, so both are
eligible from the first iteration. Each tells `/implement` to write one
marker under `.features/synthetic-drain/markers/` and commit.

## Run

The walk runs in a throwaway **synthetic-consumer workspace** — a fresh
git repo that symlinks the host's live `framework/` and the local-markdown
binding. The host repo is never modified (see [Notes](#notes)). Run from
the host repo root:

```sh
# 1. Build the workspace (must live under $HOME — see Notes).
mkdir -p .runner-state/smoke-work
ws=$(mktemp -d "$(pwd)/.runner-state/smoke-work/run.XXXXXX")
ln -s "$(pwd)/framework" "$ws/.formann"
mkdir -p "$ws/docs/formann"
ln -s ../../.formann/bindings/issue-tracker/local-markdown "$ws/docs/formann/issue-tracker"
cp -RP .claude "$ws/.claude"
printf '/.formann\n/docs/formann/issue-tracker\n/.claude\n/.runner-state/\n' > "$ws/.gitignore"

# 2. Scaffold main, then commit the fixture on the synthetic-drain branch.
#    (The snapshot reads committed HEAD — the fixture MUST be committed; see Notes.)
git -C "$ws" init -q
git -C "$ws" config user.email smoke@test && git -C "$ws" config user.name smoke
git -C "$ws" symbolic-ref HEAD refs/heads/main
git -C "$ws" add -A && git -C "$ws" commit -q -m "scaffold workspace"
git -C "$ws" checkout -q -b synthetic-drain
mkdir -p "$ws/.features/synthetic-drain"
cp framework/runner/tests/fixtures/synthetic-drain/PRD.md "$ws/.features/synthetic-drain/"
cp -R framework/runner/tests/fixtures/synthetic-drain/issues "$ws/.features/synthetic-drain/"
git -C "$ws" add -A && git -C "$ws" commit -q -m "synthetic-drain: install fixture"

# 3. Park on main with an untracked copy so discovery (--list, working tree) sees it.
git -C "$ws" checkout -q main
mkdir -p "$ws/.features/synthetic-drain"
cp framework/runner/tests/fixtures/synthetic-drain/PRD.md "$ws/.features/synthetic-drain/"
cp -R framework/runner/tests/fixtures/synthetic-drain/issues "$ws/.features/synthetic-drain/"

# 4. Sanity-check discovery through the binding the runner uses, then drain.
( cd "$ws" && bash docs/formann/issue-tracker/tracker-snapshot --list )   # → ["synthetic-drain"]
( cd "$ws" && bash .formann/runner/run-the-queue.sh )
```

**Expected:** both issues run `implement → review → done`; `stop reason:
completed`; exit 0. HEAD is parked on `main`, so propagation
fast-forwards host's `refs/heads/synthetic-drain`; the markers
(`MARKER-01.txt`, `MARKER-02.txt`) and tracker commits land on that
branch.

To exercise the **parked** path instead, stay on the `synthetic-drain`
branch (skip step 3's `checkout main`). git then refuses the host
fast-forward and the work parks at `refs/remotes/runner/synthetic-drain`
(recover with `git pull runner synthetic-drain`).

## Ctrl-C demo

While a dispatch is in flight (`[hh:mm:ss] dispatch start:
synthetic-drain/01`), press Ctrl-C. The runner SIGTERMs the container,
escalates to SIGKILL after `RUNNER_KILL_GRACE_SECONDS` (10s), prints
`runner: interrupted during dispatch …`, and exits without starting the
next iteration.

## Teardown

```sh
rm -rf "$ws"
docker volume rm runner-mvn-cache-synthetic-drain   # optional — reclaim the mvn cache
```

Nothing else to undo: the host repo and its active binding were never
modified.

## Notes

**Why a workspace, not the host repo.** The runner discovers and
dispatches through the binding symlinked at `docs/formann/issue-tracker`.
This fixture is local-markdown-shaped (`.features/<slug>/…`), but a real
consumer's active binding may be github-issues, which can't see
`.features/`. Rather than swap the host's binding and have to restore it
(fragile if the walk aborts), the walk builds a disposable local-markdown
consumer that symlinks the host's live `framework/`. Abort-safe by
construction — `rm -rf "$ws"` leaves nothing in the host repo to undo.

**The workspace must live under `$HOME`.** Docker Desktop on macOS only
bind-mounts paths under `$HOME` by default. Under `$TMPDIR`
(`/var/folders/…`) or `/tmp` the `.formann` mount comes up empty, every
framework skill dangles, and the dispatch fails with `Unknown command:
/implement`. `.runner-state/smoke-work/` sits under the host repo, so it
satisfies this.

**The fixture must be committed on the branch.** The per-feature snapshot
extracts `.features/` from the runner-checkout's committed `HEAD`, not the
working tree. A working-tree-only fixture is listed by `--list` but fails
the snapshot — discovery and dispatch read different sources. The
untracked copy in step 3 is only there so `--list` finds the slug while
HEAD is parked on `main`.

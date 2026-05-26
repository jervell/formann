# Smoke fixture

A one-issue micro-feature used by `tests/smoke.bats` to drive the
AFK runner end-to-end against real Docker, real claude inference, and
real fast-forward. Slow and expensive, so guarded behind the
`RUNNER_SMOKE` env var — default `bats` invocations skip the test.

## Layout

```
smoke/
├── README.md                 (this file)
├── PRD.md                    installs at .features/smoke/PRD.md
└── issues/
    └── 01-stamp-marker.md    trivial AFK task — write MARKER-01.txt
```

`smoke.bats` stages a throwaway workspace under
`<host>/.runner-state/smoke-work/run.XXXXXX/` as a synthetic consumer of
the host's live framework — a `.formann` symlink into
`<host>/framework`, a `docs/formann/issue-tracker` symlink into the
local-markdown binding (the fixture's shape), and a copy of `.claude/`.
The fixture is committed on a `smoke` branch; the test then drives two
scenarios — one with HEAD parked on `main` (propagation fast-forwards
host's `refs/heads/smoke`), one with HEAD parked on `smoke` (propagation
step 2 refuses, the work parks at `refs/remotes/runner/smoke`).

The workspace lives under the host's gitignored `.runner-state/`
(rather than `$BATS_TEST_TMPDIR`) because Docker Desktop on macOS only
bind-mounts paths under `$HOME` by default — `$TMPDIR` resolves under
`/var/folders/...` and the dispatch container would see an empty
mount.

## Manual reproduction

`smoke.bats` itself is the source of truth — see its `setup()` for the
exact workspace plumbing and each `@test` block for the dispatch and
assertions. To drive a single scenario by hand without bats, follow the
same shape:

```sh
# Workspace must live under $HOME for Docker Desktop's bind-mount;
# a bare `mktemp -d` would resolve under /var/folders/... and the
# dispatch container would see an empty mount.
mkdir -p .runner-state/smoke-work
ws=$(mktemp -d "$(pwd)/.runner-state/smoke-work/run.XXXXXX")

# Synthetic consumer of host's live framework.
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

# Scaffold commit on main, then smoke branch with fixture committed.
git -C "$ws" init -q
git -C "$ws" symbolic-ref HEAD refs/heads/main
git -C "$ws" -c user.email=smoke@test -c user.name=smoke add -A
git -C "$ws" -c user.email=smoke@test -c user.name=smoke \
  commit -q -m "smoke: initial workspace scaffold"
git -C "$ws" -c user.email=smoke@test -c user.name=smoke checkout -q -b smoke
mkdir -p "$ws/.features/smoke"
cp framework/runner/tests/fixtures/smoke/PRD.md "$ws/.features/smoke/"
cp -R framework/runner/tests/fixtures/smoke/issues "$ws/.features/smoke/"
git -C "$ws" -c user.email=smoke@test -c user.name=smoke add -A
git -C "$ws" -c user.email=smoke@test -c user.name=smoke \
  commit -q -m "smoke: install fixture"

# Park elsewhere to exercise the propagated path, or stay on smoke for
# the parked path.
git -C "$ws" -c user.email=smoke@test -c user.name=smoke checkout -q main
mkdir -p "$ws/.features/smoke"
cp framework/runner/tests/fixtures/smoke/PRD.md "$ws/.features/smoke/"
cp -R framework/runner/tests/fixtures/smoke/issues "$ws/.features/smoke/"

( cd "$ws" && bash "$ws/.formann/runner/run-the-queue.sh" )
```

The runner should report `queue empty` after one dispatch. On the
propagated path, the workspace's `smoke` branch advances by the
dispatch + tracker commits; on the parked path, `refs/remotes/runner/smoke`
carries the new tip and host's `refs/heads/smoke` stays put. The marker
lands at `.features/smoke/markers/MARKER-01.txt` on whichever ref took
the work. Tear-down is `rm -rf "$ws"` and (optionally) `docker volume rm
runner-mvn-cache-smoke` to reclaim the per-feature mvn cache.

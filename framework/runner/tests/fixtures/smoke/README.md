# Smoke fixture

A one-issue micro-feature used by `tests/smoke.bats` to drive the
AFK runner end-to-end against real Docker, real claude inference, and
real fast-forward. Slow and expensive, so guarded behind the
`RUNNER_SMOKE` env var — default `bats` invocations skip the test.

## Layout

```
smoke/
├── README.md                 (this file)
├── PRD.md                    installs at .scratch/smoke/PRD.md
└── issues/
    └── 01-stamp-marker.md    trivial AFK task — write MARKER-01.txt
```

`smoke.bats` stages the fixture into a throwaway workspace under
`<host>/.runner-state/smoke-work/run.XXXXXX/`, copies the in-tree
framework (`framework/`) and project-level skill symlinks
(`.claude/skills/`) alongside it, commits, switches the workspace to
branch `smoke`, runs `bash <workspace>/framework/runner/run-the-queue.sh`,
and asserts the runner advanced the issue and fast-forwarded the
workspace branch. The workspace lives under the host's gitignored
`.runner-state/` (rather than `$BATS_TEST_TMPDIR`) because Docker
Desktop on macOS only bind-mounts paths under `$HOME` by default —
`$TMPDIR` resolves under `/var/folders/...` and the dispatch container
would see an empty mount.

## Manual reproduction

To reproduce a smoke run by hand without going through bats:

```sh
# Workspace must live under $HOME for Docker Desktop's bind-mount
# (see Layout note above); a bare `mktemp -d` would resolve under
# /var/folders/... and the dispatch container would see an empty mount.
mkdir -p .runner-state/smoke-work
ws=$(mktemp -d "$(pwd)/.runner-state/smoke-work/run.XXXXXX")
cp -RP .agents "$ws/.agents"
mkdir -p "$ws/.claude" && cp -RP .claude/skills "$ws/.claude/skills"
mkdir -p "$ws/.scratch/smoke"
cp framework/runner/tests/fixtures/smoke/PRD.md "$ws/.scratch/smoke/"
cp -R framework/runner/tests/fixtures/smoke/issues "$ws/.scratch/smoke/"
printf '/.runner-state/\n' > "$ws/.gitignore"
git -C "$ws" init -q
git -C "$ws" symbolic-ref HEAD refs/heads/smoke
git -C "$ws" -c user.email=smoke@test -c user.name=smoke add -A
git -C "$ws" -c user.email=smoke@test -c user.name=smoke \
  commit -q -m "smoke: initial fixture"
( cd "$ws" && bash "$ws/framework/runner/run-the-queue.sh" )
```

The runner should report `queue empty` after one dispatch. The
workspace's `smoke` branch advances by one commit; the marker lands
at `.scratch/smoke/markers/MARKER-01.txt`. Tear-down is `rm -rf
"$ws"` and (optionally) `docker volume rm runner-mvn-cache-smoke` to
reclaim the per-feature mvn cache.

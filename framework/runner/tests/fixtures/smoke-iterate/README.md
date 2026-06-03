# smoke-iterate fixture

Smoke fixture for the unrolled iterate manifest composition:
`[review-and-gate, fix, review-and-gate]`. Exercises the early-exit
behavior: the runner stops at the first manifest entry that reaches
`done`, spending no further Dispatches.

Note: this manifest has repeated labels (`review-and-gate` appears at
steps 1 and 3). The runner disambiguates log files by walk position:
`01-01-review-and-gate.log`, `01-02-fix.log`, `01-03-review-and-gate.log`.

## Layout

```
smoke-iterate/
├── README.md                 (this file)
├── PRD.md                    installs at .features/smoke-iterate/PRD.md
├── manifest.md               install as runner/manifest.md in the workspace
└── issues/
    └── 01-stamp-marker.md    trivial AFK task — write MARKER-01.txt
```

## Claimed outcome

For a clean issue (no Critical findings at step 1):

1. `/implement` runs and lands the issue at `in-review`.
2. Step 1 (`review-and-gate`): review runs, no Critical findings, issue
   promoted to `done`. The runner records `stop-success` and exits the
   manifest walk.
3. Steps 2 (`fix`) and 3 (`review-and-gate`) are **not dispatched** —
   early-exit triggered by `done` status.
4. Only `01-01-review-and-gate.log` exists; `01-02-fix.log` and
   `01-03-review-and-gate.log` are absent.
5. `SUMMARY.md` records `done`.

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
cp framework/runner/tests/fixtures/smoke-iterate/manifest.md \
   "$ws/runner/manifest.md"

git -C "$ws" init -q
git -C "$ws" symbolic-ref HEAD refs/heads/main
git -C "$ws" -c user.email=smoke@test -c user.name=smoke add -A
git -C "$ws" -c user.email=smoke@test -c user.name=smoke \
  commit -q -m "smoke-iterate: initial workspace scaffold"
git -C "$ws" -c user.email=smoke@test -c user.name=smoke checkout -q -b smoke-iterate
mkdir -p "$ws/.features/smoke-iterate"
cp framework/runner/tests/fixtures/smoke-iterate/PRD.md \
   "$ws/.features/smoke-iterate/"
cp -R framework/runner/tests/fixtures/smoke-iterate/issues \
      "$ws/.features/smoke-iterate/"
git -C "$ws" -c user.email=smoke@test -c user.name=smoke add -A
git -C "$ws" -c user.email=smoke@test -c user.name=smoke \
  commit -q -m "smoke-iterate: install fixture"

git -C "$ws" -c user.email=smoke@test -c user.name=smoke checkout -q main
mkdir -p "$ws/.features/smoke-iterate"
cp framework/runner/tests/fixtures/smoke-iterate/PRD.md \
   "$ws/.features/smoke-iterate/"
cp -R framework/runner/tests/fixtures/smoke-iterate/issues \
      "$ws/.features/smoke-iterate/"
```

### Run

```sh
( cd "$ws" && bash "$ws/.formann/runner/run-the-queue.sh" )
```

### Verify

```sh
# Issue reached done (early-exit at first clean gate).
grep '^status:' "$ws/.features/smoke-iterate/issues/01-stamp-marker.md"
# → status: done

# Only the first step's log exists; steps 2 and 3 were skipped.
ls "$ws/.runner-state/runs/"*/01-01-review-and-gate.log  # present
ls "$ws/.runner-state/runs/"*/01-02-fix.log 2>/dev/null   # absent
ls "$ws/.runner-state/runs/"*/01-03-review-and-gate.log 2>/dev/null  # absent

# SUMMARY.md shows done.
grep 'done' "$ws/.runner-state/runs/"*/SUMMARY.md
```

### Teardown

```sh
rm -rf "$ws"
docker volume rm runner-mvn-cache-smoke-iterate 2>/dev/null || true
```

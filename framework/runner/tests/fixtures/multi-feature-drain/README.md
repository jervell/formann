# Multi-feature drain fixture

Operator-attended smoke for the AFK runner's bare-invocation **drain-all**
outer loop. Two micro-features (`multi-drain-alpha`, `multi-drain-beta`),
each with one trivial AFK issue, so a bare invocation has two side-by-side
features to walk. Exercises the multi-feature loop end-to-end against real
Docker, real claude inference, the real binding, and real `git fetch`
propagation. The dispatch container has no Docker socket, so drive this
from the host, not from inside the runner.

## Layout

```
multi-feature-drain/
├── README.md                          (this file)
├── multi-drain-alpha/
│   ├── PRD.md                         → .features/multi-drain-alpha/PRD.md
│   └── issues/01-stamp-marker.md      trivial AFK task — write MARKER-01.txt
└── multi-drain-beta/
    ├── PRD.md                         → .features/multi-drain-beta/PRD.md
    └── issues/01-stamp-marker.md      trivial AFK task — write MARKER-01.txt
```

Each issue tells `/implement` to write one marker under its feature's
`markers/` dir and commit. Both are `ready-for-agent + AFK` with no
blockers, so each has one eligible ref on the first iteration.

## Set up a workspace

Each scenario runs in its own throwaway **synthetic-consumer workspace** —
a fresh git repo that symlinks the host's live `framework/` and the
local-markdown binding, with both fixtures committed on their own branches.
The host repo is never modified (see [Notes](#notes)). Starting each
scenario fresh keeps them independent — no inter-scenario resets.

Paste this helper into your shell (run from the host repo root), then call
it at the top of each scenario:

```sh
mfd_workspace() {
  local ws fx slug
  mkdir -p .runner-state/smoke-work
  ws=$(mktemp -d "$(pwd)/.runner-state/smoke-work/run.XXXXXX")
  ln -s "$(pwd)/framework" "$ws/.formann"
  mkdir -p "$ws/docs/formann"
  ln -s ../../.formann/bindings/issue-tracker/local-markdown "$ws/docs/formann/issue-tracker"
  cp -RP .claude "$ws/.claude"
  printf '/.formann\n/docs/formann/issue-tracker\n/.claude\n/.runner-state/\n' > "$ws/.gitignore"
  git -C "$ws" init -q
  git -C "$ws" config user.email smoke@test; git -C "$ws" config user.name smoke
  git -C "$ws" symbolic-ref HEAD refs/heads/main
  git -C "$ws" add -A && git -C "$ws" commit -q -m "scaffold workspace"
  fx="$(pwd)/framework/runner/tests/fixtures/multi-feature-drain"
  # Commit each fixture on its own branch (the snapshot reads committed HEAD — see Notes).
  for slug in multi-drain-alpha multi-drain-beta; do
    git -C "$ws" checkout -q main
    git -C "$ws" checkout -q -b "$slug"
    mkdir -p "$ws/.features/$slug"
    cp "$fx/$slug/PRD.md" "$ws/.features/$slug/"; cp -R "$fx/$slug/issues" "$ws/.features/$slug/"
    git -C "$ws" add -A && git -C "$ws" commit -q -m "$slug: install fixture"
  done
  # Park on main with untracked copies so discovery (--list, working tree) sees both.
  git -C "$ws" checkout -q main
  for slug in multi-drain-alpha multi-drain-beta; do
    mkdir -p "$ws/.features/$slug"
    cp "$fx/$slug/PRD.md" "$ws/.features/$slug/"; cp -R "$fx/$slug/issues" "$ws/.features/$slug/"
  done
  echo "$ws"
}
```

Capture each scenario's command, exit code, trailing `stop reason:` line,
and the `SUMMARY.md` the runner prints, into the gitignored smoke artifact
(see `.claude/rules/runner-smoke-artifacts.md`).

## Scenarios

Scenarios are independent; run any subset. Each begins with a fresh
workspace.

### 1 — Bare invocation, host on `main`

Both features drain in one pass and fast-forward onto the host branches.

```sh
ws=$(mfd_workspace); cd "$ws"
bash .formann/runner/run-the-queue.sh
```

**Expected:** exit 0; `stop reason: completed`; both rows `done` with
`propagated → host`; both `refs/heads/multi-drain-*` advanced; HEAD still
`main`.

### 2 — Bare invocation, host on a feature branch

The runner is branch-state-agnostic. Both drain; `alpha` **parks** (HEAD is
on it, so the host fast-forward is refused), `beta` propagates.

```sh
ws=$(mfd_workspace); cd "$ws"
rm -rf .features/multi-drain-alpha    # drop the untracked copy before switching — see Notes
git checkout multi-drain-alpha
bash .formann/runner/run-the-queue.sh
```

**Expected:** exit 0; `stop reason: completed`; `alpha` →
`parked → runner/multi-drain-alpha` (host branch unchanged, parking ref
advanced); `beta` → `propagated → host`.

### 3 — `--feature multi-drain-alpha`, host on that branch

Targeted drain; `beta` is left untouched.

```sh
ws=$(mfd_workspace); cd "$ws"
rm -rf .features/multi-drain-alpha
git checkout multi-drain-alpha
bash .formann/runner/run-the-queue.sh --feature multi-drain-alpha
```

**Expected:** exit 0; `stop reason: queue-empty`; `alpha` →
`parked → runner/multi-drain-alpha`; `beta`'s branch tip unchanged.

### 4 — `--feature <unknown>`

Loud refusal.

```sh
ws=$(mfd_workspace); cd "$ws"
bash .formann/runner/run-the-queue.sh --feature multi-drain-nope
```

**Expected:** exit 2; stderr `runner: feature-restricted refused: feature
'multi-drain-nope' not in discovery output`; `stop reason:
feature-restricted (refused: unknown-feature)`.

## Teardown

```sh
cd /path/to/host-repo
rm -rf .runner-state/smoke-work                       # all scenario workspaces
docker volume rm runner-mvn-cache-multi-drain-alpha runner-mvn-cache-multi-drain-beta   # optional
```

The host repo and its active binding were never modified.

## Notes

**Why a workspace, not the host repo.** The runner discovers and dispatches
through the binding symlinked at `docs/formann/issue-tracker`. These
fixtures are local-markdown-shaped (`.features/<slug>/…`), but a real
consumer's active binding may be github-issues, which can't see
`.features/`. Rather than swap the host's binding and have to restore it
(fragile if a walk aborts), each scenario builds a disposable
local-markdown consumer that symlinks the host's live `framework/`.
Abort-safe by construction — `rm -rf` the workspace and there is nothing in
the host repo to undo.

**Workspaces must live under `$HOME`.** Docker Desktop on macOS only
bind-mounts paths under `$HOME` by default. Under `$TMPDIR`
(`/var/folders/…`) or `/tmp` the `.formann` mount comes up empty, every
framework skill dangles, and the dispatch fails with `Unknown command:
/implement`. `.runner-state/smoke-work/` sits under the host repo, so it
satisfies this.

**Fixtures must be committed on their branches.** The per-feature snapshot
extracts `.features/` from the runner-checkout's committed `HEAD`, not the
working tree. A working-tree-only fixture is listed by `--list` but fails
the snapshot. The untracked copies on `main` exist only so `--list`
discovers both slugs while HEAD is parked there.

**The `rm -rf` before `git checkout` (Scenarios 2–3).** The workspace
parks on `main` with both `.features/<slug>/` dirs untracked for discovery.
`git checkout multi-drain-alpha` would refuse — the branch tracks
`.features/multi-drain-alpha/`, which collides with the untracked copy. The
copy is a redundant discovery prop on the branch we're switching to, so
drop it first. (`beta`'s untracked copy stays, so discovery still sees it
while HEAD is on `alpha`.)

**Why fresh-per-scenario.** Once a feature drains, its work lives on the
parking ref `refs/remotes/runner/<slug>`, and the runner syncs the
runner-checkout to that ref when it is ahead of the host branch — so
re-running against an already-drained workspace reports `queue-empty`
unless you also clear the parking ref. Starting each scenario from a fresh
workspace sidesteps that entirely; no resets, no parking-ref surgery.

**No template-drop needed.** The fixture template tree lives under the
read-only `.formann` mount (`.formann/runner/tests/fixtures/…`), outside
the workspace's `.features/`, so `/implement` sees a single match per issue
— unlike an in-place setup where the committed template and the live
`.features/` copy both match.

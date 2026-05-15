# Multi-feature drain fixture

Operator-attended smoke fixture for the AFK runner's bare-invocation
**drain-all** mode. Two micro-features (`multi-drain-alpha` and
`multi-drain-beta`), each with one trivial AFK issue, set up so the bare
invocation has two side-by-side features to walk. Walks the operator through
five scenarios that together exercise the multi-feature outer loop end-to-end
against real Docker, the real binding, and real `git fetch`-based
propagation.

Sandboxed `/implement` cannot invoke Docker (no host docker socket inside
the runner container), so this smoke must be driven from the host repo by
the maintainer. The agent prepares fixture + runbook + smoke-artifact
skeleton at `.runner-state/smoke-runs/<date>-multi-feature-drain.md`; the
maintainer runs the scenarios and records observed outcomes back into
that artifact. The artifact is gitignored and ephemeral — once the issue
that owns the walk is `done`, the artifact may be deleted (the issue's
Verification comment carries the durable record).

## Layout

```
multi-feature-drain/
├── README.md                              (this file — the runbook)
├── multi-drain-alpha/
│   ├── PRD.md                             installs at .features/multi-drain-alpha/PRD.md
│   └── issues/
│       └── 01-stamp-marker.md             trivial AFK task — write MARKER-01.txt
└── multi-drain-beta/
    ├── PRD.md                             installs at .features/multi-drain-beta/PRD.md
    └── issues/
        └── 01-stamp-marker.md             trivial AFK task — write MARKER-01.txt
```

Each issue tells `/implement` to create a one-line marker file inside its
own feature dir (`.features/<slug>/markers/MARKER-01.txt`) and commit. Both
issues are `ready-for-agent + AFK` with no blockers, so each feature has one
eligible ref on the first iteration.

## Setup

Run this on host **before** the first scenario. Establishes both feature
branches with the fixture committed on each, then returns host to master
with the fixture dirs present in the working tree so discovery sees them.

Each feature branch installs only its own `.features/<feature>/` fixture and
**also drops the `tests/fixtures/multi-feature-drain/` template tree from
that branch.** Why the drop: when the feature branch is created off a
parent that already contains the fixture template (which it does, once
this slice has merged), the dispatched `/implement` sees two files
matching the issue path pattern — the template at
`framework/runner/tests/fixtures/multi-feature-drain/<feature>/issues/01-stamp-marker.md`
and the live issue at `.features/<feature>/issues/01-stamp-marker.md` — and
picks nondeterministically. Removing the template from the feature branch
leaves a single match.

```sh
# 0. Confirm starting state — host on master, working tree clean.
git status
git rev-parse --abbrev-ref HEAD   # → master

# 1. Branch 'multi-drain-alpha' off master with fixture A committed.
git checkout -b multi-drain-alpha master
mkdir -p .features/multi-drain-alpha
cp -R framework/runner/tests/fixtures/multi-feature-drain/multi-drain-alpha/PRD.md \
      .features/multi-drain-alpha/
cp -R framework/runner/tests/fixtures/multi-feature-drain/multi-drain-alpha/issues \
      .features/multi-drain-alpha/
# Drop the template tree so /implement matches one file, not two.
if [ -d framework/runner/tests/fixtures/multi-feature-drain ]; then
  git rm -r framework/runner/tests/fixtures/multi-feature-drain
fi
git add .features/multi-drain-alpha
git commit -m "multi-drain-alpha: install smoke fixture"

# 2. Branch 'multi-drain-beta' off master with fixture B committed.
git checkout -b multi-drain-beta master
mkdir -p .features/multi-drain-beta
cp -R framework/runner/tests/fixtures/multi-feature-drain/multi-drain-beta/PRD.md \
      .features/multi-drain-beta/
cp -R framework/runner/tests/fixtures/multi-feature-drain/multi-drain-beta/issues \
      .features/multi-drain-beta/
if [ -d framework/runner/tests/fixtures/multi-feature-drain ]; then
  git rm -r framework/runner/tests/fixtures/multi-feature-drain
fi
git add .features/multi-drain-beta
git commit -m "multi-drain-beta: install smoke fixture"

# 3. Return to master. Re-stage the fixture dirs in master's working tree
#    so 'tracker-snapshot --list' (which reads the host working tree)
#    discovers both features. They sit as untracked dirs on master —
#    do NOT commit them on master.
git checkout master
mkdir -p .features/multi-drain-alpha .features/multi-drain-beta
cp -R framework/runner/tests/fixtures/multi-feature-drain/multi-drain-alpha/PRD.md \
      framework/runner/tests/fixtures/multi-feature-drain/multi-drain-alpha/issues \
      .features/multi-drain-alpha/
cp -R framework/runner/tests/fixtures/multi-feature-drain/multi-drain-beta/PRD.md \
      framework/runner/tests/fixtures/multi-feature-drain/multi-drain-beta/issues \
      .features/multi-drain-beta/

# 4. Sanity-check the setup.
git rev-parse --abbrev-ref HEAD                              # → master
git rev-parse multi-drain-alpha multi-drain-beta             # → two distinct SHAs
bash framework/bindings/issue-tracker/local-markdown/tracker-snapshot --list # → JSON array containing both slugs
git ls-tree -r multi-drain-alpha -- framework/runner/tests/fixtures/multi-feature-drain   # → empty
git ls-tree -r multi-drain-beta  -- framework/runner/tests/fixtures/multi-feature-drain   # → empty
```

After step 4, the host repo holds:

- `master` (host HEAD, unchanged from your starting commit).
- `multi-drain-alpha` branch with `.features/multi-drain-alpha/` committed.
- `multi-drain-beta` branch with `.features/multi-drain-beta/` committed.
- Untracked `.features/multi-drain-alpha/` and `.features/multi-drain-beta/`
  in master's working tree (so discovery can list them).

## Scenarios

**Run the scenarios in order.** Scenarios 2 and 3 inherit host state from
the previous scenario: Scenario 2 reads `/tmp/smoke-alpha-before` written
during Scenario 1's preconditions, and Scenario 3 assumes host is checked
out on `multi-drain-alpha` from Scenario 2. Running them out of order (or
skipping ahead) leaves the runbook's preconditions unmet and the expected
outcomes will not reproduce.

For each scenario, capture:

1. The terminal command + exit code.
2. The trailing `stop reason:` line on stdout.
3. The contents of `<run-dir>/SUMMARY.md` (path printed by the runner).
4. The contents of `<run-dir>/discovery.json`.
5. `git -C <host> status` and the two feature branch tips before/after.

Paste each scenario's outputs into the matching section of the
gitignored skeleton at
`.runner-state/smoke-runs/<date>-multi-feature-drain.md`.

### Scenario 1 — Bare invocation, host on master

Both features drain in one pass.

```sh
# Pre-conditions: host on master; both feature branches exist; both
# .features/multi-drain-{alpha,beta}/ dirs present (untracked) in working tree.
git rev-parse multi-drain-alpha > /tmp/smoke-alpha-before
git rev-parse multi-drain-beta  > /tmp/smoke-beta-before

bash framework/runner/run-the-queue.sh
```

**Expected outcome:**

- Exit 0.
- Stop reason: `completed`.
- `discovery.json` is a JSON array containing both `multi-drain-alpha` and
  `multi-drain-beta` (alongside any other live `.features/` features).
- `SUMMARY.md` has a `# AFK runner — multi-feature drain` heading.
- Two per-feature sections in source order:
  - `## multi-drain-alpha — drained` followed by a per-issue table with one
    row: `multi-drain-alpha/01 | … | done`.
  - `## multi-drain-beta — drained` followed by a per-issue table with one
    row: `multi-drain-beta/01 | … | done`.
- Host's HEAD still on `master`; working tree shows no changes attributable
  to the runner (the untracked fixture dirs are unchanged).
- `git rev-parse multi-drain-alpha` differs from `/tmp/smoke-alpha-before`
  (branch advanced by one commit — the dispatch's marker + tracker commit).
- Same for `multi-drain-beta`.

### Scenario 2 — Bare invocation, host on `multi-drain-alpha`

The checked-out feature is skipped; the other still drains.

```sh
git checkout multi-drain-alpha
# Reset alpha to its pre-scenario-1 tip so we can verify it isn't touched.
git reset --hard "$(cat /tmp/smoke-alpha-before)"
git rev-parse multi-drain-alpha > /tmp/smoke-alpha-before-2

bash framework/runner/run-the-queue.sh
```

**Expected outcome:**

- Exit 0.
- Stop reason: `completed`.
- `SUMMARY.md` two sections:
  - `## multi-drain-alpha — skipped: branch-checked-out` (one-line section,
    no per-issue table).
  - `## multi-drain-beta — drained` with one per-issue row.
    - Note: if Scenario 1 already drained beta, its only issue is now
      `done` on the branch — discovery still lists beta, but the per-feature
      gate produces `skip: queue-empty` and the section is `## multi-drain-beta
      — skipped: queue-empty` instead. If you want to see beta drain again,
      reset its branch before this scenario:
      `git update-ref refs/heads/multi-drain-beta "$(cat /tmp/smoke-beta-before)"`.
- Host's HEAD still on `multi-drain-alpha`; working tree unchanged from
  before the run; `git rev-parse multi-drain-alpha` equals
  `/tmp/smoke-alpha-before-2` (branch ref untouched by the runner).

### Scenario 3 — `--feature multi-drain-alpha` while host is on `multi-drain-alpha`

Loud refusal, exit 2.

```sh
# Pre-condition: host still on multi-drain-alpha.
git rev-parse --abbrev-ref HEAD   # → multi-drain-alpha

bash framework/runner/run-the-queue.sh --feature multi-drain-alpha
```

**Expected outcome:**

- Exit 2.
- stderr contains: `runner: feature-restricted refused: feature
  'multi-drain-alpha' branch-checked-out`.
- `SUMMARY.md` stop reason: `feature-restricted (refused: branch-checked-out)`.
- Host's HEAD, working tree, and both feature branch refs unchanged.

### Scenario 4 — `--feature <unknown>`

Loud refusal, exit 2, with `unknown-feature`.

```sh
git checkout master   # park elsewhere so this scenario isn't entangled with #3
bash framework/runner/run-the-queue.sh --feature multi-drain-does-not-exist
```

**Expected outcome:**

- Exit 2.
- stderr contains: `runner: feature-restricted refused: feature
  'multi-drain-does-not-exist' not in discovery output`.
- `SUMMARY.md` stop reason: `feature-restricted (refused: unknown-feature)`.
- Host's HEAD on master; working tree unchanged.

### Scenario 5 — Cleanup

Removes the fixture from the host and reclaims the cache volumes.

```sh
# 1. Park on master.
git checkout master

# 2. Drop the two feature branches.
git branch -D multi-drain-alpha
git branch -D multi-drain-beta

# 3. Remove the working-tree fixture dirs (they were untracked on master).
rm -rf .features/multi-drain-alpha .features/multi-drain-beta

# 4. Reclaim the per-feature mvn cache volumes if they exist.
docker volume rm runner-mvn-cache-multi-drain-alpha 2>/dev/null || true
docker volume rm runner-mvn-cache-multi-drain-beta  2>/dev/null || true

# 5. Optional — remove the abort flag dirs if any dispatch wrote one.
rm -rf .runner-state/aborted/multi-drain-alpha .runner-state/aborted/multi-drain-beta

# 6. Sanity-check the teardown.
git status                                                   # → clean
git branch | grep -E 'multi-drain-(alpha|beta)' && echo BAD || echo OK   # → OK
ls .features | grep -E 'multi-drain-(alpha|beta)' && echo BAD || echo OK  # → OK
bash framework/bindings/issue-tracker/local-markdown/tracker-snapshot --list # → neither slug in output
```

**Expected outcome:**

- Host is back on master with a clean working tree.
- Neither `multi-drain-alpha` nor `multi-drain-beta` appears in
  `git branch` or `.features/`.
- `tracker-snapshot --list` no longer mentions either slug.
- Per-run dirs under `.runner-state/runs/` from the smoke remain (forensics;
  remove manually if desired).

## Capture

When all five scenarios have been run, fill in the gitignored skeleton
at `.runner-state/smoke-runs/<date>-multi-feature-drain.md` with the
captured outputs. Each scenario's "Observed" subsection should hold the
literal terminal output (exit code, stop-reason line, SUMMARY.md content,
discovery.json content, host-repo state). The "Verdict" line marks
expected-vs-observed. The artifact is read by the maintainer during
verification; once the owning issue is `done`, it may be deleted (the
issue's Verification comment carries the durable record).

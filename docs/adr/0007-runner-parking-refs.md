# Runner publishes to a parking ref; host fast-forward is best-effort

When the runner ships work for `<feature>`, it always publishes to a runner-owned parking ref (`refs/remotes/runner/<feature>`) in the host repo, then attempts to fast-forward the host's `refs/heads/<feature>`. If git refuses the fast-forward — because the host has the branch checked out (HEAD-on-target), or because the branch and the parking ref have diverged — the work lives in the parking ref and the maintainer reconciles with `git pull runner <feature>`. The `branch-checked-out` refusal is removed; the runner no longer cares what branch the maintainer has checked out.

## Why

The original runner refused to dispatch on a feature whose branch the maintainer had checked out, on the rationale that propagation would either disturb the working tree (HEAD-on-branch updates require `--update-head-ok`) or refuse as non-fast-forward (maintainer commits diverge from runner's chain). The refusal was operationally restrictive: a maintainer who wanted to work on the same feature the runner was draining had to switch branches first, defeating much of the value of fire-and-forget agent dispatch.

Treating the runner as a contributor — one that publishes to a known place — closes that gap without compromising the safety the original gate provided. The maintainer pulls when ready; the runner never mutates the host working tree; the only mutations on host are ref-level writes and a one-time `git config` entry.

## Decision A: Parking ref as the runner's authoritative chain

The runner's output for `<feature>` always lives in `refs/remotes/runner/<feature>`. Per-feature; advances linearly in the steady-state on-branch loop, and is force-updated when the maintainer pulls and rebases (the next dispatch's tip is no longer a descendant of the prior parking-ref tip, so a non-`+` refspec would refuse). Pre-dispatch sync uses the parking ref (when it exists and is at-or-ahead-of host's branch) as the runner-checkout's base, so subsequent dispatches build on prior runner output even when the maintainer hasn't pulled.

### Considered options

- **Direct fast-forward only, refuse when blocked** (status quo) — Rejected because it forces the maintainer off the branch the runner is working on, which is the pain point this ADR resolves.
- **Auto-rebase runner's chain onto maintainer's branch** — Rejected: the runner would silently rewrite shipped commits; if the rebase has conflicts, the runner has to either invent a resolution policy or fall back to an abort that is just a more complex version of the parking-ref approach.
- **Runner pushes through `origin`** — Rejected: requires expanding the sandbox's credential surface (today the sandbox has no host credentials), and forces runner work to be visible on the public remote regardless of whether that is desired.
- **Parking ref + best-effort host fast-forward** (chosen) — The maintainer's working copy is never touched; runner work is always reachable on a known ref; reconciliation uses standard git semantics at maintainer-chosen timing.

## Decision B: Origin remains the branch upstream

Although the runner registers itself as a git remote (`runner`) and publishes to `refs/remotes/runner/<feature>`, it does not change a branch's upstream config. To pull runner work the maintainer types `git pull runner <feature>` (not bare `git pull`).

### Considered options

- **Plain `git pull` finds runner work** (override upstream to `runner/<feature>`) — Rejected: any feature branch with an `origin/<feature>` (because the maintainer has pushed it for backup or visibility) would have its upstream silently redirected for the duration of runner work, making `git pull` and `git push` defaults point at the wrong place. The "branch cut off from origin" failure mode is more disruptive than the small UX cost of typing seven extra characters.
- **Hidden ref namespace** (`refs/runner/<feature>`, no remote) — Rejected: plain `git pull <name>` doesn't work without a configured remote, and a custom ref namespace is non-standard plumbing the maintainer has to learn.
- **Origin keeps upstream; explicit `git pull runner <feature>`** (chosen) — Origin defaults stay intact; runner work is opt-in pulled. A wrapper command (`formann pull` / `formann reconcile`) can layer on top later for convenience without changing the architecture.

## Decision C: Runner-remote registration is lazy

The `runner` remote is registered (`git remote add runner .runner-state/checkout`) on the runner's first invocation, not at installer time.

### Considered options

- **Installer adds the remote** — Rejected: the remote would point at a path (`.runner-state/checkout`) that does not exist until the first runner invocation, so `git remote -v` would show a broken-looking entry that a maintainer cleaning up unknown remotes might remove.
- **Manual setup documented in README** — Rejected: easy to forget; the first `git pull runner` would fail confusingly until done.
- **Lazy at first invocation** (chosen) — The remote appears exactly when it is usable, and the runner re-creates it on subsequent invocations if removed.

## Decision D: On-branch detection is implicit

The runner does not explicitly check whether the maintainer is on the target branch. It unconditionally attempts to fast-forward host's branch ref; git's own refusal (HEAD-on-target or non-fast-forward) is the trigger for the parking-ref-only fallback.

### Considered options

- **Explicit `git symbolic-ref` check before fast-forward attempt** — Rejected: duplicates git's built-in safety, adds a code path the test suite has to cover, and produces a second source of truth for the same condition.
- **Try fast-forward; classify failure** (chosen) — Single code path. The runner does not model "am I on-branch?" or "is the maintainer's branch divergent?" separately, because both produce the same outcome: parking ref carries the work, maintainer pulls.

## Consequences

- The runner's mutation surface on host is ref-level only: a write to `refs/remotes/runner/<feature>`, an optional successful write to `refs/heads/<feature>`, and (first invocation) a `git config` write to register the remote. No working-tree, index, or HEAD operations on host.
- `branch-checked-out` is removed from `evaluate_feature_gate`'s priority order. Drain mode no longer skips on-branch features; loop and single-dispatch modes no longer refuse them.

**Amendment (lazy branch creation from main):** The runner may additionally create `refs/heads/<feature>` on host from `refs/heads/main` when the slug's branch is missing at dispatch time — i.e., when both `refs/heads/<feature>` and `refs/remotes/runner/<feature>` are absent on host. The mutation is additive: no existing ref is overwritten and no working tree is touched, matching the same architectural posture as the existing parking-ref write. `branch-missing` is removed from `evaluate_feature_gate`'s priority order; drain, loop, and single-dispatch modes no longer refuse or skip a feature solely because its host branch doesn't yet exist. The source ref is hardcoded as `refs/heads/main`; dynamic default-branch detection is out of scope.
- Propagation halt as a failure mode collapses. When the host fast-forward refuses, that is now an expected outcome, not a halt. The existing abort-flag write for the propagation-halt case is removed (implement-classifier failures and gate-failed still write abort flags).
- Per-dispatch progress lines and end-of-run `SUMMARY.md` gain a per-feature "parked at `runner/<feature>`" indicator when the host fast-forward did not succeed. A returning maintainer sees a clear ledger of which features have work waiting.
- Maintainer-side reconciliation cost scales with the number of features where runner work and maintainer commits diverged. For fast-forward-able cases (parking ref strictly ahead of host's branch, no maintainer commits) the pull is trivial but still requires being on the branch. A future `formann reconcile` convenience can collapse the trivial cases into ref-level updates without branch switches; the architecture leaves this as a layer-on-top, not a built-in.
- `git remote -v` in a consumer with an active runner shows `runner   /…/.runner-state/checkout (fetch/push)`. The runner does not push to this remote (it only fetches into it from the runner-checkout side); git's standard listing shows the URL twice regardless.

**Amendment (stale-parking-ref sweep):** Once per runner invocation, immediately after pre-flight and before any tracker query or dispatch, the runner sweeps `refs/remotes/runner/*` on host. For each parking ref, it resolves the tip commit and runs `git for-each-ref --contains <tip>` (restricted to host's ref namespace). If any ref other than the parking ref itself and `refs/remotes/runner/HEAD` contains the tip, **and** the runner-checkout's `refs/heads/<slug>` tip (when the source branch is present) is similarly reachable from a host ref, git has proven both sides' work is preserved — the runner-checkout's source branch is deleted first, then the host parking ref. Source-first ordering closes a race where an interleaved `git fetch runner` would restore the host ref from the surviving source. If either side fails its reachability proof, both refs are kept; the slug self-cleans on the next successful propagate. If the source-side delete itself fails (lock contention, permissions), the host parking ref is also kept — proceeding alone would silently reintroduce the original cluttering bug on the next fetch. The safety invariant is: a ref is only deleted when git proves its tip is reachable from another host ref AND the deletion on the other side succeeded (or wasn't needed). `refs/remotes/runner/HEAD` (the symbolic ref git creates for the runner remote) is never a parking ref and is unconditionally skipped. A parking ref whose tip is unreadable (corrupt or missing object) is skipped with a warning logged to `runner.log`; the sweep continues to the next ref and exits 0. Each deletion produces a log line in `runner.log` naming the swept ref and the witnessing ref that proved reachability. When at least one parking ref was swept, a `## Swept parking refs` section listing the deleted refs is appended to `SUMMARY.md`. A subsequent dispatch on a slug whose parking ref was just swept proceeds normally — `ensure_runner_checkout_on_branch` sees an absent parking ref and syncs from the host branch tip, recreating the parking ref on the next successful propagation.
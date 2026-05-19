# Runner publishes to a parking ref; host fast-forward is best-effort

When the runner ships work for `<feature>`, it always publishes to a runner-owned parking ref (`refs/remotes/runner/<feature>`) in the host repo, then attempts to fast-forward the host's `refs/heads/<feature>`. If git refuses the fast-forward — because the host has the branch checked out (HEAD-on-target), or because the branch and the parking ref have diverged — the work lives in the parking ref and the maintainer reconciles with `git pull runner <feature>`. The `branch-checked-out` refusal is removed; the runner no longer cares what branch the maintainer has checked out.

## Why

The original runner refused to dispatch on a feature whose branch the maintainer had checked out, on the rationale that propagation would either disturb the working tree (HEAD-on-branch updates require `--update-head-ok`) or refuse as non-fast-forward (maintainer commits diverge from runner's chain). The refusal was operationally restrictive: a maintainer who wanted to work on the same feature the runner was draining had to switch branches first, defeating much of the value of fire-and-forget agent dispatch.

Treating the runner as a contributor — one that publishes to a known place — closes that gap without compromising the safety the original gate provided. The maintainer pulls when ready; the runner never mutates the host working tree; the only mutations on host are ref-level writes and a one-time `git config` entry.

## Decision A: Parking ref as the runner's authoritative chain

The runner's output for `<feature>` always lives in `refs/remotes/runner/<feature>`. Per-feature; advances linearly across dispatches. Pre-dispatch sync uses the parking ref (when it exists and is at-or-ahead-of host's branch) as the runner-checkout's base, so subsequent dispatches build on prior runner output even when the maintainer hasn't pulled.

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
- Propagation halt as a failure mode collapses. When the host fast-forward refuses, that is now an expected outcome, not a halt. The existing abort-flag write for the propagation-halt case is removed (implement-classifier failures and gate-failed still write abort flags).
- Per-dispatch progress lines and end-of-run `SUMMARY.md` gain a per-feature "parked at `runner/<feature>`" indicator when the host fast-forward did not succeed. A returning maintainer sees a clear ledger of which features have work waiting.
- Maintainer-side reconciliation cost scales with the number of features where runner work and maintainer commits diverged. For fast-forward-able cases (parking ref strictly ahead of host's branch, no maintainer commits) the pull is trivial but still requires being on the branch. A future `formann reconcile` convenience can collapse the trivial cases into ref-level updates without branch switches; the architecture leaves this as a layer-on-top, not a built-in.
- `git remote -v` in a consumer with an active runner shows `runner   /…/.runner-state/checkout (fetch/push)`. The runner does not push to this remote (it only fetches into it from the runner-checkout side); git's standard listing shows the URL twice regardless.
# AFK runner

Detailed architecture and process flow of the runner that drains a feature's `ready-for-agent + AFK` queue without maintainer keystrokes. This doc complements three other surfaces:

- [`lifecycle.md`](lifecycle.md) — high-level overview and where the runner fits in the pipeline.
- [`runner/README.md`](runner/README.md) — operator-facing reference (per-run output, sandbox primitives, OAuth setup, smoke test, verification recipes).
- `.scratch/afk-runner/PRD.md` (or `.scratch/done/afk-runner/PRD.md` once archived) — full design rationale, user stories, out-of-scope decisions, and the original module decomposition.

If you want to *use* the runner, start with the README. If you want to *understand* the runner, start here.

## Why the runner exists

The maintainer triages many issues as `ready-for-agent + AFK` — work that has been pre-authorized to run unattended. Advancing each one to `in-review` requires a manual `/implement` invocation, observation of the result, and dispatch of the next. The bottleneck is the maintainer's time at the keyboard for work that, by definition, doesn't need their judgment in the loop.

The runner replaces the keystroke. Given a feature, it sequentially drains the eligible queue, dispatching each issue inside an isolated sandbox container, classifying outcomes from a structured tracker delta, and propagating any commits the dispatch lands to the host repo. After a successful AFK implement, an independent **review-and-gate** dispatch decides whether to auto-accept to `done` or surface the findings for the maintainer's return.

## Where it fits in the lifecycle

The runner sits between **triage** (which sets `ready-for-agent + AFK`) and **verify** (the maintainer's `/triage <#> done`-or-rework decision):

```
…triage ─► ready-for-agent + AFK ─► [runner: implement + gate] ─► done | in-review (with findings)
```

It does not change the pipeline or the state machine. It only automates which keystroke moves an issue through a stretch of states the maintainer has already authorized.

The runner dispatches **eligible AFK refs only** — both loop and single-dispatch modes share that gate. Loop mode enforces it via the snapshot's `eligible` flag at selection time; single-dispatch (`--issue <ref>`) reads the same flag for the named ref before dispatching and refuses with exit 2 if the ref is HITL, has the wrong status, has unmet blockers, or is missing from the feature snapshot. HITL refs are not the runner's mandate — the maintainer's manual verify is the contract there, and `/implement <ref>` invoked locally lands the same `in-review` outcome without paying the sandbox/checkout overhead.

**On failure, the runner doesn't rewrite state — neither outcome takes the issue back to `ready-for-agent` automatically.** What happens to the issue depends on which stage failed:

- **Implement-stage FAIL** (classifier verdict or container error, no propagation halt) — two sub-cases:
  - **Logical bail** — `/implement` posted an explanation and flipped status to `needs-info`. The status change makes the issue ineligible on its own; no abort flag is needed. To resume, the maintainer revises the brief and runs `/triage <ref> ready-for-agent`.
  - **Technical failure** (container died before any commit) — status is still `ready-for-agent`, so the runner writes an abort flag to prevent re-dispatch.
- **Gate-failed** — `/implement` succeeded; the issue sits at `in-review` and is no longer eligible. The runner writes an abort flag for unified "what is the runner stuck on" visibility.
- **Propagation halt** — implement landed at least one commit but the host-side fast-forward refused. The dispatched commit is stranded in the runner-checkout; the runner writes an abort flag and the maintainer reconciles manually.

The failed `/implement` already posted its own comment; the runner adds nothing. The abort-flag mechanism — file location, format, and recovery recipe — is detailed under [Abort flags](#abort-flags) below.

## Binding portability

The runner is binding-portable by design. Porting to a different issue-tracker binding (GitHub Issues, Jira, …) is a binding-level change, not a runner-level rewrite.

Concretely, swapping the binding means:

- Rewriting `<binding>/tracker-snapshot` to read state from the new tracker.
- Expanding the binding doc with the new tracker's write conventions for skills (`/triage`, `/implement`, `/to-issues`, …) — same skill prose, different mechanical actions.

It does **not** mean:

- Rewriting `run-the-queue.sh`.
- Forking a parallel runner.
- Changing the dispatch loop, classifier, gate prompt, or the host-propagation step.

The runner's coupling to git is to **code transport**, not to the tracker. The host repo, the runner-checkout, and propagation are all about landing the dispatched container's code commits on the host's branch — universal across bindings, since code lives in git regardless of where tracker state lives.

Tracker reads go through `<binding>/tracker-snapshot`, which is binding-implementation-specific by contract (read files for local-markdown, query an API for GitHub Issues, etc.). Tracker writes happen inside the dispatched `claude` session, which follows the binding doc's prose conventions the same way `/triage` does outside the runner.

If a runner change appears to require special-casing one binding's tracker mechanics (e.g., assuming tracker mutations land as git commits in the runner-checkout), that's a coupling leak and should be refactored back behind the binding contract, not encoded into the runner.

## Architecture

### Runner script — `framework/runner/run-the-queue.sh`

The orchestrator. A bash script structured as:

1. **Argument parsing** — three modes:
   - **Drain mode** (bare invocation, no args) — walks every active feature in discovery order and drains the ones it's allowed to touch. The scheduled-job shape: park host on master, fire the runner, every authorized AFK queue advances.
   - **Loop mode** (`--feature <slug>`) — narrows to a single feature; refuses loudly on structural gate failures.
   - **Single-dispatch mode** (`--issue <feature>/<NN>`) — dispatches a single ref; refuses loudly on eligibility gate failures.
2. **Pre-flight** — fail-fast invariants (see below). The set differs by mode: drain mode defers runner-checkout sync and mvn-cache to the per-feature loop; narrowed modes materialise them up front.
3. **Outer drain loop** (drain mode only) — one iteration per feature: evaluate per-feature gate; if `drain`, run the per-issue loop scoped to that feature; if `skip:<reason>`, record a SUMMARY row and continue.
4. **Per-issue dispatch loop** — one iteration per issue inside a drained feature: snapshot, pick, implement, classify, propagate, (optionally) gate, classify again, propagate.
5. **EXIT trap** — writes `SUMMARY.md`, prints the end-of-run table, releases the pidfile lock.

Pure logic (`classify_outcome`, `next_eligible_ref`, `next_eligible_feature`, `classify_gate_outcome`, `evaluate_feature_gate`, formatters) is sourceable; `main` runs only when the script is executed directly. The `bats` suite under `runner/tests/` exercises that logic with synthetic inputs.

### Sandbox container

Each dispatch runs in a fresh container built from `framework/runner/Dockerfile`:

- Debian-slim base, JDK 21 (matching the project's pom), Maven, git, and the `claude` CLI installed via npm.
- Non-root user (UID/GID 1000), workdir `/repo`.
- Pass-through entrypoint that suppresses kernel core dumps (`ulimit -c 0`) so an in-container crash can't drop a `core` file into the bind-mounted runner-checkout.
- Permissions: `claude --dangerously-skip-permissions`. The blast radius is bounded by the container, not by per-tool allowlists.

The container mounts:

- **Runner-checkout** at `/repo` — a separate clone, not the host repo. The container has no access to the host's `.git/`.
- **Per-feature mvn cache** at `/home/runner/.m2` — Docker volume named `runner-mvn-cache-<slug>`.
- **OAuth token** as `CLAUDE_CODE_OAUTH_TOKEN` env var — retrieved once from Keychain during pre-flight, held in the runner shell's memory as a private variable for the rest of the run, and passed to each container via `docker run --env-file <(printf …)` (bash process substitution, a kernel pipe). Never written to disk on the host, logged, or echoed. This keeps the token out of `docker run`'s argv and `/proc/<pid>/cmdline`; the only residual exposure is the bash variable in the runner's own `/proc/<runner-pid>/environ`, bounded by the same Unix UID.

### Sandbox network — `framework/runner/setup-network.sh`

A custom Docker bridge (`afk-runner-sandbox`, bridge interface `afk-rnr-br0`, subnet `192.168.219.0/24`) with iptables rules that:

- **Allow** intra-bridge traffic (so containers can talk to each other).
- **Allow** public internet (Anthropic API, Maven Central, GitHub, javadoc).
- **Deny** RFC1918 destinations: `10.0.0.0/8`, `172.16.0.0/12`, `192.168.0.0/16`. The Pi, the LAN, corporate VPN ranges are unreachable.

Rules live in a dedicated chain (`AFK-RUNNER-SANDBOX-FW`) that `DOCKER-USER` jumps to for packets entering on the sandbox bridge. Idempotent — re-running `setup-network.sh` re-applies rules cleanly. They persist for as long as the Docker daemon's iptables state is intact (cleared by Docker Desktop restart; re-applied by the next pre-flight).

### Tracker-snapshot — the binding interface

The runner consumes the issue tracker through a single binding-supplied executable, reached via the role surface: `$HOST_REPO/docs/formann/issue-tracker/tracker-snapshot <feature-slug>`. It emits a JSON document on stdout:

```json
{
  "feature": "<slug>",
  "issues": [
    {
      "ref": "<feature>/NN",
      "status": "<frontmatter status>",
      "category": "<frontmatter category>",
      "type": "<frontmatter type>",
      "blocked_by": ["<feature>/NN", ...],
      "eligible": <bool>,
      "parse_error": "<short diagnostic>"
    }
  ]
}
```

`eligible` is `true` iff `status == "ready-for-agent"` **and** `type == "AFK"` **and** every blocker is an in-feature issue with `status == "done"`. Anything else (HITL, unmet blockers, cross-feature blockers the binding can't verify, malformed frontmatter) yields `eligible: false`.

`parse_error` is emitted only on issues whose frontmatter failed to parse — missing closing `---`, non-`key: value` lines, etc. The script does not exit non-zero just because one issue is malformed; the malformed entry appears in `issues[]` with `parse_error` set and `eligible: false` so the runner can see it and skip past it.

The runner uses snapshots for two purposes:

- **Selection** — at the start of each iteration the loop iterates the snapshot's `eligible: true` refs in source order and picks the first one that doesn't have an abort flag (see "Abort flags" below). Recomputed every iteration so an issue unblocked mid-run by an earlier success becomes selectable without restarting. The pure-logic `next_eligible_ref` helper exposes the "first eligible ref" half of this selection for the bats suite (`first(.issues[] | select(.eligible == true) | .ref)`); the runtime path uses the same `select(.eligible == true)` predicate but streams the matching refs (drops the `first(...)` wrapper) so it can iterate and skip flagged refs in turn.
- **Outcome classification** — pre-dispatch and post-dispatch snapshots feed the classifier (`classify_outcome` for implement, `classify_gate_outcome` for the gate). The two classifiers treat the dispatch exit code differently:
  - **Implement** — status delta is the source of truth; the exit code is captured to `<NN>.exit` for forensics but never reaches the classifier. `/implement` has no "non-zero on failure" contract and claude may exit 0 from a session that didn't ship, so the committed `tracker:` flip is the only trustworthy signal.
  - **Gate** — delta and exit code together drive the verdict. The gate prompt explicitly contracts "exit non-zero if you can't classify; don't commit a half-baked result", so a nonzero exit short-circuits to `gate-failed` regardless of the delta. A dirty runner-checkout after the gate also forces `gate-failed` (uncommitted gate edits make the delta untrustworthy). See the truth tables below.

Snapshots are taken against the runner-checkout's **HEAD** (i.e. committed state), not the working tree. Fast-forward propagation only lands committed history on the host, so an apparent status flip living only in the working tree (because `/implement` skipped its `tracker:` commit) would never reach the host. Reading from HEAD makes the classifier's verdict match what actually propagates.

The local-markdown binding's implementation is a shell script that globs `.scratch/<feature>/issues/*.md`, parses YAML frontmatter, and emits the JSON. A future binding (e.g., GitHub Issues) replaces this script; the contract is unchanged.

### Runner-checkout — `.runner-state/checkout/`

A separate `git clone` of the host repo (not a worktree, not a `--reference` clone). Reasons:

- The sandbox mounts only this checkout. The dispatched container — running with bypass permissions — has no path to the host's real `.git/`.
- A self-contained object store survives in-container `git repack`/`git gc` operations without corrupting alternates back to the host.
- Pre-flight syncs it to host's branch tip (`fetch origin <branch>` → `checkout -B <branch> origin/<branch>` → `reset --hard` → `clean -fd`) before each dispatch, so prior interrupted state can't leak forward.

After a successful dispatch, the runner advances host's branch ref from the runner-checkout via fetch-into-ref — no HEAD or working-tree side effects:

```sh
git -C <host-repo> fetch <runner-checkout> <branch>:<branch>
```

Propagation refuses in two cases:
- **Host is on the target branch** — `git fetch` would need `--update-head-ok` to update HEAD, and the working-tree conflict is unacceptable. Refused with a clear message; manual recovery: switch off the branch, then run the fetch command.
- **Non-fast-forward** — same safety guarantee as `merge --ff-only`; the runner never overwrites history.

If propagation refuses, the commit lives in the runner-checkout; the maintainer reconciles by hand.

**The recovery recipe has a deadline in loop mode.** A propagation halt is recorded as a failure, but the loop continues. The next iteration's `ensure_runner_checkout` runs `git checkout -B <branch> origin/<branch>` followed by `reset --hard` and `clean -fd`, which resets the runner-checkout's branch ref to origin's tip and orphans the parked commit from the branch. The commit still exists in the runner-checkout's object store (recoverable via `git -C .runner-state/checkout reflog show <branch>` until git GC runs), but `git fetch <runner-checkout> <branch>` no longer reaches it. To preserve a parked commit cleanly, Ctrl-C the runner before the next iteration starts. See "Failure handling and host propagation" for the longer story.

The runner never pushes to a remote.

### Per-feature mvn cache — `framework/runner/ensure-mvn-cache.sh`

Each feature gets its own Docker volume (`runner-mvn-cache-<slug>`) so a slow, dependency-heavy first build doesn't pay full price every dispatch. The volume is created on first use (and `chown -R 1000:1000` is applied so the non-root container can write it) and idempotent thereafter. It mounts at `/home/runner/.m2` inside the container.

### OAuth token — `framework/runner/retrieve-token.sh`

The dispatched `claude` CLI needs a long-lived OAuth token. The runner retrieves it from macOS Keychain (or libsecret/keyctl on Linux) via the vendored `retrieve-secret.sh`, captures it into a shell variable, passes it to `docker run --env-file <(printf 'CLAUDE_CODE_OAUTH_TOKEN=%s\n' "$TOKEN")` (bash process substitution — kernel pipe, no on-disk temp file), and never writes it anywhere else. This keeps the token out of `docker run`'s argv; the only residual exposure is the bash `$TOKEN` variable in the runner's own process environment (`/proc/<runner-pid>/environ`), readable only by the same UID for the dispatch window. Pre-flight aborts if retrieval fails.

One-time token setup (per OS) lives in [`runner/README.md`](runner/README.md#oauth-token).

## The outer drain loop

In drain mode (bare invocation), the runner sits an additional loop above the per-issue dispatch loop. The outer loop walks every feature returned by `tracker-snapshot --list` (the discovery output, persisted to `<run-dir>/discovery.json` for forensics) in source order and decides per feature whether to drain or skip:

1. **Top-of-iteration check** — Ctrl-C arrived? Stop with reason `interrupted`.
2. **Pick next feature** — `next_eligible_feature` returns the first discovery slug not yet considered in this run, or empty when discovery is exhausted.
3. **Per-feature gate** — `evaluate_feature_gate` is called with the full bundle of signals computed by side-effecting helpers below; it returns `drain` or `skip:<reason>` (priority order: `branch-checked-out` → `branch-missing` → `fetch-failed` → `feature-snapshot-failed` → `queue-empty` → `drain`). The loop short-circuits at the first signal that demands skipping — no point fetching when the branch doesn't exist:
   - **`skip:branch-checked-out`** — host's HEAD is on this feature's branch. The maintainer's parked-elsewhere convention prevents the runner from disturbing local work; the feature waits for the next run.
   - **`skip:branch-missing`** — discovery says the feature exists but host has no ref for it. Incomplete feature setup; runner does not invent a branch.
   - **`skip:fetch-failed`** — `ensure_runner_checkout_on_branch <feature>` failed to sync the runner-checkout to this feature's tip (git error, transient I/O, permissions). Recorded and run continues.
   - **`feature-snapshot-failed`** — `tracker-snapshot <slug>` exited non-zero or returned unparseable output for this feature. Distinct from the run-level `discovery-failed` (which catches the same issue at run start). One feature's snapshot crash does **not** abort the run — other features still drain.
   - **`skip:queue-empty`** — the feature snapshot has no eligible non-aborted AFK refs. Every snapshot's `eligible: true` ref carries an abort flag, or there are no eligible refs in the first place. The feature shows up in SUMMARY as "considered, nothing to do".
   - **`drain`** — proceeds to the per-issue dispatch loop (next section).
4. **mvn-cache (lazy)** — the per-feature Docker volume is created the moment a feature gates `drain`, not at run start. Features the runner skips don't materialise a cache volume.
5. **Per-issue dispatch** — the per-issue loop body runs against this feature, scoped to its branch in the runner-checkout. A snapshot crash mid-feature surfaces as the feature outcome `feature-snapshot-failed` and the outer loop continues; a propagation halt stops the outer loop (the parked commit is the maintainer's recovery surface; chaining more features would muddy the recovery story).
6. **Record feature outcome** — `drained`, `skipped: <reason>`, or `feature-snapshot-failed` is recorded for SUMMARY.md.
7. **Next iteration** — back to step 1.

Run-level stop reasons in drain mode:

- **`completed`** — every discovery slug considered. The bare-invocation analogue of single-feature mode's `queue-empty`.
- **`interrupted`** — Ctrl-C during the outer loop. The in-flight container received SIGTERM via the per-dispatch signal trap; the outer loop bails before the next feature.
- **`propagation-halt`** — a per-feature drain halted on propagation. Subsequent features are not drained — the parked commit must be reconciled before further work lands.
- **`discovery-failed`** — `tracker-snapshot --list` exited non-zero or returned unparseable JSON. Pre-flight invariant; the loop never starts.

Narrowed modes (`--feature`, `--issue`) use the stop-reason vocabulary enumerated in the "Narrowed modes" section below — they do not produce drain-mode reasons.

## The dispatch loop

One iteration, end to end:

1. **Top-of-iteration check** — Ctrl-C arrived during the previous dispatch? Exit immediately.
2. **Snapshot + select** — `tracker-snapshot <feature>` against the runner-checkout's HEAD. The loop iterates the snapshot's `eligible: true` refs in source order and picks the first one without an abort flag. If none remain, stop with reason `queue-empty`.
3. **Re-sync runner-checkout** — `fetch + checkout + reset --hard + clean -fd` to host's branch tip. `reset --hard` scrubs tracked changes; `clean -fd` removes untracked files and directories (e.g., kernel core dumps the container may drop into `/repo`, stray writes from a confused dispatch). Together they leave no residue from a prior failed dispatch.
4. **Implement dispatch** — capture the runner-checkout's HEAD, then run `claude -p "/implement <ref>" --dangerously-skip-permissions` in a fresh sandbox container. Output captured to `<run-dir>/<NN>.log`, exit code to `<NN>.exit`. Capture HEAD again afterwards.
5. **Classify implement** — pre/post snapshots feed `classify_outcome`. `success` requires status to flip from `ready-for-agent` to `in-review` or `done`.
6. **Propagate (any committed runner-checkout change)** — if the runner-checkout's HEAD advanced during the dispatch (it has commits ahead of host's branch tip), fast-forward the host's branch. The propagation gate is the commit delta, not the classifier verdict — a `/implement` bail commits an explanatory `tracker:` comment without flipping status and that comment must reach the host before the next iteration's reset wipes it. A genuine container-died-before-commit failure leaves HEAD unchanged and the runner skips propagation. Propagation halt is recorded as a failure regardless of the classifier verdict; iteration ends here. If the classifier verdict is `failure` (independent of whether propagation ran), iteration also ends here with `FAIL`.
7. **Gate decision** — every successful AFK implement proceeds to the review-and-gate dispatch. Both run modes refuse non-AFK refs before reaching this point (loop via the snapshot's `eligible` filter, single-dispatch via the same flag in `run_single`), so `dispatch_one` never sees a non-AFK ref.
8. **Review-and-gate dispatch** — `claude -p "<gate-prompt>\n<ref>" --dangerously-skip-permissions` in another fresh sandbox container. Output captured to `<NN>-review.log`.
9. **Classify gate** — pre/post snapshots and the dispatch exit code feed `classify_gate_outcome`. Verdict is `clean`, `blocked`, or `gate-failed`. A dirty runner-checkout after the gate forces `gate-failed` regardless of the snapshot delta — uncommitted edits can't be trusted.
10. **Propagate (if gate succeeded)** — fast-forward the host's branch again to land the gate's `tracker:` commit.

Per-issue failures don't stop the queue — they're logged, the runner moves to the next eligible issue. The failed `/implement` already posts its own comment on the issue; the runner adds nothing beyond the abort flag written on stuck failures (see "Failure handling" below).

## Implement dispatch

The implement dispatch is a regular `/implement` invocation, just spawned non-interactively inside the sandbox. It reads the issue, the agent brief, and the rest of the project context exactly as a maintainer-driven `/implement` would. On success it lands the work, the in-review summary comment, and a `tracker:` commit moving the issue to `in-review`.

The runner makes no assumptions about *how* the dispatch ships the work. It asks the binding via snapshot whether the status flipped — that's it.

## Review-and-gate dispatch

After a successful AFK implement, the runner spawns a second sandbox container running the gate prompt at `framework/runner/review-and-gate.md`. The prompt instructs `claude` to:

1. Read the issue file in full.
2. Spawn the `review-issue` agent (via the `Agent` tool) for an independent review of the just-shipped commits.
3. Classify the agent's findings by highest severity — anything at `🔴 Critical` (or equivalent) → `blocked`; `🟡 Important` or below or no findings → `clean`.
4. Comment with Review (AFK gate) on the issue, with the agent's findings verbatim (including its Verification summary) and the AI-generated disclaimer.
5. **On `clean` only**, set the state to `done`.
6. Commit a single `tracker: review <ref> → done|blocked` commit referencing the issue ref.
7. Emit the review-issue agent's output verbatim on stdout, followed by a `verdict: clean|blocked` line.

The runner classifies the gate's outcome from the snapshot delta and the dispatch exit code — it does not parse the verdict line. The verdict line exists for the human reading `<NN>-review.log` after the fact.

Why a separate dispatch (not a slash command, not part of `/implement`)? Independence. The same `claude` session that just shipped the work would have a strong continuity bias toward declaring it good. A fresh session, with no implementation context, reading only the committed state, exercises closer-to-cold-eyes judgment. The Docker isolation makes "fresh session" cheap.

## Outcome classification

Two pure functions in `run-the-queue.sh`. Both take JSON snapshots and return a string verdict.

### `classify_outcome` — implement stage

| Pre status         | Post status     | Verdict   |
| ------------------ | --------------- | --------- |
| `ready-for-agent`  | `in-review`     | `success` |
| `ready-for-agent`  | `done`          | `success` |
| `ready-for-agent`  | anything else   | `failure` |
| anything else      | (any)           | `failure` |

A missing entry in either snapshot counts as "anything else" — `failure`. The pre-status guard catches argument-order swaps and stale snapshots.

### `classify_gate_outcome` — gate stage

Inputs: pre-gate snapshot (post-implement state), post-gate snapshot, ref, gate dispatch exit code.

The function evaluates a sequence of guards and returns on the first match. Reading the table as guards-in-order rather than as pre×exit×post combinations matches the code at run-the-queue.sh:120-148 and is inherently complete:

| #  | Guard (evaluated in order)                          | Verdict       |
| -- | --------------------------------------------------- | ------------- |
| 1  | pre status ∉ {`in-review`, `done`}                  | `gate-failed` |
| 2  | exit code is nonzero                                 | `gate-failed` |
| 3  | post status == `done`                                | `clean`       |
| 4  | post status == `in-review`                           | `blocked`     |
| 5  | post status is anything else (incl. missing)         | `gate-failed` |

Pre status of `done` is admitted alongside `in-review` because `/implement` can legitimately land at either (a maintainer-adjusted brief may direct the dispatch straight to `done`); guards 2–5 do not differentiate which of the two pre states reached them.

`clean` and `blocked` both set `RUNNER_LAST_OUTCOME=success` — operational health is fine, the verdict is independent. `gate-failed` sets `RUNNER_LAST_OUTCOME=failure` and writes an abort flag.

### Combined per-iteration outcome

| Outcome       | Meaning                                                                                      |
| ------------- | -------------------------------------------------------------------------------------------- |
| `done`        | AFK iteration; gate found no Critical findings and flipped status to `done`.                |
| `blocked`     | AFK iteration; gate found ≥1 Critical; findings appended as a comment, status stays `in-review`. |
| `gate-failed` | AFK iteration; gate dispatch errored or off-mission. Runner writes an abort flag and continues.  |
| `FAIL`        | Implement-stage failure (classifier verdict, propagation halt, container error). Runner writes an abort flag where applicable and continues. |

## Pre-flight invariants

Fail-fast checks run before the loop starts. A failure prints `runner: <invariant>: <message>` and exits 2; the EXIT trap still writes a SUMMARY.md naming the invariant.

| # | Invariant          | Check                                                                                           |
| - | ------------------ | ----------------------------------------------------------------------------------------------- |
| 1 | `discovery`        | `tracker-snapshot --list` exits 0 and returns a parseable JSON array of feature slugs. Persisted to `<run-dir>/discovery.json` for forensics. |
| 2 | `runner-checkout`  | Runner-checkout exists or can be cloned, and is sync'd to the target branch tip. **Drain mode**: deferred to the per-feature loop. |
| 3 | `docker-daemon`    | `docker info` succeeds.                                                                         |
| 4 | `runner-image`     | The sandbox image exists or builds.                                                             |
| 4b | `gate-prompt`     | `review-and-gate.md` exists next to `run-the-queue.sh`.                                        |
| 5 | `mvn-cache`        | Per-feature Docker volume exists (created on first use). **Drain mode**: deferred to the per-feature loop — features the runner skips don't get a cache volume. |
| 6 | `sandbox-network`  | Custom Docker bridge + RFC1918-deny rules in place.                                            |
| 7 | `oauth-token`      | Keychain retrieval succeeds; the token is captured into a shell variable.                      |
| 8 | `no-other-runner`  | Pidfile lock at `.runner-state/lock` not held by a live process. Acquired first within `preflight()`, before invariants 1–7. |

The runner is independent of the host's current branch and working-tree state — no invariant inspects either. Feature validation (unknown slug, branch checked out) runs as a CLI-input gate between invariants 1 and 2 (`check_feature_eligibility`, **narrowed modes only**); on refusal the runner exits 2 with a `feature-restricted (refused: <reason>)` / `single-dispatch (refused: <reason>)` stop reason, not a `preflight-abort:`. The gate sits before `runner-checkout` so an unknown slug surfaces the AC-mandated refusal instead of an opaque `git fetch origin <slug>` failure.

Drain mode (bare invocation) skips `check_feature_eligibility`, `runner-checkout`, and `mvn-cache` at pre-flight: there's no single target feature to validate up front, and the runner-checkout / mvn-cache are scoped per-drained-feature inside the outer loop. The per-feature gate evaluator handles the analogous refusals at iteration time (`skip:branch-checked-out`, `skip:branch-missing`, `skip:fetch-failed`, etc.). The remaining global invariants (`discovery`, `docker-daemon`, `runner-image`, `gate-prompt`, `sandbox-network`, `oauth-token`, `no-other-runner`) still gate the whole run — they're infrastructure-level concerns, not feature-specific.

Per-run dir creation, log capture, and trap installation happen earlier in `main()` — before `preflight()` runs. A concurrent invocation therefore does mint a per-run dir before its lock acquisition fails, and that dir gets a `preflight-abort: no-other-runner` SUMMARY.md.

## Stop conditions

The runner stops on one of these run-level reasons. Pre-flight-phase stops and loop-phase stops differ because the signal trap is replaced once pre-flight succeeds (so a Ctrl-C during image build behaves differently from a Ctrl-C between dispatches).

### Drain mode (bare invocation)

- **`completed`** — every feature in discovery output considered (replaces single-feature's `queue-empty` at the run level). Normal drain. Exit 0.
- **`interrupted`** — Ctrl-C during the outer loop. The in-flight container, if any, receives SIGTERM; next feature is not started. Exit 0.
- **`propagation-halt`** — a per-feature drain halted on propagation. The outer loop stops so the parked commit is recoverable without further branches getting muddled. Exit 0.
- **`discovery-failed`** — `tracker-snapshot --list` exited non-zero or returned unparseable JSON. Surfaces as `preflight-abort: discovery` in the existing pre-flight stop family. Exit 2.

### Narrowed modes (`--feature`, `--issue`)

- **`queue-empty`** — no eligible, non-aborted ref remains at the top of an iteration. Normal completion (loop mode). Exit 0.
- **`interrupted`** — Ctrl-C during the dispatch loop. Exit 0.
- **`snapshot-failed`** — `tracker-snapshot` exited non-zero mid-loop (corrupt runner-checkout, jq missing, binding-implementation crash). Exit 1.
- **`propagation-halt`** — a fast-forward refused; the parked commit lives in the runner-checkout. Exit 0.

Single-dispatch mode (`--issue <ref>`) reports `single-dispatch (success|failure)`, or `single-dispatch (refused: <reason>)` when the named ref fails the eligibility gate (HITL type, wrong status, unmet blockers, missing from the feature snapshot, `unknown-feature`, `branch-checked-out`, or `snapshot-failed` if `tracker-snapshot` itself exited non-zero).

### All modes — pre-flight-phase stops

- **`interrupted-during-preflight`** — Ctrl-C during pre-flight (image build, mvn-cache init, network setup, token retrieval, runner-checkout sync). Handled by a separate trap (`handle_preflight_signal`) installed before `preflight` and replaced by the loop-phase trap once pre-flight succeeds. No dispatches ran; SUMMARY.md's table is empty.
- **`preflight-abort: <invariant>`** — a pre-flight invariant tripped before the loop began. SUMMARY.md replaces the per-issue table with a single line naming the failing invariant.

There is no wall-time cap, no daemon mode, no pause file. The runner is always invoked explicitly and runs to one of the conditions above.

## Per-run output

Every invocation that parses cleanly — including pre-flight aborts — creates `.runner-state/runs/<YYYYMMDD-HHMMSS>/`. Argparse rejects (missing flag values, unknown flags, malformed slugs) `exit 2` before the run dir is created, by design: a malformed invocation isn't a "run", and the stderr message is already self-explanatory.

| File              | Role                                                                                              |
| ----------------- | ------------------------------------------------------------------------------------------------- |
| `runner.log`      | Everything the runner emits to stdout/stderr (tee'd, terminal still gets the live stream).        |
| `discovery.json`  | The JSON array returned by `tracker-snapshot --list`. Written immediately after the `discovery` invariant passes; same lifecycle as `runner.log`. |
| `<NN>.log` (narrowed) / `<feature>/<NN>.log` (drain) | Full per-issue implement-dispatch output (stdout + stderr from the container). Drain mode uses a per-feature subdir so per-issue artifacts don't collide across features that share `<NN>`. |
| `<NN>.exit` / `<feature>/<NN>.exit` | Per-issue implement-dispatch exit code. Same flat / nested layout as the log file. |
| `<NN>-review.log` / `<feature>/<NN>-review.log` | Full per-issue review-and-gate dispatch output. Present for iterations that reached the gate stage; absent for implement-stage failures. |
| `SUMMARY.md`      | End-of-run Markdown summary. Narrowed modes: feature heading + flat per-issue table. Drain mode: `# AFK runner — multi-feature drain` heading + per-feature sections (`## <feature> — drained` with the same nested per-issue table, or `## <feature> — skipped: <reason>` / `## <feature> — feature-snapshot-failed` one-liner). |

Live stdout uses per-stage progress lines. A typical iteration produces four — implement starting/outcome and review starting/outcome:

```
[09:12:45] afk-runner/06 implement → starting
[09:13:27] afk-runner/06 implement → in-review (42s)
[09:13:27] afk-runner/06 review → starting
[09:13:31] afk-runner/06 review → clean → done (4s)
```

When propagation halts after a stage, the original outcome line is preserved (so `runner.log` retains the forensic story — the dispatch step itself succeeded; the halt was downstream) and a follow-up `halt → <recorded outcome>` line is emitted so the visible terminal record matches the SUMMARY.md row:

```
[09:13:27] afk-runner/06 implement → in-review (42s)
[09:13:28] afk-runner/06 implement → halt → FAIL (43s)
```

The end-of-run table prints one row per iteration with a single combined-outcome column, followed by a `stop reason: <reason>` line.

## Failure handling and host propagation

Per-issue failures log full output and continue. The failed `/implement` already posts its own comment on the issue describing what went wrong; the runner adds no additional comment. The next iteration re-snapshots and picks the next eligible issue.

### Abort flags

When a dispatch fails and the issue's status is still `ready-for-agent`, the next run (started by the maintainer after returning) would re-pick the same issue and fail again — without bound, across runs. The abort flag prevents that. Whenever a dispatch fails and the issue could be re-selected, the runner writes `.runner-state/aborted/<feature>/<NN>` (plain text, documented fields):

```
type: technical
dispatch: implement
at: 2026-05-07T14:23:11Z
exit: 137
log: .runner-state/runs/20260507-142133/03.log
```

The `dispatch` field is `implement` for implement-stage failures and `gate` for gate-stage failures. The flag is written in three cases:

1. **Implement classifier `failure` + post-status still eligible** — the genuine "stuck" case. The snapshot's `eligible: true` would re-pick it on the next iteration or next run. A logical bail where `/implement` flipped status to `needs-info` is already ineligible and does not trigger a flag — the status change itself prevents re-dispatch.
2. **Gate-failed (including dirty-checkout override)** — the issue is at `in-review` (non-eligible), so the snapshot filter already excludes it. The flag is still written as a unified "what is the runner stuck on" surface.
3. **Propagation halt** — always written, regardless of post-status, because the dispatched work is stranded in the runner-checkout.

**Exception — operator-initiated interrupts:** When the operator presses Ctrl-C or sends SIGTERM during an active dispatch, `RUNNER_INTERRUPTED` is set and no abort flag is written. The signal-handling path already records the iteration as failed and stops the loop with stop reason `interrupted` — that is the visible record the maintainer needs. No flag is written; the next run re-dispatches the issue normally.

On repeat failure, the flag is overwritten so it always reflects the most recent abort context.

**Eligibility selection skips flagged refs** — before dispatching, the loop iterates all eligible refs in snapshot order, skipping any with an existing abort flag and emitting a stdout line with the recovery recipe:

```
[09:23:11] runner: skipping aborted afk-runner/05 — rm .runner-state/aborted/afk-runner/05 to resume
```

When the snapshot has no non-aborted eligible refs, the runner stops with `queue-empty` — it doesn't spin.

**Recovery**: `rm .runner-state/aborted/<feature>/<NN>`. The ref reappears in the next eligibility selection. The maintainer typically reviews the abort flag (`cat <path>`) to find the dispatch log (`log:` field), reads what failed, revises the brief or fixes the environment, then removes the flag.

Host propagation is the moment of trust. The runner advances the host's branch ref via `git fetch <runner-checkout> <branch>:<branch>` — a pure ref update that doesn't touch HEAD, the index, or the working tree, so the maintainer's uncommitted work on any other branch is unaffected. Propagation halts in two cases: the host is currently on the target branch (updating the ref would dislocate HEAD), or the update isn't a fast-forward (the maintainer committed independently to the branch). On halt, the runner prints a recovery recipe; the dispatched commit lives in the runner-checkout and the maintainer reconciles manually. The runner never force-pushes, never pushes to a remote, never rewrites history.

**Propagation runs whenever the runner-checkout has committed work, regardless of the classifier's verdict.** That makes the host repo a faithful record of every dispatch's tracker output: successful `tracker: in-review` flips, and the bail comment + `needs-info` status flip that a `/implement` bail commits on its way out. A genuine technical failure (container died before any commit) leaves the runner-checkout at host's tip, so the propagation step is a no-op for it. The classifier's verdict determines whether the iteration is recorded as a success or a failure (driving abort-flag logic); only the propagation decision is independent of the verdict.

**Loop-mode caveat — the parked commit is fragile.** A halt is a per-iteration failure: the loop records it and proceeds. The next iteration's pre-dispatch `ensure_runner_checkout` resets the runner-checkout's branch ref to `origin/<branch>` and runs `git clean -fd`. The dispatched commit is no longer on the branch — it survives in the object store but the friendly `git fetch <runner-checkout> <branch>` recovery recipe won't find it. So in loop mode the printed recipe has a deadline: act before the next iteration's sync, or fall back to `git -C .runner-state/checkout reflog show <branch>` to find the orphan by sha (until git GC runs, typically weeks). For a single ad-hoc run where a halt is more likely, use Ctrl-C once the halt message appears so the runner-checkout stays frozen in the parked state.

## The trust boundary

Bypass mode (`--dangerously-skip-permissions`) is on, but only inside the container. The container has:

- **No access to host filesystem outside `/repo`** — only the runner-checkout is mounted, not the host repo, not `~/.ssh`, not `~/.gitconfig`, not `~/.m2` (project-specific cache instead).
- **No LAN access** — RFC1918-deny rules block the Pi, the home network, corporate VPN ranges. Public internet stays open.
- **No persistent state outside the mounted volumes** — token is per-container env var, not in any image layer.
- **No host docker socket** — the container can't spawn sibling containers or escape via Docker.

This is the operational meaning of `AFK` in the lifecycle vocabulary: the maintainer pre-authorized the work to run unsupervised, and the sandbox enforces what "unsupervised" can mean.

The trust boundary is the docker isolation, not per-tool allowlists. A curated allowlist would either be too narrow (legitimate `/implement` work blocked) or so broad that it stops adding safety. Bounding the blast radius at the container is simpler and stronger.

## Why bash, not a slash command

The runner's outer loop is deterministic state-machine work — eligible-issue selection, dispatch, outcome classification, repeat — that bash handles cleanly. LLM judgment is confined to `/implement` itself, dispatched per issue as a subprocess.

A slash-command wrapper would add a layer of indirection: an outer `claude` session sitting idle while inner sessions run. That's neither faster nor more capable, and it consumes a long-lived session whose cache wouldn't help (each inner dispatch has its own context anyway).

The runner *is* a slash command's worth of judgment about how to drive `/implement` repeatedly. Encoding that judgment in bash makes the looping shape explicit, the state observable, and the failure modes recoverable without LLM intervention.

## Where each piece lives

```
framework/
├── lifecycle.md                              ← high-level pipeline + state machine
├── afk-runner.md                             ← this doc
├── afk-runner-flow.md                        ← flowchart-style companion to this doc
├── bindings/
│   └── local-markdown/
│       ├── README.md                         ← binding doc + tracker-snapshot contract
│       ├── issue-tracker.md                  ← role doc (source of truth)
│       └── tracker-snapshot                  ← machine-readable interface
└── runner/
    ├── README.md                             ← operator-facing reference
    ├── NOTES.md                              ← provenance of vendored files
    ├── run-the-queue.sh                      ← orchestrator
    ├── lib.sh                                ← shared constants
    ├── Dockerfile + entrypoint.sh            ← sandbox image
    ├── build-image.sh                        ← idempotent image builder
    ├── setup-network.sh                      ← bridge + iptables policy
    ├── ensure-mvn-cache.sh                   ← per-feature volume helper
    ├── retrieve-secret.sh                    ← vendored Keychain reader
    ├── retrieve-token.sh                     ← OAuth token wrapper
    ├── review-and-gate.md                    ← gate dispatch prompt
    ├── demo-dispatch.sh + demo-fixture/      ← end-to-end shake-out
    └── tests/                                ← bats suite (pure logic) + smoke fixture

.runner-state/                                ← per-project, gitignored
├── lock                                      ← pidfile lock
├── checkout/                                 ← separate clone of the host repo
├── aborted/<feature>/                        ← runner-private abort flags (one per stuck issue)
├── runs/<ts>/                                ← per-run logs and SUMMARY.md
└── smoke-runs/                               ← ephemeral smoke-walk artifacts (see SMOKE-ARTIFACTS.md)
```

The framework lives in `framework/`. Per-project state lives in `.runner-state/` (gitignored). When the framework is eventually moved to a single per-machine instance outside any project, adopting projects will symlink into it; until then, `framework/` is in-tree and committable.

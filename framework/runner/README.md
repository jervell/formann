# AFK runner

Bash-driven runner that drains a feature's `ready-for-agent + AFK` queue by
dispatching `/implement` per issue inside a sandboxed Docker container.

`run-the-queue.sh` has three invocation forms:

- **Bare invocation** (`run-the-queue.sh`, no args) — **drain mode**. Walks every active feature returned by `tracker-snapshot --list` (the discovery output, persisted to `<run-dir>/discovery.json`) and drains the ones it's allowed to touch. Features skipped for per-feature reasons (`fetch-failed`, `feature-snapshot-failed`, `queue-empty`) produce a SUMMARY row and the run continues. This is the scheduled-job shape: fire the runner regardless of which branch you have checked out; every authorized AFK queue advances.
- **`--feature <slug>`** — **loop mode**. Narrows to one feature; refuses loudly on a structural gate failure (`unknown-feature`).
- **`--issue <feature>/<NN>`** — **single-dispatch mode**. Dispatches one ref; refuses loudly on eligibility gate failures.

Drain mode stops on: every feature considered (`completed`); Ctrl-C (`interrupted`); or `tracker-snapshot --list` itself failing (`preflight-abort: discovery`).

Narrowed modes stop on: queue empty; Ctrl-C (the in-flight container receives SIGTERM, then SIGKILL after `RUNNER_KILL_GRACE_SECONDS` if it lingers); or a mid-loop `tracker-snapshot` crash (`snapshot-failed`, exit 1). The full stop-reason vocabulary — including the pre-flight-phase stops — is enumerated below the per-issue table.

## Per-run output

Every invocation — including pre-flight aborts — creates a fresh run dir
at `.runner-state/runs/<YYYYMMDD-HHMMSS>/` containing:

| File | Role |
|------|------|
| `runner.log` | Everything the runner emits to stdout/stderr, captured via `tee` (terminal still receives the live stream). |
| `discovery.json` | The JSON array returned by `tracker-snapshot --list`. Written immediately after the `discovery` pre-flight invariant passes; same lifecycle as `runner.log`. Forensics for "why didn't the runner consider feature X?". |
| `<NN>.log` (narrowed) / `<feature>/<NN>.log` (drain) | Full per-issue implement-dispatch output (stdout + stderr from the container). Drain mode nests under a per-feature subdir so per-issue artifacts don't collide across features that share `<NN>`. |
| `<NN>.exit` / `<feature>/<NN>.exit` | Per-issue implement-dispatch exit code. |
| `<NN>-<step>-<label>.log` (narrowed) / `<feature>/<NN>-<step>-<label>.log` (drain) | Full per-step dispatch output for each post-implement walk step, e.g. `01-01-review.log` for the default single `review` step. One log per step that ran; absent when the implement stage failed and the walk never started. |
| `SUMMARY.md` | Markdown end-of-run summary. Narrowed modes: feature heading + flat per-issue table. Drain mode: `# AFK runner — multi-feature drain` heading + per-feature sections (`## <feature> — drained` with nested per-issue table, or `## <feature> — skipped: <reason>` / `## <feature> — feature-snapshot-failed` one-liner). Pre-flight aborts replace the table with a single line naming the failing invariant. |

Stdout while a run is in flight uses per-stage progress lines. A typical
iteration produces four (implement starting/outcome, review starting/outcome):

```
[09:12:45] afk-runner/06 implement → starting
[09:13:27] afk-runner/06 implement → in-review (42s)
[09:13:27] afk-runner/06 review → starting
[09:13:31] afk-runner/06 review → clean → done (4s)
```

When a parking-ref publish fails after a stage, the original outcome
line is preserved (the dispatch step itself succeeded; the failure is
downstream) and a follow-up `halt → <recorded outcome>` line is emitted
so the visible record matches the SUMMARY.md row:

```
[09:13:27] afk-runner/06 implement → in-review (42s)
[09:13:28] afk-runner/06 implement → halt → FAIL (43s)
```

The end-of-run table prints one row per iteration, with a single
combined-outcome column. The combined-outcome vocabulary is:

| Outcome | Meaning |
|---------|---------|
| `done` | Gate found no Critical findings; status flipped to `done`. |
| `left-for-human` | Post-implement walk exhausted with the issue still at `in-review` (e.g. the review step found ≥1 🔴 Critical and appended findings as a comment). No abort flag; the maintainer picks it up. |
| `gate-failed` | Gate dispatch errored or landed on an off-mission status. Runner writes a `type: technical` abort flag and continues. |
| `review-aborted` | Gate subprocess transport-crashed (empty log, API 5xx/429, network error) and exhausted its retries. Runner writes a `type: transport` abort flag and continues. |
| `dispatch-aborted` | Implement subprocess transport-crashed and exhausted its retries. Runner writes a `type: transport` abort flag and continues. |
| `in-review` | AFK iteration interrupted between implement-finish and the start of the post-implement walk: implement landed `in-review`, the interrupt pre-empted the first walk step, and the iteration is recorded at its implement outcome. |
| `FAIL` | Implement-stage failure (classifier verdict, container error, or parking-ref publish failure). Any `tracker:` work the dispatch did commit (notably the comment `/implement` posts on a bail) is still propagated to the host so it shows up on your branch when you return. |
| `halt → runaway` | A post-implement step drove the issue back to `ready-for-agent` (eligible) — a misconfigured manifest that would otherwise re-dispatch the same ref forever. The runner halts the entire run immediately. No abort flag (the issue is eligible, not stuck); the maintainer fixes the manifest. |

The trailing `stop reason:` line varies by mode.

**Drain mode (bare invocation):**

- `completed` — every feature in discovery output considered (the multi-feature analogue of single-feature mode's `queue-empty` at the run level).
- `interrupted` — Ctrl-C during the outer loop.
- `propagation-error` — parking-ref publish failed inside a feature loop; the entire drain halts (exit 1).
- `preflight-abort: discovery` — `tracker-snapshot --list` exited non-zero or returned unparseable JSON.

**Narrowed modes (`--feature`, `--issue`):**

- `queue-empty` / `interrupted` / `snapshot-failed` / `propagation-error` — the per-issue loop's stop reasons (see "The dispatch loop" in `afk-runner.md`).
- `feature-restricted (refused: <reason>)` (`--feature`) — `<reason>` is `unknown-feature` (slug not in discovery output).
- `single-dispatch (success|failure)` (`--issue`); or `single-dispatch (refused: <reason>)` — `<reason>` is one of: HITL type, wrong status, unmet blockers, `unknown-feature`, `snapshot-failed`.

**All modes — pre-flight-phase:**

- `interrupted-during-preflight` — Ctrl-C arrived before the loop started.
- `preflight-abort: <invariant>` — a pre-flight invariant tripped before the loop began.

## Transport-class retry

When a dispatch container exits with a transport-class failure (API 5xx or 429, network error, or an empty log with no model output), the runner retries the dispatch automatically before recording an abort flag.

**Default schedule** (overridable via env vars):

| Attempt | Wait before next attempt |
|---------|--------------------------|
| 1 → 2   | 30 s                     |
| 2 → 3   | 90 s                     |
| 3 → 4   | 240 s                    |
| (max 4 attempts total) | —          |

The wait is a 1-second poll loop so `Ctrl-C` / `SIGTERM` exits immediately rather than blocking until the sleep expires.

**Defensive guard:** if the runner-checkout's `HEAD` advances between attempts (a prior attempt committed partial work), retries are suppressed and the original failure is propagated. The intent is to avoid double-applying work. The check inspects the runner-checkout under `.runner-state/checkout/`, not the host repo.

**Per-attempt logs:** each failed attempt's log is preserved as `<log>.attempt-<N>` alongside the primary log file, so the maintainer can inspect what each attempt produced.

**Escape hatch:**

```sh
RUNNER_DISABLE_TRANSPORT_RETRY=1 ./run-the-queue.sh ...
```

Set `RUNNER_DISABLE_TRANSPORT_RETRY=1` to skip the retry layer entirely (useful when debugging or when the upstream API quota issue is known to be persistent).

**Knobs:**

| Variable | Default | Meaning |
|----------|---------|---------|
| `RUNNER_TRANSPORT_RETRY_MAX_ATTEMPTS` | `4` | Maximum total attempts (including the first) |
| `RUNNER_TRANSPORT_RETRY_BACKOFFS` | `"30 90 240"` | Space-separated list of wait seconds for attempts 1→2, 2→3, 3→4, … |
| `RUNNER_DISABLE_TRANSPORT_RETRY` | `0` | Set to `1` to bypass all retry logic |

## Resuming after a technical failure

When a dispatch fails and the issue could otherwise be re-picked (implement failure with the issue still eligible, or gate failure), the runner writes a plain-text abort flag at `.runner-state/aborted/<feature>/<NN>`. Eligibility selection skips flagged refs on every subsequent run, preventing infinite re-dispatch across restarts.

The flag's first line identifies the failure class:

```
type: technical   # model error, bad brief, or other non-transport cause
type: transport   # transport-class crash: API 5xx/429, network error, or empty log
```

A `type: transport` flag means the subprocess never produced model output — the failure is infrastructure, not a problem with the brief or implementation. A `type: technical` flag means the subprocess ran and produced output indicating a genuine failure. Sample flag with the full layout:

```
type: transport
dispatch: review
at: 2026-05-16T19:58:37Z
exit: 1
log: .runner-state/runs/20260516-195837/f/01-review.log
```

The `dispatch` field carries the manifest item's label (e.g. `review` for the default single-entry manifest). An interrupted dispatch (Ctrl-C or SIGTERM during an active implement or item run) does not write an abort flag — the maintainer's intent is to stop, not to mark the issue as stuck. The next run re-dispatches the issue normally without any `rm` recipe required.

Single-dispatch (`--issue <ref>`) shares the same eligibility gate as loop mode but reacts differently when the named ref fails it: instead of silently skipping (loop mode's response — the ref isn't in the eligible set, so it never gets picked), single-dispatch exits 2 with `single-dispatch (refused: <reason>)` and prints a stderr diagnostic naming the cause (HITL, wrong status, unmet blockers, missing from snapshot, or `snapshot-failed` if `tracker-snapshot` itself crashed). No container runs and no abort flag is written — the maintainer corrects the invocation (target an eligible AFK ref, or re-triage the named one) and re-runs.

To inspect what is stuck:

```sh
# List all aborted issues for the current feature
ls .runner-state/aborted/<feature>/

# Read an abort flag (dispatch, timestamp, exit code, log path)
cat .runner-state/aborted/<feature>/<NN>

# Follow up on the dispatch log named in the flag
cat .runner-state/runs/<ts>/<NN>.log
```

To resume (re-include the ref in eligibility selection):

```sh
rm .runner-state/aborted/<feature>/<NN>
```

After removal, the next `run-the-queue.sh` invocation will see the ref as eligible again. Typical workflow: read the abort flag to find the log, diagnose the failure (wrong brief, expired token, infra issue), fix the underlying cause, then `rm` the flag and restart the runner.

## Review-and-gate dispatch (AFK)

After a successful AFK `/implement` shipping, the runner spawns a
second sandbox container that runs an independent review of the just-
shipped commits. The gate prompt — at `review-and-gate.md`, sibling to
this README — instructs the dispatched claude session to:

1. Read the issue file.
2. Spawn the `review-issue` agent for an independent review.
3. Classify by 🔴 Critical findings — clean if none, blocked otherwise.
4. Comment with Review (AFK gate) on the issue, with the findings verbatim.
5. On a clean verdict only, set the state to `done`.
6. Land a single `tracker:` commit and emit a `verdict:` line on stdout.

The runner classifies the step's outcome from the snapshot delta and the
dispatch exit code (`classify_item_action` in `run-the-queue.sh`, called
per walk step by `walk_post_implement_steps`) — it does not parse the
verdict line. A terminal status (`done`) and an issue left at `in-review`
both return 0 from `dispatch_one` (operational health is fine; the
verdict is independent); a failed step returns 1 and writes an abort flag.

## Sandbox primitives

| File | Role |
|------|------|
| `Dockerfile` | **Consumer-owned** (lives at `<consumer>/runner/Dockerfile`, not in the framework — see ADR-0002). The installer scaffolds an initial Debian-slim image with JDK 21, Maven, git, the `claude` CLI, a non-root user (UID/GID 1000), workdir `/repo`, and an inlined entrypoint that suppresses kernel core dumps (`ulimit -c 0`). The consumer edits it for their project. |
| `build-image.sh` | Builds the consumer's image idempotently from `<consumer>/runner/Dockerfile`. Walks `$PWD` upward to find the consumer root (`.formann` ancestor), so it works from anywhere inside the consumer repo. Reuses the cached image. `--rebuild` forces a build that still reuses the layer cache (cheap; picks up Dockerfile edits but keeps installed tools at their cached versions). `--fresh` forces a build with no layer cache and a base-image re-pull, so every tool — apt packages, the JDK, Node, and the Claude CLI — re-resolves to its current published version. Prints the image name on stdout. |
| `setup-network.sh` | Creates the sandbox bridge network and applies the RFC1918-deny outbound policy. Idempotent. Prints the network name on stdout. |
| `retrieve-secret.sh` | Verbatim vendor of `arne/claude-code-api-key-setup`'s generic Keychain/libsecret/keyctl reader. Provenance in `NOTES.md`. |
| `retrieve-token.sh` | Wraps `retrieve-secret.sh` with the OAuth-token service/account constants from `lib.sh`. Prints the token on stdout, fails fast with a populate-the-Keychain hint on stderr. Token never echoed beyond stdout. |
| `ensure-mvn-cache.sh` | Per-feature mvn cache helper. Creates `runner-mvn-cache-<slug>` on first use (and chowns it to uid 1000 so the non-root container can write); idempotent on re-invocation. Prints the volume name on stdout. |
| `demo-dispatch.sh` | End-to-end demonstration of the slice-03 surface: retrieve token, ensure cache, `docker run` with `claude -p "echo hi"`, then two `mvn install` runs against `demo-fixture/` to demonstrate cache reuse. Per-run logs at `/tmp/afk-runner-demo-<ts>/`. |
| `demo-fixture/` | Tiny Maven project (single class + JUnit Jupiter test) used by `demo-dispatch.sh` to make first-vs-second timing meaningful. |
| `lib.sh` | Shared constants (image, network, bridge, subnet, iptables chain, OAuth keychain coords, mvn-cache prefix, container `~/.m2` path). Source of truth for the names below. |
| `NOTES.md` | Provenance of vendored files (currently `retrieve-secret.sh`). Re-vendor instructions live there. |
| `tests/` | `bats` suite covering `tracker-snapshot` (including `--list`), the runner's pure-logic functions (`classify_outcome`, `next_eligible_ref`, `next_eligible_feature`, `classify_item_action`, `walk_post_implement_steps`, `propagate_feature`, `format_multi_feature_summary_md`), the outer drain loop (`run_drain`, `drain_one_feature`), and `run_loop` mechanics (drain / interrupt / abort-flag skipping / feature-gate refusals) with mocked dispatch. Real-Docker exercising is the job of slice 08's smoke test. |
| `tests/fixtures/synthetic-drain/` | Two-issue micro-feature template the maintainer installs into `.features/synthetic-drain/` for the loop's live demo. Reused by slice 08. See its README for the runbook. |

## Stable Docker asset names

Both the image and the bridge network use the same human-readable name —
they live in different Docker namespaces, so no collision. The Linux bridge
interface name is shorter to fit `IFNAMSIZ` (15 chars). All values live in
`lib.sh`.

| Asset | Name |
|-------|------|
| Image | `afk-runner-sandbox` |
| Docker network | `afk-runner-sandbox` |
| Linux bridge interface | `afk-rnr-br0` |
| Bridge subnet | `192.168.219.0/24` |
| iptables chain | `AFK-RUNNER-SANDBOX-FW` |

## Network policy

The bridge gives sandboxed containers public-internet access while denying
outbound traffic to private (RFC1918) destinations:

- `10.0.0.0/8` — corporate / VPN ranges.
- `172.16.0.0/12` — common LAN range, also Docker's default bridge subnets.
- `192.168.0.0/16` — common home LAN range.

Implementation: `setup-network.sh` creates the bridge, then runs a
privileged sidecar (`alpine` with `iptables`) on the Docker host network
namespace to install rules in a dedicated chain that `DOCKER-USER` jumps to
for packets arriving on `afk-rnr-br0`. Intra-bridge traffic (the bridge's
own subnet) is allowed before the deny rules so containers can still talk
to each other.

The rules persist for as long as the Docker daemon's iptables state is
intact. After a Docker Desktop restart they are cleared; re-running
`setup-network.sh` re-applies them.

## OAuth token

The runner needs a long-lived Claude Code OAuth token to dispatch
`/implement` inside the sandbox. The token lives in macOS Keychain (or
libsecret/keyctl on Linux); `retrieve-token.sh` reads it at dispatch
time into a shell variable that is passed to `docker run --env-file
<(printf 'CLAUDE_CODE_OAUTH_TOKEN=%s\n' "$TOKEN")` — a bash process
substitution (kernel pipe, no on-disk file) — and never written anywhere
else. This keeps the token out of `docker run`'s argv and
`/proc/<pid>/cmdline`. The only residual exposure is the `$TOKEN` bash
variable in the runner's own process environment, readable as
`/proc/<runner-pid>/environ` by the same Unix UID for the duration of a
dispatch.

One-time setup:

```sh
claude setup-token   # follow the URL; copy the printed long-lived token
```

Then store the printed token under service `claude-code-oauth`, account
`anthropic`, in whichever backend your OS uses:

```sh
# macOS Keychain (paste the token at the prompt; add -U to overwrite)
security add-generic-password -s claude-code-oauth -a anthropic -w

# Linux — libsecret (GNOME Keyring, KWallet, …)
secret-tool store --label=claude-code-oauth service claude-code-oauth account anthropic

# Linux — kernel keyring (fallback when libsecret isn't available)
keyctl padd user claude_code_oauth_anthropic @s   # type/paste the token, then Ctrl-D
```

The service/account live in `lib.sh` as
`RUNNER_OAUTH_KEYCHAIN_SERVICE` / `RUNNER_OAUTH_KEYCHAIN_ACCOUNT`. The
token is valid for ~1 year; rotate by re-running `claude setup-token`
and overwriting the entry (e.g. `security ... -U` on macOS, re-run
`secret-tool store` or `keyctl padd` on Linux).

## Per-feature mvn cache

Each feature gets its own Docker volume (`runner-mvn-cache-<slug>`) so a
slow, dependency-heavy first build doesn't pay full price every
dispatch. `ensure-mvn-cache.sh <slug>` creates the volume on first use
(initialising ownership for the non-root `runner` user) and is
idempotent thereafter; the volume mounts at
`$RUNNER_CONTAINER_M2_PATH` (`/home/runner/.m2`) inside the container.

## Verification recipe

The runner script in slice 04 invokes these helpers automatically. To
verify them by hand:

```sh
# Build (or rebuild) the image. Run from anywhere inside the consumer repo;
# the script locates the consumer root via the .formann indirection symlink.
.formann/runner/build-image.sh
# .formann/runner/build-image.sh --rebuild   # rebuild, reusing the layer cache
# .formann/runner/build-image.sh --fresh     # rebuild from scratch; re-resolves
#                                             # every tool (incl. the Claude CLI)
#                                             # to its current published version

# Create the sandbox network and apply the deny-RFC1918 policy.
.formann/runner/setup-network.sh

# Sanity-check the image:
docker run --rm afk-runner-sandbox id          # uid=1000(runner) ...
docker run --rm afk-runner-sandbox mvn --version
docker run --rm afk-runner-sandbox claude --version

# Sanity-check the network policy:
docker run --rm --network afk-runner-sandbox afk-runner-sandbox \
  curl -sSf -m 10 -o /dev/null https://repo.maven.apache.org && echo PUBLIC_OK
docker run --rm --network afk-runner-sandbox afk-runner-sandbox \
  curl -sS -m 5 -o /dev/null http://10.0.0.1 && echo LEAK || echo BLOCKED

# End-to-end shake-out (token + cache + claude + mvn timings + leakage scan):
framework/runner/demo-dispatch.sh --clean
```

## Token argv leakage probe

To verify that the OAuth token is absent from all process arguments while a
dispatch is in flight, run this probe in a second terminal during an active
dispatch:

```sh
# Probe: token must NOT appear in any process argv on the host.
# Run while a dispatch is in flight (the docker run is running in another terminal).
ps -eo pid,args | grep CLAUDE_CODE_OAUTH_TOKEN | grep -v grep && echo "LEAK DETECTED" || echo "argv clean"
```

Expected result: `argv clean` — the token value is delivered to the container
via a kernel pipe (process substitution), not via `docker run`'s command-line
arguments.

On Linux you can also confirm via `/proc`:

```sh
# Check every process's cmdline for the token string (requires same UID).
for f in /proc/*/cmdline; do
  tr '\0' ' ' < "$f" 2>/dev/null
done | grep -F CLAUDE_CODE_OAUTH_TOKEN && echo "LEAK" || echo "argv clean"
```

## Smoke test

The `bats` suite under `tests/` covers pure-logic surfaces with mocked
dispatch. To exercise the *real* path — image, network policy, token
passing, dispatch container, classifier, fast-forward — there's a
guarded end-to-end smoke test that drains a synthetic single-issue
micro-feature in a throwaway workspace.

Slow (~1–2 min) and expensive, so opt in via the `RUNNER_SMOKE` env
var. Default `bats` invocations skip it.

```sh
# Default — pure-logic suite only (smoke test reports as 'skipped'):
bats framework/runner/tests/

# Opt-in — runs the smoke test too:
RUNNER_SMOKE=1 bats framework/runner/tests/smoke.bats
```

Run it manually before milestones — anytime something the unit suite
can't see might have drifted:

- Consumer Dockerfile changes (`<consumer>/runner/Dockerfile`, scaffolded by the installer; edited per consumer).
- `setup-network.sh` changes (RFC1918 deny list, bridge config).
- Bumps to the bundled `claude` CLI (`@anthropic-ai/claude-code` in
  the Dockerfile).
- Token-passing or Keychain changes (`retrieve-secret.sh`,
  `retrieve-token.sh`).
- Pre-flight or dispatch loop changes in `run-the-queue.sh`.
- `tracker-snapshot` contract changes (binding-doc revisions or
  fixture migrations).

Pre-requisites: Docker Desktop running, the OAuth token populated in
Keychain (see "OAuth token" above). Fixture lives at
`tests/fixtures/smoke/` with a manual-reproduction recipe in its
README. Per-feature mvn cache is `runner-mvn-cache-smoke` (persists
across smoke runs; remove with `docker volume rm runner-mvn-cache-smoke`).

## Captured smoke runs

Operator-attended walks against fixtures under `tests/fixtures/` that
cannot run inside the AFK runner's dispatch container (no
Docker-in-Docker) leave intermediate per-walk artifacts under
`.runner-state/smoke-runs/` (gitignored, ephemeral). The durable record
of what was walked and observed lives in the issue's Implementation /
Verification comments; the artifact is scratch the verifier reads during
the walk.

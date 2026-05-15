# AFK runner — flow diagram

A factual flow of `run-the-queue.sh` from inputs through process steps and decision points to outputs. Companion to [`afk-runner.md`](afk-runner.md) (architecture narrative) and [`runner/README.md`](runner/README.md) (operator reference). For *why* each step is shaped as it is, read the narrative; this doc records *what* the script does, in evaluation order.

Conventions:

- `[bracketed]` text marks a decision point.
- Plain text is a process step.
- `─►` and `▼` are "next step" / "verdict edge".
- File paths are relative to the host repo root unless noted.

## Inputs

| Source                                       | What it provides                                                                                            |
| -------------------------------------------- | ----------------------------------------------------------------------------------------------------------- |
| CLI arguments                                | Three modes — **bare invocation** (drain every active feature), `--feature <slug>` (narrow to one feature), `--issue <ref>` (single-dispatch). |
| Host repo                                    | Host's HEAD and working tree are not consulted — runner is independent of local state. `tracker-snapshot --list` returns the slugs to consider; per-feature gates handle the rest at iteration time. |
| Keychain                                     | OAuth token at service `claude-code-oauth`, account `anthropic` (macOS Keychain / libsecret / keyctl).      |
| Docker daemon                                | Image `afk-runner-sandbox`, network `afk-runner-sandbox` (with RFC1918-deny rules), volume `runner-mvn-cache-<feature>` (created lazily per drained feature). |
| `.runner-state/checkout/`                    | Separate clone of the host repo. Created on first run; **branch-switched** per drained feature inside the outer loop (drain mode) or sync'd once up front (narrowed modes). |
| `$HOST_REPO/docs/formann/issue-tracker/tracker-snapshot` | Binding-supplied executable, reached via the role surface. `--list` returns active feature slugs (drain mode discovery); `<slug>` returns per-issue JSON with computed `eligible` flag. |
| `framework/runner/review-and-gate.md`          | Prompt for the post-implement gate dispatch.                                                                |

## Top-level flow

```
                main()
                  │
                  ▼
              parse_args
                  │
                  ▼
        [args parse cleanly?] ──no──► exit 2  (no run dir created — by design)
                  │ yes
                  ▼
            resolve_host_repo
                  │
                  ▼
             setup_run_dir              ─► creates .runner-state/runs/<YYYYMMDD-HHMMSS>/
                  │
                  ▼
       start_runner_log_capture          ─► tee → runner.log (live + persisted)
                  │
                  ▼
       trap finalize_run        on EXIT
       trap handle_preflight_signal on INT/TERM
                  │
                  ▼
                preflight                (9 invariants — see below;
                                          narrowed modes also run the
                                          `check_feature_eligibility`
                                          CLI-input gate)
                  │
        ┌─────────┼──────────────┐
        │         │              │
        │   [Ctrl-C during       │
        │   preflight?]          │
        │         │              │
        │        yes             │
        │         ▼              │
        │  RUN_STOP_REASON =     │
        │  "interrupted-during-  │
        │   preflight"           │
        │  exit 130              │
        │                        │
        │             [invariant fails?]
        │                        │
        │                       yes
        │                        ▼
        │                fail_invariant
        │                  exit 2
        │                  (RUN_PREFLIGHT_INVARIANT set)
        │
        │ all invariants pass
        ▼
   trap handle_signal on INT/TERM         (replaces preflight signal trap)
                  │
                  ▼
              [RUN_MODE?]
        ┌──────────────┼──────────────┐
        ▼              ▼              ▼
    run_single      run_loop      run_drain
   (one dispatch)  (one feature) (every active feature)
        │              │              │
        └──────────────┼──────────────┘
                  ▼
            finalize_run
                  │
                  ▼
                 exit (rc)
```

## Pre-flight invariants

Rows in evaluation order. `no-other-runner` runs first (lock acquisition gates everything else); the rest run in numeric order with `4b` immediately after `4`. Drain mode (bare invocation) defers `runner-checkout` and `mvn-cache` into the outer loop — those are per-feature concerns when more than one feature might drain.

| # | Name                       | Check                                                                                              | Drain mode? |
| - | -------------------------- | -------------------------------------------------------------------------------------------------- | ----------- |
| 8 | `no-other-runner`          | `.runner-state/lock` not held by a live process. (`acquire_lock` runs first.)                      | global      |
| 1 | `discovery`                | `tracker-snapshot --list` exits 0 and returns a parseable JSON array. Persisted to `<run-dir>/discovery.json`. | global |
| 2 | `runner-checkout`          | `.runner-state/checkout/` exists or clones; sync'd to the target branch tip.                       | per-feature (lazy) |
| 3 | `docker-daemon`            | `docker info` succeeds.                                                                            | global      |
| 4 | `runner-image`             | `afk-runner-sandbox` exists (else built from `Dockerfile`).                                        | global      |
| 4b | `gate-prompt`             | `framework/runner/review-and-gate.md` is present.                                                    | global      |
| 5 | `mvn-cache`                | Volume `runner-mvn-cache-<feature>` exists or is created and chowned `1000:1000`.                  | per-feature (lazy) |
| 6 | `sandbox-network`          | `afk-runner-sandbox` bridge + iptables RFC1918-deny rules in place.                                | global      |
| 7 | `oauth-token`              | Keychain returns a non-empty token; held in `TOKEN` for the rest of the run.                       | global      |

The runner is independent of host's HEAD and working tree: no invariant inspects either. Feature validation (unknown slug, branch checked out) in narrowed modes runs through `check_feature_eligibility`, a CLI-input gate that sits between invariants 1 and 2. It is **not** an invariant: on refusal it returns 2 with a `feature-restricted` / `single-dispatch (refused: <reason>)` stop reason — not `fail_invariant`, not `preflight-abort:`. Drain mode skips this gate entirely; per-feature eligibility is decided inside the outer loop by `evaluate_feature_gate`.

Global invariant failure → `fail_invariant` → `exit 2`. The EXIT trap (`finalize_run`) then writes a SUMMARY.md whose body names the failing invariant. Per-feature lazy failures (drain mode) record a `skip:<reason>` row in SUMMARY.md and the run continues.

## Outer drain loop (`run_drain`, bare invocation)

Wraps the per-issue loop and walks every feature in the discovery output.

```
┌─ next feature ────────────────────────────────────────────────────────────┐
│                                                                           │
│   [RUNNER_INTERRUPTED?] ──yes──► RUN_STOP_REASON = "interrupted"; stop    │
│         │ no                                                              │
│         ▼                                                                 │
│   feature = next_eligible_feature(DISCOVERY_JSON, considered, "")         │
│         │                                                                 │
│   [feature empty?] ──yes──► RUN_STOP_REASON = "completed"; stop           │
│         │ no                                                              │
│         ▼                                                                 │
│   host_branch = git symbolic-ref --short HEAD (on host)                   │
│   branch_exists = git show-ref refs/heads/$feature (yes/no)               │
│   verdict = evaluate_feature_gate(slug, host_branch,                      │
│                                   branch_exists, ok, nonempty, ok)        │
│         │                                                                 │
│   [verdict ∈ {skip:branch-checked-out, skip:branch-missing}?]             │
│         │ yes ──► record_feature_outcome; next feature                    │
│         │ no                                                              │
│         ▼                                                                 │
│   ensure_runner_checkout_on_branch(feature)                               │
│         │                                                                 │
│   [fetch failed?] ──yes──► record skip:fetch-failed; next feature         │
│         │ no                                                              │
│         ▼                                                                 │
│   snap = take_snapshot(feature)                                           │
│         │                                                                 │
│   [snap failed?] ──yes──► record feature-snapshot-failed; next feature    │
│         │ no                                                              │
│         ▼                                                                 │
│   [≥1 eligible non-aborted ref in snap?]                                  │
│         │ no  ──► record skip:queue-empty; next feature                   │
│         │ yes                                                             │
│         ▼                                                                 │
│   ensure_mvn_cache_for(feature)   (lazy — only here, not in preflight)    │
│         │                                                                 │
│   [mvn-cache failed?] ──yes──► record skip:fetch-failed; next feature     │
│         │ no                                                              │
│         ▼                                                                 │
│   run_loop                       (per-issue loop, scoped to this          │
│         │                         feature; sets RUNNER_HALT_OCCURRED on   │
│         │                         propagation halt; sets inner            │
│         │                         RUN_STOP_REASON = "snapshot-failed" on  │
│         │                         a mid-feature crash, "fetch-failed" on  │
│         │                         a per-iteration runner-checkout sync    │
│         │                         failure)                                │
│         ▼                                                                 │
│   record_feature_outcome — once, keyed off inner RUN_STOP_REASON:         │
│     "snapshot-failed" → feature-snapshot-failed                           │
│     "fetch-failed"    → skip:fetch-failed                                 │
│     anything else     → drained                                           │
│         │                                                                 │
│         ▼                                                                 │
│   [RUNNER_INTERRUPTED?] ──yes──► RUN_STOP_REASON = "interrupted"; stop    │
│         │ no                                                              │
│         ▼                                                                 │
│   [RUNNER_HALT_OCCURRED?] ──yes──► RUN_STOP_REASON = "propagation-halt";  │
│         │ no                       stop                                   │
│         └────────► next feature                                           │
│                                                                           │
└───────────────────────────────────────────────────────────────────────────┘
```

`discovery.json` is written immediately after the `discovery` invariant passes (in `check_discovery`), so the file exists for every run that gets past pre-flight — not just successful drains.

## Loop iteration (`run_loop`)

```
┌─ next iteration ─────────────────────────────────────────────────────────┐
│                                                                          │
│   [RUNNER_INTERRUPTED?] ──yes──► RUN_STOP_REASON = "interrupted"; stop   │
│         │ no                                                             │
│         ▼                                                                │
│   snap = take_snapshot(feature)        (against runner-checkout HEAD)    │
│         │                                                                │
│   [snapshot rc != 0?] ──yes──► RUN_STOP_REASON = "snapshot-failed"; stop │
│         │ no                                                             │
│         ▼                                                                │
│   Select first eligible ref not flagged as aborted:                      │
│     for each ref where eligible=true (source order):                     │
│       [.runner-state/aborted/<feature>/<NN> exists?]                     │
│         │ yes → log "skipping aborted <ref> — rm <path> to resume"       │
│         │       continue to next eligible ref                            │
│         │ no  → ref = this ref; break                                    │
│     [ref still empty after all eligible refs checked?]                   │
│         │ yes ──► RUN_STOP_REASON = "queue-empty"; stop                  │
│         │ no                                                             │
│         ▼                                                                │
│   ensure_runner_checkout                (re-sync to host tip;            │
│         │                                fetch + checkout + reset --hard │
│         │                                + clean -fd; HEAD must match)   │
│         ▼                                                                │
│   dispatch_one(ref)  ───► see "dispatch_one" below                       │
│         │  (sets RUNNER_LAST_OUTCOME, returns 0/1)                       │
│         ▼                                                                │
│   [RUNNER_INTERRUPTED?] ──yes──► RUN_STOP_REASON = "interrupted"; stop   │
│         │ no                                                             │
│         └────────► next iteration                                        │
│                                                                          │
└──────────────────────────────────────────────────────────────────────────┘
```

Abort flags persist across runs (files on disk). The eligibility skip log line includes the `rm` recipe so the maintainer sees the recovery gesture without consulting any doc.

## `dispatch_one` (per issue)

### Implement stage

```
   pre = take_snapshot(feature)
   pre_head = git rev-parse HEAD (runner-checkout)
        │
        ▼
   run_dispatch_container("/implement <ref>")        ─► writes <NN>.log, <NN>.exit
        │
        ▼
   post_head = git rev-parse HEAD (runner-checkout)
   post_impl = take_snapshot(feature)
        │
        ▼
   v_impl = classify_outcome(pre, post_impl, ref)
   (3 args — exit code is NOT consulted; status delta is the verdict)
   has_commits = (pre_head != post_head)
        │
        ▼
   [has_commits?]
   ┌──────┴───────┐
  no             yes
   │              │
   │              ▼
   │         propagate_to_host    (runner fetches from the runner-checkout
   │              │                into the host repo and ff-merges; no push)
   │          [ff ok?]
   │          ┌───┴────┐
   │         no       yes
   │          │        │
   │          ▼        │
   │    write_abort_flag(implement)   (propagation halt — always write)
   │       record FAIL │
   │       ret 1       │
   │                   │
   └─────────┬─────────┘
             ▼
          [v_impl?]
       ┌─────┴───────────────────────┐
     failure                       success
       │                             │
       ▼                             ▼
   [post_impl eligible?]     (continue to gate stage)
   ┌──────┴──────┐
  yes           no
   │             │
   ▼             │
write_abort_flag │    (stuck: would be re-picked without flag)
 (implement)     │
   │             │
   └──────┬──────┘
          ▼
       record FAIL
       ret 1
```

The runner dispatches eligible AFK refs only — both loop mode (snapshot
`eligible` filter at selection) and single-dispatch (`run_single`'s
fresh-snapshot read for the named ref) refuse non-AFK or otherwise
ineligible refs before reaching `dispatch_one`. The post-implement
success path therefore proceeds straight to the gate stage.

The `has_commits` gate makes propagation reachable from the non-success
branch: a `/implement` bail commits an explanatory `tracker:` comment
without flipping status (classifier verdict = `failure`), and that
comment must reach the host before the next iteration's
`ensure_runner_checkout` resets the runner-checkout. A genuine
container-died-before-commit failure leaves `pre_head == post_head`,
so the propagation branch is a no-op for it.

### Gate stage

```
   [RUNNER_INTERRUPTED?]
        │
   ┌────┴────┐
  yes       no
   │         │
   ▼         │
 record      │
 (in-review  │
  or done)   │
 success     │
 return 0    │
             ▼
   run_gate_container(prompt + ref)              ─► writes <NN>-review.log
             │
             ▼
   gate_dirty = `git status --porcelain` of runner-checkout
             │
             ▼
   post_gate = take_snapshot(feature)
             │
             ▼
   v_gate = classify_gate_outcome(post_impl, post_gate, ref, gate_rc)
   (4 args — both the snapshot delta AND the exit code are primary)
             │
             ▼
   [gate_dirty non-empty?] ──yes──► v_gate := "gate-failed"   (override)
             │
             ▼
        [v_gate?]
   ┌─────────┼───────────┐
   │         │           │
 gate-     clean        blocked
 failed      │           │
   │         └─────┬─────┘
   │               │
   ▼               ▼
 write_abort_  propagate_to_host  (runner fetches from the runner-checkout
 flag(gate)        │                into the host repo and ff-merges the gate
 record            │                commit forward; no push)
 gate-failed   [ff ok?]
 ret 1        ┌────┴─────┐
             no         yes
              │          │
              ▼          ▼
        write_abort_  record (done if v_gate=clean, else blocked)
        flag(gate)    RUNNER_LAST_OUTCOME = success
        record        return 0
        gate-failed
        ret 1
```

### Per-iteration verdict reference

| Path                                                                          | Recorded outcome | `RUNNER_LAST_OUTCOME` | `dispatch_one` rc | Abort flag written? |
| ----------------------------------------------------------------------------- | ---------------- | --------------------- | ----------------- | ------------------- |
| Implement classifier `failure`, no committed change                           | `FAIL`           | `failure`             | 1                 | yes (`implement`)   |
| Implement classifier `failure` with committed change, propagate ok, post eligible | `FAIL`       | `failure`             | 1                 | yes (`implement`)   |
| Implement classifier `failure` with committed change, propagate ok, post non-eligible | `FAIL`   | `failure`             | 1                 | no                  |
| Implement classifier `failure` with committed change, propagate halts         | `FAIL`           | `failure`             | 1                 | yes (`implement`)   |
| Implement classifier `success`, propagate halts                               | `FAIL`           | `failure`             | 1                 | yes (`implement`)   |
| Gate classifier `gate-failed` (or dirty-checkout override)                    | `gate-failed`    | `failure`             | 1                 | yes (`gate`)        |
| Gate `clean`/`blocked`, propagate halts                                       | `gate-failed`    | `failure`             | 1                 | yes (`gate`)        |
| Gate `clean`, propagate ok                                                    | `done`           | `success`             | 0                 | no                  |
| Gate `blocked`, propagate ok                                                  | `blocked`        | `success`             | 0                 | no                  |

The "no committed change" row writes the implement abort flag unconditionally because, in code, the write is gated on `post_eligible == "true"` — and with no commits the post-snapshot reads HEAD (unchanged), so post-status equals pre-status (`ready-for-agent`) and `post_eligible` is necessarily `true`. The "post non-eligible" branch is reachable only when a commit *did* land (e.g., `/implement` bailed to `needs-info`), which is captured by the dedicated row above.

## Outputs

### Files written under `.runner-state/runs/<YYYYMMDD-HHMMSS>/`

| File              | When                                                                      | Content                                                       |
| ----------------- | ------------------------------------------------------------------------- | ------------------------------------------------------------- |
| `runner.log`      | Always (created at run start, finalized at exit by `tee` drain).          | Full runner stdout + stderr.                                  |
| `discovery.json`  | Always for runs that pass the `discovery` pre-flight invariant.            | Pretty-printed JSON array returned by `tracker-snapshot --list`. |
| `<NN>.log` (narrowed) / `<feature>/<NN>.log` (drain) | Per implement dispatch. | Container stdout + stderr from `claude -p "/implement <ref>"`. Drain mode nests under a feature subdir so per-issue artifacts don't collide across features. |
| `<NN>.exit` / `<feature>/<NN>.exit` | Per implement dispatch. | Container exit code (forensics only — classifier ignores it). |
| `<NN>-review.log` / `<feature>/<NN>-review.log` | Per gate dispatch (iterations that reached the gate stage). | Container stdout + stderr from gate dispatch. |
| `SUMMARY.md`      | Always (written by `finalize_run` from EXIT trap).                         | Narrowed modes: feature heading + flat per-issue table. Drain mode: per-feature sections (`## <feature> — drained` with nested table, or `## <feature> — skipped: <reason>` / `## <feature> — feature-snapshot-failed` one-liner). Pre-flight aborts replace the table with a single line naming the invariant. |

### Files written under `.runner-state/aborted/<feature>/`

| File    | When                                                                                     | Content                                                                       |
| ------- | ---------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------- |
| `<NN>`  | On any failure that leaves the ref stuck or stranded (see "Abort flags" in afk-runner.md). | Plain-text abort flag: `type`, `dispatch`, `at`, `exit`, `log` fields. Overwritten on repeat failure. Removed by the maintainer to re-include the ref. |

### Stop reasons (in `SUMMARY.md` and the final terminal line)

**Drain mode (bare invocation):**

- `completed` *(every discovery slug considered)*
- `interrupted` *(outer-loop Ctrl-C)*
- `propagation-halt` *(per-feature drain halted; outer loop stops)*
- `preflight-abort: discovery` *(`tracker-snapshot --list` exited non-zero or unparseable)*

**Narrowed modes (`--feature`, `--issue`):**

- `queue-empty`
- `interrupted` *(loop-phase Ctrl-C)*
- `snapshot-failed` *(`tracker-snapshot` crashed mid-loop; exit 1)*
- `propagation-halt`
- `feature-restricted (refused: unknown-feature | branch-checked-out)` *(--feature mode)*
- `single-dispatch (success)` / `single-dispatch (failure)` / `single-dispatch (refused: <reason>)` *(--issue mode; refusal reasons: `HITL`, `wrong-status`, `blockers-unmet`, `missing`, `unknown-feature`, `branch-checked-out`, `snapshot-failed`)*

**All modes — pre-flight-phase:**

- `interrupted-during-preflight` *(pre-flight-phase Ctrl-C)*
- `preflight-abort: <invariant>`

### Exit codes

| Code | Meaning                                                                               |
| ---- | ------------------------------------------------------------------------------------- |
| 0    | Loop drained / interrupted; or single-dispatch success.                               |
| 1    | Single-dispatch failure (classifier verdict, propagation halt, container error); or loop aborted by `snapshot-failed`. |
| 2    | Pre-flight invariant failed; argparse rejected the invocation before any run dir was created; or single-dispatch refused the named ref (eligibility gate). |
| 130  | Ctrl-C arrived during pre-flight (`handle_preflight_signal` calls `exit 130`).        |

### Side effects (success path only)

- Host repo's target branch fast-forwarded with `/implement` and gate `tracker:` commits — observable via `git log` on the host.
- Issue tracker state advanced in committed history (issue files updated; visible to the next `tracker-snapshot`).
- Per-feature mvn cache populated/updated for the next run.
- Pidfile `.runner-state/lock` released by `finalize_run`.

The runner never pushes to a remote.

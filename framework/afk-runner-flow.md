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
| CLI arguments                                | Three modes — **bare invocation** (drain every active feature), `--feature <slug>` (narrow to one feature), `--issue <ref>` (single-dispatch). Optional `--model <id>` overrides the model for every dispatch in the run. |
| Host repo                                    | Host's HEAD and working tree are not consulted — runner is independent of local state. `tracker-snapshot --list` returns the slugs to consider; per-feature gates handle the rest at iteration time. |
| Keychain                                     | OAuth token at service `claude-code-oauth`, account `anthropic` (macOS Keychain / libsecret / keyctl).      |
| Docker daemon                                | Image `afk-runner-sandbox`, network `afk-runner-sandbox` (with RFC1918-deny rules), volume `runner-mvn-cache-<feature>` (created lazily per drained feature). |
| `.runner-state/checkout/`                    | Separate clone of the host repo. Created on first run; **branch-switched** per drained feature inside the outer loop (drain mode) or sync'd once up front (narrowed modes). |
| `$HOST_REPO/docs/formann/issue-tracker/tracker-snapshot` | Binding-supplied executable, reached via the role surface. `--list` returns active feature slugs (drain mode discovery); `<slug>` returns per-issue JSON with computed `eligible` flag. |
| `framework/runner/steps/review-and-gate.md`    | Prompt for the default post-implement step (review-and-gate); the `steps/` dir also ships the `review.md` / `gate.md` / `fix.md` / `find-and-fix.md` building-block step prompts for custom manifests. |

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
                preflight                (10 invariants — see below;
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

Rows in evaluation order. `no-other-runner` runs first (lock acquisition gates everything else); the rest run in numeric order, with `1b` after `1` and `4b` immediately after `4`. Drain mode (bare invocation) defers two per-feature concerns into the outer loop: `runner-checkout` *branch-sync* (2b) and `mvn-cache` (5). Everything else — including the `runner-checkout` *clone-existence* check (2a) — is global and runs before the mode split.

| # | Name                       | Check                                                                                              | Drain mode? |
| - | -------------------------- | -------------------------------------------------------------------------------------------------- | ----------- |
| 8 | `no-other-runner`          | `.runner-state/lock` not held by a live process. (`acquire_lock` runs first.)                      | global      |
| 1 | `discovery`                | `tracker-snapshot --list` exits 0 and returns a parseable JSON array. Persisted to `<run-dir>/discovery.json`. | global |
| 1b | `runner-remote`           | `runner` git remote on the host repo is absent (added → `HOST_CHECKOUT`) or already matches it; a conflicting URL fails. Mutates only host `.git/config`. | global |
| 2a | `runner-checkout`         | `.runner-state/checkout/` exists, else cloned from the host repo. Clone-existence only — no branch-switching. | global |
| 2b | `runner-checkout`         | Runner-checkout sync'd to the target branch's tip on host.                                          | per-feature (lazy) |
| 3 | `docker-daemon`            | `docker info` succeeds.                                                                            | global      |
| 4 | `runner-image`             | `afk-runner-sandbox` exists (else built from `Dockerfile`).                                        | global      |
| 4b | `manifest`                | `runner/manifest.md` (Consumer-owned) exists and `resolve_manifest` validates every entry.           | global      |
| 5 | `mvn-cache`                | Volume `runner-mvn-cache-<feature>` exists or is created and chowned `1000:1000`.                  | per-feature (lazy) |
| 6 | `sandbox-network`          | `afk-runner-sandbox` bridge + iptables RFC1918-deny rules in place.                                | global      |
| 7 | `oauth-token`              | Keychain returns a non-empty token; held in `TOKEN` for the rest of the run.                       | global      |

The runner is independent of host's HEAD and working tree: no invariant inspects either. Feature validation (unknown slug) in narrowed modes runs through `check_feature_eligibility`, a CLI-input gate that runs after the global invariants (through `runner-checkout` clone-existence, 2a) and immediately before branch-sync (2b). It is **not** an invariant: on refusal it returns 2 with a `feature-restricted` / `single-dispatch (refused: <reason>)` stop reason — not `fail_invariant`, not `preflight-abort:`. Drain mode skips this gate entirely; per-feature eligibility is decided inside the outer loop by `drain_one_feature`'s cascade.

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
│   ensure_runner_checkout_on_branch(feature)  (lazy: inits from resolved   │
│                                                default branch's host tip  │
│                                                if host has no ref yet)    │
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
│         │                         feature; sets inner                     │
│         │                         RUN_STOP_REASON = "snapshot-failed" on  │
│         │                         a mid-feature crash, "fetch-failed" on  │
│         │                         a per-iteration runner-checkout sync    │
│         │                         failure)                                │
│         ▼                                                                 │
│   record_feature_outcome — once, keyed off inner RUN_STOP_REASON:         │
│     "propagation-error" → no row; halts the drain (see stop reasons)      │
│     "snapshot-failed"   → feature-snapshot-failed                         │
│     "fetch-failed"      → skip:fetch-failed                               │
│     anything else       → drained                                         │
│         │                                                                 │
│         ▼                                                                 │
│   [RUNNER_INTERRUPTED?] ──yes──► RUN_STOP_REASON = "interrupted"; stop    │
│         │ no                                                              │
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
│   ensure_runner_checkout                (re-sync to chosen tip;          │
│         │                                parking-ref when strictly ahead │
│         │                                or diverged, else host branch;  │
│         │                                fetch + checkout + reset --hard │
│         │                                + clean -fd; HEAD must match)   │
│         ▼                                                                │
│   dispatch_one(ref)  ───► see "dispatch_one" below                       │
│         │  (returns 0/1; sets RUN_STOP_REASON on halt-class errors)      │
│         ▼                                                                │
│   [RUNNER_INTERRUPTED?] ──yes──► RUN_STOP_REASON = "interrupted"; stop   │
│         │ no                                                             │
│   [RUN_STOP_REASON=propagation-error?] ──yes──► stop (exit 1)            │
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
        │  (fail ──► RUN_STOP_REASON = snapshot-failed-mid-dispatch:pre;
        │            record FAIL; ret 1)
   pre_head = git rev-parse HEAD (runner-checkout)
        │
        ▼
   run_dispatch_container("/implement <ref>")  ─► writes <NN>.{stdout.jsonl,stderr.log,exit}
        │  (per attempt, run_sandbox_container spawns the liveness renderer —
        │   a read-only observer tailing <NN>.stdout.jsonl and painting the
        │   liveness line on /dev/tty — and reaps it when the container ends;
        │   no-op when detached or RUNNER_DISABLE_LIVENESS=1)
   extract_result_summary(<NN>.stdout.jsonl)   ─► writes <NN>.summary.md
   impl_transport_crash = is_transport_crash(<NN>.stdout.jsonl, impl_rc)
        │
        ▼
   post_head = git rev-parse HEAD (runner-checkout)
   has_commits = (pre_head != post_head)
        │
        ▼
   post_impl = take_snapshot(feature)
        │
   [post-implement snapshot ok?]
        │
        ├─ no ─► park committed work to parking ref (when has_commits):
        │           • park error    → RUN_STOP_REASON = propagation-error;
        │                             record FAIL; ret 1
        │           • park ok / none → RUN_STOP_REASON =
        │                             snapshot-failed-mid-dispatch:post-implement;
        │                             record FAIL; ret 1
        │
        ▼ yes
   v_impl = classify_outcome(pre, post_impl, ref, impl_transport_crash)
   (4 args — classify_outcome ignores the container exit code; status delta is
    the verdict. The transport-crash flag flips the non-success path from
    failure to dispatch-aborted.)
        │
        ▼
   [has_commits?]
   ┌──────┴───────┐
  no             yes
   │              │
   │              ▼
   │         propagate_feature   (publish to parking ref; best-effort host ff)
   │              │
   │          [error?]
   │          ┌───┴────┐
   │         yes       no
   │          │        │
   │          ▼        │
   │   RUN_STOP_REASON │
   │   = propagation-  │
   │     error         │
   │   record FAIL     │
   │   ret 1           │
   │                   │
   └─────────┬─────────┘
             ▼
          [v_impl?]
   ┌─────────┴───────────────────────┐
 failure / dispatch-aborted        success
   │                                 │
   ▼                                 ▼
   [post_impl eligible?]     (success → post-implement walk)
   ┌──────┴──────┐
  yes           no
   │             │
   ▼             │    (stuck: would be re-picked without flag)
write_abort_flag │
 (implement;     │
  type=transport │
  on dispatch-   │
  aborted, else  │
  technical)     │
   │             │
   └──────┬──────┘
          ▼
   record FAIL (or dispatch-aborted)
   ret 1
```

The runner dispatches eligible AFK refs only — both loop mode (snapshot
`eligible` filter at selection) and single-dispatch (`run_single`'s
fresh-snapshot read for the named ref) refuse non-AFK or otherwise
ineligible refs before reaching `dispatch_one`. The post-implement
success path therefore proceeds straight to the walk.

The `has_commits` gate makes propagation reachable from the non-success
branch: a `/implement` bail commits an explanatory `tracker:` comment
without flipping status (classifier verdict = `failure`), and that
comment must reach the host before the next iteration's
`ensure_runner_checkout` resets the runner-checkout. A genuine
container-died-before-commit failure leaves `pre_head == post_head`,
so the propagation branch is a no-op for it.

A transport crash — the dispatch hit an infrastructure fault
(`is_transport_crash`: the terminal `result` event reports a retryable
error, or no result event is recoverable and the exit is nonzero) —
sets `impl_transport_crash`, which flips the classifier's non-success
verdict from `failure` to `dispatch-aborted`: the abort flag carries
`type=transport` instead of `technical`, and the recorded outcome is
`dispatch-aborted`. The post-implement snapshot-failure branch takes
precedence over that signal — an unreadable snapshot leaves the issue's
state unknown, so the iteration parks any committed work and bails before
the classifier runs.

### Post-implement walk

```
   [RUNNER_INTERRUPTED?]                  (checked in dispatch_one, before the walk)
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
   walk_post_implement_steps(RESOLVED_MANIFEST)
             │
   ┌─ next manifest item ──────────────────────────────────────────────────────┐
   │                                                                           │
   │   pre_item_head = git rev-parse HEAD (runner-checkout)                    │
   │   run_item_container(item prompt + ref) ─► <NN>-<step>-<label>.{stdout.jsonl,stderr.log,summary.md} │
   │   post_item_head = git rev-parse HEAD (runner-checkout)                   │
   │   item_has_commits = (pre_item_head != post_item_head)                    │
   │   item_transport_crash = is_transport_crash(<NN>-….stdout.jsonl, item_rc) │
   │             │                                                             │
   │             ▼                                                             │
   │   post = take_snapshot(feature)                                           │
   │             │                                                             │
   │   [post-item snapshot ok?]                                                │
   │        ├─ no ─► park committed work (when item_has_commits):              │
   │        │          • park error    → RUN_STOP_REASON = propagation-error;  │
   │        │                            record FAIL; ret 1                    │
   │        │          • park ok / none → RUN_STOP_REASON =                    │
   │        │                            snapshot-failed-mid-dispatch:post-<label>; │
   │        │                            record FAIL; ret 1                    │
   │        ▼ yes                                                              │
   │   action = classify_item_action(post status, item_rc)                     │
   │        (status + exit code only; nonzero exit ─► fail)                    │
   │             │                                                             │
   │        [action?]                                                          │
   │        │                                                                  │
   │        ├─ stop-success ─► propagate (when item_has_commits; park error    │
   │        │                   ─► record gate-failed, propagation-error,      │
   │        │                   ret 1); record done; ret 0                     │
   │        │                                                                  │
   │        ├─ fail ─► write_abort_flag(<label>; type=transport on review-     │
   │        │          aborted, else technical); propagate (when commits;      │
   │        │          park error ─► propagation-error); record gate-failed    │
   │        │          / review-aborted; ret 1                                 │
   │        │                                                                  │
   │        ├─ terminate-run ─► propagate (when commits); RUN_STOP_REASON =    │
   │        │                   runaway-halt(<ref>); record halt → runaway;    │
   │        │                   ret 1   (no abort flag — issue is eligible)    │
   │        │                                                                  │
   │        └─ continue ─► propagate (when commits; park error ─► record       │
   │             gate-failed, propagation-error, ret 1); next manifest item    │
   │                                                                           │
   └─ items exhausted, issue still in-review ──────────────────────────────────┘
             │
             ▼
   record left-for-human; ret 0   (no abort flag)
```

### Per-iteration verdict reference

| Path                                                                          | Recorded outcome | `dispatch_one` rc | `RUN_STOP_REASON` set?   | Abort flag written? |
| ----------------------------------------------------------------------------- | ---------------- | ----------------- | ------------------------ | ------------------- |
| Snapshot fails mid-dispatch (`pre` / `post-implement` / `post-step`); committed work, if any, parks ok | `FAIL` | 1 | `snapshot-failed-mid-dispatch:<stage>` | no |
| Snapshot fails `post-implement`/`post-step`, committed work, park error | `FAIL` | 1 | `propagation-error` | no |
| Implement classifier `failure`, no committed change | `FAIL` | 1 | no | yes (`implement`) |
| Implement classifier `failure`, committed change, propagate ok, post eligible | `FAIL` | 1 | no | yes (`implement`) |
| Implement classifier `failure`, committed change, propagate ok, post non-eligible | `FAIL` | 1 | no | no |
| Implement classifier `dispatch-aborted`, post eligible | `dispatch-aborted` | 1 | no | yes (`implement`, `transport`) |
| Implement classifier `dispatch-aborted`, post non-eligible | `dispatch-aborted` | 1 | no | no |
| Implement, committed change, propagate error (any classifier verdict) | `FAIL` | 1 | `propagation-error` | no |
| Step `fail` → `gate-failed` (no step commit, or parked ok) | `gate-failed` | 1 | no | yes (`<label>`) |
| Step `fail` → `review-aborted` (transport crash; no step commit, or parked ok) | `review-aborted` | 1 | no | yes (`<label>`, `transport`) |
| Step `fail`, committed step work, park error | `gate-failed`/`review-aborted` | 1 | `propagation-error` | yes (`<label>`) |
| Step `stop-success`/`continue`, propagate error | `gate-failed` | 1 | `propagation-error` | no |
| Step `stop-success`, propagate ok | `done` | 0 | no | no |
| Walk exhausted (issue still `in-review`) | `left-for-human` | 0 | no | no |
| Step `terminate-run` (issue back to `ready-for-agent`) | `halt → runaway` | 1 | `runaway-halt (<ref>)` | no |

The two snapshot-failure rows bail before the classifier runs — an unreadable snapshot leaves the issue's state unknown — parking any committed work first so the next iteration's reset can't lose it. `snapshot-failed-mid-dispatch:<stage>` is transient: `run_single` overwrites it with `single-dispatch (…)`, and in loop / drain mode the next iteration re-snapshots and re-classifies, so it shows up in the per-iteration record but not in the terminal Stop reasons list below.

The "no committed change" row writes the implement abort flag unconditionally because, in code, the write is gated on `post_eligible == "true"` — and with no commits the post-snapshot reads HEAD (unchanged), so post-status equals pre-status (`ready-for-agent`) and `post_eligible` is necessarily `true`. The "post non-eligible" branch is reachable only when a commit *did* land (e.g., `/implement` bailed to `needs-info`), which is captured by the dedicated row above.

The `dispatch-aborted` / `review-aborted` rows are the transport-crash variants — the container died for an infrastructure reason. Control flow matches the corresponding `failure` / `gate-failed` row, but the abort flag carries `type=transport` and the recorded label changes.

The "propagate error" rows cover a parking-ref publish failure; `RUN_STOP_REASON="propagation-error"` causes `run_loop` to break immediately, preserving the un-published commits on the runner-checkout for operator recovery. No abort flag is written — except on the step `fail` row (`gate-failed`/`review-aborted`), which writes its flag *before* attempting the park, making it the one path where an abort flag and `propagation-error` coincide.

## Outputs

### Files written under `.runner-state/runs/<YYYYMMDD-HHMMSS>/`

| File              | When                                                                      | Content                                                       |
| ----------------- | ------------------------------------------------------------------------- | ------------------------------------------------------------- |
| `runner.log`      | Always (created at run start, finalized at exit by `tee` drain).          | Full runner stdout + stderr.                                  |
| `discovery.json`  | Always for runs that pass the `discovery` pre-flight invariant.            | Pretty-printed JSON array returned by `tracker-snapshot --list`. |
| `<NN>.stdout.jsonl` (narrowed) / `<feature>/<NN>.stdout.jsonl` (drain) | Per implement dispatch. | Container stdout: the streamed structured-event trace (`claude … --output-format stream-json --verbose`). What the classifier and summary extraction read. Drain mode nests under a feature subdir so per-issue artifacts don't collide across features. |
| `<NN>.stderr.log` / `<feature>/<NN>.stderr.log` | Per implement dispatch. | Container stderr (diagnostics). Forensics only — never a detection input. |
| `<NN>.summary.md` / `<feature>/<NN>.summary.md` | Per implement dispatch. | The agent's closing message, extracted from the terminal `result` event. The skim-the-outcome artifact the SUMMARY table links. |
| `<NN>.exit` / `<feature>/<NN>.exit` | Per implement dispatch. | Container exit code (the classifier's Rung-2 input). |
| `<NN>-<step>-<label>.{stdout.jsonl,stderr.log,summary.md}` / `<feature>/…` | Per post-implement step dispatch (one set per walk step that ran; e.g. `01-01-review.stdout.jsonl`). | The same three per-dispatch artifacts as the implement stage, for the step dispatch. |
| `SUMMARY.md`      | Always (written by `finalize_run` from EXIT trap).                         | Narrowed modes: feature heading + flat per-issue table. Drain mode: per-feature sections (`## <feature> — drained` with nested table, or `## <feature> — skipped: <reason>` / `## <feature> — feature-snapshot-failed` one-liner). Pre-flight aborts replace the table with a single line naming the invariant. When any dispatch parked work to a parking ref, a `## Unpulled parked work` section (one `git pull runner <feature>` recipe per parked feature) follows the table; when `finalize_run` swept any stale parking ref, a `## Swept parking refs` section is appended after the body. |

### Files written under `.runner-state/aborted/<feature>/`

| File    | When                                                                                     | Content                                                                       |
| ------- | ---------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------- |
| `<NN>`  | On any failure that leaves the ref stuck or stranded (see "Abort flags" in afk-runner.md). | Plain-text abort flag: `type`, `dispatch`, `at`, `exit`, `log` fields. Overwritten on repeat failure. Removed by the maintainer to re-include the ref. |

### Stop reasons (in `SUMMARY.md` and the final terminal line)

**Drain mode (bare invocation):**

- `completed` *(every discovery slug considered)*
- `interrupted` *(outer-loop Ctrl-C)*
- `propagation-error` *(parking-ref publish failed inside a feature loop; exit 1; halts the entire drain)*
- `preflight-abort: discovery` *(`tracker-snapshot --list` exited non-zero or unparseable)*

**Narrowed modes (`--feature`, `--issue`):**

- `queue-empty`
- `interrupted` *(loop-phase Ctrl-C)*
- `snapshot-failed` *(`tracker-snapshot` crashed mid-loop; exit 1)*
- `propagation-error` *(parking-ref publish failed; exit 1; runner-checkout retains un-published commits)*
- `feature-restricted (refused: unknown-feature)` *(--feature mode)*
- `single-dispatch (success)` / `single-dispatch (failure)` / `single-dispatch (refused: <reason>)` *(--issue mode; refusal reasons: `HITL`, `wrong-status`, `blockers-unmet`, `missing`, `unknown-feature`, `snapshot-failed`)*

**All modes — pre-flight-phase:**

- `interrupted-during-preflight` *(pre-flight-phase Ctrl-C)*
- `preflight-abort: <invariant>`

### Exit codes

| Code | Meaning                                                                               |
| ---- | ------------------------------------------------------------------------------------- |
| 0    | Loop drained / interrupted; or single-dispatch success.                               |
| 1    | Single-dispatch failure (classifier verdict, container error, or parking-ref publish failure); or loop aborted by `snapshot-failed` or `propagation-error`. |
| 2    | Pre-flight invariant failed; argparse rejected the invocation before any run dir was created; or single-dispatch refused the named ref (eligibility gate). |
| 130  | Ctrl-C arrived during pre-flight (`handle_preflight_signal` calls `exit 130`).        |

### Side effects (success path only)

- Host repo's target branch fast-forwarded with `/implement` and post-implement step `tracker:` commits — observable via `git log` on the host.
- Issue tracker state advanced in committed history (issue files updated; visible to the next `tracker-snapshot`).
- Per-feature mvn cache populated/updated for the next run.
- Pidfile `.runner-state/lock` released by `finalize_run`.

The runner never pushes to a remote.

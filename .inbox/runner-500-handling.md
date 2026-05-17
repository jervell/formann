# Runner reaction to API 500s

In run `.runner-state/runs/20260516-165625/`, a ~4.5-minute Anthropic API blip (19:58:37 → 20:03:15) hit four sequential runner subprocesses. Each one received only an `API Error: 500 Internal server error.` line and exited 1 before producing any output. The runner handled this in two ways that are both worth revisiting.

## Failure signature

The `claude -p` CLI invocation crashes with this exact log content (verbatim, full file — no model output, no partial commits):

```
API Error: 500 Internal server error. This is a server-side issue, usually temporary — try again in a moment. If it persists, check status.claude.com.
<terminal-control-bytes>exit status 1
```

Container exit code: `1`. No commits added in the runner-checkout. No tracker-snapshot delta. Duration in this run: 5–18 seconds (all model-time, zero output bytes).

## What the runner did with it

### Implement stage (issues 12, glossary-rename/01, glossary-rename/02)

`framework/runner/run-the-queue.sh`:

- `run_dispatch_container` at line 1272 invokes `claude -p "/implement <ref>" --dangerously-skip-permissions`. `impl_rc=1` captured at line 1406.
- `classify_outcome` (line 1423) reads pre/post tracker snapshots; with no commits made, status is unchanged from `ready-for-agent` → verdict `failure`.
- Line 1496–1501: since post-status is still eligible, `write_abort_flag` runs → `.runner-state/aborted/<feature>/<NN>` is created. Marker format:
  ```
  type: technical
  dispatch: implement
  at: <ISO-8601 UTC>
  exit: 1
  log: .runner-state/runs/<ts>/<feature>/<NN>.log
  ```
- `record_dispatch` writes `FAIL`. No retry.
- Maintainer must `rm` each marker before the next pass will touch the ref.

### Gate stage (issue 11)

- Implement landed clean — issue 11's `feat` commit `c341a83` is on the branch, status flipped to `in-review`.
- `run_gate_container` at line 1281 invokes `claude -p "<gate-prompt>\n<ref>"`. `gate_rc=1`.
- `classify_gate_outcome` (defined line 130): the case at lines **144–147** fires:
  ```sh
  if [ "$exit_code" != "0" ]; then
    echo "gate-failed"
    return 0
  fi
  ```
  No inspection of the log, no distinction between "subprocess crashed before producing any review output" and "review ran, found problems, committed properly, exited weird". Both bucket to `gate-failed`.
- Line 1584: `write_abort_flag` runs against the gate; record `gate-failed`. SUMMARY.md shows `gate-failed` next to the issue.
- **Re-review is not automatic.** The host's `next_eligible_ref` (line 107) only picks `eligible: true` snapshot entries, and the snapshot only marks `ready-for-agent` issues as eligible. The issue is now `in-review`, so no future runner pass will touch it. The maintainer is the only path back to review.

## Two distinct bugs

### Bug 1: review-stage 500 mislabeled as `gate-failed`

`gate-failed` is a terminal label that semantically means "review found a problem you should look at". A crashed gate subprocess produces no review content and no findings. SUMMARY.md offers the operator no way to tell them apart short of opening each `-review.log` file individually.

Suggested fix shape: add a new outcome (e.g. `review-aborted` or `gate-crashed`) for the case where `gate_rc != 0` AND the review subprocess produced no commits AND its log matches a crash signature (empty, or only `API Error:` / similar transport errors). That outcome should:

- Not consume the issue's review slot (i.e. flip the snapshot eligibility back so the next runner pass re-tries the review), or
- At minimum surface clearly in SUMMARY.md so the maintainer doesn't read it as a real gate failure.

### Bug 2: any 500 is a hard abort; no transport-error retry

`run_dispatch_container` and `run_gate_container` are single-shot. A single transient 5xx writes an abort marker; the runner moves on. In a queue tail, one upstream blip can knock out the remaining issues across multiple features (this run: 3 consecutive aborts).

Suggested fix shape: detect transport-class failures (`API Error: 5xx` patterns, network timeouts, rate-limit 429) by tailing the log immediately after the subprocess exits. On a transport-class failure, retry the same `claude -p` invocation 2–3 times with exponential backoff (e.g. 30s, 90s, 240s) before declaring the issue aborted. Distinguish from model-produced errors (which can legitimately mean "this issue is unworkable") by gating retry on a log-content predicate, not on exit code alone.

## Synthetic reproducer

The runner already has bats coverage of `classify_gate_outcome` as a pure function (`framework/runner/tests/run-the-queue.bats` lines 94–170). The cheapest reproducer for Bug 1 is a bats test that exercises a new variant of the classifier (or a new helper):

```bash
@test "review subprocess crashed (rc=1, empty review log) is review-aborted, not gate-failed" {
  pre="$(snap_with_status in-review)"
  post="$pre"  # no commits made → no delta
  empty_log="$(mktemp)"
  result="$(classify_gate_outcome_v2 "$pre" "$post" f/01 1 "$empty_log")"
  [ "$result" = "review-aborted" ]
}

@test "review subprocess crashed (rc=1, log contains only API 500) is review-aborted" {
  pre="$(snap_with_status in-review)"
  post="$pre"
  five_hundred_log="$(mktemp)"
  printf 'API Error: 500 Internal server error.\n' >"$five_hundred_log"
  result="$(classify_gate_outcome_v2 "$pre" "$post" f/01 1 "$five_hundred_log")"
  [ "$result" = "review-aborted" ]
}
```

For end-to-end verification (covers both bugs), drop a fake `claude` into the sandbox PATH that always emits the 500 line and exits 1:

```bash
#!/usr/bin/env bash
printf 'API Error: 500 Internal server error. This is a server-side issue, usually temporary — try again in a moment. If it persists, check status.claude.com.\n'
exit 1
```

The sandbox build step (`framework/runner/build-image.sh`) controls what's on PATH inside the dispatch container — wiring a `FAKE_CLAUDE=1` env that flips `claude` to that script (or that the bats test rig overrides via test-only sandbox build) reproduces the exact runtime conditions of this incident without needing an upstream outage.

A retry-layer test for Bug 2 follows the same shape: a fake `claude` that exits 1 with the 500 line on the first N invocations and succeeds on the (N+1)th, with an assertion that the runner retried before writing the abort marker.

## Why this matters

The misleading `gate-failed` label was the bigger of the two — it pointed maintainer attention at "review found a problem" when no review had run. The bulk-abort on a single 500 is a sharper edge: one upstream blip can knock out an arbitrary number of consecutive issues at the tail of a queue, requiring the maintainer to manually `rm` markers under `.runner-state/aborted/` before the next run can touch them.

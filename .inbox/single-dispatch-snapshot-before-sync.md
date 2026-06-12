# Single-dispatch eligibility snapshot runs before branch-sync and crashes on a swept HEAD

Observed 2026-06-12 in the iot consumer, first `--issue` invocation after a
tracker commit had advanced the host feature branch past both the parking ref
and the runner-checkout's source branch:

```
runner: swept runner-checkout source refs/heads/media-image-detail-page (reachable from refs/heads/media-image-detail-page)
runner: swept stale parking ref refs/remotes/runner/media-image-detail-page (reachable from refs/heads/media-image-detail-page)
tracker-snapshot: failed to extract committed .features/ from <runner-checkout>
runner: tracker-snapshot exited non-zero (1) for feature media-image-detail-page
runner: single-dispatch refused: tracker-snapshot failed for feature 'media-image-detail-page'
```

The sweep correctly deleted the superseded source branch — but the
runner-checkout's HEAD was a symbolic ref to that branch, so the deletion left
HEAD dangling. In `--issue` mode the eligibility snapshot (`git archive HEAD
.features` under local-markdown) runs *before* `ensure_runner_checkout_on_branch`,
whose unborn-HEAD recovery exists for exactly this state. The snapshot crashes
against the dangling HEAD that the very next step would have repaired, and the
run dies with a spurious `single-dispatch (refused: snapshot-failed)`.

Drain mode is unaffected: its per-feature gate cascade syncs the branch before
snapshotting.

The sweep's own comment block names this as the routine post-merge-cleanup
path, so the state is expected — only the `--issue` ordering is wrong.

Fix directions (pick at triage): run the branch-sync (or at least the
unborn-HEAD repair) before the single-dispatch eligibility snapshot; or make
the sweep re-point HEAD at a surviving ref when it deletes the branch HEAD
symrefs to.

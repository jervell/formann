---
paths:
  - "framework/runner/**"
---

# Smoke-run artifacts

Per-walk markdown artifacts capture operator-attended walks against fixtures under `tests/fixtures/` which cannot run inside the AFK runner's dispatch container (no Docker socket — no Docker-in-Docker). An artifact records one end-to-end run of a runbook against real Docker, the real binding, and real `git fetch`-based propagation. The maintainer reads it to render a verdict during verification; once the issue is `done`, the artifact has served its purpose.

Artifacts live under `.runner-state/smoke-runs/` (gitignored, ephemeral — same lifecycle as `.runner-state/runs/`). The durable record of what was walked and observed belongs in the issue's Implementation / Verification comments, not in the artifact file. The artifact is intermediate scratch; the issue comment is the proof.

## When to produce a new artifact

- A smoke fixture lands its first walk (the artifact is born with the fixture).
- A rework changes the runbook in a way that alters the walk (preconditions, commands, expected outcomes) — re-walk the modified runbook and either append the new walk to the existing artifact or supersede it with a fresh one.
- A runner change invalidates prior walks (pre-flight invariants, gate semantics, propagation mechanics, SUMMARY shape) — re-walk every fixture whose artifact's runner contract drifted.

## Filename

`YYYY-MM-DD-<fixture-slug>.md` (UTC date; the fixture's directory name under `framework/runner/tests/fixtures/`). One artifact per walk; same-day re-walks get a numeric suffix (`…-1.md`, `…-2.md`).

## Expected content

- **Header:** operator (`Claude (via /implement on host)` or maintainer name), date (UTC), host repo HEAD at start (SHA + branch), park branch used (and why, if non-obvious), feature-branch parent (if the fixture installs feature branches).
- **Per-scenario section** (one if the fixture is single-scenario, several if it walks multiple scenarios):
  - Pre-conditions and the literal command run.
  - Observed: exit code, trailing `stop reason:` line, `SUMMARY.md` contents, `discovery.json` contents, host repo state delta (HEAD, working tree, feature branch tips before/after).
  - Verdict: `PASS` / `FAIL` plus a one-line diagnosis on `FAIL`.
- **Conclusion:** one paragraph summarising the walk's verdict against the runbook's claimed outcome.
- **Teardown:** the actual teardown commands run, with their output.

## Append-only during the walk

The artifact is append-only while the walk is in progress and while the issue is in `in-review`. If the walk exposed a runbook bug, raise it as a rework on the issue that owns the runbook; do not edit the artifact's observations after the fact. Once the issue is `done`, the artifact may be deleted at any time — the issue's Verification comment is the durable record.

## Skeleton when the dispatch can't drive the walk

When the AFK runner dispatches `/implement` for an issue whose verification needs a smoke walk, the dispatched agent cannot drive the walk itself (no Docker socket inside the dispatch container). In that case the agent writes a skeleton artifact at the conventional path: populate the Header, stub each Per-scenario section with the literal commands the runbook prescribes, leave Observed / Verdict / Teardown empty for the maintainer to fill in on host. The agent cites the skeleton artifact's path as the AC's Evidence; the maintainer drives the walk on host, fills the artifact in, and verifies the issue.
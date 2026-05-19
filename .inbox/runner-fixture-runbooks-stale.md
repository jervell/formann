# Runner fixture runbooks have drifted from current conventions

The operator-attended runbooks shipped with the runner's smoke/demo fixtures (`multi-feature-drain`, `synthetic-drain`, `smoke`) have drifted from the project's current binding and branch conventions. Following them literally either fails outright or silently degrades to "the runner doesn't see the fixture". All four drivers hit on 2026-05-19 during the `/triage` smoke walk for #10.

## Drivers (all hit on 2026-05-19, runner-allow-on-branch walk)

1. **Binding-shape mismatch — fixture vs. active binding** (`multi-feature-drain`, `synthetic-drain`). The fixtures install `.features/<slug>/PRD.md` + `.features/<slug>/issues/*.md` (local-markdown shape), and their runbooks sanity-check setup with `bash framework/bindings/issue-tracker/local-markdown/tracker-snapshot --list`. The runner's discovery uses the host's *active* binding via `docs/formann/issue-tracker/tracker-snapshot --list`. Under the github-issues binding, the fixture's slug is never returned, so the runner exits with `queue-empty` or `unknown-feature` without ever dispatching. The walk for #10 worked around it via `FORMANN_INSTALL_BINDING_issue_tracker=local-markdown ./installer/install.sh .` before setup and the reverse swap after teardown.

2. **Untracked-overwrites-checkout between scenarios** (`multi-feature-drain`). Setup step 3 leaves `.features/multi-drain-{alpha,beta}/` as untracked dirs in the park branch's working tree so discovery sees them. Scenario 2 then asks the operator to `git checkout multi-drain-alpha` — but the same paths are tracked on that branch, so git refuses with `error: The following untracked working tree files would be overwritten by checkout`. No cleanup step between scenarios. Workaround during the #10 walk: `rm -rf .features/multi-drain-alpha` before the switch. `synthetic-drain` doesn't trigger this on its happy path (no switch back to the feature branch) but the same shape is latent if the operator deviates.

3. **`master`-branch assumption** (`multi-feature-drain`, `synthetic-drain`). Runbooks say "branch off `master`", "park host on `master`", "`git checkout master`". This repo's primary branch is `main`. During the #10 walk we substituted `runner-allow-on-branch` for `master` (so the fixture branches inherited the new propagate_feature code under test). Under github-issues conventions the substitution would be `main` instead. Either way it's a silent manual step the operator has to figure out.

4. **`smoke/README.md` "Manual reproduction" example is incomplete.** Lines 34-52 walk through staging the workspace but never copy `framework/` into it and never wire `docs/formann/issue-tracker`. Then `bash "$ws/framework/runner/run-the-queue.sh"` is invoked — that path doesn't exist after the documented steps. `smoke.bats` itself also doesn't visibly wire `docs/formann/issue-tracker`; either it relies on a fallback or some implicit `.agents`/`.claude/skills` symlink resolution. Either way, the README's repro is unfollow-able and the underlying bats path is opaque to a maintainer reading the docs.

## Proposed shape

A few directions, not mutually exclusive:

- **Binding-mismatch fix:** the simplest path is to teach the runbooks to swap the binding via `FORMANN_INSTALL_BINDING_issue_tracker=local-markdown ./installer/install.sh .` as an explicit setup step (with the reverse in teardown). The cleaner path is to make the fixtures binding-agnostic — emit equivalent GitHub-issues state (label-marked sub-issues) on demand for the github-issues binding. The cleanest is for the fixture to ship as an installable mini-binding the runner switches to for the duration of the walk. Probably overkill; the explicit swap is enough.
- **Untracked-overwrites fix:** add a one-line `rm -rf .features/<slug>` before each `git checkout <slug>` step in `multi-feature-drain/README.md`. Possibly extract a tiny helper into the fixture dir.
- **`master` assumption fix:** stop hard-coding the branch name. Either parameterise the runbook (`PARK_BRANCH=${PARK_BRANCH:-main}`) or detect via `git symbolic-ref refs/remotes/origin/HEAD` / `git config init.defaultBranch`.
- **`smoke/README.md` fix:** either complete the manual repro (add the framework copy + binding wiring `smoke.bats` actually does) or replace the manual-repro section with a one-liner pointing at `smoke.bats` itself as the documentation, since the bats test is the source of truth.

## Pointers

- The walk that surfaced all four: `/triage` for #10, artifact at `.runner-state/smoke-runs/2026-05-19-multi-feature-drain.md`, Verification (2) comment on issue #10.
- Affected runbooks: `framework/runner/tests/fixtures/{multi-feature-drain,synthetic-drain,smoke}/README.md`.
- Bats driver (smoke): `framework/runner/tests/smoke.bats:73-132`.
- Runner's discovery contract (uses host's active binding): `framework/runner/run-the-queue.sh:980` (`tracker-snapshot --list` invocation).
- Installer's binding-pick plumbing: `installer/install.sh:56–106` (`prompt_role_bindings`).

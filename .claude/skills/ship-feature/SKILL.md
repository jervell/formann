---
name: ship-feature
description: Ship a completed feature — sync runner-side work, archive via triage, reconcile the changelog, clear inbox entries, and merge into the default branch. Use when the maintainer says "ship", "land this feature", "finalize", "merge this feature into main", or "/ship-feature".
argument-hint: "[feature slug; defaults to current branch]"
---

# Ship Feature

Take a feature that's done and merge it. The maintainer drives the final commit and merge — gate on explicit confirmation before either.

## Resolve the target

Resolve the project's **default branch** first — `git symbolic-ref --short refs/remotes/origin/HEAD` with the `origin/` prefix stripped, falling back to whichever of `main`/`master` exists. Don't assume `main`, and don't use the currently-checked-out branch. Call it `<default-branch>` below.

Then interpret `$ARGUMENTS`:

- **Empty** — the current branch name is the slug. Refuse if it's `<default-branch>` or HEAD is detached.
- **A slug** — use it verbatim. Refuse if no matching branch exists locally or on a remote.

Report the resolved slug before proceeding.

## Steps

1. **Check out the feature branch.** `git switch <slug>`. Track from `origin` or `runner` if missing locally. Refuse if the working tree is dirty in unrelated files — ask to stash, commit, or abort.

2. **Pull runner-side work.** If a `runner` remote exists: `git fetch runner`; fast-forward or merge `runner/<slug>` if it has commits the host branch doesn't. Stop on conflicts; don't auto-resolve. Skip silently if the remote or branch is absent.

3. **Run the full test suite.** Run the project's full test / feedback-loop command — every suite must pass (exit 0). A red suite blocks the merge: stop and report, don't proceed.

4. **Ensure the feature is archived.** Invoke `/triage` with "archive `<slug>`". Archive is idempotent: if the feature is already archived, `/triage` reports so and no-ops — treat that as success and continue. Interactive `[human]`-row walks are expected, not a hang. Stop only if `/triage` refuses because the feature isn't ready to archive (non-terminal issues remain).

5. **Reconcile the changelog.** Skip this step if the project keeps no changelog. Otherwise reconcile the unreleased section (e.g. `[Unreleased]`) against `git log --oneline <default-branch>..HEAD`, following the project's changelog rules if it documents any. Present proposed edits before writing.

6. **Clear resolved inbox entries.** Only if the project uses the inbox add-on (`.inbox.md` exists). Read `.inbox.md` and any linked files under `.inbox/`. Delete any entry this feature resolved — both the bullet and the body file if it has one.

7. **Confirm, commit, merge.**
   - Refuse if local `<default-branch>` is behind `origin/<default-branch>` — fetch and update first.
   - Summarise pending edits and the merge plan. Default: fast-forward if possible, else a merge commit. Maintainer may request rebase or squash instead.
   - On go-ahead, commit the pending edits per the project's commit conventions. Keep changelog and inbox edits in separate commits, and prefix the inbox-clearing commit's subject with `inbox:` so it stays filterable, per the inbox add-on convention. Omit either commit if that step made no edits.
   - Check out `<default-branch>`, merge `<slug>` per the agreed strategy, report commit and merge SHAs.
   - Don't push.
   - After a successful merge, ask separately whether to delete the feature branch.
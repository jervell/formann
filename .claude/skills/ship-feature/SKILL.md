---
name: ship-feature
description: Ship a completed feature — sync runner-side work, archive via triage, reconcile CHANGELOG.md, clear inbox entries, and merge into main. Use when the maintainer says "ship", "land this feature", "finalize", "merge this feature into main", or "/ship-feature".
argument-hint: "[feature slug or issue ref; defaults to current branch]"
---

# Ship Feature

Take a feature that's done and merge it. The maintainer drives the final commit and merge — gate on explicit confirmation before either.

## Resolve the target

Interpret `$ARGUMENTS`:

- **Empty** — current branch is the slug. Refuse on `main` or detached HEAD.
- **`#N` or bare `N`** — `gh issue view N --json labels`; derive slug from `formann:slug:<slug>`. If the issue is a sub-issue (no `formann:feature`), look up its parent and refuse with the parent ref named.
- **Anything else** — slug verbatim. Refuse if no matching branch exists locally or on a remote.

Surface and stop on a slug collision from Read-the-feature.

Report the resolved slug before proceeding.

## Steps

1. **Check out the feature branch.** `git switch <slug>`. Track from `origin` or `runner` if missing locally. Refuse if the working tree is dirty in unrelated files — ask to stash, commit, or abort.

2. **Pull runner-side work.** If a `runner` remote exists: `git fetch runner`; fast-forward or merge `runner/<slug>` if it has commits the host branch doesn't. Stop on conflicts; don't auto-resolve. Skip silently if the remote or branch is absent.

3. **Run the full test suite.** Run `bin/test.sh` — every tracked bats suite must pass (exit 0). A red suite blocks the merge: stop and report, don't proceed. `build-image.bats` needs a reachable Docker daemon and fails loudly without one — that's intentional, don't skip it.

4. **Confirm the feature is archived.** Resolve the parent issue per the **Read the feature** verb in `docs/formann/issue-tracker/BINDING.md`. If it's closed and carries `formann:archived`, continue. Otherwise invoke `/triage` with "archive `<slug>`" — interactive `[human]`-row walks are expected, not a hang. Stop if `/triage` refuses.

5. **Reconcile `CHANGELOG.md`.** Compare `[Unreleased]` against `git log --oneline main..HEAD`. Follow the rules at `~/.claude/skills/commit/CHANGELOG.rules.md`. Present proposed edits before writing.

6. **Clear resolved inbox entries.** Read `.inbox.md` and any linked files under `.inbox/`. Delete any entry this feature resolved — both the bullet and the body file if it has one.

7. **Confirm, commit, merge.**
   - Refuse if local `main` is behind `origin/main` — fetch and update first.
   - Summarise pending edits and the merge plan. Default: fast-forward if possible, else a merge commit. Maintainer may request rebase or squash instead.
   - On go-ahead: invoke `/commit` twice — once for CHANGELOG (`changelog: …`), once for inbox edits (`inbox: …`). Two commits preserve the `inbox:` subject-prefix filter.
   - Check out `main`, merge `<slug>` per the agreed strategy, report commit and merge SHAs.
   - Don't push.
   - After a successful merge, ask separately whether to delete the feature branch. Don't bundle with the merge confirmation.
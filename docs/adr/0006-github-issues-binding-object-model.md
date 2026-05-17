# GitHub Issues binding: parent-issue-with-sub-issues and slug-as-label

The github-issues binding models a Formann feature as a **parent GitHub issue** (labelled `formann:feature`) whose sub-issues are the individual vertical slices. The feature slug travels alongside as the label `formann:slug:<slug>` on the parent issue.

## Decision A: Feature/slice modelling shape

A feature (PRD + ordered slices) maps to a GitHub parent issue whose sub-issues are the slices.

### Considered options

- **Milestones** — A milestone groups issues with a due-date and completion percentage. Rejected: milestones carry no body, so the PRD has no natural home; the parent → child relationship is absent from the milestone UI; a single GraphQL query cannot fetch milestone + all issues + their bodies + labels in one round-trip.
- **Labels-only grouping** — A feature label (e.g. `formann:feature:my-feature`) applied to every issue in the feature. Rejected: there is no native parent–child hierarchy in the GitHub UI; the feature PRD has no natural home; fetching the feature snapshot requires filtering all issues by label and does not yield a single-query snapshot.
- **GitHub Projects v2** — A project board with status fields and kanban views grouping issues across repos. Rejected: Projects v2 is a cross-repo overlay that requires a separate GraphQL surface and additional permissions; it offers drag-and-drop ordering but at the cost of a wholly different object model; and it provides no benefit to the existing skill flows (triage, implement, review) that only need parent–child traversal, body access, and label-based state.
- **Parent issue with sub-issues** (chosen) — A GitHub issue becomes the parent by virtue of having sub-issues linked via the `addSubIssue` GraphQL mutation. The native sub-issue panel renders parent → child navigation without label decoding; a single GraphQL query fetches the parent body (= PRD), all sub-issues, their bodies, and their labels in one round-trip, keeping the binding cheap on the API rate limit; and the shape maps one-to-one onto the framework's existing feature/slice mental model with no conceptual translation layer.

## Decision B: Slug storage

The feature slug is stored as the label `formann:slug:<slug>` on the parent issue.

### Considered options

- **Body-marker** — Embed the slug as a machine-readable comment or structured line in the parent issue body (e.g., `<!-- formann-slug: my-feature -->`). Rejected: regex-parsing the body is fragile; a careless body edit (reformatting, section deletion, whitespace change) silently breaks slug resolution; the slug is invisible in the GitHub list view and unsearchable via `gh issue list --label`.
- **Title-prefix** — Encode the slug at the start of the issue title (e.g., `[my-feature] My Feature Title`). Rejected: pollutes the human-readable title that appears in every GitHub UI surface (search, autolinks, PR references); it is not possible to rename the slug independently of the display title; and title-prefix parsing breaks on titles that legitimately contain brackets.
- **No-slug-storage** — Resolve features by issue number alone; derive the slug on demand from the title or from a runner-side mapping. Rejected: GitHub issue numbers are repository-scoped integers with no cross-system stability guarantee; if a feature issue is closed and a new one opened for the same feature the number changes; the slug — not the number — is the stable identifier across reorderings, renames, and snapshot rebuilds. Number-only lookup also provides no way to detect slug collisions at creation time.
- **`formann:slug:<slug>` label** (chosen) — A per-feature label created on demand by `/to-prd`. The slug renders as a chip in every GitHub list view and issue header, making feature identity visible at a glance without decoding the title; `gh issue list --label formann:slug:<slug>` resolves the parent in a single API call without body parsing; labels are robust against careless body edits; and the slug acts as a stable identifier across issue-number reorderings because the label travels with the issue regardless of its number. Uniqueness is enforced at creation time and at every snapshot read (see PRD, Slug identity and uniqueness).

## Consequences

- The `addSubIssue` GraphQL mutation is a hard prerequisite; GitHub Enterprise Server instances that have not enabled sub-issues cannot use this binding. BINDING.md documents this version requirement.
- GitHub's hard limit of 100 sub-issues per parent bounds feature size. Features approaching the limit must split into sibling features.
- The `formann:slug:<slug>` label namespace is dynamic — a new label is created per feature at `/to-prd` time. The `bootstrap-labels` install script creates only the static namespace; slug labels accumulate incrementally. Label names are bounded by GitHub's 50-char limit (13 chars consumed by `formann:slug:`; 37 available for the slug itself).
- GitHub enforces no uniqueness constraint on labels. Slug uniqueness is maintained by pre-flight checks at feature creation and cardinality checks at every snapshot read; hand-applied label duplication is detectable but not preventable. BINDING.md documents the recovery recipe.
- The feature PRD lives in the parent issue's body. The 65,536-char GitHub body limit is the PRD size ceiling; content approaching that ceiling should be moved to a linked design doc.

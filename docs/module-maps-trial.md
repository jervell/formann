# Module maps trial

Started 2026-10-20 on branch `module-maps`, with Omumu as the consumer. Checkpoint around 2026-11-17: a
`/grill-with-docs` session over this log and the numbers from the consumer's `scripts/module-map-report.sh`,
ending in one of three decisions: open the pull request upstream, adjust the skills, or drop the branch.

## What counts as working

- The maintainer edited the module table or the primary flow before approving it on at least some features.
  Never editing means either the agent designs well enough or the step is being waved through; the per-feature
  notes say which.
- Merged changes that touch a mapped area also touch its map, without the maintainer asking (the report's drift
  rate stays near zero).
- The number of `unchecked` claims does not grow; claims turn into checks.
- Issues in mapped areas come back for rework less than issues in unmapped areas.

## Weekly numbers

From `scripts/module-map-report.sh` in the consumer, run once a week.

| Week of | PRDs with design / PRDs | PRs touching mapped areas | of which map updated | `unchecked` claims | map-check findings |
| ------- | ----------------------- | ------------------------- | -------------------- | ------------------ | ------------------ |
| 2026-10-20 | | | | | |

## Per feature

One entry per feature that passed through `/to-prd` or `/implement` during the trial, filled in at archive.

### Template

- **Feature:** slug, PRD issue
- **Areas touched, map existed before:**
- **Edits to the module table or flow before approval:** none / which rows or arrows changed, and why
- **Map created or updated by implement:** which maps, in which PRs
- **Map-check findings:** none / which, and whether they were right
- **Rework rounds, gate outcomes:** from the runner's `SUMMARY.md`
- **Notes:** anything the numbers miss, such as a map that made a slice faster to brief or a claim that was wrong

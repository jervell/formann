# GitHub-issues binding: migrate `## Blocked by` to native issue dependencies

The github-issues binding currently encodes blockers as a `## Blocked by` markdown section in the issue body, parsed back by `tracker-snapshot` via regex (`framework/bindings/issue-tracker/github-issues/tracker-snapshot:91-97`). This forces the per-feature GraphQL query to pull `body` on every sub-issue (up to 100 per parent) just so we can extract `#N` refs from one section.

GitHub has shipped (or is shipping) a native **issue dependencies** feature — first-class `blocks` / `blocked by` relationships between issues, separate from sub-issue containment. If/when it's GA and exposed in the GraphQL schema, the snapshot read could drop body-fetching entirely and read dependencies as a typed connection.

## Why it would be better

- No body-bandwidth cost on snapshot reads (currently up to ~6.5 MB worst-case per feature; typical is much less but still wasteful).
- No regex-based parsing; no risk of a web-UI edit silently breaking blocker extraction.
- Native UI surfacing (dependency panel, blocked indicators) for free.
- Cross-repo blockers become possible if/when the feature supports them.

## Why we're not doing it now

1. **Verify GA status and GraphQL surface** before designing — I'm working from assumption, not confirmation.
2. **GHE prerequisite compounding** — the binding already requires sub-issues. Adding dependencies as a second hard requirement narrows compatible GHE versions further.
3. **Cross-binding divergence** — the `local-markdown` binding has no equivalent and must keep `## Blocked by` in the markdown body. The two bindings would diverge on blocker storage (though snapshot output stays byte-compatible).
4. **Migration of existing data** — any open features with `## Blocked by` sections would need a one-shot conversion to native dependency links.

## Where to start when picking this up

- Confirm GitHub issue-dependencies feature is GA on github.com and check GHE availability.
- Inspect the GraphQL schema: relevant connection fields on `Issue` (likely `blockedByIssues` / `dependsOnIssues` or similar).
- Decide whether `local-markdown` keeps body-parsing forever (probably yes — it has no alternative).
- Spec the migration of existing `## Blocked by` sections to native links.
- Update `tracker-snapshot` to drop `body` from the per-feature query and read the new connection instead.
# GitHub Issues binding: blockers as native dependencies

The github-issues binding stores an issue's blockers as native GitHub issue dependencies — the `Issue.blockedBy` connection read-side, the `addBlockedBy` / `removeBlockedBy` mutations write-side — not as a `## Blocked by` body section parsed by regex. The snapshot's `blocked_by` JSON field remains `#N`-shaped; only the source of truth changes.

## Considered options

- **Body-section only.** Encode blockers in a `## Blocked by` markdown section in the issue body; extract `#N` refs with an awk regex in `tracker-snapshot`. (The original binding state, parallel to local-markdown's storage.) Rejected: every per-feature snapshot read pulls the full `body` field on every sub-issue (up to ~6.5 MB worst-case for a saturated 100-sub-issue feature) just to extract a small set of refs; the regex matches `#N` tokens regardless of context, so a parenthetical "Not blocked by #23" reads as a real blocker ref; a web-UI hand-edit that mangles the section heading silently strips all blockers with no tracker-side error; and GitHub's own Relationships sidebar, dependency search filters (`is:blocked`, `blocking:`), and `BlockedByAdded`/`BlockedByRemoved` timeline events render nothing because the body-section convention is invisible to GitHub.

- **Dual-write mirror.** Write to both native dependencies AND a `## Blocked by` body-section mirror; read from the cheaper native path. Rejected: doubles the partial-failure surface (two independent API calls per blocker write, no transaction primitive) for purely cosmetic gain — the body mirror is human-readable but redundant with the Relationships sidebar GitHub already renders; any web-UI hand-edit to either surface silently diverges from the other; and the cross-binding parity argument that motivates the mirror (local-markdown's body section) is binding-private — both bindings produce byte-identical snapshot JSON regardless of internal storage.

- **Native dependencies only** (chosen). Write blockers via `addBlockedBy` / `removeBlockedBy`; read via the `Issue.blockedBy` connection. Drop the body section from the github-issues issue template, drop the `body-edit "Blocked by"` write path, and drop the `tracker-snapshot` body-regex extractor. The per-feature GraphQL query drops `body` on sub-issues entirely. A new role-surface declarative script `set-blockers <N> <ref>...` performs the read-diff-apply-mutations dance under the hood, mirroring the local-markdown binding's declarative "Set issue metadata > Blocked-by" verb contract.

## Consequences

- The github-issues binding's GHE prerequisite tightens. In addition to the `addSubIssue` mutation and `subIssues` connection (per ADR-0006), the `Issue.blockedBy` connection and `addBlockedBy` / `removeBlockedBy` mutations must be present. BINDING.md gains a second introspection probe alongside the sub-issues check.

- GitHub's hard limit of 50 blockers per relationship type bounds blocker fan-in. Irrelevant under Formann's vertical-slice topology, but documented in BINDING.md alongside the 100-sub-issues limit.

- Blockers leave the issue body. A reader running `gh issue view <N>` sees no `## Blocked by` section; blockers surface only in the Relationships sidebar, the dependency search filters, the timeline events, and `tracker-snapshot` JSON. Skills consume the snapshot, so they are unaffected; humans reading raw issues must look at the sidebar.

- Web-UI hand-edits to add blockers no longer work via markdown — the maintainer must use GitHub's native Add-dependency picker. The mutation surface and the UI surface now agree.

- Cross-repo blockers, although technically expressible via the `blockingIssueId: ID!` mutation argument, are out of scope. The snapshot's `blocked_by` field remains repo-local `#N`-shaped, matching local-markdown's same-feature blocker constraint. Future expansion would touch both bindings' eligibility resolution rules.

- The github-issues Issue template carries a second omission alongside `## Parent`: under this binding, sub-issue bodies omit both `## Parent` and `## Blocked by`. Local-markdown's template keeps both. The cross-binding divergence is documented in each binding's own Issue template section.

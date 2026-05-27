# Issue tracker contract

This document is for **binding implementors** — people writing a new issue-tracker binding or auditing an existing one for conformance. It lists the canonical verb set every binding must implement.

**Skills and runners do not read this file.** They reference the active binding's `docs/formann/issue-tracker/BINDING.md` view, which is self-contained (abstract description plus realization per verb). `CONTRACT.md` is the parity authority: when adding or modifying a binding, check the `###` verb headings under `## Tracker operations` in that binding's `BINDING.md` against this list.

Conformance is convention only. There are no tests and no CI gate.

## Install-time setup hook

Bindings may ship an optional `setup` executable at `framework/bindings/<role>/<impl>/setup`. The installer invokes it once per selected `(role, impl)` pair — after binding selection and before product enumeration — with no positional arguments. The installer sets CWD to the consumer path before invocation, so the hook can write into the consumer tree via relative paths.

**Exit code contract:** 0 = success; non-zero = installer failure (stderr from the hook propagates).

**Idempotency requirement:** The hook must be idempotent — re-running the installer must produce no externally visible change beyond a clean exit. A hook that violates this is a binding bug.

Bindings without a `setup` file contribute no install-time setup; the installer skips silently.

**github-issues realization:** The github-issues binding ships `framework/bindings/issue-tracker/github-issues/setup`, which delegates to the sibling `bootstrap-labels` script. `bootstrap-labels` creates the static `formann:*` label namespace via `gh label create --force`, which is idempotent — re-running updates labels in place without error or duplication.

## Canonical verbs

### Read the issue

Read the full content of an issue: its metadata, body sections (title, what to build, acceptance criteria, blocked-by, agent brief, triage notes), and its comment timeline.

### Read the feature

Retrieve the parent feature's PRD body. When the parent carries a status label it is a work-item parent, not a PRD container; this verb returns empty. Skill prose stays unconditional; the empty result propagates naturally.

### List issues in a feature

Return the set of issues in a feature with their metadata (ref, nn, status, category, type, blocked-by). Includes the work-item parent (when present) and all sub-issues, in priority order.

### Set the state to `<state>`

Transition an issue to a new lifecycle state. Terminal states (`done`, `wontfix`) close the issue; non-terminal states keep it open. Re-running the same transition leaves the issue's final state unchanged (idempotent).

### Set issue metadata

Set the category, type, or blocked-by of an issue.

### Make issue runner-ready

Ensure an issue is discoverable and dispatchable by the runner before transitioning it to `ready-for-agent` or `ready-for-human`. The verb is idempotent — re-running on a fully-ready issue performs no writes.

### Publish the agent brief

Write (or replace) the agent brief for this issue. Body-shaped: re-publishing overwrites the prior brief; prior content is not preserved.

### Record triage notes

Write (or replace) the triage notes for this issue. Body-shaped: recording overwrites the prior notes. Used only on `needs-info` transitions; the section is removed when the issue leaves `needs-info`.

### Comment with `<kind>`

Append a comment to the issue's timeline. Timeline-shaped: append-only, history is preserved. The kind names the producing context — examples: `Implementation`, `Verification`, `Rework notes`, `Wontfix explanation`, `Post-mortem`, `Review (AFK gate)`, `Note`.

The comment's first line must be `### <Kind> — <YYYY-MM-DD>`. Same-day same-kind collisions append a numeric suffix: `### Implementation (2) — <YYYY-MM-DD>`, etc.

### Create a feature

Create a new feature: validate the slug, check for uniqueness, publish the parent artifact (issue or directory), and set up the feature branch.

**Inputs:** `slug` — must be unique across all features, open or closed. `title`, `body` (PRD content).

**Idempotency:** Not idempotent. Re-running creates a second feature.

### Create a standalone issue

Create a new issue with no parent feature. The issue enters at `needs-triage`.

**Inputs:** `slug` (optional), `title`, `body`, `category`, `type`.

**Idempotency:** Not idempotent. Re-running creates a second issue.

### Add an issue to slug X

Add a new issue under an existing feature. The issue enters at `needs-triage`.

**Inputs:** `slug` (X) — must match exactly one existing feature. `title`, `body`, `category`, `type`.

**Idempotency:** Not idempotent. Re-running creates a second issue under the same feature.

### Archive a feature

Close the feature and mark it as archived. Pre-condition: all issues in the feature must be in a terminal state (`done` or `wontfix`). Sub-issues remain in whatever state they had at archive time.

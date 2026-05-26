---
name: to-issues
description: Break a plan, spec, or PRD into independently-grabbable issues using tracer-bullet vertical slices, and publish them. Use when user wants to convert a plan into issues, create implementation tickets, or break down work into issues.
---

# To Issues

Break a plan into independently-grabbable issues using vertical slices (tracer bullets).

## Process

### 1. Gather context

Work from whatever is already in the conversation context. If the user passes an issue reference (issue number, URL, or path) as an argument, read the issue. Otherwise, the current git branch identifies the feature — look up its PRD in the tracker.

### 2. Explore the codebase (optional)

If you have not already explored the codebase, do so to understand the current state of the code. Issue titles and descriptions should use the project's domain glossary vocabulary, and respect ADRs in the area you're touching.

### 3. Draft vertical slices

Break the plan into **tracer bullet** issues. Each issue is a thin vertical slice that cuts through ALL integration layers end-to-end, NOT a horizontal slice of one layer.

Slices may be 'HITL' or 'AFK'. HITL slices require human interaction, such as an architectural decision or a design review. AFK slices can be implemented and merged without human interaction. Prefer AFK over HITL where possible.

<vertical-slice-rules>
- Each slice delivers a narrow but COMPLETE path through every layer (schema, API, UI, tests)
- A completed slice is demoable or verifiable on its own
- Prefer many thin slices over few thick ones
</vertical-slice-rules>

### 4. Quiz the user

Present the proposed breakdown as a numbered list. For each slice, show:

- **Title**: short descriptive name
- **Type** (provisional, triage decides): HITL / AFK
- **Blocked by**: which other slices (if any) must complete first
- **User stories covered**: which user stories this addresses (if the source material has them)

Ask the user:

- Does the granularity feel right? (too coarse / too fine)
- Are the dependency relationships correct?
- Should any slices be merged or split further?

Iterate until the user approves the breakdown.

### 5. Publish the issues

For each approved slice, write and publish a new issue per `docs/formann/issue-tracker/BINDING.md`, using the body template below. Set:

- state: `needs-triage` (every new issue enters the normal triage flow)
- category: `bug` or `enhancement`
- type: `AFK` or `HITL` (provisional; triage will confirm or flip it)

Publish issues in dependency order (blockers first) so you can reference real issue identifiers when setting each issue's blockers.

### Writing the Gist

Open every issue body with `## Gist`: 1–3 plain-English sentences for a colleague reading cold. The technical detail lives under `## What to build`; the Gist exists so a new teammate can grasp what's at stake before hitting it.

- Lead with the human-level problem or change, not the mechanism.
- Use shared vocabulary — the consumer's `GLOSSARY.md` terms are fair game. Code identifiers, paths, line numbers, label strings, and internal jargon are not.
- Prose. No bullets, no code spans, no "This issue…" / "We will…" boilerplate.
- A teammate reading only the Gist should be able to paraphrase what's wrong and what's changing. If they'd need to open the code first, rewrite it.

Worked example, same bug, two writeups:

> **Good:** When an upload fails partway through, the user sees "Success" but the file isn't saved. This surfaces the failure so the user can retry.
>
> **Bad:** `upload_handler` returns `nil` instead of an error tuple when `S3Client.put_object` raises, so the caller's `case` falls through to `:ok`.

<issue-body-template>
## Gist

1–3 plain-English sentences. See "Writing the Gist" above.

## What to build

A concise description of this vertical slice. Describe the end-to-end behavior, not layer-by-layer implementation.

## Acceptance criteria

- [ ] Criterion 1
- [ ] Criterion 2
- [ ] Criterion 3

</issue-body-template>

The active binding may require additional body sections; see its **Issue template** section in `docs/formann/issue-tracker/BINDING.md`.

Do NOT mutate any parent issue.

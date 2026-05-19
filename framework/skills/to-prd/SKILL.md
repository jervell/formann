---
name: to-prd
description: Turn the current conversation context into a PRD and publish it. Use when user wants to create a PRD from the current context.
---

This skill takes the current conversation context and codebase understanding and produces a PRD. Do NOT interview the user — just synthesize what you already know.

## Process

1. Explore the repo to understand the current state of the codebase, if you haven't already. Use the project's domain glossary vocabulary throughout the PRD, and respect any ADRs in the area you're touching.

2. Sketch out the major modules you will need to build or modify to complete the implementation. Actively look for opportunities to extract deep modules that can be tested in isolation.

A deep module (as opposed to a shallow module) is one which encapsulates a lot of functionality in a simple, testable interface which rarely changes.

Check with the user that these modules match their expectations. Check with the user which modules they want tests written for.

3. Pick a feature slug from the grilling context and confirm it with the maintainer.

4. Set up the feature workspace per `docs/formann/issue-tracker/BINDING.md`.

5. Write and publish the PRD using the template below; publish per `docs/formann/issue-tracker/BINDING.md`.

### Writing the Gist

Open the PRD with `## Gist`: 1–3 plain-English sentences for a colleague reading cold. The structured sections below carry the contract; the Gist exists so a new teammate can grasp what's at stake before hitting them.

- Lead with the human-level problem or change, not the mechanism.
- Use shared vocabulary — the consumer's `GLOSSARY.md` terms are fair game. Code identifiers, paths, line numbers, label strings, and internal jargon are not.
- Prose. No bullets, no code spans, no "This PRD…" / "We will…" boilerplate.
- A teammate reading only the Gist should be able to paraphrase what's wrong and what's changing. If they'd need to open the code first, rewrite it.

Worked example, same feature, two writeups:

> **Good:** Today every upload goes to one shared bucket, so a leaked credential exposes every tenant's files. This carves storage into per-tenant prefixes with their own access policies.
>
> **Bad:** `S3Uploader.put_object/3` uses a single `@bucket` module attribute; we'll thread a `tenant_id` through the call sites and key off `{tenant_id, bucket}` in `StorageRouter`.

<prd-template>

## Gist

1–3 plain-English sentences. See "Writing the Gist" above.

## Problem Statement

The problem that the user is facing, from the user's perspective.

## Solution

The solution to the problem, from the user's perspective.

## User Stories

A LONG, numbered list of user stories. Each user story should be in the format of:

1. As an <actor>, I want a <feature>, so that <benefit>

<user-story-example>
1. As a mobile bank customer, I want to see balance on my accounts, so that I can make better informed decisions about my spending
</user-story-example>

This list of user stories should be extremely extensive and cover all aspects of the feature.

## Implementation Decisions

A list of implementation decisions that were made. This can include:

- The modules that will be built/modified
- The interfaces of those modules that will be modified
- Technical clarifications from the developer
- Architectural decisions
- Schema changes
- API contracts
- Specific interactions

Do NOT include specific file paths or code snippets. They may end up being outdated very quickly.

## Testing Decisions

A list of testing decisions that were made. Include:

- A description of what makes a good test (only test external behavior, not implementation details)
- Which modules will be tested
- Prior art for the tests (i.e. similar types of tests in the codebase)

## Out of Scope

A description of the things that are out of scope for this PRD.

## Further Notes

Any further notes about the feature.

</prd-template>

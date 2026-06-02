---
name: audit-docs
description: Audits documentation files against the code they describe, reporting discrepancies grouped by severity (CRITICAL / IMPORTANT / MINOR). A deliberate, on-demand audit — not a passive consistency check.
when_to_use: Only on explicit /audit-docs invocation (directly by the user, or as an explicit instruction passed to a sub-agent). Do NOT auto-trigger from passive context — opening, reading, editing, or discussing documentation, reviewing diffs or PRs, or explaining how something works.
argument-hint: "<doc-path> [more-doc-paths...]"
allowed-tools: Read, Grep, Glob, Bash(git:*)
---

# Documentation vs. code audit

Audit these documents against the codebase: $ARGUMENTS

If no documents were specified, stop and report: "No documents to audit. Pass paths or @references as arguments."

The code and the documentation should be in agreement. Read the documents and the code they describe. Cross-check the documents against each other when more than one is given.

## Classification

### CRITICAL
- Direct lies: documentation that doesn't match the implementation.
- Internal inconsistencies: one part of a doc — or one doc vs. another — telling a different story.
- Logical errors or misbehavior in the code or documentation surfaced by the audit.

### IMPORTANT
- Verbose sections that could be expressed more clearly with fewer words.
- Ambiguous, complex, or muddled formulations that should be rewritten for clarity.

### MINOR
- Spelling errors.
- Grammatical errors.

## Output

Group findings by criticality (CRITICAL → IMPORTANT → MINOR). For each finding:
- Quote or paraphrase the relevant doc passage.
- Cite the doc location: `path/to/doc.md:line`.
- Cite the conflicting code location (or its absence): `path/to/code.ext:line`.
- Explain the discrepancy in one or two sentences. No essays.

If a tier has no findings, omit it. Don't write "(none)".

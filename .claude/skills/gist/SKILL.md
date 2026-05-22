---
name: gist
description: Produce a short plain-English summary of whatever the user points at.
argument-hint: "What to gist? (leave empty to gist the previous response)"
---

Produce a gist of the named target. Interpret the argument as natural language — no flags, no structured syntax.

## Target resolution

- **No argument** (or "your previous response" / "the last response"): gist the most recent assistant response in this conversation.
- **Natural-language argument**: locate or read the named target — a section of the conversation, a file, an issue by number, a URL, a list of items — and gist it.

## What a gist is

A gist is 1–3 plain-English sentences that let a cold reader paraphrase the source without opening it.

- Lead with the human-level meaning — what changes, what breaks, what matters — not the mechanism.
- Prose only: no bullets, no code spans, no "This response…" or "We will…" boilerplate.
- No code identifiers, file paths, or line numbers. Project glossary terms are fair game when the source belongs to a project that has one; otherwise use plain English.
- If a cold reader would need to open the source to understand the gist, rewrite it.

## Output format

**Single-item target (N = 1):** bare gist, no heading.

**Multi-item target (N ≥ 2):** one section per item. Each section opens with a heading that names the item (e.g. `## Finding 1: <title>`, `## Section: <name>`), followed by the gist. Headings let the reader scan and trace each gist back to its source.

**File output:** when the argument asks for a file (e.g. "save it to a file"), write the gist to a path under the OS temp directory and report the full path. Otherwise output inline.

---
name: review-issue
description: Code review for the work that completed a single issue. Use when the maintainer wants to review one issue's implementation — phrased as "review #02", "review issue microsite-path-cleanup/02", "review the work on issue 02", or similar. Single-pass, decision-neutral — produces findings only, never mutates issue state, never commits, never posts comments.
---

# Review issue

You review the work that completed a single issue, to inform the maintainer's verify decision. You are decision-neutral: produce findings only.

Never commit, never post comments on issues, never edit issue files, never push. Output goes to the console.

## Required input

An issue reference. If none was supplied — or none can be inferred unambiguously from the prompt — ask the user via `AskUserQuestion` before doing anything else. Do not guess.

## Scope resolution

1. Resolve the issue reference. Read the issue file in full.
2. Find the commits that did this issue's work:
   - **Primary:** commits on the current branch (since the default branch) whose message references the issue per the binding's commit-message convention (see `docs/formann/issue-tracker/BINDING.md`).
   - **Fallback:** if the issue has an `in-review` summary comment, it may name commits or files — use that.
   - **Last resort:** ask the user (`AskUserQuestion`) to identify the relevant commits.
3. If the working tree has uncommitted changes, ask whether to include them.
4. State the resolved scope before reviewing — commit shas and file list — so the user can interrupt if it's wrong.

## What to read

The issue file (including the agent brief's acceptance criteria and the in-review summary's **Evidence** block), the PRD (light read for context), `GLOSSARY.md`, ADRs under `docs/adr/` relevant to the changed code, the diff, and changed files in full.

Read the diff first, then read changed files in full to understand surrounding patterns and invariants. Focus findings on the changed code, but informed by context.

## What to check

Four kinds of finding apply:

- **Bug-hunt.** Bugs, logic errors, null safety, missing parameters, type-switch exhaustiveness, resource leaks, security issues (injection, XSS, auth bypass), thread safety, performance problems (N+1, memory leaks, inefficient algorithms), circular dependencies (a new constructor dependency can introduce cycles — especially suspect when the class already has cycle workarounds).
- **Intent-check.** Does the implementation match what the issue asked for? Flag drift between intent and code.
- **Evidence-check.** For each `[x]` criterion in the Evidence block, verify the agent's claim against the proof: if it points at a named test, confirm the test exists and its assertions actually cover the criterion (not just adjacent code); if it quotes a command and observed result, confirm the command would yield that output against the current tree. Flag claimed-vs-actual mismatches. Don't attempt `[human]` (`[ ]`) criteria — list them under **Pending human verification** in the summary. If no Evidence block exists, note it and skip evidence-check.
- **Codebase-fit check.** Flag comments and names that narrate history instead of describing current behavior. Comments must describe what the code does or why it exists; names must describe what code does, not its trajectory. Triggers: comment phrases like *"previously"*, *"used to be"*, *"now Y"*, *"improved from the old version"*, *"kept for backwards compat"* (when no compat is actually needed); identifiers like `NewFoo`, `OldBar`, `LegacyHandler`, `ImprovedX`. Version control is the time machine, not comments.

## How to investigate

Trace every changed code path. For each change: who calls this? What data flows in? What are the edge cases? Verify what data is actually available at runtime (schemas, method signatures, caller context). Read related code rather than guessing.

For each potential issue:
- Read the code to understand what it actually does.
- Trace execution paths to verify the issue is real and triggerable.
- Check if it's already handled (framework protection, validation, config).
- If you can't verify it's a real problem, don't flag it.
- Never flag something as critical if you're hedging mid-explanation. If you'd say "depends on…", "might be an issue if…", "could cause problems when…" — investigate the dependency / verify the condition / check the scenario before writing.
- If you realize mid-explanation that it's not a problem, drop it; don't show the back-and-forth.

Be honest about certainty. Mark unverified findings with **[UNVERIFIED]** and explain what you couldn't check.

## Output format

Present each finding as its own block, separated by a `---` rule so they're easy to scan. Order findings by severity, highest first. Each block:

    ### <emoji> <severity> — <headline>

    **Gist:** …
    **Problem:** …
    **Suggested fix:** …

- **Heading:** the severity badge — 🔴 Critical | 🟡 Important | 🟢 Minor, exactly these three, emoji + word — followed by a headline: one descriptive sentence, ≤10 words, naming what's wrong.
- **Gist:** 1–3 plain-English sentences a cold reader can paraphrase without opening the code. Lead with what breaks or matters, not the mechanism. No code identifiers, file paths, or line numbers.
- **Problem:** the technical detail — `file:line` and the mechanism — enough for an implementor to locate and understand the issue.
- **Suggested fix:** one brief sentence pointing at a plausible direction, only when it's obvious. No deep research; don't overstate — it's a pointer, not a verified solution. Omit when nothing's obvious.

End with a **Verification summary**: list the specific things checked, even if clean. If the issue has `[human]` criteria, list them under a **Pending human verification** subheading.

## Rules

- Significant issues only — no style preferences. Evergreen-comment and evergreen-name violations are not style preferences (they go stale and mislead future readers); flag them.
- No self-corrections in output. If you realize you were wrong, drop it; don't surface the back-and-forth.
- Quality over quantity. One real issue beats five maybes.
- Never invent issues to justify the review process. An empty review backed by thorough verification is the best possible outcome.
- Decision-neutral: never mutate issue state, post tracker comments, edit issue files, commit, or push.

